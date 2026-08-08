// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build linux

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/mdlayher/socket"
	"github.com/mdlayher/vsock"
	"golang.org/x/sys/unix"
)

const (
	reverseVsockRetryDelay   = 50 * time.Millisecond
	reverseVsockDialTimeout  = 250 * time.Millisecond
	reverseVsockPollInterval = 25 * time.Millisecond
)

// serviceVsockSocket is the non-blocking Linux VSOCK primitive used for the
// guest-initiated sealed-service connection.
type serviceVsockSocket interface {
	io.ReadWriteCloser
	SetDeadline(time.Time) error
	SetReadDeadline(time.Time) error
	SetWriteDeadline(time.Time) error
	SyscallConn() (syscall.RawConn, error)
	Getsockname() (unix.Sockaddr, error)
}

type serviceVsockSocketOpener func() (serviceVsockSocket, error)

// serviceVsockOperations keeps the kernel boundary narrow and makes the
// completion semantics deterministic under focused tests.
type serviceVsockOperations struct {
	connect     func(int, unix.Sockaddr) error
	poll        func([]unix.PollFd, int) (int, error)
	socketError func(int, int, int) (int, error)
}

var defaultServiceVsockOperations = serviceVsockOperations{
	connect:     unix.Connect,
	poll:        unix.Poll,
	socketError: unix.GetsockoptInt,
}

// reverseVsockListener presents guest-initiated host VSOCK connections as a
// normal listener. It keeps at most one pending connection so a long-lived
// service cannot fill the host listener before a logging client asks for it.
type reverseVsockListener struct {
	port              uint32
	dial              serviceVsockDialer
	reportDialFailure func(error)

	closed    chan struct{}
	permits   chan struct{}
	closeOnce sync.Once

	activeMu sync.Mutex
	active   net.Conn
}

func newReverseVsockListener(port uint32, dial serviceVsockDialer) *reverseVsockListener {
	return newReverseVsockListenerWithReporter(port, dial, nil)
}

func newReverseVsockListenerWithReporter(
	port uint32,
	dial serviceVsockDialer,
	reportDialFailure func(error),
) *reverseVsockListener {
	if reportDialFailure == nil {
		reportDialFailure = func(error) {}
	}
	listener := &reverseVsockListener{
		port:              port,
		dial:              dial,
		reportDialFailure: reportDialFailure,
		closed:            make(chan struct{}),
		permits:           make(chan struct{}, 1),
	}
	listener.permits <- struct{}{}
	return listener
}

func (listener *reverseVsockListener) Accept() (net.Conn, error) {
	select {
	case <-listener.closed:
		return nil, net.ErrClosed
	case <-listener.permits:
	}

	connection, err := listener.dialUntilClosed()
	if err != nil {
		return nil, err
	}
	wrapped := &reverseVsockConnection{Conn: connection}
	wrapped.release = func() {
		listener.release(wrapped)
	}
	listener.activeMu.Lock()
	select {
	case <-listener.closed:
		listener.activeMu.Unlock()
		_ = wrapped.Close()
		return nil, net.ErrClosed
	default:
		listener.active = wrapped
		listener.activeMu.Unlock()
	}
	return wrapped, nil
}

func (listener *reverseVsockListener) Close() error {
	listener.closeOnce.Do(func() {
		close(listener.closed)
		listener.activeMu.Lock()
		active := listener.active
		listener.active = nil
		listener.activeMu.Unlock()
		if active != nil {
			_ = active.Close()
		}
	})
	return nil
}

func (listener *reverseVsockListener) Addr() net.Addr {
	return &vsock.Addr{ContextID: vsock.Host, Port: listener.port}
}

func (listener *reverseVsockListener) dialUntilClosed() (net.Conn, error) {
	dialContext, cancelDial := context.WithCancel(context.Background())
	dialDone := make(chan struct{})
	go func() {
		select {
		case <-listener.closed:
			cancelDial()
		case <-dialDone:
		}
	}()
	defer func() {
		close(dialDone)
		cancelDial()
	}()

	reportedFailure := false
	for {
		attemptContext, cancelAttempt := context.WithTimeout(dialContext, reverseVsockDialTimeout)
		connection, err := listener.dial(attemptContext, vsock.Host, listener.port)
		cancelAttempt()
		if err == nil {
			return connection, nil
		}
		if dialContext.Err() != nil {
			return nil, net.ErrClosed
		}
		if !reportedFailure {
			listener.reportDialFailure(err)
			reportedFailure = true
		}
		select {
		case <-listener.closed:
			return nil, net.ErrClosed
		case <-time.After(reverseVsockRetryDelay):
		}
	}
}

// dialHostVsock uses the socket package directly because vsock.Dial in the
// pinned dependency always uses context.Background and its Connect path waits
// for getpeername after SO_ERROR reports a completed VSOCK connection. The
// Virtualization guest can leave getpeername pending there, so complete the
// non-blocking connect from SO_ERROR and keep the poll bounded by ctx.
func dialHostVsock(ctx context.Context, contextID uint32, port uint32) (net.Conn, error) {
	return dialHostVsockWith(ctx, contextID, port, func() (serviceVsockSocket, error) {
		return socket.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0, "container-gelf-service", nil)
	})
}

func dialHostVsockWith(
	ctx context.Context,
	contextID uint32,
	port uint32,
	openSocket serviceVsockSocketOpener,
) (net.Conn, error) {
	return dialHostVsockWithOperations(
		ctx,
		contextID,
		port,
		openSocket,
		defaultServiceVsockOperations,
	)
}

func dialHostVsockWithOperations(
	ctx context.Context,
	contextID uint32,
	port uint32,
	openSocket serviceVsockSocketOpener,
	operations serviceVsockOperations,
) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	connection, err := openSocket()
	if err != nil {
		return nil, err
	}
	closeConnection := true
	defer func() {
		if closeConnection {
			_ = connection.Close()
		}
	}()

	if err := connectServiceVsock(
		ctx,
		connection,
		&unix.SockaddrVM{CID: contextID, Port: port},
		operations,
	); err != nil {
		return nil, err
	}
	localAddress, err := connection.Getsockname()
	if err != nil {
		return nil, err
	}
	localVsockAddress, ok := localAddress.(*unix.SockaddrVM)
	if !ok {
		return nil, fmt.Errorf("sealed host VSOCK dial returned local address %T, want *unix.SockaddrVM", localAddress)
	}

	closeConnection = false
	return &serviceVsockConnection{
		serviceVsockSocket: connection,
		local: &vsock.Addr{
			ContextID: localVsockAddress.CID,
			Port:      localVsockAddress.Port,
		},
		remote: &vsock.Addr{ContextID: contextID, Port: port},
	}, nil
}

func connectServiceVsock(
	ctx context.Context,
	connection serviceVsockSocket,
	address unix.Sockaddr,
	operations serviceVsockOperations,
) error {
	rawConnection, err := connection.SyscallConn()
	if err != nil {
		return err
	}

	var connectErr error
	if err := rawConnection.Control(func(fd uintptr) {
		connectErr = operations.connect(int(fd), address)
	}); err != nil {
		return err
	}
	switch {
	case connectErr == nil || errors.Is(connectErr, unix.EISCONN):
		return nil
	case errors.Is(connectErr, unix.EAGAIN),
		errors.Is(connectErr, unix.EALREADY),
		errors.Is(connectErr, unix.EINPROGRESS),
		errors.Is(connectErr, unix.EINTR):
		return waitForServiceVsockConnect(ctx, rawConnection, operations)
	default:
		return os.NewSyscallError("connect", connectErr)
	}
}

func waitForServiceVsockConnect(
	ctx context.Context,
	rawConnection syscall.RawConn,
	operations serviceVsockOperations,
) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		fds := []unix.PollFd{{Events: unix.POLLOUT | unix.POLLERR | unix.POLLHUP}}
		var (
			ready   int
			pollErr error
		)
		if err := rawConnection.Control(func(fd uintptr) {
			fds[0].Fd = int32(fd)
			ready, pollErr = operations.poll(fds, serviceVsockPollTimeout(ctx))
		}); err != nil {
			return err
		}
		if pollErr != nil {
			if errors.Is(pollErr, unix.EINTR) {
				continue
			}
			return os.NewSyscallError("poll", pollErr)
		}
		if ready == 0 {
			continue
		}
		if fds[0].Revents&unix.POLLNVAL != 0 {
			return os.NewSyscallError("poll", unix.EBADF)
		}

		var socketErr int
		if err := rawConnection.Control(func(fd uintptr) {
			socketErr, pollErr = operations.socketError(int(fd), unix.SOL_SOCKET, unix.SO_ERROR)
		}); err != nil {
			return err
		}
		if pollErr != nil {
			return os.NewSyscallError("getsockopt", pollErr)
		}
		if socketErr != 0 {
			return os.NewSyscallError("connect", unix.Errno(socketErr))
		}

		// A completed VSOCK connection must be writable without a terminal poll
		// event. SO_ERROR alone is not enough: a peer teardown can report zero
		// after the kernel has consumed its pending error. Do not call
		// getpeername here; VZ guests can leave that query pending after the
		// connection is usable, which defeats the caller's deadline.
		if fds[0].Revents&unix.POLLOUT != 0 &&
			fds[0].Revents&(unix.POLLERR|unix.POLLHUP) == 0 {
			return nil
		}
		if fds[0].Revents&(unix.POLLERR|unix.POLLHUP) != 0 {
			return os.NewSyscallError("connect", unix.ECONNRESET)
		}
	}
}

func serviceVsockPollTimeout(ctx context.Context) int {
	timeout := reverseVsockPollInterval
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return 0
		}
		if remaining < timeout {
			timeout = remaining
		}
	}
	return max(1, int((timeout+time.Millisecond-1)/time.Millisecond))
}

// serviceVsockConnection adds the net.Conn address accessors that the low-level
// context-aware socket primitive intentionally does not expose.
type serviceVsockConnection struct {
	serviceVsockSocket
	local  net.Addr
	remote net.Addr
}

func (connection *serviceVsockConnection) LocalAddr() net.Addr { return connection.local }

func (connection *serviceVsockConnection) RemoteAddr() net.Addr { return connection.remote }

func (listener *reverseVsockListener) release(connection net.Conn) {
	listener.activeMu.Lock()
	if listener.active != connection {
		listener.activeMu.Unlock()
		return
	}
	listener.active = nil
	listener.activeMu.Unlock()
	select {
	case <-listener.closed:
		return
	default:
	}
	select {
	case listener.permits <- struct{}{}:
	default:
	}
}

type reverseVsockConnection struct {
	net.Conn
	release func()
	once    sync.Once
}

func (connection *reverseVsockConnection) Close() error {
	err := connection.Conn.Close()
	connection.once.Do(connection.release)
	return err
}

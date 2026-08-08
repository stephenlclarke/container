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
	"net"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/mdlayher/vsock"
	"golang.org/x/sys/unix"
)

type fakeServiceVsockSocket struct {
	net.Conn
	getsockname func() (unix.Sockaddr, error)
	raw         syscall.RawConn
	closed      atomic.Int32
}

func (socket *fakeServiceVsockSocket) Close() error {
	socket.closed.Add(1)
	return socket.Conn.Close()
}

func (socket *fakeServiceVsockSocket) SyscallConn() (syscall.RawConn, error) { return socket.raw, nil }

func (socket *fakeServiceVsockSocket) Getsockname() (unix.Sockaddr, error) {
	return socket.getsockname()
}

type fakeServiceVsockRawConn struct {
	fd         uintptr
	controlErr error
}

func (connection fakeServiceVsockRawConn) Control(fn func(uintptr)) error {
	if connection.controlErr != nil {
		return connection.controlErr
	}
	fn(connection.fd)
	return nil
}

func (fakeServiceVsockRawConn) Read(func(uintptr) bool) error {
	return errors.New("unexpected raw VSOCK read")
}

func (fakeServiceVsockRawConn) Write(func(uintptr) bool) error {
	return errors.New("unexpected raw VSOCK write")
}

func TestReverseVsockListenerDialsHostAndLimitsPendingConnections(t *testing.T) {
	var calls atomic.Int32
	var receivedContextID atomic.Uint32
	var receivedPort atomic.Uint32
	peers := make(chan net.Conn, 2)
	listener := newReverseVsockListener(21000, func(_ context.Context, contextID uint32, port uint32) (net.Conn, error) {
		receivedContextID.Store(contextID)
		receivedPort.Store(port)
		calls.Add(1)
		server, client := net.Pipe()
		peers <- server
		return client, nil
	})
	defer listener.Close()

	first, err := listener.Accept()
	if err != nil {
		t.Fatalf("accept first reverse connection: %v", err)
	}
	defer first.Close()
	if calls.Load() != 1 {
		t.Fatalf("reverse dial count = %d, want 1", calls.Load())
	}
	if receivedContextID.Load() != vsock.Host || receivedPort.Load() != 21000 {
		t.Fatalf(
			"reverse VSOCK dial = (%d, %d)",
			receivedContextID.Load(),
			receivedPort.Load(),
		)
	}

	type accepted struct {
		connection net.Conn
		err        error
	}
	secondResult := make(chan accepted, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		secondResult <- accepted{connection: connection, err: acceptErr}
	}()
	select {
	case result := <-secondResult:
		if result.connection != nil {
			_ = result.connection.Close()
		}
		t.Fatalf("second reverse connection arrived before first closed: %v", result.err)
	case <-time.After(2 * reverseVsockRetryDelay):
	}
	if calls.Load() != 1 {
		t.Fatalf("reverse dial count while first active = %d, want 1", calls.Load())
	}

	if err := first.Close(); err != nil {
		t.Fatalf("close first reverse connection: %v", err)
	}
	select {
	case result := <-secondResult:
		if result.err != nil {
			t.Fatalf("accept second reverse connection: %v", result.err)
		}
		defer result.connection.Close()
	case <-time.After(time.Second):
		t.Fatal("second reverse connection did not arrive after first closed")
	}
	if calls.Load() != 2 {
		t.Fatalf("reverse dial count = %d, want 2", calls.Load())
	}
	for len(peers) > 0 {
		_ = (<-peers).Close()
	}
}

func TestReverseVsockListenerCloseUnblocksAConnectingAccept(t *testing.T) {
	attempted := make(chan struct{}, 1)
	listener := newReverseVsockListener(21000, func(context.Context, uint32, uint32) (net.Conn, error) {
		select {
		case attempted <- struct{}{}:
		default:
		}
		return nil, errors.New("host listener is not ready")
	})
	done := make(chan error, 1)
	go func() {
		_, err := listener.Accept()
		done <- err
	}()
	select {
	case <-attempted:
	case <-time.After(time.Second):
		_ = listener.Close()
		t.Fatal("reverse listener did not attempt its host dial")
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close reverse listener: %v", err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("closed reverse listener accept error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("closing reverse listener did not unblock accept")
	}
}

func TestReverseVsockListenerReportsOnlyItsFirstDialFailureBeforeConnecting(t *testing.T) {
	wantFailure := errors.New("host listener is not ready")
	var calls atomic.Int32
	reports := make(chan error, 2)
	peers := make(chan net.Conn, 1)
	listener := newReverseVsockListenerWithReporter(
		21000,
		func(context.Context, uint32, uint32) (net.Conn, error) {
			if calls.Add(1) <= 2 {
				return nil, wantFailure
			}
			server, client := net.Pipe()
			peers <- server
			return client, nil
		},
		func(err error) { reports <- err },
	)
	defer listener.Close()

	connection, err := listener.Accept()
	if err != nil {
		t.Fatalf("accept reverse connection after retry: %v", err)
	}
	defer connection.Close()
	defer func() { _ = (<-peers).Close() }()

	select {
	case report := <-reports:
		if !errors.Is(report, wantFailure) {
			t.Fatalf("dial failure report = %v, want %v", report, wantFailure)
		}
	case <-time.After(time.Second):
		t.Fatal("reverse listener did not report its first failed dial")
	}
	select {
	case extra := <-reports:
		t.Fatalf("reverse listener reported a repeated dial failure: %v", extra)
	case <-time.After(2 * reverseVsockRetryDelay):
	}
}

func TestReverseVsockListenerReportsHostAddressAndRejectsAcceptAfterClose(t *testing.T) {
	listener := newReverseVsockListener(21000, func(context.Context, uint32, uint32) (net.Conn, error) {
		return nil, errors.New("reverse dial should not run after close")
	})
	address, ok := listener.Addr().(*vsock.Addr)
	if !ok || address.ContextID != vsock.Host || address.Port != 21000 {
		t.Fatalf("reverse listener address = %#v", listener.Addr())
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close reverse listener: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("repeat close reverse listener: %v", err)
	}
	if _, err := listener.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("closed reverse listener accept error = %v", err)
	}
}

func TestReverseVsockListenerCloseCancelsAnInFlightDial(t *testing.T) {
	dialStarted := make(chan struct{})
	dialCancelled := make(chan error, 1)
	listener := newReverseVsockListener(21000, func(ctx context.Context, _ uint32, _ uint32) (net.Conn, error) {
		close(dialStarted)
		<-ctx.Done()
		dialCancelled <- ctx.Err()
		return nil, ctx.Err()
	})
	done := make(chan error, 1)
	go func() {
		_, err := listener.Accept()
		done <- err
	}()
	select {
	case <-dialStarted:
	case <-time.After(time.Second):
		_ = listener.Close()
		t.Fatal("reverse listener did not start its VSOCK dial")
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close reverse listener: %v", err)
	}
	select {
	case err := <-dialCancelled:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled reverse dial error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("close did not cancel the in-flight reverse VSOCK dial")
	}
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("closed reverse listener accept error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("close did not unblock reverse listener accept")
	}
}

func TestDialHostVsockWithOperationsBuildsAConnectionAfterWritableSOErrorZero(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	var dialAddress *unix.SockaddrVM
	var polls atomic.Int32
	socket := &fakeServiceVsockSocket{
		Conn: client,
		raw:  fakeServiceVsockRawConn{fd: 42},
		getsockname: func() (unix.Sockaddr, error) {
			return &unix.SockaddrVM{CID: 17, Port: 23000}, nil
		},
	}
	operations := serviceVsockOperations{
		connect: func(fd int, address unix.Sockaddr) error {
			if fd != 42 {
				t.Fatalf("VSOCK connect fd = %d, want 42", fd)
			}
			var ok bool
			dialAddress, ok = address.(*unix.SockaddrVM)
			if !ok {
				t.Fatalf("VSOCK connect address = %T, want *unix.SockaddrVM", address)
			}
			return unix.EINPROGRESS
		},
		poll: func(fds []unix.PollFd, timeout int) (int, error) {
			if timeout < 1 || timeout > int(reverseVsockPollInterval/time.Millisecond) {
				t.Fatalf("VSOCK poll timeout = %dms", timeout)
			}
			if len(fds) != 1 || fds[0].Fd != 42 || fds[0].Events&unix.POLLOUT == 0 {
				t.Fatalf("VSOCK poll fds = %#v", fds)
			}
			polls.Add(1)
			fds[0].Revents = unix.POLLOUT
			return 1, nil
		},
		socketError: func(fd, level, option int) (int, error) {
			if fd != 42 || level != unix.SOL_SOCKET || option != unix.SO_ERROR {
				t.Fatalf("VSOCK socket-error query = (%d, %d, %d)", fd, level, option)
			}
			return 0, nil
		},
	}
	connection, err := dialHostVsockWithOperations(
		context.Background(),
		vsock.Host,
		21000,
		func() (serviceVsockSocket, error) { return socket, nil },
		operations,
	)
	if err != nil {
		t.Fatalf("dial sealed host VSOCK: %v", err)
	}
	if dialAddress == nil || dialAddress.CID != vsock.Host || dialAddress.Port != 21000 {
		t.Fatalf("VSOCK dial address = %#v", dialAddress)
	}
	if polls.Load() != 1 {
		t.Fatalf("VSOCK poll count = %d, want 1", polls.Load())
	}
	local, ok := connection.LocalAddr().(*vsock.Addr)
	if !ok || local.ContextID != 17 || local.Port != 23000 {
		t.Fatalf("local VSOCK address = %#v", connection.LocalAddr())
	}
	remote, ok := connection.RemoteAddr().(*vsock.Addr)
	if !ok || remote.ContextID != vsock.Host || remote.Port != 21000 {
		t.Fatalf("remote VSOCK address = %#v", connection.RemoteAddr())
	}
	if socket.closed.Load() != 0 {
		t.Fatalf("successful VSOCK socket closed %d times before connection close", socket.closed.Load())
	}
	if err := connection.Close(); err != nil {
		t.Fatalf("close VSOCK connection: %v", err)
	}
	if socket.closed.Load() != 1 {
		t.Fatalf("successful VSOCK socket closed %d times, want 1", socket.closed.Load())
	}
}

func TestDialHostVsockWithOperationsClosesFailedSocketAndPropagatesFailure(t *testing.T) {
	wantConnectError := errors.New("connect failed")
	wantSocketNameError := errors.New("getsockname failed")
	for _, test := range []struct {
		name        string
		controlErr  error
		connectErr  error
		poll        func([]unix.PollFd, int) (int, error)
		socketError func(int, int, int) (int, error)
		getsockname func() (unix.Sockaddr, error)
		want        error
	}{
		{
			name:       "connect failure",
			connectErr: wantConnectError,
			getsockname: func() (unix.Sockaddr, error) {
				return nil, nil
			},
			want: wantConnectError,
		},
		{
			name:       "raw connection control failure",
			controlErr: wantConnectError,
			getsockname: func() (unix.Sockaddr, error) {
				return nil, nil
			},
			want: wantConnectError,
		},
		{
			name:       "socket error after writable poll",
			connectErr: unix.EINPROGRESS,
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				fds[0].Revents = unix.POLLERR
				return 1, nil
			},
			socketError: func(int, int, int) (int, error) { return int(unix.ECONNREFUSED), nil },
			getsockname: func() (unix.Sockaddr, error) {
				return nil, nil
			},
			want: unix.ECONNREFUSED,
		},
		{
			name:       "getsockname failure",
			connectErr: nil,
			getsockname: func() (unix.Sockaddr, error) {
				return nil, wantSocketNameError
			},
			want: wantSocketNameError,
		},
		{
			name:       "non VSOCK local address",
			connectErr: nil,
			getsockname: func() (unix.Sockaddr, error) {
				return &unix.SockaddrUnix{Name: "/run/not-vsock.sock"}, nil
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			server, client := net.Pipe()
			defer server.Close()
			socket := &fakeServiceVsockSocket{
				Conn:        client,
				raw:         fakeServiceVsockRawConn{fd: 42, controlErr: test.controlErr},
				getsockname: test.getsockname,
			}
			operations := serviceVsockOperations{
				connect: func(int, unix.Sockaddr) error { return test.connectErr },
				poll: func(fds []unix.PollFd, timeout int) (int, error) {
					if test.poll == nil {
						t.Fatalf("unexpected VSOCK poll with timeout %d", timeout)
					}
					return test.poll(fds, timeout)
				},
				socketError: func(fd, level, option int) (int, error) {
					if test.socketError == nil {
						t.Fatalf("unexpected VSOCK socket-error query = (%d, %d, %d)", fd, level, option)
					}
					return test.socketError(fd, level, option)
				},
			}
			connection, err := dialHostVsockWithOperations(
				context.Background(),
				vsock.Host,
				21000,
				func() (serviceVsockSocket, error) { return socket, nil },
				operations,
			)
			if connection != nil {
				_ = connection.Close()
				t.Fatal("failed VSOCK dial returned a connection")
			}
			if err == nil {
				t.Fatal("failed VSOCK dial returned nil error")
			}
			if test.want != nil && !errors.Is(err, test.want) {
				t.Fatalf("VSOCK dial error = %v, want %v", err, test.want)
			}
			if socket.closed.Load() != 1 {
				t.Fatalf("failed VSOCK socket closed %d times, want 1", socket.closed.Load())
			}
		})
	}

	wantOpenError := errors.New("socket open failed")
	connection, err := dialHostVsockWithOperations(
		context.Background(),
		vsock.Host,
		21000,
		func() (serviceVsockSocket, error) { return nil, wantOpenError },
		defaultServiceVsockOperations,
	)
	if connection != nil || !errors.Is(err, wantOpenError) {
		t.Fatalf("socket open failure = connection %v, error %v", connection, err)
	}
}

func TestDialHostVsockWithOperationsStopsWhenTheContextIsCancelled(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	socket := &fakeServiceVsockSocket{
		Conn: client,
		raw:  fakeServiceVsockRawConn{fd: 42},
		getsockname: func() (unix.Sockaddr, error) {
			return nil, errors.New("getsockname must not run after cancellation")
		},
	}
	connection, err := dialHostVsockWithOperations(
		ctx,
		vsock.Host,
		21000,
		func() (serviceVsockSocket, error) { return socket, nil },
		serviceVsockOperations{
			connect: func(int, unix.Sockaddr) error { return unix.EINPROGRESS },
			poll: func([]unix.PollFd, int) (int, error) {
				cancel()
				return 0, nil
			},
			socketError: func(int, int, int) (int, error) {
				t.Fatal("VSOCK socket-error query ran without a poll event")
				return 0, nil
			},
		},
	)
	if connection != nil {
		_ = connection.Close()
		t.Fatal("cancelled VSOCK dial returned a connection")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled VSOCK dial error = %v, want context.Canceled", err)
	}
	if socket.closed.Load() != 1 {
		t.Fatalf("cancelled VSOCK socket closed %d times, want 1", socket.closed.Load())
	}
}

func TestDialHostVsockWithOperationsHonorsAnAlreadyCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	opened := false
	connection, err := dialHostVsockWithOperations(
		ctx,
		vsock.Host,
		21000,
		func() (serviceVsockSocket, error) {
			opened = true
			return nil, errors.New("cancelled VSOCK dial opened a socket")
		},
		defaultServiceVsockOperations,
	)
	if connection != nil {
		_ = connection.Close()
		t.Fatal("cancelled VSOCK dial returned a connection")
	}
	if !errors.Is(err, context.Canceled) || opened {
		t.Fatalf("cancelled VSOCK dial = connection %v, error %v, opened %t", connection, err, opened)
	}
}

func TestDialHostVsockHonorsAnAlreadyCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	connection, err := dialHostVsock(ctx, vsock.Host, 21000)
	if connection != nil {
		_ = connection.Close()
		t.Fatal("cancelled host VSOCK dial returned a connection")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled host VSOCK dial error = %v, want context.Canceled", err)
	}
}

func TestWaitForServiceVsockConnectRetriesAnInterruptedPoll(t *testing.T) {
	var polls atomic.Int32
	err := waitForServiceVsockConnect(
		context.Background(),
		fakeServiceVsockRawConn{fd: 42},
		serviceVsockOperations{
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				if polls.Add(1) == 1 {
					return 0, unix.EINTR
				}
				fds[0].Revents = unix.POLLOUT
				return 1, nil
			},
			socketError: func(fd, level, option int) (int, error) {
				if fd != 42 || level != unix.SOL_SOCKET || option != unix.SO_ERROR {
					t.Fatalf("VSOCK socket-error query = (%d, %d, %d)", fd, level, option)
				}
				return 0, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("interrupted VSOCK poll did not retry: %v", err)
	}
	if polls.Load() != 2 {
		t.Fatalf("VSOCK poll count = %d, want 2", polls.Load())
	}
}

func TestWaitForServiceVsockConnectReportsKernelFailures(t *testing.T) {
	wantPollError := errors.New("poll failed")
	wantSocketError := errors.New("socket-error query failed")
	for _, test := range []struct {
		name        string
		poll        func([]unix.PollFd, int) (int, error)
		socketError func(int, int, int) (int, error)
		want        error
	}{
		{
			name: "poll failure",
			poll: func([]unix.PollFd, int) (int, error) {
				return 0, wantPollError
			},
			socketError: func(int, int, int) (int, error) {
				t.Fatal("socket-error query ran after a failed VSOCK poll")
				return 0, nil
			},
			want: wantPollError,
		},
		{
			name: "invalid poll descriptor",
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				fds[0].Revents = unix.POLLNVAL
				return 1, nil
			},
			socketError: func(int, int, int) (int, error) {
				t.Fatal("socket-error query ran after an invalid VSOCK poll descriptor")
				return 0, nil
			},
			want: unix.EBADF,
		},
		{
			name: "socket-error query failure",
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				fds[0].Revents = unix.POLLERR
				return 1, nil
			},
			socketError: func(int, int, int) (int, error) {
				return 0, wantSocketError
			},
			want: wantSocketError,
		},
		{
			name: "hung up connection with consumed socket error",
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				fds[0].Revents = unix.POLLHUP
				return 1, nil
			},
			socketError: func(int, int, int) (int, error) { return 0, nil },
			want:        unix.ECONNRESET,
		},
		{
			name: "writable event accompanied by hangup",
			poll: func(fds []unix.PollFd, _ int) (int, error) {
				fds[0].Revents = unix.POLLOUT | unix.POLLHUP
				return 1, nil
			},
			socketError: func(int, int, int) (int, error) { return 0, nil },
			want:        unix.ECONNRESET,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := waitForServiceVsockConnect(
				context.Background(),
				fakeServiceVsockRawConn{fd: 42},
				serviceVsockOperations{poll: test.poll, socketError: test.socketError},
			)
			if !errors.Is(err, test.want) {
				t.Fatalf("VSOCK wait error = %v, want %v", err, test.want)
			}
		})
	}
}

func TestServiceVsockPollTimeoutUsesTheContextBudget(t *testing.T) {
	if got, want := serviceVsockPollTimeout(context.Background()), int(reverseVsockPollInterval/time.Millisecond); got != want {
		t.Fatalf("default VSOCK poll timeout = %dms, want %dms", got, want)
	}

	expiredContext, cancelExpired := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancelExpired()
	if got := serviceVsockPollTimeout(expiredContext); got != 0 {
		t.Fatalf("expired VSOCK poll timeout = %dms, want 0ms", got)
	}

	shortContext, cancelShort := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancelShort()
	if got := serviceVsockPollTimeout(shortContext); got < 1 || got > 10 {
		t.Fatalf("short VSOCK poll timeout = %dms, want 1ms through 10ms", got)
	}
}

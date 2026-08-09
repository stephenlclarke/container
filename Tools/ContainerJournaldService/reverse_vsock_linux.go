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

//go:build linux && cgo

package main

import (
	"net"
	"sync"
	"time"

	"github.com/mdlayher/vsock"
)

const reverseVsockRetryDelay = 50 * time.Millisecond

// reverseVsockListener presents guest-initiated host VSOCK connections as a
// normal listener. It keeps at most one pending connection so a long-lived
// service cannot fill the host listener before a logging client asks for it.
type reverseVsockListener struct {
	port uint32
	dial serviceVsockDialer

	closed    chan struct{}
	permits   chan struct{}
	closeOnce sync.Once

	activeMu sync.Mutex
	active   net.Conn
}

func newReverseVsockListener(port uint32, dial serviceVsockDialer) *reverseVsockListener {
	listener := &reverseVsockListener{
		port:    port,
		dial:    dial,
		closed:  make(chan struct{}),
		permits: make(chan struct{}, 1),
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
	for {
		connection, err := listener.dial(vsock.Host, listener.port)
		if err == nil {
			return connection, nil
		}
		select {
		case <-listener.closed:
			return nil, net.ErrClosed
		case <-time.After(reverseVsockRetryDelay):
		}
	}
}

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

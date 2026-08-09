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
	"net"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// connectionOperationContext interrupts a blocking journal read when its
// one-in-flight request connection disappears. Readable data is also treated
// as cancellation because request pipelining is outside the v1 protocol.
func connectionOperationContext(parent context.Context, connection net.Conn) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	syscallConnection, ok := connection.(syscall.Conn)
	if !ok {
		return ctx, cancel
	}
	rawConnection, err := syscallConnection.SyscallConn()
	if err != nil {
		return ctx, cancel
	}
	var descriptor int32 = -1
	if err := rawConnection.Control(func(fd uintptr) {
		descriptor = int32(fd)
	}); err != nil || descriptor < 0 {
		return ctx, cancel
	}
	var wakeDescriptors [2]int
	if err := unix.Pipe2(wakeDescriptors[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return ctx, cancel
	}
	var finishOnce sync.Once
	stop := func() {
		finishOnce.Do(func() {
			cancel()
			_, _ = unix.Write(wakeDescriptors[1], []byte{1})
		})
	}
	go func() {
		defer unix.Close(wakeDescriptors[0])
		defer unix.Close(wakeDescriptors[1])
		pollDescriptors := []unix.PollFd{
			{
				Fd:     descriptor,
				Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLRDHUP,
			},
			{Fd: int32(wakeDescriptors[0]), Events: unix.POLLIN},
		}
		for {
			count, pollError := unix.Poll(pollDescriptors, -1)
			if pollError == unix.EINTR {
				continue
			}
			if pollError != nil {
				finishOnce.Do(cancel)
				return
			}
			if count > 0 {
				if pollDescriptors[0].Revents != 0 {
					finishOnce.Do(cancel)
				}
				return
			}
		}
	}()
	return ctx, stop
}

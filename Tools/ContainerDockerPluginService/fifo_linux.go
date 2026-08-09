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
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"

	"golang.org/x/sys/unix"
)

const fifoPollIntervalMilliseconds = 100

type linuxFIFOFactory struct {
	root string
}

func newLinuxFIFOFactory(root string) (*linuxFIFOFactory, error) {
	path := filepath.Clean(root)
	if !filepath.IsAbs(path) || path == string(filepath.Separator) {
		return nil, errors.New("unsafe FIFO root")
	}
	if err := ensurePrivateDirectory(path); err != nil {
		return nil, err
	}
	return &linuxFIFOFactory{root: path}, nil
}

func (factory *linuxFIFOFactory) Open(sessionID string, providerGeneration uint64) (fifoHandle, error) {
	if !validIdentifier(sessionID) || providerGeneration == 0 {
		return nil, errInvalidFence
	}
	name := fmt.Sprintf(
		"%x.fifo",
		sha256.Sum256([]byte(fmt.Sprintf("%d\x00%s", providerGeneration, sessionID))),
	)
	path := filepath.Join(factory.root, name)
	if err := unix.Mkfifo(path, 0o700); err != nil && !errors.Is(err, syscall.EEXIST) {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeNamedPipe == 0 || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("FIFO path is not a protected named pipe")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return nil, err
	}
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("cannot own FIFO descriptor")
	}
	return &linuxFIFO{path: path, file: file}, nil
}

func ensurePrivateDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if err := rejectSymlinkComponents(path); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("FIFO root is not a protected directory")
	}
	return ensurePrivateDirectoryMode(path)
}

type linuxFIFO struct {
	path    string
	file    *os.File
	revoked atomic.Bool
}

func (fifo *linuxFIFO) Path() string {
	return fifo.path
}

func (fifo *linuxFIFO) Write(ctx context.Context, frame []byte) error {
	if len(frame) == 0 || len(frame) > maximumLogFrameBytes {
		return errors.New("invalid log frame")
	}
	if fifo.revoked.Load() {
		return errInvalidFence
	}
	remaining := frame
	for len(remaining) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		if fifo.revoked.Load() {
			return errInvalidFence
		}
		written, err := unix.Write(int(fifo.file.Fd()), remaining)
		if written > 0 {
			remaining = remaining[written:]
			continue
		}
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EWOULDBLOCK) {
			if err := fifo.waitWritable(ctx); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		return errors.New("FIFO write made no progress")
	}
	return nil
}

func (fifo *linuxFIFO) waitWritable(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		poll := []unix.PollFd{{
			Fd:     int32(fifo.file.Fd()),
			Events: unix.POLLOUT | unix.POLLERR | unix.POLLHUP,
		}}
		ready, err := unix.Poll(poll, fifoPollIntervalMilliseconds)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if ready == 0 {
			continue
		}
		if poll[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			return errUnavailable
		}
		if poll[0].Revents&unix.POLLOUT != 0 {
			return nil
		}
	}
}

func (fifo *linuxFIFO) CloseAndRemove() error {
	return fifo.remove(false)
}

func (fifo *linuxFIFO) RevokeAndRemove() error {
	return fifo.remove(true)
}

func (fifo *linuxFIFO) remove(revoked bool) error {
	if revoked {
		fifo.revoked.Store(true)
	}
	if err := fifo.file.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
		return err
	}
	if err := os.Remove(fifo.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

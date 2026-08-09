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
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/mdlayher/vsock"
	"golang.org/x/sys/unix"
)

const defaultServicePort = uint(19532)
const defaultMaximumConnections = 64

// The VZ guest agent listens on VMADDR_CID_ANY. Sealed service workloads can
// run in a different guest network namespace, so use the same wildcard CID
// instead of inferring a namespace-specific local CID from /dev/vsock.
const serviceVsockContextID = unix.VMADDR_CID_ANY

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "container-gelf-service: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return runWithContext(os.Args[0], os.Args[1:], ctx, openServiceListener)
}

type serviceListenerOpener func(uint32, string, bool) (net.Listener, func(), error)
type serviceVsockListenerOpener func(uint32, uint32) (net.Listener, error)
type serviceVsockDialer func(context.Context, uint32, uint32) (net.Conn, error)

func runWithContext(
	program string,
	arguments []string,
	ctx context.Context,
	listenerOpener serviceListenerOpener,
) error {
	flags := flag.NewFlagSet(program, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	port := flags.Uint("port", defaultServicePort, "protected AF_VSOCK service port")
	sandboxGeneration := flags.Uint64("sandbox-generation", 0, "active EngineLinuxSandbox generation")
	unixSocket := flags.String("listen-unix", "", "test-only Unix listener")
	connectHostVsock := flags.Bool("connect-host-vsock", false, "dial the sealed host VSOCK listener")
	maximumConnections := flags.Int("max-connections", defaultMaximumConnections, "bounded concurrent clients")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 || *port == 0 || *port > uint(^uint32(0)) ||
		*sandboxGeneration == 0 || *maximumConnections <= 0 ||
		(*connectHostVsock && *unixSocket != "") {
		return errors.New("invalid service arguments")
	}

	listener, cleanup, err := listenerOpener(uint32(*port), *unixSocket, *connectHostVsock)
	if err != nil {
		return err
	}
	defer cleanup()
	return serveListener(ctx, listener, *sandboxGeneration, *maximumConnections)
}

func openServiceListener(port uint32, unixSocket string, connectHostVsock bool) (net.Listener, func(), error) {
	openVSockListener := func(contextID uint32, port uint32) (net.Listener, error) {
		return vsock.ListenContextID(contextID, port, nil)
	}
	dialVSock := func(ctx context.Context, contextID uint32, port uint32) (net.Conn, error) {
		return dialHostVsock(ctx, contextID, port)
	}
	return openServiceListenerWithReporter(
		port,
		unixSocket,
		connectHostVsock,
		openVSockListener,
		dialVSock,
		func(err error) {
			fmt.Fprintf(
				os.Stderr,
				"container-gelf-service: waiting for sealed host VSOCK listener: %v\\n",
				err,
			)
		},
	)
}

func openServiceListenerWith(
	port uint32,
	unixSocket string,
	connectHostVsock bool,
	openVSockListener serviceVsockListenerOpener,
	dialVSock serviceVsockDialer,
) (net.Listener, func(), error) {
	return openServiceListenerWithReporter(
		port,
		unixSocket,
		connectHostVsock,
		openVSockListener,
		dialVSock,
		nil,
	)
}

func openServiceListenerWithReporter(
	port uint32,
	unixSocket string,
	connectHostVsock bool,
	openVSockListener serviceVsockListenerOpener,
	dialVSock serviceVsockDialer,
	reportDialFailure func(error),
) (net.Listener, func(), error) {
	if connectHostVsock {
		if unixSocket != "" {
			return nil, func() {}, errors.New("host VSOCK and Unix listeners are mutually exclusive")
		}
		listener := newReverseVsockListenerWithReporter(port, dialVSock, reportDialFailure)
		return listener, func() { _ = listener.Close() }, nil
	}
	if unixSocket == "" {
		listener, err := openVSockListener(serviceVsockContextID, port)
		if err != nil {
			return nil, func() {}, err
		}
		return listener, func() { _ = listener.Close() }, nil
	}
	path := filepath.Clean(unixSocket)
	if !filepath.IsAbs(path) || path == string(filepath.Separator) {
		return nil, func() {}, errors.New("unsafe Unix socket path")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, func() {}, errors.New("refusing to replace non-socket Unix path")
		}
		if err := os.Remove(path); err != nil {
			return nil, func() {}, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, func() {}, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, func() {}, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, func() {}, err
	}
	if err := os.Chmod(path, 0o600); err != nil &&
		!errors.Is(err, syscall.EINVAL) && !errors.Is(err, syscall.EOPNOTSUPP) {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, func() {}, err
	}
	return listener, func() {
		_ = listener.Close()
		_ = os.Remove(path)
	}, nil
}

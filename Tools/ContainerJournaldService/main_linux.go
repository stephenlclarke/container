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

const defaultServicePort = uint(19530)

// The VZ guest agent listens on VMADDR_CID_ANY. Sealed service workloads can
// run in a different guest network namespace, so use the same wildcard CID
// instead of inferring a namespace-specific local CID from /dev/vsock.
const serviceVsockContextID = unix.VMADDR_CID_ANY

type serviceVsockListenerOpener func(uint32, uint32) (net.Listener, error)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "container-journald-service: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	port := flags.Uint("port", defaultServicePort, "service endpoint identity and AF_VSOCK fallback port")
	generation := flags.Uint64("sandbox-generation", 0, "active EngineLinuxSandbox generation")
	statePath := flags.String("state", "/var/lib/container-journald-service/state.json", "private durable state path")
	journalDirectory := flags.String("journal-directory", "", "read a system journal from this directory")
	unixSocket := flags.String("listen-unix", "", "private workload Unix listener relayed to the host")
	maximumConnections := flags.Int("max-connections", defaultMaximumConnections, "bounded concurrent connections")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || *generation == 0 || *port == 0 || *port > uint(^uint32(0)) || *maximumConnections <= 0 {
		return errors.New("invalid service arguments")
	}
	store, err := newFileStateStore(*statePath)
	if err != nil {
		return err
	}
	journalAdapter := newSystemdJournalAdapter(*journalDirectory)
	defer journalAdapter.Close()
	backend, err := loadDurableBackend(*generation, store, journalAdapter)
	if err != nil {
		return err
	}
	listener, cleanup, err := openServiceListener(uint32(*port), *unixSocket)
	if err != nil {
		return err
	}
	defer cleanup()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return serveListener(ctx, listener, newProtocolHandler(backend), *maximumConnections)
}

func openServiceListener(port uint32, unixSocket string) (net.Listener, func(), error) {
	openVSockListener := func(contextID uint32, port uint32) (net.Listener, error) {
		return vsock.ListenContextID(contextID, port, nil)
	}
	return openServiceListenerWith(port, unixSocket, openVSockListener)
}

func openServiceListenerWith(
	port uint32,
	unixSocket string,
	openVSockListener serviceVsockListenerOpener,
) (net.Listener, func(), error) {
	if unixSocket == "" {
		listener, err := openVSockListener(serviceVsockContextID, port)
		if err != nil {
			return nil, func() {}, fmt.Errorf("listen on AF_VSOCK port %d: %w", port, err)
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
	// Some mounted filesystems can reject chmod even though the entrypoint's
	// 0077 umask created a private socket. Accept that only after inspection.
	if err := os.Chmod(path, 0o600); err != nil &&
		!errors.Is(err, syscall.EINVAL) && !errors.Is(err, syscall.EOPNOTSUPP) {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, func() {}, err
	}
	cleanup := func() {
		_ = listener.Close()
		_ = os.Remove(path)
	}
	return listener, cleanup, nil
}

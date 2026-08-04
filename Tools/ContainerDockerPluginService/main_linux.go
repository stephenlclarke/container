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
	"strconv"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
)

const defaultServicePort = uint(19531)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "container-docker-plugin-service: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	port := flags.Uint("port", defaultServicePort, "service endpoint identity and AF_VSOCK fallback port")
	sandboxGeneration := flags.Uint64("sandbox-generation", 0, "active EngineLinuxSandbox generation")
	providerID := flags.String("provider-id", "", "installed provider identity")
	providerGeneration := flags.Uint64("provider-generation", 0, "installed provider generation")
	contractDigest := flags.String("contract-digest", "", "installed provider contract digest")
	pluginSocket := flags.String("plugin-socket", "", "protected Docker plugin Unix socket")
	expectedReadLogs := flags.String("expected-read-logs", "", "exact installed plugin ReadLogs capability")
	authenticationKeyFile := flags.String("authentication-key-file", "", "private 32-byte request authentication key")
	statePath := flags.String("state", "/var/lib/container-docker-plugin-service/state.json", "private durable state path")
	fifoRoot := flags.String("fifo-root", "/run/docker/logging", "private plugin FIFO directory")
	unixSocket := flags.String("listen-unix", "", "private workload Unix listener relayed to the host")
	maximumConnections := flags.Int("max-connections", defaultMaximumConnections, "bounded concurrent connections")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	identity := serviceIdentity{
		ID:                *providerID,
		Generation:        *providerGeneration,
		SandboxGeneration: *sandboxGeneration,
		ContractDigest:    *contractDigest,
	}
	readLogs, readLogsErr := strconv.ParseBool(*expectedReadLogs)
	if (*expectedReadLogs != "true" && *expectedReadLogs != "false") || readLogsErr != nil ||
		flags.NArg() != 0 || identity.validate() != nil || *port == 0 ||
		*port > uint(^uint32(0)) || *maximumConnections <= 0 {
		return errors.New("invalid service arguments")
	}
	authenticationKey, err := loadAuthenticationKey(*authenticationKeyFile)
	if err != nil {
		return err
	}
	store, err := newFileStateStore(*statePath)
	if err != nil {
		return err
	}
	plugin, err := newUnixHTTPLoggingPlugin(*pluginSocket)
	if err != nil {
		return err
	}
	capabilityContext, cancelCapabilityCheck := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelCapabilityCheck()
	if err := validatePluginCapabilities(capabilityContext, plugin, readLogs); err != nil {
		return err
	}
	fifos, err := newLinuxFIFOFactory(*fifoRoot)
	if err != nil {
		return err
	}
	backend, err := loadDurableBackend(
		identity,
		store,
		plugin,
		fifos,
		cryptoTokenGenerator{},
	)
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
	return serveListener(ctx, listener, newProtocolHandler(backend, authenticationKey), *maximumConnections)
}

func loadAuthenticationKey(path string) ([]byte, error) {
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) || clean == string(filepath.Separator) {
		return nil, errors.New("unsafe authentication key path")
	}
	if err := rejectSymlinkComponents(filepath.Dir(clean)); err != nil {
		return nil, err
	}
	info, err := os.Lstat(clean)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0o077 != 0 || info.Size() != 32 {
		return nil, errors.New("authentication key is not a protected 32-byte regular file")
	}
	key, err := os.ReadFile(clean)
	if err != nil || len(key) != 32 {
		return nil, errors.New("cannot read authentication key")
	}
	return key, nil
}

func openServiceListener(port uint32, unixSocket string) (net.Listener, func(), error) {
	if unixSocket == "" {
		listener, err := vsock.Listen(port, nil)
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
	cleanup := func() {
		_ = listener.Close()
		_ = os.Remove(path)
	}
	return listener, cleanup, nil
}

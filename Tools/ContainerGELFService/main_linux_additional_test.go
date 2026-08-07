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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRunWithContextRejectsInvalidArgumentsBeforeOpeningAListener(t *testing.T) {
	called := false
	opener := func(uint32, string) (net.Listener, func(), error) {
		called = true
		return nil, func() {}, nil
	}
	for _, arguments := range [][]string{
		{"--port", "0", "--sandbox-generation", "1"},
		{"--sandbox-generation", "0"},
		{"--sandbox-generation", "1", "--max-connections", "0"},
		{"--sandbox-generation", "1", "unexpected"},
	} {
		if err := runWithContext("gelf-test", arguments, context.Background(), opener); err == nil {
			t.Fatalf("invalid arguments succeeded: %q", arguments)
		}
	}
	if called {
		t.Fatal("invalid arguments opened a listener")
	}
}

func TestRunWithContextPassesValidatedConfigurationAndStopsOnCancellation(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	opened := make(chan struct{})
	var receivedPort uint32
	var receivedSocket string
	opener := func(port uint32, socket string) (net.Listener, func(), error) {
		receivedPort = port
		receivedSocket = socket
		close(opened)
		return listener, func() { _ = listener.Close() }, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runWithContext("gelf-test", []string{
			"--port", "21000",
			"--sandbox-generation", "5",
			"--listen-unix", "/run/gelf.sock",
			"--max-connections", "2",
		}, ctx, opener)
	}()
	select {
	case <-opened:
	case <-time.After(time.Second):
		cancel()
		t.Fatal("validated invocation did not open its listener")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("cancelled invocation failed: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("validated invocation did not stop")
	}
	if receivedPort != 21000 || receivedSocket != "/run/gelf.sock" {
		t.Fatalf("listener configuration = %d, %q", receivedPort, receivedSocket)
	}
}

func TestRunWithContextPropagatesListenerFailure(t *testing.T) {
	sentinel := errors.New("listener failed")
	err := runWithContext("gelf-test", []string{"--sandbox-generation", "1"}, context.Background(), func(uint32, string) (net.Listener, func(), error) {
		return nil, func() {}, sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("listener failure = %v", err)
	}
}

func TestRunUsesTheSignalContextForArgumentValidation(t *testing.T) {
	originalArguments := os.Args
	os.Args = []string{"gelf-test", "--sandbox-generation", "0"}
	t.Cleanup(func() { os.Args = originalArguments })
	if err := run(); err == nil {
		t.Fatal("run accepted an invalid sandbox generation")
	}
}

func TestMainExitsForInvalidArguments(t *testing.T) {
	if os.Getenv("GELF_TEST_CALL_MAIN") == "1" {
		os.Args = []string{"gelf-test", "--sandbox-generation", "0"}
		main()
		t.Fatal("main returned after an invalid invocation")
	}
	command := exec.Command(os.Args[0], "-test.run=TestMainExitsForInvalidArguments")
	command.Env = append(os.Environ(), "GELF_TEST_CALL_MAIN=1")
	output, err := command.CombinedOutput()
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) || exitError.ExitCode() != 1 {
		t.Fatalf("main exit = %v, output = %s", err, output)
	}
	if !strings.Contains(string(output), "container-gelf-service: invalid service arguments") {
		t.Fatalf("main output = %s", output)
	}
}

func TestOpenServiceListenerRejectsUnsafePathsAndReplacesOnlyAStaleSocket(t *testing.T) {
	for _, path := range []string{"relative.sock", string(filepath.Separator)} {
		if _, _, err := openServiceListener(uint32(defaultServicePort), path); err == nil {
			t.Fatalf("unsafe socket path succeeded: %q", path)
		}
	}

	root := t.TempDir()
	path := filepath.Join(root, "stale.sock")
	stale, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatalf("create stale socket: %v", err)
	}
	if err := syscall.Bind(stale, &syscall.SockaddrUnix{Name: path}); err != nil {
		_ = syscall.Close(stale)
		t.Fatalf("bind stale socket: %v", err)
	}
	if err := syscall.Close(stale); err != nil {
		t.Fatalf("close stale socket: %v", err)
	}
	if _, err := os.Lstat(path); err != nil {
		t.Fatalf("stale socket disappeared before replacement: %v", err)
	}
	replacement, cleanup, err := openServiceListener(uint32(defaultServicePort), path)
	if err != nil {
		t.Fatalf("replace stale socket: %v", err)
	}
	cleanup()
	if replacement == nil {
		t.Fatal("replacement listener is nil")
	}
}

func TestOpenServiceListenerCreatesNestedUnixPathAndHandlesVsockAvailability(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "nested", "control.sock")
	listener, cleanup, err := openServiceListener(uint32(defaultServicePort), path)
	if err != nil {
		t.Fatalf("create nested Unix listener: %v", err)
	}
	cleanup()
	if listener == nil {
		t.Fatal("nested Unix listener is nil")
	}

	listener, cleanup, err = openServiceListener(uint32(defaultServicePort), "")
	if err == nil {
		cleanup()
		if listener == nil {
			t.Fatal("AF_VSOCK listener is nil")
		}
	}
}

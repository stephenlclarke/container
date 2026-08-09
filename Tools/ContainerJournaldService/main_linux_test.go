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
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestOpenServiceListenerUsesWildcardVsockContextID(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("create substitute listener: %v", err)
	}
	var receivedContextID uint32
	var receivedPort uint32
	opened, cleanup, err := openServiceListenerWith(
		21000,
		"",
		func(contextID uint32, port uint32) (net.Listener, error) {
			receivedContextID = contextID
			receivedPort = port
			return listener, nil
		},
	)
	if err != nil {
		_ = listener.Close()
		t.Fatalf("open wildcard VSOCK listener: %v", err)
	}
	defer cleanup()
	if opened == nil {
		t.Fatal("wildcard VSOCK listener is nil")
	}
	if receivedContextID != unix.VMADDR_CID_ANY {
		t.Fatalf("VSOCK context ID = %d, want VMADDR_CID_ANY", receivedContextID)
	}
	if receivedPort != 21000 {
		t.Fatalf("VSOCK port = %d, want 21000", receivedPort)
	}
}

func TestOpenServiceUnixListenerIsPrivateAndCleanupIsExact(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "control.sock")
	listener, cleanup, err := openServiceListener(uint32(defaultServicePort), path, false)
	if err != nil {
		t.Fatalf("open Unix listener: %v", err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		cleanup()
		t.Fatalf("Unix listener mode = %v, %v", info, err)
	}
	cleanup()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("listener cleanup left socket: %v", err)
	}
	_ = listener

	regularPath := filepath.Join(root, "regular")
	if err := os.WriteFile(regularPath, []byte("preserve"), 0o600); err != nil {
		t.Fatalf("write regular path: %v", err)
	}
	if _, _, err := openServiceListener(uint32(defaultServicePort), regularPath, false); err == nil {
		t.Fatal("listener replaced a regular file")
	}
}

func TestOpenServiceListenerRejectsReverseVsockWithUnixSocket(t *testing.T) {
	if _, _, err := openServiceListenerWithOptions(
		21000,
		"/run/private.sock",
		true,
		func(uint32, uint32) (net.Listener, error) {
			t.Fatal("direct listener must not be opened for reverse VSOCK")
			return nil, nil
		},
		func(uint32, uint32) (net.Conn, error) {
			t.Fatal("reverse dialer must not be used with a Unix listener")
			return nil, nil
		},
	); err == nil {
		t.Fatal("reverse VSOCK accepted a Unix listener")
	}
}

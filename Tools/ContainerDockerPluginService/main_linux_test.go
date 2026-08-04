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
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAuthenticationKeyRequiresProtectedRegularFile(t *testing.T) {
	root := t.TempDir()
	keyPath := filepath.Join(root, "authentication.key")
	want := bytes.Repeat([]byte{0x5a}, 32)
	if err := os.WriteFile(keyPath, want, 0o600); err != nil {
		t.Fatalf("write authentication key: %v", err)
	}
	got, err := loadAuthenticationKey(keyPath)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("loaded authentication key length = %d, %v", len(got), err)
	}
	if err := os.Chmod(keyPath, 0o644); err != nil {
		t.Fatalf("make authentication key permissive: %v", err)
	}
	if _, err := loadAuthenticationKey(keyPath); err == nil {
		t.Fatal("permissive authentication key was accepted")
	}
	if err := os.Chmod(keyPath, 0o600); err != nil {
		t.Fatalf("restore authentication key mode: %v", err)
	}
	linkPath := filepath.Join(root, "authentication-link.key")
	if err := os.Symlink(keyPath, linkPath); err != nil {
		t.Fatalf("create authentication key symlink: %v", err)
	}
	if _, err := loadAuthenticationKey(linkPath); err == nil {
		t.Fatal("authentication key symlink was accepted")
	}
	for _, unsafePath := range []string{"relative.key", string(filepath.Separator)} {
		if _, err := loadAuthenticationKey(unsafePath); err == nil {
			t.Fatalf("unsafe authentication key path %q succeeded", unsafePath)
		}
	}
}

func TestRunValidatesAuthenticationBeforeCreatingServiceState(t *testing.T) {
	root := t.TempDir()
	statePath := filepath.Join(root, "state", "state.json")
	fifoRoot := filepath.Join(root, "fifos")
	listenerPath := filepath.Join(root, "control.sock")
	originalArguments := os.Args
	t.Cleanup(func() { os.Args = originalArguments })
	os.Args = []string{
		"container-docker-plugin-service",
		"--sandbox-generation=9",
		"--provider-id=io.container.logging.plugin.test",
		"--provider-generation=7",
		"--plugin-socket=/run/docker/plugins/test.sock",
		"--authentication-key-file=" + filepath.Join(root, "missing.key"),
		"--state=" + statePath,
		"--fifo-root=" + fifoRoot,
		"--listen-unix=" + listenerPath,
	}
	if err := run(); err == nil {
		t.Fatal("run succeeded without an authentication key")
	}
	for _, path := range []string{statePath, fifoRoot, listenerPath} {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("authentication failure created %s: %v", path, err)
		}
	}
}

func TestOpenServiceUnixListenerIsPrivateAndCleanupIsExact(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "control.sock")
	listener, cleanup, err := openServiceListener(uint32(defaultServicePort), path)
	if err != nil {
		t.Fatalf("open Unix listener: %v", err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		cleanup()
		t.Fatalf("Unix listener mode = %v, %v", info, err)
	}
	client, err := net.Dial("unix", path)
	if err != nil {
		cleanup()
		t.Fatalf("dial Unix listener: %v", err)
	}
	accepted, err := listener.Accept()
	if err != nil {
		_ = client.Close()
		cleanup()
		t.Fatalf("accept Unix listener: %v", err)
	}
	_ = accepted.Close()
	_ = client.Close()
	cleanup()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("listener cleanup left socket: %v", err)
	}

	regularPath := filepath.Join(root, "regular")
	if err := os.WriteFile(regularPath, []byte("preserve"), 0o600); err != nil {
		t.Fatalf("write regular path: %v", err)
	}
	if _, _, err := openServiceListener(uint32(defaultServicePort), regularPath); err == nil {
		t.Fatal("listener replaced a regular file")
	}
	contents, err := os.ReadFile(regularPath)
	if err != nil || string(contents) != "preserve" {
		t.Fatalf("regular path changed: %q, %v", contents, err)
	}
	if _, _, err := openServiceListener(uint32(defaultServicePort), "relative.sock"); err == nil {
		t.Fatal("relative listener path succeeded")
	}
}

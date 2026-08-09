// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestFixtureCapturesAndReadsPluginFrames(t *testing.T) {
	root := t.TempDir()
	fifoRoot := filepath.Join(root, "run", "docker", "logging")
	if err := os.MkdirAll(fifoRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(fifoRoot, "writer.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	plugin := &fixturePlugin{
		historyPath: filepath.Join(root, "history.bin"),
		fifoRoot:    fifoRoot,
		writers:     make(map[string]*fixtureCapture),
	}

	start := startLoggingRequest{File: fifo, Info: json.RawMessage(`{"ContainerID":"fixture"}`)}
	startBody, err := json.Marshal(start)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/LogDriver.StartLogging", bytes.NewReader(startBody))
	response := httptest.NewRecorder()
	plugin.startLogging(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", response.Code, response.Body.String())
	}

	payload := []byte{0x0a, 0x07, 'f', 'i', 'x', 't', 'u', 'r', 'e'}
	frame := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(payload)))
	copy(frame[4:], payload)
	if err := writeAll(writer, frame); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		history, readErr := os.ReadFile(plugin.historyPath)
		if readErr == nil && bytes.Equal(history, frame) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("captured history = %x, error = %v", history, readErr)
		}
		time.Sleep(10 * time.Millisecond)
	}

	readRequest := httptest.NewRequest(
		http.MethodPost,
		"/LogDriver.ReadLogs",
		bytes.NewBufferString(`{"Info":{},"Config":{}}`),
	)
	readResponse := httptest.NewRecorder()
	plugin.readLogs(readResponse, readRequest)
	if !bytes.Equal(readResponse.Body.Bytes(), frame) {
		t.Fatalf("read history = %x, want %x", readResponse.Body.Bytes(), frame)
	}
	plugin.close()
}

func TestFixtureStopLoggingDrainsAcknowledgedFrames(t *testing.T) {
	root := t.TempDir()
	fifoRoot := filepath.Join(root, "run", "docker", "logging")
	if err := os.MkdirAll(fifoRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(fifoRoot, "writer.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	plugin := &fixturePlugin{
		historyPath: filepath.Join(root, "history.bin"),
		fifoRoot:    fifoRoot,
		writers:     make(map[string]*fixtureCapture),
	}

	startBody, err := json.Marshal(startLoggingRequest{
		File: fifo,
		Info: json.RawMessage(`{"ContainerID":"fixture"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	startResponse := httptest.NewRecorder()
	plugin.startLogging(
		startResponse,
		httptest.NewRequest(http.MethodPost, "/LogDriver.StartLogging", bytes.NewReader(startBody)),
	)
	if startResponse.Code != http.StatusOK {
		t.Fatalf("start status = %d, body = %s", startResponse.Code, startResponse.Body.String())
	}

	first := fixtureFrame([]byte("stdout"))
	second := fixtureFrame([]byte("stderr"))
	if err := writeAll(writer, append(first, second...)); err != nil {
		t.Fatal(err)
	}
	stopBody, err := json.Marshal(stopLoggingRequest{File: fifo})
	if err != nil {
		t.Fatal(err)
	}
	stopResponse := httptest.NewRecorder()
	plugin.stopLogging(
		stopResponse,
		httptest.NewRequest(http.MethodPost, "/LogDriver.StopLogging", bytes.NewReader(stopBody)),
	)
	if stopResponse.Code != http.StatusOK {
		t.Fatalf("stop status = %d, body = %s", stopResponse.Code, stopResponse.Body.String())
	}

	history, err := os.ReadFile(plugin.historyPath)
	if err != nil {
		t.Fatal(err)
	}
	if want := append(first, second...); !bytes.Equal(history, want) {
		t.Fatalf("captured history = %x, want %x", history, want)
	}
	plugin.close()
}

func fixtureFrame(payload []byte) []byte {
	frame := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(payload)))
	copy(frame[4:], payload)
	return frame
}

func TestFixtureRejectsPathsOutsidePrivateRoots(t *testing.T) {
	for _, path := range []string{"", "/run/docker/plugins", "/run/docker/plugins/../escape.sock", "relative.sock"} {
		if safeSocketPath(path) {
			t.Fatalf("accepted unsafe socket path %q", path)
		}
	}
	for _, path := range []string{"", "/tmp/writer.fifo", "/run/docker/logging/../escape"} {
		if safeFIFOPath(path) {
			t.Fatalf("accepted unsafe FIFO path %q", path)
		}
	}
}

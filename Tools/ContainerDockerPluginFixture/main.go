// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maximumRequestBytes = 1 << 20
	maximumFrameBytes   = 1 << 20
	maximumHistoryBytes = 64 << 20
	capturePollInterval = time.Millisecond
	captureDrainTimeout = 2 * time.Second
)

type fixtureCapture struct {
	file     *os.File
	stop     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
}

func (capture *fixtureCapture) stopAndWait() {
	capture.stopOnce.Do(func() { close(capture.stop) })
	select {
	case <-capture.done:
		return
	case <-time.After(captureDrainTimeout):
		_ = capture.file.Close()
		<-capture.done
	}
}

type fixturePlugin struct {
	historyPath string
	fifoRoot    string

	mu       sync.Mutex
	writers  map[string]*fixtureCapture
	captures sync.WaitGroup
}

type startLoggingRequest struct {
	File string          `json:"File"`
	Info json.RawMessage `json:"Info"`
}

type stopLoggingRequest struct {
	File string `json:"File"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "container-docker-plugin-fixture: unavailable")
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	socketPath := flags.String("socket", "", "private Docker plugin Unix socket")
	historyPath := flags.String("history", "", "durable captured protobuf history")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || !safeSocketPath(*socketPath) || !safeHistoryPath(*historyPath) {
		return errors.New("invalid fixture paths")
	}
	if err := os.MkdirAll(filepath.Dir(*socketPath), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*historyPath), 0o700); err != nil {
		return err
	}
	if err := removeStaleSocket(*socketPath); err != nil {
		return err
	}
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		return err
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(*socketPath)
	}()
	if err := os.Chmod(*socketPath, 0o600); err != nil {
		return err
	}

	plugin := &fixturePlugin{
		historyPath: *historyPath,
		fifoRoot:    "/run/docker/logging",
		writers:     make(map[string]*fixtureCapture),
	}
	server := &http.Server{
		Handler:           plugin.handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- server.Serve(listener)
	}()
	select {
	case <-ctx.Done():
		_ = server.Shutdown(context.Background())
		plugin.close()
		err = <-serveResult
	case err = <-serveResult:
		plugin.close()
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (plugin *fixturePlugin) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/LogDriver.Capabilities", plugin.capabilities)
	mux.HandleFunc("/LogDriver.StartLogging", plugin.startLogging)
	mux.HandleFunc("/LogDriver.StopLogging", plugin.stopLogging)
	mux.HandleFunc("/LogDriver.ReadLogs", plugin.readLogs)
	return mux
}

func (plugin *fixturePlugin) capabilities(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, map[string]any{
		"Cap": map[string]bool{"ReadLogs": true},
		"Err": "",
	})
}

func (plugin *fixturePlugin) startLogging(response http.ResponseWriter, request *http.Request) {
	var input startLoggingRequest
	if decodeRequest(request, &input) != nil || !safePrivatePath(input.File, plugin.fifoRoot) || len(input.Info) == 0 {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	file, err := os.OpenFile(input.File, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		writeJSON(response, map[string]string{"Err": "logging FIFO is unavailable"})
		return
	}
	capture := &fixtureCapture{
		file: file,
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	plugin.mu.Lock()
	if _, exists := plugin.writers[input.File]; exists {
		plugin.mu.Unlock()
		_ = file.Close()
		writeJSON(response, map[string]string{"Err": "logging FIFO is already active"})
		return
	}
	plugin.writers[input.File] = capture
	plugin.captures.Add(1)
	plugin.mu.Unlock()
	go plugin.capture(input.File, capture)
	writeJSON(response, map[string]string{"Err": ""})
}

func (plugin *fixturePlugin) stopLogging(response http.ResponseWriter, request *http.Request) {
	var input stopLoggingRequest
	if decodeRequest(request, &input) != nil || !safePrivatePath(input.File, plugin.fifoRoot) {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	plugin.mu.Lock()
	capture := plugin.writers[input.File]
	delete(plugin.writers, input.File)
	plugin.mu.Unlock()
	if capture != nil {
		capture.stopAndWait()
	}
	writeJSON(response, map[string]string{"Err": ""})
}

func (plugin *fixturePlugin) readLogs(response http.ResponseWriter, request *http.Request) {
	var input map[string]json.RawMessage
	if decodeRequest(request, &input) != nil || input["Info"] == nil || input["Config"] == nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	plugin.mu.Lock()
	history, err := os.ReadFile(plugin.historyPath)
	plugin.mu.Unlock()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		http.Error(response, "history unavailable", http.StatusInternalServerError)
		return
	}
	if len(history) > maximumHistoryBytes {
		http.Error(response, "history unavailable", http.StatusInternalServerError)
		return
	}
	response.Header().Set("Content-Type", "application/octet-stream")
	_, _ = response.Write(history)
}

func (plugin *fixturePlugin) capture(path string, capture *fixtureCapture) {
	defer plugin.captures.Done()
	defer close(capture.done)
	defer func() {
		plugin.mu.Lock()
		if plugin.writers[path] == capture {
			delete(plugin.writers, path)
		}
		plugin.mu.Unlock()
		_ = capture.file.Close()
	}()
	buffer := make([]byte, 0, 64*1024)
	chunk := make([]byte, 64*1024)
	for {
		count, err := capture.file.Read(chunk)
		if count > 0 {
			buffer = append(buffer, chunk[:count]...)
			for len(buffer) >= 4 {
				length := int(binary.BigEndian.Uint32(buffer[:4]))
				if length <= 0 || length > maximumFrameBytes {
					return
				}
				frameLength := 4 + length
				if len(buffer) < frameLength {
					break
				}
				if plugin.appendFrame(buffer[:frameLength]) != nil {
					return
				}
				buffer = buffer[frameLength:]
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EWOULDBLOCK) {
			select {
			case <-capture.stop:
				return
			default:
				time.Sleep(capturePollInterval)
				continue
			}
		}
		if errors.Is(err, io.EOF) && len(buffer) == 0 {
			return
		}
		return
	}
}

func (plugin *fixturePlugin) appendFrame(frame []byte) error {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	info, err := os.Stat(plugin.historyPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if info != nil && info.Size()+int64(len(frame)) > maximumHistoryBytes {
		return errors.New("fixture history is full")
	}
	file, err := os.OpenFile(plugin.historyPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := writeAll(file, frame); err != nil {
		return err
	}
	return file.Sync()
}

func (plugin *fixturePlugin) close() {
	plugin.mu.Lock()
	captures := make([]*fixtureCapture, 0, len(plugin.writers))
	for path, capture := range plugin.writers {
		captures = append(captures, capture)
		delete(plugin.writers, path)
	}
	plugin.mu.Unlock()
	for _, capture := range captures {
		capture.stopAndWait()
	}
	plugin.captures.Wait()
}

func decodeRequest(request *http.Request, value any) error {
	defer request.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(request.Body, maximumRequestBytes+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("unexpected trailing request data")
	}
	return nil
}

func writeJSON(response http.ResponseWriter, value any) {
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(value)
}

func writeAll(writer io.Writer, contents []byte) error {
	for len(contents) > 0 {
		count, err := writer.Write(contents)
		if err != nil {
			return err
		}
		if count <= 0 {
			return io.ErrShortWrite
		}
		contents = contents[count:]
	}
	return nil
}

func removeStaleSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("refusing to replace non-socket plugin path")
	}
	return os.Remove(path)
}

func safeSocketPath(path string) bool {
	clean := filepath.Clean(path)
	return filepath.IsAbs(path) && clean == path && strings.HasPrefix(path, "/run/docker/plugins/")
}

func safeFIFOPath(path string) bool {
	return safePrivatePath(path, "/run/docker/logging")
}

func safePrivatePath(path string, root string) bool {
	clean := filepath.Clean(path)
	cleanRoot := filepath.Clean(root)
	return filepath.IsAbs(path) && filepath.IsAbs(root) && clean == path &&
		cleanRoot == root && strings.HasPrefix(path, root+string(filepath.Separator))
}

func safeHistoryPath(path string) bool {
	clean := filepath.Clean(path)
	return filepath.IsAbs(path) && clean == path && strings.HasPrefix(path, "/var/lib/container-docker-plugin-service/")
}

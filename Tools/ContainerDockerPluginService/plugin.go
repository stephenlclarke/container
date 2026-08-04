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

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"sync"
	"time"
)

const (
	maximumPluginResponseBytes = 64 * 1024
	maximumReadFrameBytes      = 16 * 1024 * 1024
)

type pluginCapabilities struct {
	ReadLogs bool `json:"ReadLogs"`
}

type pluginReadStream interface {
	Next(context.Context) ([]byte, error)
	Close() error
}

type loggingPlugin interface {
	Capabilities(context.Context) (pluginCapabilities, error)
	StartLogging(context.Context, string, json.RawMessage) error
	StopLogging(context.Context, string) error
	ReadLogs(context.Context, json.RawMessage) (pluginReadStream, error)
}

type fifoHandle interface {
	Path() string
	Write(context.Context, []byte) error
	CloseAndRemove() error
	RevokeAndRemove() error
}

type fifoFactory interface {
	Open(string, uint64) (fifoHandle, error)
}

type unixHTTPLoggingPlugin struct {
	client *http.Client
}

func newUnixHTTPLoggingPlugin(socketPath string) (*unixHTTPLoggingPlugin, error) {
	path := filepath.Clean(socketPath)
	if !filepath.IsAbs(path) || path == string(filepath.Separator) {
		return nil, errors.New("unsafe plugin socket path")
	}
	transport := &http.Transport{
		DisableCompression: true,
		DisableKeepAlives:  false,
		MaxConnsPerHost:    64,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "unix", path)
		},
	}
	return &unixHTTPLoggingPlugin{
		client: &http.Client{Transport: transport},
	}, nil
}

func (plugin *unixHTTPLoggingPlugin) Capabilities(ctx context.Context) (pluginCapabilities, error) {
	response, err := plugin.call(ctx, "LogDriver.Capabilities", nil)
	if err != nil {
		return pluginCapabilities{}, err
	}
	var envelope struct {
		Capability pluginCapabilities `json:"Cap"`
		Error      string             `json:"Err"`
	}
	if err := decodePluginResponse(response, &envelope); err != nil {
		return pluginCapabilities{}, err
	}
	if envelope.Error != "" {
		return pluginCapabilities{}, errors.New("plugin rejected capabilities")
	}
	return envelope.Capability, nil
}

func (plugin *unixHTTPLoggingPlugin) StartLogging(
	ctx context.Context,
	fifoPath string,
	info json.RawMessage,
) error {
	body, err := json.Marshal(struct {
		File string          `json:"File"`
		Info json.RawMessage `json:"Info"`
	}{File: fifoPath, Info: info})
	if err != nil {
		return err
	}
	response, err := plugin.call(ctx, "LogDriver.StartLogging", body)
	if err != nil {
		return err
	}
	return decodePluginError(response)
}

func (plugin *unixHTTPLoggingPlugin) StopLogging(ctx context.Context, fifoPath string) error {
	body, err := json.Marshal(struct {
		File string `json:"File"`
	}{File: fifoPath})
	if err != nil {
		return err
	}
	response, err := plugin.call(ctx, "LogDriver.StopLogging", body)
	if err != nil {
		return err
	}
	return decodePluginError(response)
}

func (plugin *unixHTTPLoggingPlugin) ReadLogs(
	ctx context.Context,
	request json.RawMessage,
) (pluginReadStream, error) {
	httpRequest, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		"http://plugin/LogDriver.ReadLogs",
		bytes.NewReader(request),
	)
	if err != nil {
		return nil, err
	}
	httpRequest.Header.Set("Content-Type", "application/json")
	response, err := plugin.client.Do(httpRequest)
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_ = response.Body.Close()
		return nil, errors.New("plugin rejected read logs")
	}
	return &pluginFrameStream{body: response.Body}, nil
}

func (plugin *unixHTTPLoggingPlugin) call(
	ctx context.Context,
	endpoint string,
	body []byte,
) ([]byte, error) {
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		"http://plugin/"+endpoint,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := plugin.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, errors.New("plugin rejected request")
	}
	contents, err := io.ReadAll(io.LimitReader(response.Body, maximumPluginResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(contents) > maximumPluginResponseBytes {
		return nil, errors.New("plugin response exceeds limit")
	}
	return contents, nil
}

func decodePluginError(data []byte) error {
	var envelope struct {
		Error string `json:"Err"`
	}
	if err := decodePluginResponse(data, &envelope); err != nil {
		return err
	}
	if envelope.Error != "" {
		return errors.New("plugin rejected request")
	}
	return nil
}

func decodePluginResponse(data []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(output); err != nil {
		return errors.New("malformed plugin response")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("malformed plugin response")
	}
	return nil
}

type pluginFrameStream struct {
	body      io.ReadCloser
	closeOnce sync.Once
}

func (stream *pluginFrameStream) Next(ctx context.Context) ([]byte, error) {
	if deadline, ok := ctx.Deadline(); ok {
		if connection, ok := stream.body.(interface{ SetReadDeadline(time.Time) error }); ok {
			if err := connection.SetReadDeadline(deadline); err != nil {
				return nil, err
			}
		}
	}
	type result struct {
		frame []byte
		err   error
	}
	completed := make(chan result, 1)
	go func() {
		frame, err := stream.readFrame()
		completed <- result{frame: frame, err: err}
	}()
	select {
	case <-ctx.Done():
		_ = stream.Close()
		<-completed
		return nil, ctx.Err()
	case result := <-completed:
		return result.frame, result.err
	}
}

func (stream *pluginFrameStream) Close() error {
	var err error
	stream.closeOnce.Do(func() { err = stream.body.Close() })
	return err
}

func (stream *pluginFrameStream) readFrame() ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(stream.body, header); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > maximumReadFrameBytes {
		return nil, fmt.Errorf("invalid plugin frame length %d", length)
	}
	frame := make([]byte, 4+int(length))
	copy(frame, header)
	if _, err := io.ReadFull(stream.body, frame[4:]); err != nil {
		return nil, err
	}
	return frame, nil
}

type ownedPluginReadStream struct {
	pluginReadStream
	cancel    context.CancelFunc
	closeOnce sync.Once
}

func (stream *ownedPluginReadStream) Close() error {
	var err error
	stream.closeOnce.Do(func() {
		stream.cancel()
		err = stream.pluginReadStream.Close()
	})
	return err
}

func openPluginReadStream(
	ctx context.Context,
	plugin loggingPlugin,
	request json.RawMessage,
) (pluginReadStream, error) {
	streamContext, cancel := context.WithCancel(context.WithoutCancel(ctx))
	type result struct {
		stream pluginReadStream
		err    error
	}
	completed := make(chan result, 1)
	go func() {
		stream, err := plugin.ReadLogs(streamContext, request)
		completed <- result{stream: stream, err: err}
	}()
	select {
	case <-ctx.Done():
		cancel()
		result := <-completed
		if result.stream != nil {
			_ = result.stream.Close()
		}
		return nil, ctx.Err()
	case result := <-completed:
		if result.err != nil {
			cancel()
			return nil, result.err
		}
		return &ownedPluginReadStream{
			pluginReadStream: result.stream,
			cancel:           cancel,
		}, nil
	}
}

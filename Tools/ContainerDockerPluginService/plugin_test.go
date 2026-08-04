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
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type pluginRoundTripper func(*http.Request) (*http.Response, error)

func (roundTrip pluginRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTrip(request)
}

func TestPluginFrameStreamReadObservesCancellation(t *testing.T) {
	reader, writer := io.Pipe()
	defer writer.Close()
	stream := &pluginFrameStream{body: reader}
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.AfterFunc(20*time.Millisecond, cancel)
	defer timer.Stop()
	started := time.Now()
	_, err := stream.Next(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("stream read error = %v, want cancellation", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("stream read cancellation took %s", elapsed)
	}
}

func TestDecodePluginErrorClassifiesDefinitiveRejection(t *testing.T) {
	if err := decodePluginError([]byte(`{"Err":"rejected"}`)); !errors.Is(err, errPluginRequestRejected) {
		t.Fatalf("plugin rejection error = %v, want definitive rejection", err)
	}
	if err := decodePluginError([]byte(`{"Err":""}`)); err != nil {
		t.Fatalf("successful plugin response failed: %v", err)
	}
}

func TestValidatePluginCapabilitiesRequiresExactReadContract(t *testing.T) {
	plugin := newFakePlugin(true)
	if err := validatePluginCapabilities(context.Background(), plugin, true); err != nil {
		t.Fatalf("matching plugin capabilities failed: %v", err)
	}
	if err := validatePluginCapabilities(context.Background(), plugin, false); !errors.Is(err, errCapabilityMismatch) {
		t.Fatalf("capability mismatch error = %v", err)
	}
}

func TestPluginCapabilitiesAreCachedForTheProcessLifetime(t *testing.T) {
	calls := 0
	plugin := &unixHTTPLoggingPlugin{
		client: &http.Client{Transport: pluginRoundTripper(func(*http.Request) (*http.Response, error) {
			calls++
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(`{"Cap":{"ReadLogs":true},"Err":""}`)),
				Header:     make(http.Header),
			}, nil
		})},
	}

	first, err := plugin.Capabilities(context.Background())
	if err != nil || !first.ReadLogs {
		t.Fatalf("first capabilities = %#v, %v", first, err)
	}
	second, err := plugin.Capabilities(context.Background())
	if err != nil || !second.ReadLogs {
		t.Fatalf("cached capabilities = %#v, %v", second, err)
	}
	if calls != 1 {
		t.Fatalf("capability request count = %d, want 1", calls)
	}
}

func TestPluginCapabilityFailureIsNotCached(t *testing.T) {
	calls := 0
	plugin := &unixHTTPLoggingPlugin{
		client: &http.Client{Transport: pluginRoundTripper(func(*http.Request) (*http.Response, error) {
			calls++
			if calls == 1 {
				return nil, errors.New("transient capability transport failure")
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(`{"Cap":{"ReadLogs":true},"Err":""}`)),
				Header:     make(http.Header),
			}, nil
		})},
	}

	if _, err := plugin.Capabilities(context.Background()); err == nil {
		t.Fatal("first capability request unexpectedly succeeded")
	}
	capabilities, err := plugin.Capabilities(context.Background())
	if err != nil || !capabilities.ReadLogs {
		t.Fatalf("retried capabilities = %#v, %v", capabilities, err)
	}
	if _, err := plugin.Capabilities(context.Background()); err != nil {
		t.Fatalf("cached capability request failed: %v", err)
	}
	if calls != 2 {
		t.Fatalf("capability request count = %d, want 2", calls)
	}
}

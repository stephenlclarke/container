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
	"net"
	"testing"
)

func TestHostDockerInternalResolvesThroughTheLinuxDefaultGateway(t *testing.T) {
	host, err := normalizedConnectHost("HOST.DOCKER.INTERNAL")
	if err != nil {
		t.Fatalf("resolve host.docker.internal: %v", err)
	}
	if net.ParseIP(host) == nil {
		t.Fatalf("gateway host is not an IP address: %q", host)
	}
	address, err := (endpoint{Host: "host.docker.internal", Port: "12201"}).address()
	if err != nil || address != net.JoinHostPort(host, "12201") {
		t.Fatalf("gateway address = %q, %v", address, err)
	}
}

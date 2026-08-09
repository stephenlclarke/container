// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"bytes"
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

type serverHarness struct {
	client net.Conn
	server *semanticServer
	done   <-chan error
}

func newServerHarness(t *testing.T) serverHarness {
	t.Helper()
	client, serverConnection := net.Pipe()
	server := newSemanticServer(serverConnection)
	done := make(chan error, 1)
	go func() {
		done <- server.serve()
	}()
	t.Cleanup(func() {
		_ = client.Close()
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, net.ErrClosed) {
				t.Errorf("semantic server shutdown: %v", err)
			}
		case <-time.After(time.Second):
			t.Error("semantic server did not stop")
		}
	})
	return serverHarness{client: client, server: server, done: done}
}

func (h serverHarness) roundTrip(
	t *testing.T,
	requestID uint64,
	op opcode,
	payload []byte,
) (frameHeader, []byte) {
	t.Helper()
	frame, err := encodeFrame(frameHeader{
		kind: requestFrame, opcode: op, requestID: requestID,
		timeoutNanoseconds: uint64(5 * time.Second),
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.client.Write(frame); err != nil {
		t.Fatal(err)
	}
	header, response, err := readFrame(h.client)
	if err != nil {
		t.Fatal(err)
	}
	if header.kind != responseFrame || header.opcode != op || header.requestID != requestID {
		t.Fatalf("unexpected response header: %+v", header)
	}
	return header, response
}

func appendByteList(t *testing.T, writer *protocolWriter, values ...string) {
	t.Helper()
	writer.uint32(uint32(len(values)))
	for _, value := range values {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
}

func appendStringMap(t *testing.T, writer *protocolWriter, values map[string]string) {
	t.Helper()
	writer.uint32(uint32(len(values)))
	for key, value := range values {
		if err := writer.byteField([]byte(key)); err != nil {
			t.Fatal(err)
		}
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
}

func templatePayload(t *testing.T, format string) []byte {
	t.Helper()
	writer := &protocolWriter{}
	if err := writer.byteField([]byte(format)); err != nil {
		t.Fatal(err)
	}
	appendStringMap(t, writer, map[string]string{"tag": format})
	for _, value := range []string{
		"0123456789abcdef0123456789abcdef",
		"/alpha",
		"/bin/sh",
	} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	appendByteList(t, writer, "-c", "echo ok")
	for _, value := range []string{
		"abcdef0123456789abcdef0123456789",
		"example/image:latest",
	} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	writer.int64(1_234_567_890)
	writer.int32(123_456_789)
	appendByteList(t, writer, "ALPHA=one")
	appendStringMap(t, writer, map[string]string{"com.example.label": "value"})
	for _, value := range []string{"/private/log", "dockerd", "engine-host"} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	return writer.bytes
}

func gcpStartPayload(t *testing.T, sessionID string) []byte {
	t.Helper()
	writer := &protocolWriter{}
	if err := writer.byteField([]byte(sessionID)); err != nil {
		t.Fatal(err)
	}
	appendStringMap(t, writer, map[string]string{"gcp-project": "project"})
	for _, value := range []string{
		"0123456789abcdef0123456789abcdef",
		"/alpha",
		"/bin/sh",
	} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	appendByteList(t, writer, "-c", "echo ok")
	for _, value := range []string{
		"abcdef0123456789abcdef0123456789",
		"example/image:latest",
	} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	writer.int64(1_234_567_890)
	writer.int32(123_456_789)
	appendByteList(t, writer, "ALPHA=one")
	appendStringMap(t, writer, map[string]string{"com.example.label": "value"})
	for _, value := range []string{"/private/log", "dockerd", "engine-host"} {
		if err := writer.byteField([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	return writer.bytes
}

func TestServerRoundTripsEverySemanticOperation(t *testing.T) {
	harness := newServerHarness(t)

	header, hello := harness.roundTrip(t, 1, opHello, nil)
	if header.status != statusOK {
		t.Fatalf("hello status = %d", header.status)
	}
	reader := newProtocolReader(hello)
	for range 6 {
		if _, err := reader.byteField(256); err != nil {
			t.Fatal(err)
		}
	}

	regexpRequest := &protocolWriter{}
	if err := regexpRequest.byteField([]byte("^alpha$")); err != nil {
		t.Fatal(err)
	}
	appendByteList(t, regexpRequest, "alpha", "beta")
	header, response := harness.roundTrip(t, 2, opRegexpBatch, regexpRequest.bytes)
	if header.status != statusOK || !bytes.Equal(response, []byte{0, 0, 0, 2, 1, 0}) {
		t.Fatalf("regexp response = %d/%v", header.status, response)
	}

	header, response = harness.roundTrip(t, 3, opTemplateRender, templatePayload(t, "{{.Name}}"))
	if header.status != statusOK {
		t.Fatalf("template status = %d", header.status)
	}
	reader = newProtocolReader(response)
	if value, err := reader.byteField(maximumOutputBytes); err != nil || string(value) != "alpha" {
		t.Fatalf("template response = %q/%v", value, err)
	}

	for requestID, operation := range []struct {
		opcode opcode
		input  string
	}{
		{opURLParse, "tcp://host:1234/path"},
		{opFluentdAddress, "localhost:24224"},
		{opGELFAddress, "udp://127.0.0.1:12201"},
		{opSyslogAddress, "udp://host"},
	} {
		request := &protocolWriter{}
		if err := request.byteField([]byte(operation.input)); err != nil {
			t.Fatal(err)
		}
		header, response = harness.roundTrip(t, uint64(requestID+4), operation.opcode, request.bytes)
		if header.status != statusOK || len(response) == 0 {
			t.Fatalf("operation %d response = %d/%v", operation.opcode, header.status, response)
		}
	}
}

func TestServerReturnsTypedRequestAndSemanticErrors(t *testing.T) {
	harness := newServerHarness(t)

	request := &protocolWriter{}
	if err := request.byteField([]byte("a(?=b)")); err != nil {
		t.Fatal(err)
	}
	appendByteList(t, request)
	header, response := harness.roundTrip(t, 10, opRegexpBatch, request.bytes)
	if header.status != statusParseError {
		t.Fatalf("regexp status = %d", header.status)
	}
	reader := newProtocolReader(response)
	if message, err := reader.byteField(maximumErrorBytes); err != nil || len(message) == 0 {
		t.Fatalf("regexp error = %q/%v", message, err)
	}

	header, _ = harness.roundTrip(t, 11, opHello, []byte{1})
	if header.status != statusInvalidRequest {
		t.Fatalf("invalid hello status = %d", header.status)
	}
	header, _ = harness.roundTrip(t, 12, opURLParse, nil)
	if header.status != statusInvalidRequest {
		t.Fatalf("malformed URL request status = %d", header.status)
	}

	for requestID, operation := range []struct {
		opcode opcode
		input  string
	}{
		{opFluentdAddress, "http://host"},
		{opGELFAddress, "udp://host"},
		{opSyslogAddress, "http://host"},
	} {
		request = &protocolWriter{}
		if err := request.byteField([]byte(operation.input)); err != nil {
			t.Fatal(err)
		}
		header, _ = harness.roundTrip(t, uint64(requestID+13), operation.opcode, request.bytes)
		if header.status != statusParseError {
			t.Fatalf("operation %d parse status = %d", operation.opcode, header.status)
		}
	}

	frame, err := encodeFrame(frameHeader{
		kind: requestFrame, opcode: opHello, requestID: 20,
		timeoutNanoseconds: uint64(maximumRequestTimeout + time.Second),
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := harness.client.Write(frame); err != nil {
		t.Fatal(err)
	}
	header, _, err = readFrame(harness.client)
	if err != nil || header.status != statusInvalidRequest {
		t.Fatalf("invalid timeout response = %+v/%v", header, err)
	}
}

func TestServerRoundTripsGCPLoggingLifecycle(t *testing.T) {
	harness := newServerHarness(t)
	metadata := &fakeGCPMetadataSource{}
	client := &fakeGCPCloudClient{}
	logger := &fakeGCPCloudLogger{}
	harness.server.gcp, _ = testGCPManager(metadata, client, logger)

	header, response := harness.roundTrip(
		t, 30, opGCPStart, gcpStartPayload(t, "gcp-session"),
	)
	if header.status != statusOK || len(response) != 0 {
		t.Fatalf("start response = %d/%v", header.status, response)
	}

	logRequest := &protocolWriter{}
	if err := logRequest.byteField([]byte("gcp-session")); err != nil {
		t.Fatal(err)
	}
	logRequest.int64(1_700_000_000)
	logRequest.int32(123_456_789)
	if err := logRequest.byteField([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	header, response = harness.roundTrip(t, 31, opGCPLog, logRequest.bytes)
	if header.status != statusOK || len(response) != 0 || len(logger.entries) != 1 {
		t.Fatalf("log response = %d/%v entries=%d", header.status, response, len(logger.entries))
	}

	for requestID, operation := range []opcode{opGCPFlush, opGCPClose} {
		request := &protocolWriter{}
		if err := request.byteField([]byte("gcp-session")); err != nil {
			t.Fatal(err)
		}
		header, response = harness.roundTrip(
			t, uint64(requestID+32), operation, request.bytes,
		)
		if header.status != statusOK || len(response) != 0 {
			t.Fatalf("operation %d response = %d/%v", operation, header.status, response)
		}
	}
	if logger.flushCalls != 2 || client.closeCalls != 1 {
		t.Fatalf("lifecycle calls = flush:%d close:%d", logger.flushCalls, client.closeCalls)
	}
}

func TestServerCancellationAndRegistry(t *testing.T) {
	harness := newServerHarness(t)
	contextValue, cancel := context.WithCancel(context.Background())
	if !harness.server.register(99, cancel) {
		t.Fatal("first registration failed")
	}
	if harness.server.register(99, func() {}) {
		t.Fatal("duplicate registration succeeded")
	}

	request := &protocolWriter{}
	request.uint64(99)
	header, _ := harness.roundTrip(t, 20, opCancel, request.bytes)
	if header.status != statusOK {
		t.Fatalf("cancel status = %d", header.status)
	}
	select {
	case <-contextValue.Done():
	case <-time.After(time.Second):
		t.Fatal("registered operation was not cancelled")
	}
	harness.server.unregister(99)

	secondContext, secondCancel := context.WithCancel(context.Background())
	if !harness.server.register(100, secondCancel) {
		t.Fatal("second registration failed")
	}
	harness.server.cancelAll()
	select {
	case <-secondContext.Done():
	case <-time.After(time.Second):
		t.Fatal("cancelAll did not cancel the operation")
	}
	harness.server.unregister(100)
}

func TestServerRejectsInvalidFrameHeader(t *testing.T) {
	client, serverConnection := net.Pipe()
	server := newSemanticServer(serverConnection)
	done := make(chan error, 1)
	go func() { done <- server.serve() }()

	frame, err := encodeFrame(frameHeader{
		kind: responseFrame, opcode: opHello, requestID: 1,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Write(frame); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("invalid request header did not stop the server")
		}
	case <-time.After(time.Second):
		t.Fatal("server did not reject invalid request header")
	}
	_ = client.Close()
}

func TestRunValidatesArgumentsAndServesConnection(t *testing.T) {
	for _, arguments := range [][]string{
		nil,
		{"--fd=2"},
		{"--fd=3", "extra"},
		{"--unknown"},
	} {
		if err := run(arguments, func(int) (net.Conn, error) {
			t.Fatal("invalid arguments reached the connection adopter")
			return nil, nil
		}); err == nil {
			t.Fatalf("arguments %q must fail", arguments)
		}
	}

	client, serverConnection := net.Pipe()
	done := make(chan error, 1)
	go func() {
		done <- run([]string{"--fd=3"}, func(descriptor int) (net.Conn, error) {
			if descriptor != 3 {
				return nil, errors.New("unexpected descriptor")
			}
			return serverConnection, nil
		})
	}()
	harness := serverHarness{client: client}
	header, _ := harness.roundTrip(t, 1, opHello, nil)
	if header.status != statusOK {
		t.Fatalf("hello status = %d", header.status)
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("run did not stop after peer closure")
	}

	expected := errors.New("adoption failed")
	if err := run([]string{"--fd=3"}, func(int) (net.Conn, error) {
		return nil, expected
	}); !errors.Is(err, expected) {
		t.Fatalf("adopter error = %v", err)
	}
}

// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/logging"
)

type fakeGCPMetadataSource struct {
	onCompute      bool
	project        string
	zoneValue      string
	nameValue      string
	idValue        string
	onComputeCalls int
}

func (m *fakeGCPMetadataSource) onGCE() bool {
	m.onComputeCalls++
	return m.onCompute
}

func (m *fakeGCPMetadataSource) projectID(context.Context) (string, error) {
	return m.project, nil
}

func (m *fakeGCPMetadataSource) zone(context.Context) (string, error) {
	return m.zoneValue, nil
}

func (m *fakeGCPMetadataSource) instanceName(context.Context) (string, error) {
	return m.nameValue, nil
}

func (m *fakeGCPMetadataSource) instanceID(context.Context) (string, error) {
	return m.idValue, nil
}

type fakeGCPCloudClient struct {
	pingError    error
	closeError   error
	closeCalls   int
	errorHandler func(error)
}

func (c *fakeGCPCloudClient) Ping(context.Context) error {
	return c.pingError
}

func (c *fakeGCPCloudClient) Close() error {
	c.closeCalls++
	return c.closeError
}

func (c *fakeGCPCloudClient) setErrorHandler(handler func(error)) {
	c.errorHandler = handler
}

type fakeGCPCloudLogger struct {
	entries    []logging.Entry
	flushError error
	flushCalls int
}

func (l *fakeGCPCloudLogger) Log(entry logging.Entry) {
	l.entries = append(l.entries, entry)
}

func (l *fakeGCPCloudLogger) Flush() error {
	l.flushCalls++
	return l.flushError
}

type fakeGCPCloudFactory struct {
	client   *fakeGCPCloudClient
	logger   *fakeGCPCloudLogger
	project  string
	instance *gcpInstanceInfo
}

func (f *fakeGCPCloudFactory) newClient(
	_ context.Context,
	project string,
	instance *gcpInstanceInfo,
) (gcpCloudClient, gcpCloudLogger, error) {
	f.project = project
	f.instance = instance
	return f.client, f.logger, nil
}

func testGCPManager(
	metadata *fakeGCPMetadataSource,
	client *fakeGCPCloudClient,
	logger *fakeGCPCloudLogger,
) (*gcpLoggingManager, *fakeGCPCloudFactory) {
	factory := &fakeGCPCloudFactory{client: client, logger: logger}
	return &gcpLoggingManager{
		metadataSource: metadata,
		cloudFactory:   factory,
		sessions:       make(map[string]*gcpLoggingSession),
	}, factory
}

func TestGCPLoggingUsesExplicitProjectMetadataAndDockerPayload(t *testing.T) {
	metadata := &fakeGCPMetadataSource{}
	client := &fakeGCPCloudClient{}
	logger := &fakeGCPCloudLogger{}
	manager, factory := testGCPManager(metadata, client, logger)
	info := testLogInfo()
	info.Config = map[string]string{
		"gcp-project":   "project-one",
		"gcp-log-cmd":   "true",
		"gcp-meta-zone": "europe-west2-a",
		"gcp-meta-name": "host-one",
		"gcp-meta-id":   "instance-one",
		"labels":        "com.example.label",
		"env":           "ALPHA",
	}

	if err := manager.start(context.Background(), "session-one", info); err != nil {
		t.Fatal(err)
	}
	if factory.project != "project-one" {
		t.Fatalf("project = %q", factory.project)
	}
	wantInstance := &gcpInstanceInfo{
		Zone: "europe-west2-a", Name: "host-one", ID: "instance-one",
	}
	if !reflect.DeepEqual(factory.instance, wantInstance) {
		t.Fatalf("instance = %+v, want %+v", factory.instance, wantInstance)
	}

	timestamp := time.Unix(1_700_000_000, 123_456_789).UTC()
	if err := manager.log("session-one", timestamp, []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if len(logger.entries) != 1 || logger.entries[0].Timestamp != timestamp {
		t.Fatalf("entries = %+v", logger.entries)
	}
	payload, ok := logger.entries[0].Payload.(*gcpDockerLogEntry)
	if !ok {
		t.Fatalf("payload type = %T", logger.entries[0].Payload)
	}
	if payload.Message != "hello" || !reflect.DeepEqual(payload.Instance, wantInstance) {
		t.Fatalf("payload = %+v", payload)
	}
	if payload.Container.Command != "/bin/sh -c echo ok" {
		t.Fatalf("command = %q", payload.Container.Command)
	}
	wantAttributes := map[string]string{
		"ALPHA": "one", "com.example.label": "value",
	}
	if !reflect.DeepEqual(payload.Container.Metadata, wantAttributes) {
		t.Fatalf("metadata = %v, want %v", payload.Container.Metadata, wantAttributes)
	}

	if err := manager.close("session-one"); err != nil {
		t.Fatal(err)
	}
	if logger.flushCalls != 1 || client.closeCalls != 1 {
		t.Fatalf("close calls = flush:%d client:%d", logger.flushCalls, client.closeCalls)
	}
}

func TestGCPLoggingUsesCachedComputeMetadataAndExplicitProjectOverride(t *testing.T) {
	metadata := &fakeGCPMetadataSource{
		onCompute: true,
		project:   "metadata-project",
		zoneValue: "metadata-zone",
		nameValue: "metadata-name",
		idValue:   "metadata-id",
	}
	client := &fakeGCPCloudClient{}
	logger := &fakeGCPCloudLogger{}
	manager, factory := testGCPManager(metadata, client, logger)
	info := testLogInfo()
	info.Config = map[string]string{
		"gcp-project":   "explicit-project",
		"gcp-meta-zone": "ignored-zone",
	}

	if err := manager.start(context.Background(), "first", info); err != nil {
		t.Fatal(err)
	}
	if factory.project != "explicit-project" {
		t.Fatalf("project = %q", factory.project)
	}
	wantInstance := &gcpInstanceInfo{
		Zone: "metadata-zone", Name: "metadata-name", ID: "metadata-id",
	}
	if !reflect.DeepEqual(factory.instance, wantInstance) {
		t.Fatalf("instance = %+v, want %+v", factory.instance, wantInstance)
	}
	if metadata.onComputeCalls != 1 {
		t.Fatalf("metadata detection calls = %d", metadata.onComputeCalls)
	}
}

func TestGCPLoggingUsesMetadataProjectAndClosesAllSessions(t *testing.T) {
	metadata := &fakeGCPMetadataSource{
		onCompute: true,
		project:   "metadata-project",
		zoneValue: "metadata-zone",
		nameValue: "metadata-name",
		idValue:   "metadata-id",
	}
	client := &fakeGCPCloudClient{}
	logger := &fakeGCPCloudLogger{}
	manager, factory := testGCPManager(metadata, client, logger)
	info := testLogInfo()
	info.Config = map[string]string{}

	for _, sessionID := range []string{"first", "second"} {
		if err := manager.start(context.Background(), sessionID, info); err != nil {
			t.Fatal(err)
		}
	}
	if factory.project != "metadata-project" {
		t.Fatalf("project = %q", factory.project)
	}
	if metadata.onComputeCalls != 1 {
		t.Fatalf("metadata detection calls = %d", metadata.onComputeCalls)
	}
	manager.closeAll()
	if logger.flushCalls != 2 || client.closeCalls != 2 {
		t.Fatalf("close-all calls = flush:%d close:%d", logger.flushCalls, client.closeCalls)
	}
	if err := manager.flush("first"); err == nil {
		t.Fatal("closed session unexpectedly remained registered")
	}
}

func TestGCPLoggingRejectsInvalidSessionLifecycle(t *testing.T) {
	manager, _ := testGCPManager(
		&fakeGCPMetadataSource{},
		&fakeGCPCloudClient{},
		&fakeGCPCloudLogger{},
	)
	info := testLogInfo()
	info.Config = map[string]string{"gcp-project": "project"}
	if err := manager.start(context.Background(), "", info); err == nil {
		t.Fatal("empty session identifier unexpectedly succeeded")
	}
	if err := manager.log("missing", time.Now(), nil); err == nil {
		t.Fatal("missing session log unexpectedly succeeded")
	}
	if err := manager.close("missing"); err == nil {
		t.Fatal("missing session close unexpectedly succeeded")
	}
	if err := manager.start(context.Background(), "session", info); err != nil {
		t.Fatal(err)
	}
	if err := manager.start(context.Background(), "session", info); err == nil {
		t.Fatal("duplicate session unexpectedly succeeded")
	}
}

func TestGCPLoggingRejectsInvalidConfigurationBeforeEffects(t *testing.T) {
	for _, test := range []struct {
		name   string
		config map[string]string
	}{
		{name: "missing project", config: map[string]string{}},
		{name: "unknown option", config: map[string]string{"future": "value"}},
		{
			name: "invalid metadata expression",
			config: map[string]string{
				"gcp-project": "project", "labels-regex": "a(?=b)",
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			metadata := &fakeGCPMetadataSource{}
			client := &fakeGCPCloudClient{}
			logger := &fakeGCPCloudLogger{}
			manager, factory := testGCPManager(metadata, client, logger)
			info := testLogInfo()
			info.Config = test.config
			if err := manager.start(context.Background(), "session", info); err == nil {
				t.Fatal("start unexpectedly succeeded")
			}
			if test.name == "unknown option" && factory.project != "" {
				t.Fatal("unknown option reached cloud client creation")
			}
		})
	}
}

func TestGCPLoggingPropagatesPingFlushAndCloseFailures(t *testing.T) {
	pingFailure := errors.New("ping failed")
	metadata := &fakeGCPMetadataSource{}
	client := &fakeGCPCloudClient{pingError: pingFailure}
	logger := &fakeGCPCloudLogger{}
	manager, _ := testGCPManager(metadata, client, logger)
	info := testLogInfo()
	info.Config = map[string]string{"gcp-project": "project"}
	if err := manager.start(context.Background(), "session", info); err == nil ||
		!strings.Contains(err.Error(), pingFailure.Error()) {
		t.Fatalf("start error = %v", err)
	}

	client.pingError = nil
	logger.flushError = errors.New("flush failed")
	if err := manager.start(context.Background(), "session", info); err != nil {
		t.Fatal(err)
	}
	if err := manager.flush("session"); !errors.Is(err, logger.flushError) {
		t.Fatalf("flush error = %v", err)
	}
	client.closeError = errors.New("close failed")
	if err := manager.close("session"); !errors.Is(err, client.closeError) {
		t.Fatalf("close error = %v", err)
	}
}

func TestGCPLoggingCountsOfficialOverflowSignal(t *testing.T) {
	manager := newGCPLoggingManager()
	manager.handleAsyncError(logging.ErrOverflow)
	manager.handleAsyncError(errors.New("other"))
	if manager.droppedLogs.Load() != 1 {
		t.Fatalf("dropped logs = %d", manager.droppedLogs.Load())
	}
}

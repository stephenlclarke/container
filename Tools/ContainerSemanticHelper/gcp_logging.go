// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.
//
// The gcplogs behavior in this file is derived from Moby docker-v29.2.1
// (commit 6bc6209b88a7a834c91f77d848e025c79e0227a1), also licensed under
// Apache License 2.0.

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"cloud.google.com/go/compute/metadata"
	"cloud.google.com/go/logging"
	mrpb "google.golang.org/genproto/googleapis/api/monitoredres"
)

const gcpLoggerName = "gcplogs-docker-driver"

var gcpKnownOptions = map[string]struct{}{
	"cache-compress":  {},
	"cache-disabled":  {},
	"cache-max-file":  {},
	"cache-max-size":  {},
	"env":             {},
	"env-regex":       {},
	"gcp-log-cmd":     {},
	"gcp-meta-id":     {},
	"gcp-meta-name":   {},
	"gcp-meta-zone":   {},
	"gcp-project":     {},
	"labels":          {},
	"labels-regex":    {},
	"max-buffer-size": {},
	"mode":            {},
}

type gcpInstanceInfo struct {
	Zone string `json:"zone,omitempty"`
	Name string `json:"name,omitempty"`
	ID   string `json:"id,omitempty"`
}

type gcpContainerInfo struct {
	Name      string            `json:"name,omitempty"`
	ID        string            `json:"id,omitempty"`
	ImageName string            `json:"imageName,omitempty"`
	ImageID   string            `json:"imageId,omitempty"`
	Created   time.Time         `json:"created,omitempty"`
	Command   string            `json:"command,omitempty"`
	Metadata  map[string]string `json:"metadata,omitempty"`
}

type gcpDockerLogEntry struct {
	Instance  *gcpInstanceInfo  `json:"instance,omitempty"`
	Container *gcpContainerInfo `json:"container,omitempty"`
	Message   string            `json:"message,omitempty"`
}

type gcpMetadataSource interface {
	onGCE() bool
	projectID(context.Context) (string, error)
	zone(context.Context) (string, error)
	instanceName(context.Context) (string, error)
	instanceID(context.Context) (string, error)
}

type officialGCPMetadataSource struct{}

func (officialGCPMetadataSource) onGCE() bool {
	return metadata.OnGCE()
}

func (officialGCPMetadataSource) projectID(ctx context.Context) (string, error) {
	return metadata.ProjectIDWithContext(ctx)
}

func (officialGCPMetadataSource) zone(ctx context.Context) (string, error) {
	return metadata.ZoneWithContext(ctx)
}

func (officialGCPMetadataSource) instanceName(ctx context.Context) (string, error) {
	return metadata.InstanceNameWithContext(ctx)
}

func (officialGCPMetadataSource) instanceID(ctx context.Context) (string, error) {
	return metadata.InstanceIDWithContext(ctx)
}

type gcpCloudClient interface {
	Ping(context.Context) error
	Close() error
	setErrorHandler(func(error))
}

type gcpCloudLogger interface {
	Log(logging.Entry)
	Flush() error
}

type gcpCloudFactory interface {
	newClient(
		context.Context,
		string,
		*gcpInstanceInfo,
	) (gcpCloudClient, gcpCloudLogger, error)
}

type officialGCPCloudFactory struct{}

type officialGCPCloudClient struct {
	client *logging.Client
}

func (officialGCPCloudFactory) newClient(
	ctx context.Context,
	project string,
	instance *gcpInstanceInfo,
) (gcpCloudClient, gcpCloudLogger, error) {
	client, err := logging.NewClient(ctx, project)
	if err != nil {
		return nil, nil, err
	}
	options := []logging.LoggerOption{}
	if instance != nil {
		options = append(options, logging.CommonResource(&mrpb.MonitoredResource{
			Type: "gce_instance",
			Labels: map[string]string{
				"instance_id": instance.ID,
				"zone":        instance.Zone,
			},
		}))
	}
	return &officialGCPCloudClient{client: client}, client.Logger(gcpLoggerName, options...), nil
}

func (c *officialGCPCloudClient) Ping(ctx context.Context) error {
	return c.client.Ping(ctx)
}

func (c *officialGCPCloudClient) Close() error {
	return c.client.Close()
}

func (c *officialGCPCloudClient) setErrorHandler(handler func(error)) {
	c.client.OnError = handler
}

type gcpMetadataSnapshot struct {
	onGCE        bool
	projectID    string
	zone         string
	instanceName string
	instanceID   string
}

type gcpLoggingSession struct {
	client    gcpCloudClient
	logger    gcpCloudLogger
	instance  *gcpInstanceInfo
	container *gcpContainerInfo
}

type gcpLoggingManager struct {
	metadataSource gcpMetadataSource
	cloudFactory   gcpCloudFactory
	metadataOnce   sync.Once
	metadata       gcpMetadataSnapshot
	mu             sync.Mutex
	sessions       map[string]*gcpLoggingSession
	droppedLogs    atomic.Uint64
}

func newGCPLoggingManager() *gcpLoggingManager {
	return &gcpLoggingManager{
		metadataSource: officialGCPMetadataSource{},
		cloudFactory:   officialGCPCloudFactory{},
		sessions:       make(map[string]*gcpLoggingSession),
	}
}

func (m *gcpLoggingManager) start(
	ctx context.Context,
	sessionID string,
	info dockerLogInfo,
) error {
	if sessionID == "" {
		return errors.New("gcplogs session identifier is empty")
	}
	if err := validateGCPOptions(info.Config); err != nil {
		return err
	}
	m.mu.Lock()
	_, exists := m.sessions[sessionID]
	m.mu.Unlock()
	if exists {
		return errors.New("gcplogs session already exists")
	}

	metadata := m.metadataSnapshot()
	project := metadata.projectID
	if configured, found := info.Config["gcp-project"]; found {
		project = configured
	}
	if project == "" {
		return errors.New("No project was specified and couldn't read project from the metadata server. Please specify a project")
	}

	instance := configuredGCPInstance(metadata, info.Config)
	client, logger, err := m.cloudFactory.newClient(ctx, project, instance)
	if err != nil {
		return err
	}
	if err := client.Ping(ctx); err != nil {
		return fmt.Errorf("unable to connect or authenticate with Google Cloud Logging: %v", err)
	}
	extraAttributes, err := info.ExtraAttributes(nil)
	if err != nil {
		return err
	}
	container := &gcpContainerInfo{
		Name:      info.ContainerName,
		ID:        info.ContainerID,
		ImageName: info.ContainerImageName,
		ImageID:   info.ContainerImageID,
		Created:   info.ContainerCreated,
		Metadata:  extraAttributes,
	}
	if info.Config["gcp-log-cmd"] == "true" {
		container.Command = info.Command()
	}
	client.setErrorHandler(m.handleAsyncError)
	session := &gcpLoggingSession{
		client: client, logger: logger, instance: instance, container: container,
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.sessions[sessionID]; exists {
		_ = client.Close()
		return errors.New("gcplogs session already exists")
	}
	m.sessions[sessionID] = session
	return nil
}

func (m *gcpLoggingManager) log(
	sessionID string,
	timestamp time.Time,
	line []byte,
) error {
	session, err := m.session(sessionID)
	if err != nil {
		return err
	}
	session.logger.Log(logging.Entry{
		Timestamp: timestamp,
		Payload: &gcpDockerLogEntry{
			Instance:  session.instance,
			Container: session.container,
			Message:   string(line),
		},
	})
	return nil
}

func (m *gcpLoggingManager) flush(sessionID string) error {
	session, err := m.session(sessionID)
	if err != nil {
		return err
	}
	return session.logger.Flush()
}

func (m *gcpLoggingManager) close(sessionID string) error {
	m.mu.Lock()
	session, exists := m.sessions[sessionID]
	if exists {
		delete(m.sessions, sessionID)
	}
	m.mu.Unlock()
	if !exists {
		return errors.New("gcplogs session does not exist")
	}
	_ = session.logger.Flush()
	return session.client.Close()
}

func (m *gcpLoggingManager) closeAll() {
	m.mu.Lock()
	sessions := make([]*gcpLoggingSession, 0, len(m.sessions))
	for sessionID, session := range m.sessions {
		sessions = append(sessions, session)
		delete(m.sessions, sessionID)
	}
	m.mu.Unlock()
	for _, session := range sessions {
		_ = session.logger.Flush()
		_ = session.client.Close()
	}
}

func (m *gcpLoggingManager) session(sessionID string) (*gcpLoggingSession, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, exists := m.sessions[sessionID]
	if !exists {
		return nil, errors.New("gcplogs session does not exist")
	}
	return session, nil
}

func (m *gcpLoggingManager) metadataSnapshot() gcpMetadataSnapshot {
	m.metadataOnce.Do(func() {
		onGCE := m.metadataSource.onGCE()
		m.metadata.onGCE = onGCE
		if !onGCE {
			return
		}
		ctx := context.Background()
		m.metadata.projectID, _ = m.metadataSource.projectID(ctx)
		m.metadata.zone, _ = m.metadataSource.zone(ctx)
		m.metadata.instanceName, _ = m.metadataSource.instanceName(ctx)
		m.metadata.instanceID, _ = m.metadataSource.instanceID(ctx)
	})
	return m.metadata
}

func (m *gcpLoggingManager) handleAsyncError(err error) {
	if errors.Is(err, logging.ErrOverflow) {
		if count := m.droppedLogs.Add(1); count%1000 == 1 {
			_, _ = fmt.Fprintf(
				os.Stderr,
				"gcplogs driver has dropped %d logs\n",
				count,
			)
		}
		return
	}
	_, _ = fmt.Fprintf(os.Stderr, "gcplogs driver asynchronous error: %v\n", err)
}

func configuredGCPInstance(
	metadata gcpMetadataSnapshot,
	configuration map[string]string,
) *gcpInstanceInfo {
	if metadata.onGCE {
		return &gcpInstanceInfo{
			Zone: metadata.zone, Name: metadata.instanceName, ID: metadata.instanceID,
		}
	}
	zone := configuration["gcp-meta-zone"]
	name := configuration["gcp-meta-name"]
	id := configuration["gcp-meta-id"]
	if zone == "" && name == "" && id == "" {
		return nil
	}
	return &gcpInstanceInfo{Zone: zone, Name: name, ID: id}
}

func validateGCPOptions(configuration map[string]string) error {
	for option := range configuration {
		if _, known := gcpKnownOptions[option]; !known {
			return fmt.Errorf("%q is not a valid option for the gcplogs driver", option)
		}
	}
	return nil
}

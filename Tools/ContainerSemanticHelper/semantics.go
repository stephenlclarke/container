// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.
//
// The logger Info methods and template function behavior in this file are
// derived from Moby docker-v29.2.1 (commit 6bc6209b88a7a834c91f77d848e025c79e0227a1),
// also licensed under Apache License 2.0.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"text/template"
	"time"
)

const defaultLogTagTemplate = "{{.ID}}"

var errTemplateOutputLimit = errors.New(
	"rendered log tag exceeds helper output limit",
)

type semanticError struct {
	status  responseStatus
	message string
}

func (e *semanticError) Error() string {
	return e.message
}

type semanticEngine struct {
	regexps   *lruCache[*regexp.Regexp]
	templates *lruCache[*template.Template]
}

func newSemanticEngine() *semanticEngine {
	return &semanticEngine{
		regexps:   newLRUCache[*regexp.Regexp](256, 2*1024*1024),
		templates: newLRUCache[*template.Template](128, 2*1024*1024),
	}
}

func (e *semanticEngine) matchRegexpBatch(
	ctx context.Context,
	pattern []byte,
	candidates [][]byte,
) ([]bool, error) {
	key := string(pattern)
	expression, found := e.regexps.get(key)
	if !found {
		compiled, err := regexp.Compile(key)
		if err != nil {
			return nil, &semanticError{status: statusParseError, message: err.Error()}
		}
		expression = compiled
		e.regexps.put(key, expression, len(pattern)+512)
	}
	result := make([]bool, 0, len(candidates))
	for _, candidate := range candidates {
		select {
		case <-ctx.Done():
			return nil, contextSemanticError(ctx.Err())
		default:
		}
		result = append(result, expression.Match(candidate))
	}
	return result, nil
}

func (e *semanticEngine) renderLogTemplate(
	ctx context.Context,
	format []byte,
	info dockerLogInfo,
) ([]byte, error) {
	if len(format) == 0 {
		format = []byte(defaultLogTagTemplate)
	}
	key := string(format)
	tmpl, found := e.templates.get(key)
	if !found {
		parsed, err := newLogTemplate(key)
		if err != nil {
			return nil, &semanticError{status: statusParseError, message: err.Error()}
		}
		tmpl = parsed
		e.templates.put(key, tmpl, len(format)+2048)
	}

	type executionResult struct {
		bytes []byte
		err   error
	}
	done := make(chan executionResult, 1)
	go func() {
		writer := &boundedTemplateWriter{maximum: maximumOutputBytes}
		err := tmpl.Execute(writer, &info)
		done <- executionResult{bytes: writer.bytes(), err: err}
	}()

	select {
	case <-ctx.Done():
		return nil, contextSemanticError(ctx.Err())
	case result := <-done:
		if result.err != nil {
			status := statusExecuteError
			if errors.Is(result.err, errTemplateOutputLimit) {
				status = statusOutputLimit
			}
			return nil, &semanticError{
				status:  status,
				message: result.err.Error(),
			}
		}
		return result.bytes, nil
	}
}

func newLogTemplate(format string) (*template.Template, error) {
	return template.New("log-tag").Funcs(template.FuncMap{
		"json": func(v any) string {
			buffer := &bytes.Buffer{}
			encoder := json.NewEncoder(buffer)
			encoder.SetEscapeHTML(false)
			_ = encoder.Encode(v)
			return strings.TrimSpace(buffer.String())
		},
		"split":    strings.Split,
		"join":     strings.Join,
		"title":    strings.Title,
		"lower":    strings.ToLower,
		"upper":    strings.ToUpper,
		"pad":      padWithSpace,
		"truncate": truncateWithLength,
	}).Parse(format)
}

func padWithSpace(source string, prefix, suffix int) string {
	if source == "" {
		return source
	}
	return strings.Repeat(" ", prefix) + source + strings.Repeat(" ", suffix)
}

func truncateWithLength(source string, length int) string {
	if len(source) < length {
		return source
	}
	return source[:length]
}

type boundedTemplateWriter struct {
	buffer  bytes.Buffer
	maximum int
}

func (w *boundedTemplateWriter) Write(value []byte) (int, error) {
	if len(value) > w.maximum-w.buffer.Len() {
		return 0, errTemplateOutputLimit
	}
	return w.buffer.Write(value)
}

func (w *boundedTemplateWriter) bytes() []byte {
	return bytes.Clone(w.buffer.Bytes())
}

type dockerLogInfo struct {
	Config              map[string]string
	ContainerID         string
	ContainerName       string
	ContainerEntrypoint string
	ContainerArgs       []string
	ContainerImageID    string
	ContainerImageName  string
	ContainerCreated    time.Time
	ContainerEnv        []string
	ContainerLabels     map[string]string
	LogPath             string
	DaemonName          string
	hostname            string
}

func (info *dockerLogInfo) Hostname() (string, error) {
	return info.hostname, nil
}

func (info *dockerLogInfo) Command() string {
	terms := []string{info.ContainerEntrypoint}
	terms = append(terms, info.ContainerArgs...)
	return strings.Join(terms, " ")
}

func (info *dockerLogInfo) ExtraAttributes(
	keyModifier func(string) string,
) (map[string]string, error) {
	extra := make(map[string]string)
	if labels := info.Config["labels"]; labels != "" {
		for label := range strings.SplitSeq(labels, ",") {
			if value, found := info.ContainerLabels[label]; found {
				if keyModifier != nil {
					label = keyModifier(label)
				}
				extra[label] = value
			}
		}
	}
	if pattern := info.Config["labels-regex"]; pattern != "" {
		expression, err := regexp.Compile(pattern)
		if err != nil {
			return nil, err
		}
		for key, value := range info.ContainerLabels {
			if expression.MatchString(key) {
				if keyModifier != nil {
					key = keyModifier(key)
				}
				extra[key] = value
			}
		}
	}

	environment := make(map[string]string)
	for _, entry := range info.ContainerEnv {
		if key, value, found := strings.Cut(entry, "="); found {
			environment[key] = value
		}
	}
	if len(environment) == 0 {
		return extra, nil
	}
	if names := info.Config["env"]; names != "" {
		for name := range strings.SplitSeq(names, ",") {
			if value, found := environment[name]; found {
				if keyModifier != nil {
					name = keyModifier(name)
				}
				extra[name] = value
			}
		}
	}
	if pattern := info.Config["env-regex"]; pattern != "" {
		expression, err := regexp.Compile(pattern)
		if err != nil {
			return nil, err
		}
		for key, value := range environment {
			if expression.MatchString(key) {
				if keyModifier != nil {
					key = keyModifier(key)
				}
				extra[key] = value
			}
		}
	}
	return extra, nil
}

func (info *dockerLogInfo) ID() string {
	return info.ContainerID[:12]
}

func (info *dockerLogInfo) FullID() string {
	return info.ContainerID
}

func (info *dockerLogInfo) Name() string {
	return strings.TrimPrefix(info.ContainerName, "/")
}

func (info *dockerLogInfo) ImageID() string {
	return info.ContainerImageID[:12]
}

func (info *dockerLogInfo) ImageFullID() string {
	return info.ContainerImageID
}

func (info *dockerLogInfo) ImageName() string {
	return info.ContainerImageName
}

func parseRawURL(source []byte) (*url.URL, error) {
	parsed, err := url.Parse(string(source))
	if err != nil {
		return nil, &semanticError{status: statusParseError, message: err.Error()}
	}
	return parsed, nil
}

type fluentdAddress struct {
	protocol string
	host     string
	port     uint16
	path     string
}

func parseFluentdAddress(address string) (fluentdAddress, error) {
	const (
		defaultProtocol = "tcp"
		defaultHost     = "127.0.0.1"
		defaultPort     = 24224
	)
	if address == "" {
		return fluentdAddress{
			protocol: defaultProtocol,
			host:     defaultHost,
			port:     defaultPort,
		}, nil
	}
	if !strings.Contains(address, "://") {
		address = defaultProtocol + "://" + address
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return fluentdAddress{}, err
	}
	switch parsed.Scheme {
	case "unix":
		if strings.TrimLeft(parsed.Path, "/") == "" {
			return fluentdAddress{}, errors.New("path is empty")
		}
		return fluentdAddress{protocol: parsed.Scheme, path: parsed.Path}, nil
	case "tcp", "tls":
	default:
		return fluentdAddress{}, fmt.Errorf("unsupported scheme: '%s'", parsed.Scheme)
	}
	if parsed.Path != "" {
		return fluentdAddress{}, errors.New("should not contain a path element")
	}
	host := defaultHost
	port := uint64(defaultPort)
	if value := parsed.Hostname(); value != "" {
		host = value
	}
	if value := parsed.Port(); value != "" {
		parsedPort, err := strconv.ParseUint(value, 10, 16)
		if err != nil {
			return fluentdAddress{}, fmt.Errorf("invalid port: %w", err)
		}
		port = parsedPort
	}
	return fluentdAddress{
		protocol: parsed.Scheme,
		host:     host,
		port:     uint16(port),
	}, nil
}

type gelfAddress struct {
	scheme string
	host   string
}

func parseGELFAddress(address string) (gelfAddress, error) {
	if address == "" {
		return gelfAddress{}, errors.New("gelf-address is a required parameter")
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return gelfAddress{}, err
	}
	if parsed.Scheme != "udp" && parsed.Scheme != "tcp" {
		return gelfAddress{}, errors.New("gelf: endpoint needs to be TCP or UDP")
	}
	if _, _, err = net.SplitHostPort(parsed.Host); err != nil {
		return gelfAddress{}, errors.New(
			"gelf: please provide gelf-address as proto://host:port",
		)
	}
	return gelfAddress{scheme: parsed.Scheme, host: parsed.Host}, nil
}

type syslogAddress struct {
	protocol string
	address  string
}

func resolveNetworkEndpoint(
	ctx context.Context,
	network string,
	address string,
) (string, uint16, error) {
	host, service, err := net.SplitHostPort(address)
	if err != nil {
		return "", 0, err
	}
	port, err := net.DefaultResolver.LookupPort(ctx, network, service)
	if err != nil {
		return "", 0, err
	}
	return host, uint16(port), nil
}

func parseSyslogAddress(address string) (syslogAddress, error) {
	const (
		secureProtocol = "tcp+tls"
		defaultPort    = "514"
	)
	if address == "" {
		return syslogAddress{}, nil
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return syslogAddress{}, err
	}
	if parsed.Scheme == "unix" || parsed.Scheme == "unixgram" {
		if _, err := os.Stat(parsed.Path); err != nil {
			return syslogAddress{}, err
		}
		return syslogAddress{protocol: parsed.Scheme, address: parsed.Path}, nil
	}
	if parsed.Scheme != "udp" && parsed.Scheme != "tcp" && parsed.Scheme != secureProtocol {
		return syslogAddress{}, fmt.Errorf("unsupported scheme: '%s'", parsed.Scheme)
	}
	host := parsed.Host
	if _, _, err := net.SplitHostPort(host); err != nil {
		if !strings.Contains(err.Error(), "missing port in address") {
			return syslogAddress{}, err
		}
		host = net.JoinHostPort(host, defaultPort)
	}
	return syslogAddress{protocol: parsed.Scheme, address: host}, nil
}

func contextSemanticError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return &semanticError{
			status:  statusDeadlineExceeded,
			message: context.DeadlineExceeded.Error(),
		}
	}
	return &semanticError{
		status:  statusCancelled,
		message: context.Canceled.Error(),
	}
}

var _ io.Writer = (*boundedTemplateWriter)(nil)

// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type oracleVectors struct {
	SchemaVersion      int              `json:"schemaVersion"`
	GoVersion          string           `json:"goVersion"`
	MobyCommit         string           `json:"mobyCommit"`
	RegularExpressions []regexpOracle   `json:"regularExpressions"`
	Templates          []templateOracle `json:"templates"`
	URLs               []urlOracle      `json:"urls"`
	Fluentd            []fluentdOracle  `json:"fluentd"`
	GELF               []gelfOracle     `json:"gelf"`
	Syslog             []syslogOracle   `json:"syslog"`
}

type regexpOracle struct {
	Pattern    string   `json:"pattern"`
	Candidates []string `json:"candidates"`
	Matches    []bool   `json:"matches"`
}

type templateOracle struct {
	Template string `json:"template"`
	Expected string `json:"expected"`
}

type urlOracle struct {
	Source        string `json:"source"`
	Scheme        string `json:"scheme"`
	Opaque        string `json:"opaque"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	PasswordIsSet bool   `json:"passwordIsSet"`
	Host          string `json:"host"`
	Path          string `json:"path"`
	RawPath       string `json:"rawPath"`
	ForceQuery    bool   `json:"forceQuery"`
	RawQuery      string `json:"rawQuery"`
	Fragment      string `json:"fragment"`
	RawFragment   string `json:"rawFragment"`
	Hostname      string `json:"hostname"`
	Port          string `json:"port"`
}

type fluentdOracle struct {
	Address  string `json:"address"`
	Protocol string `json:"protocol"`
	Host     string `json:"host"`
	Port     uint16 `json:"port"`
	Path     string `json:"path"`
}

type gelfOracle struct {
	Address string `json:"address"`
	Scheme  string `json:"scheme"`
	Host    string `json:"host"`
}

type syslogOracle struct {
	Address       string `json:"address"`
	Protocol      string `json:"protocol"`
	ParsedAddress string `json:"parsedAddress"`
}

func loadOracle(t *testing.T) oracleVectors {
	t.Helper()
	contents, err := os.ReadFile("oracle-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var result oracleVectors
	if err := json.Unmarshal(contents, &result); err != nil {
		t.Fatal(err)
	}
	if result.SchemaVersion != 1 || result.GoVersion != "go1.25.6" || result.MobyCommit != "6bc6209b88a7a834c91f77d848e025c79e0227a1" {
		t.Fatalf("unexpected oracle provenance: %+v", result)
	}
	return result
}

func testLogInfo() dockerLogInfo {
	return dockerLogInfo{
		Config:              map[string]string{"tag": "configured"},
		ContainerID:         "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		ContainerName:       "/alpha",
		ContainerEntrypoint: "/bin/sh",
		ContainerArgs:       []string{"-c", "echo ok"},
		ContainerImageID:    "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
		ContainerImageName:  "example/image:latest",
		ContainerCreated:    time.Unix(1_234_567_890, 123_456_789).UTC(),
		ContainerEnv:        []string{"ALPHA=one"},
		ContainerLabels:     map[string]string{"com.example.label": "value"},
		LogPath:             "/private/log",
		DaemonName:          "dockerd",
		hostname:            "engine-host",
	}
}

func TestOracleRegularExpressions(t *testing.T) {
	engine := newSemanticEngine()
	for _, vector := range loadOracle(t).RegularExpressions {
		candidates := make([][]byte, 0, len(vector.Candidates))
		for _, candidate := range vector.Candidates {
			candidates = append(candidates, []byte(candidate))
		}
		matches, err := engine.matchRegexpBatch(context.Background(), []byte(vector.Pattern), candidates)
		if err != nil {
			t.Fatalf("pattern %q: %v", vector.Pattern, err)
		}
		if !reflect.DeepEqual(matches, vector.Matches) {
			t.Fatalf("pattern %q: got %v, want %v", vector.Pattern, matches, vector.Matches)
		}
	}

	_, err := engine.matchRegexpBatch(context.Background(), []byte("a(?=b)"), nil)
	var semantic *semanticError
	if !errors.As(err, &semantic) || semantic.status != statusParseError {
		t.Fatalf("lookahead must fail with a parse error, got %v", err)
	}
}

func TestOracleTemplates(t *testing.T) {
	engine := newSemanticEngine()
	for _, vector := range loadOracle(t).Templates {
		output, err := engine.renderLogTemplate(context.Background(), []byte(vector.Template), testLogInfo())
		if err != nil {
			t.Fatalf("template %q: %v", vector.Template, err)
		}
		if string(output) != vector.Expected {
			t.Fatalf("template %q: got %q, want %q", vector.Template, output, vector.Expected)
		}
	}

	_, err := engine.renderLogTemplate(context.Background(), []byte("{{"), testLogInfo())
	var semantic *semanticError
	if !errors.As(err, &semantic) || semantic.status != statusParseError {
		t.Fatalf("invalid template must fail with a parse error, got %v", err)
	}

	_, err = engine.renderLogTemplate(
		context.Background(),
		[]byte(`{{printf "%2097153s" "x"}}`),
		testLogInfo(),
	)
	if !errors.As(err, &semantic) || semantic.status != statusOutputLimit {
		t.Fatalf("oversized output must fail with output-limit status, got %v", err)
	}
}

func TestDockerLogInfoExtraAttributesMatchesDockerFilters(t *testing.T) {
	info := testLogInfo()
	info.ContainerEnv = append(info.ContainerEnv, "BETA=two", "MALFORMED")
	info.ContainerLabels["com.example.second"] = "second"
	info.Config = map[string]string{
		"labels":       "com.example.label,missing",
		"labels-regex": `\.second$`,
		"env":          "ALPHA,missing",
		"env-regex":    "^BETA$",
	}
	attributes, err := info.ExtraAttributes(strings.ToUpper)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"ALPHA":              "one",
		"BETA":               "two",
		"COM.EXAMPLE.LABEL":  "value",
		"COM.EXAMPLE.SECOND": "second",
	}
	if !reflect.DeepEqual(attributes, want) {
		t.Fatalf("attributes = %v, want %v", attributes, want)
	}

	info.Config["env-regex"] = "a(?=b)"
	if _, err := info.ExtraAttributes(nil); err == nil {
		t.Fatal("invalid environment expression unexpectedly succeeded")
	}
}

func TestOracleURLs(t *testing.T) {
	for _, vector := range loadOracle(t).URLs {
		parsed, err := parseRawURL([]byte(vector.Source))
		if err != nil {
			t.Fatalf("URL %q: %v", vector.Source, err)
		}
		username, password := "", ""
		passwordIsSet := false
		if parsed.User != nil {
			username = parsed.User.Username()
			password, passwordIsSet = parsed.User.Password()
		}
		actual := urlOracle{
			Source: vector.Source, Scheme: parsed.Scheme, Opaque: parsed.Opaque,
			Username: username, Password: password, PasswordIsSet: passwordIsSet,
			Host: parsed.Host, Path: parsed.Path, RawPath: parsed.RawPath,
			ForceQuery: parsed.ForceQuery, RawQuery: parsed.RawQuery,
			Fragment: parsed.Fragment, RawFragment: parsed.RawFragment,
			Hostname: parsed.Hostname(), Port: parsed.Port(),
		}
		if !reflect.DeepEqual(actual, vector) {
			t.Fatalf("URL %q: got %+v, want %+v", vector.Source, actual, vector)
		}
	}
	if _, err := parseRawURL([]byte("%zz")); err == nil {
		t.Fatal("malformed URL escape must fail")
	}
}

func TestOracleDriverAddresses(t *testing.T) {
	oracle := loadOracle(t)
	for _, vector := range oracle.Fluentd {
		actual, err := parseFluentdAddress(vector.Address)
		if err != nil {
			t.Fatalf("Fluentd address %q: %v", vector.Address, err)
		}
		expected := fluentdAddress{protocol: vector.Protocol, host: vector.Host, port: vector.Port, path: vector.Path}
		if actual != expected {
			t.Fatalf("Fluentd address %q: got %+v, want %+v", vector.Address, actual, expected)
		}
	}
	for _, vector := range oracle.GELF {
		actual, err := parseGELFAddress(vector.Address)
		if err != nil {
			t.Fatalf("GELF address %q: %v", vector.Address, err)
		}
		expected := gelfAddress{scheme: vector.Scheme, host: vector.Host}
		if actual != expected {
			t.Fatalf("GELF address %q: got %+v, want %+v", vector.Address, actual, expected)
		}
	}
	for _, vector := range oracle.Syslog {
		actual, err := parseSyslogAddress(vector.Address)
		if err != nil {
			t.Fatalf("Syslog address %q: %v", vector.Address, err)
		}
		expected := syslogAddress{protocol: vector.Protocol, address: vector.ParsedAddress}
		if actual != expected {
			t.Fatalf("Syslog address %q: got %+v, want %+v", vector.Address, actual, expected)
		}
	}
}

func TestAddressFailuresAndUnixSocket(t *testing.T) {
	for _, address := range []string{"tcp://host/path", "http://host:24224", "unix://"} {
		if _, err := parseFluentdAddress(address); err == nil {
			t.Fatalf("Fluentd address %q must fail", address)
		}
	}
	for _, address := range []string{"", "http://host:12201", "udp://host"} {
		if _, err := parseGELFAddress(address); err == nil {
			t.Fatalf("GELF address %q must fail", address)
		}
	}
	if _, err := parseSyslogAddress("http://host"); err == nil {
		t.Fatal("unsupported Syslog scheme must fail")
	}

	socketPath := filepath.Join(t.TempDir(), "logger.sock")
	if err := os.WriteFile(socketPath, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	actual, err := parseSyslogAddress("unix://" + socketPath)
	if err != nil {
		t.Fatal(err)
	}
	if actual != (syslogAddress{protocol: "unix", address: socketPath}) {
		t.Fatalf("unexpected Unix Syslog address: %+v", actual)
	}
	if _, err := parseSyslogAddress("unix://" + socketPath + ".missing"); err == nil {
		t.Fatal("missing Unix Syslog path must fail")
	}
}

func TestNetworkEndpointUsesGoDialPortSemantics(t *testing.T) {
	host, port, err := resolveNetworkEndpoint(context.Background(), "tcp", "example.test:http")
	if err != nil {
		t.Fatal(err)
	}
	if host != "example.test" || port != 80 {
		t.Fatalf("endpoint = %q/%d", host, port)
	}
	host, port, err = resolveNetworkEndpoint(context.Background(), "udp", "host:")
	if err != nil {
		t.Fatal(err)
	}
	if host != "host" || port != 0 {
		t.Fatalf("empty-port endpoint = %q/%d", host, port)
	}
	if _, _, err := resolveNetworkEndpoint(context.Background(), "tcp", "[[::1]]:514"); err == nil {
		t.Fatal("double-bracket endpoint must fail like net.Dial")
	}
}

func TestTemplateLimitsAndCancellation(t *testing.T) {
	writer := &boundedTemplateWriter{maximum: 3}
	if _, err := writer.Write([]byte("abcd")); err == nil {
		t.Fatal("bounded writer must reject oversized output")
	}
	if got := truncateWithLength("abc", 3); got != "abc" {
		t.Fatalf("truncate returned %q", got)
	}
	if got := padWithSpace("", 2, 2); got != "" {
		t.Fatalf("empty pad returned %q", got)
	}

	contextValue, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := newSemanticEngine().matchRegexpBatch(contextValue, []byte("."), [][]byte{[]byte("a")})
	var semantic *semanticError
	if !errors.As(err, &semantic) || semantic.status != statusCancelled {
		t.Fatalf("cancelled regex must return cancelled status, got %v", err)
	}
	if !strings.Contains(contextSemanticError(context.DeadlineExceeded).Error(), "deadline") {
		t.Fatal("deadline error lost its category text")
	}
}

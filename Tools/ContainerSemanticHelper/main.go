// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"runtime/debug"
)

var (
	helperVersion        = "development"
	mobyCommit           = "development"
	mobyGCPLoggingDigest = "development"
	helperSourceDigest   = "development"
	oracleFixtureDigest  = "development"
)

func main() {
	debug.SetMemoryLimit(256 * 1024 * 1024)
	if err := run(os.Args[1:], adoptInheritedConnection); err != nil {
		fatal(err)
	}
}

type connectionAdopter func(int) (net.Conn, error)

func run(arguments []string, adopt connectionAdopter) error {
	flags := flag.NewFlagSet("container-semantic-helper", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	fd := flags.Int("fd", -1, "inherited protocol socket descriptor")
	if err := flags.Parse(arguments); err != nil || *fd != 3 || flags.NArg() != 0 {
		return errors.New("container-semantic-helper requires exactly --fd=3")
	}
	connection, err := adopt(*fd)
	if err != nil {
		return err
	}

	server := newSemanticServer(connection)
	if err := server.serve(); err != nil {
		_ = connection.Close()
		return err
	}
	return connection.Close()
}

func adoptInheritedConnection(fd int) (net.Conn, error) {
	file := os.NewFile(uintptr(fd), "container-semantic-helper")
	if file == nil {
		return nil, errors.New("invalid inherited protocol descriptor")
	}
	connection, err := net.FileConn(file)
	closeErr := file.Close()
	if err != nil {
		return nil, fmt.Errorf("adopt inherited protocol descriptor: %w", err)
	}
	if closeErr != nil {
		_ = connection.Close()
		return nil, fmt.Errorf("close inherited protocol descriptor: %w", closeErr)
	}
	return connection, nil
}

func fatal(err error) {
	_, _ = fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

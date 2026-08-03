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
	"flag"
	"io"
	"log"
	"net"
)

func main() {
	listenAddress := flag.String("listen", ":19531", "test TCP listen address")
	unixSocket := flag.String("unix", "", "service Unix socket")
	flag.Parse()
	if *unixSocket == "" || flag.NArg() != 0 {
		log.Fatal("invalid proxy arguments")
	}
	listener, err := net.Listen("tcp", *listenAddress)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	for {
		client, err := listener.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go proxy(client, *unixSocket)
	}
}

func proxy(client net.Conn, unixSocket string) {
	defer client.Close()
	service, err := net.Dial("unix", unixSocket)
	if err != nil {
		return
	}
	defer service.Close()
	done := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(service, client)
		if closer, ok := service.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}()
	_, _ = io.Copy(client, service)
	if closer, ok := client.(interface{ CloseWrite() error }); ok {
		_ = closer.CloseWrite()
	}
	<-done
}

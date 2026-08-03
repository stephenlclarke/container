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

//go:build linux && cgo && integration

package main

import (
	"fmt"
	"strconv"
	"testing"
	"time"
)

func BenchmarkSystemdAdapterAppend(b *testing.B) {
	adapter := newSystemdJournalAdapter("")
	defer adapter.Close()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 10)
	containerID := fmt.Sprintf("%064x", uint64(time.Now().UnixNano()))
	b.ReportAllocs()
	b.SetBytes(128)
	b.ResetTimer()
	for index := 1; index <= b.N; index++ {
		ordinal := uint64(index)
		entry := integrationEntry(
			containerID,
			"benchmark-"+nonce,
			ordinal,
			[]byte(fmt.Sprintf("%0128d", index)),
		)
		if _, err := adapter.Append(b.Context(), journalEntryIdentity{
			SessionID: "benchmark-writer-" + nonce,
			Epoch:     entry.Fields[fieldLogEpoch],
			Ordinal:   ordinal,
		}, entry); err != nil {
			b.Fatal(err)
		}
	}
}

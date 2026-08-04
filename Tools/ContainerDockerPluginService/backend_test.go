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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func TestCryptoTokenGeneratorProducesBoundedIndependentTokens(t *testing.T) {
	generator := cryptoTokenGenerator{}
	first, err := generator.Generate(32)
	if err != nil || len(first) != 32 {
		t.Fatalf("first token = %x, %v", first, err)
	}
	second, err := generator.Generate(32)
	if err != nil || len(second) != 32 {
		t.Fatalf("second token = %x, %v", second, err)
	}
	if bytes.Equal(first, second) {
		t.Fatal("independent token generations returned the same material")
	}
	for _, count := range []int{0, maximumTokenBytes + 1} {
		if _, err := generator.Generate(count); err == nil {
			t.Fatalf("invalid token size %d succeeded", count)
		}
	}
}

func TestFileStateStoreRoundTripIsProtectedAndSymlinkSafe(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temporary root: %v", err)
	}
	statePath := filepath.Join(root, "private", "state.json")
	store, err := newFileStateStore(statePath)
	if err != nil {
		t.Fatalf("new state store: %v", err)
	}
	data := []byte(`{"schemaVersion":1}`)
	if err := store.Save(data); err != nil {
		t.Fatalf("save state: %v", err)
	}
	loaded, err := store.Load()
	if err != nil || !bytes.Equal(loaded, data) {
		t.Fatalf("loaded state = %q, %v", loaded, err)
	}
	for path, wantMode := range map[string]os.FileMode{
		filepath.Dir(statePath): 0o700,
		statePath:               0o600,
	} {
		info, statError := os.Stat(path)
		if statError != nil {
			t.Fatalf("stat %s: %v", path, statError)
		}
		if info.Mode().Perm() != wantMode {
			t.Fatalf("mode for %s = %v; want %o", path, info.Mode().Perm(), wantMode)
		}
	}

	if err := os.Chmod(statePath, 0o644); err != nil {
		t.Fatalf("make state permissive: %v", err)
	}
	if _, err := store.Load(); !errors.Is(err, errCorruptState) {
		t.Fatalf("permissive state load error = %v, want corrupt state", err)
	}

	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatalf("make symlink target: %v", err)
	}
	linkedParent := filepath.Join(root, "linked")
	if err := os.Symlink(target, linkedParent); err != nil {
		t.Fatalf("make parent symlink: %v", err)
	}
	linkedStore, err := newFileStateStore(filepath.Join(linkedParent, "state.json"))
	if err != nil {
		t.Fatalf("new linked store: %v", err)
	}
	if err := linkedStore.Save(data); !errors.Is(err, errCorruptState) {
		t.Fatalf("symlink-parent save error = %v, want corrupt state", err)
	}
	if _, err := linkedStore.Load(); !errors.Is(err, errCorruptState) {
		t.Fatalf("symlink-parent load error = %v, want corrupt state", err)
	}

	for _, unsafePath := range []string{"relative/state.json", string(filepath.Separator)} {
		if _, err := newFileStateStore(unsafePath); err == nil {
			t.Fatalf("unsafe state path %q succeeded", unsafePath)
		}
	}
}

func TestEnsurePrivateDirectoryModeAcceptsProtectedVirtiofsDirectory(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := ensurePrivateDirectoryModeWith(
		root,
		func(string, os.FileMode) error { return fs.ErrPermission },
	); err != nil {
		t.Fatalf("already-private directory rejected after chmod EPERM: %v", err)
	}
}

func TestEnsurePrivateDirectoryModeRejectsUnsafeVirtiofsDirectory(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ensurePrivateDirectoryModeWith(
		root,
		func(string, os.FileMode) error { return fs.ErrPermission },
	); err == nil {
		t.Fatal("unsafe directory accepted after chmod EPERM")
	}
}

func TestHistoryMigrationReceiptIsDurableAndReplayStable(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(true)
	backend := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	request := testHistoryMigrationRequest()

	first, err := backend.migrateHistory(context.Background(), request)
	if err != nil {
		t.Fatalf("migrate history: %v", err)
	}
	if first.Request != request || first.ProviderOutcomeDigest == "" {
		t.Fatalf("migration receipt = %#v", first)
	}
	replayed, err := backend.migrateHistory(context.Background(), request)
	if err != nil || !reflect.DeepEqual(replayed, first) {
		t.Fatalf("replayed receipt = %#v, %v; want %#v", replayed, err, first)
	}
	restarted := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	afterRestart, err := restarted.migrateHistory(context.Background(), request)
	if err != nil || !reflect.DeepEqual(afterRestart, first) {
		t.Fatalf("restart receipt = %#v, %v; want %#v", afterRestart, err, first)
	}
	if got := plugin.capabilitiesCallCount(); got != 1 {
		t.Fatalf("capability calls = %d, want one durable effect proof", got)
	}

	conflict := request
	conflict.TerminalHistoryDigest = "sha256:other-history"
	if _, err := restarted.migrateHistory(context.Background(), conflict); !errors.Is(err, errIdempotencyConflict) {
		t.Fatalf("conflicting migration error = %v, want idempotency conflict", err)
	}
}

func TestHistoryMigrationRequiresReadableExactProviderContract(t *testing.T) {
	request := testHistoryMigrationRequest()
	writeOnly := newTestBackend(
		t,
		&memoryStateStore{},
		newFakePlugin(false),
		newFakeFIFOFactory(),
	)
	if _, err := writeOnly.migrateHistory(context.Background(), request); !errors.Is(err, errCapabilityMismatch) {
		t.Fatalf("write-only migration error = %v, want capability mismatch", err)
	}

	wrongContract := request
	wrongContract.ContractDigest = "sha256:wrong-contract"
	if _, err := writeOnly.migrateHistory(context.Background(), wrongContract); !errors.Is(err, errInvalidFence) {
		t.Fatalf("wrong-contract migration error = %v, want invalid fence", err)
	}
}

func TestHistoryHandoffPromotionAndActivationAreDurableExactReplay(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(true)
	backend := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	exportRequest := testHistoryHandoffExportRequest()
	export, err := backend.exportHistoryForHandoff(context.Background(), exportRequest)
	if err != nil || export.validate() != nil {
		t.Fatalf("export history = %#v, %v", export, err)
	}
	destination := testHistoryHandoffDestinationRequest(export)
	if err := backend.preflightHistoryHandoff(context.Background(), destination); err != nil {
		t.Fatalf("preflight history: %v", err)
	}
	promotionRequest := historyHandoffPromotionRequest{
		SchemaVersion:                serviceSchemaVersion,
		Destination:                  destination,
		CommitDigestSHA256:           "sha256:commit",
		HandoffChainHeadDigestSHA256: "sha256:chain",
	}
	first, err := backend.promoteHistoryHandoff(context.Background(), promotionRequest)
	if err != nil || first.validate(testServiceIdentity()) != nil {
		t.Fatalf("promote history = %#v, %v", first, err)
	}
	replayed, err := backend.promoteHistoryHandoff(context.Background(), promotionRequest)
	if err != nil || !reflect.DeepEqual(replayed, first) {
		t.Fatalf("replayed promotion = %#v, %v; want %#v", replayed, err, first)
	}

	restarted := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	afterRestart, err := restarted.promoteHistoryHandoff(context.Background(), promotionRequest)
	if err != nil || !reflect.DeepEqual(afterRestart, first) {
		t.Fatalf("restart promotion = %#v, %v; want %#v", afterRestart, err, first)
	}
	activation := historyHandoffActivationRequest{
		SchemaVersion:               serviceSchemaVersion,
		PromotionReceipt:            first,
		TerminalOutcomeDigestSHA256: "sha256:complete",
	}
	if err := restarted.activateHistoryHandoff(activation); err != nil {
		t.Fatalf("activate history: %v", err)
	}
	restarted = newTestBackend(t, store, plugin, newFakeFIFOFactory())
	if err := restarted.activateHistoryHandoff(activation); err != nil {
		t.Fatalf("replay activation after restart: %v", err)
	}
	activation.TerminalOutcomeDigestSHA256 = "sha256:different-complete"
	if err := restarted.activateHistoryHandoff(activation); !errors.Is(err, errIdempotencyConflict) {
		t.Fatalf("conflicting activation error = %v, want idempotency conflict", err)
	}
}

func TestHistoryHandoffExportReceiptMatchesSwiftCanonicalVector(t *testing.T) {
	request := historyHandoffExportRequest{
		SchemaVersion:               serviceSchemaVersion,
		TokenID:                     "token",
		ManifestID:                  "manifest",
		ContainerID:                 "container-id",
		SourceStateRootUUID:         "source-root",
		DestinationStateRootUUID:    "destination-root",
		SourceLeaseGeneration:       2,
		SourceProviderID:            "io.container.logging.plugin.test",
		SourceProviderGeneration:    7,
		SourceContractDigest:        "sha256:" + strings.Repeat("c", 64),
		TerminalHistoryDigestSHA256: "sha256:" + strings.Repeat("a", 64),
	}
	receipt := historyHandoffExportReceipt{
		SchemaVersion:               serviceSchemaVersion,
		Request:                     request,
		ProviderOutcomeDigestSHA256: "sha256:" + strings.Repeat("1", 64),
	}
	receipt.ExportReceiptDigestSHA256 = historyHandoffExportReceiptDigest(receipt)
	const expected = "030a20fb337c31466c2c025cd94d4469c3967ffe40932b4a6ed0f672a13fef71"
	if receipt.ExportReceiptDigestSHA256 != expected {
		t.Fatalf("export receipt digest = %s, want Swift vector %s", receipt.ExportReceiptDigestSHA256, expected)
	}
}

func TestLoadDurableBackendAdvancesAcrossVerifiedSandboxAbsence(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(true)
	backend := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	if _, err := backend.migrateHistory(context.Background(), testHistoryMigrationRequest()); err != nil {
		t.Fatalf("persist history migration: %v", err)
	}
	if _, err := backend.openWriter(context.Background(), testWriterOpen(true)); err != nil {
		t.Fatalf("persist writer: %v", err)
	}

	nextIdentity := testServiceIdentity()
	nextIdentity.SandboxGeneration++
	recovered, err := loadDurableBackend(
		nextIdentity,
		store,
		plugin,
		newFakeFIFOFactory(),
		fixedTokenGenerator{},
	)
	if err != nil {
		t.Fatalf("advance sandbox generation: %v", err)
	}
	if recovered.snapshot.Provider != nextIdentity {
		t.Fatalf("provider identity = %#v, want %#v", recovered.snapshot.Provider, nextIdentity)
	}
	if len(recovered.snapshot.Writers) != 0 || len(recovered.snapshot.Readers) != 0 {
		t.Fatalf(
			"recovered guest sessions = %d writers, %d readers; want none",
			len(recovered.snapshot.Writers),
			len(recovered.snapshot.Readers),
		)
	}
	if len(recovered.snapshot.HistoryMigrations) != 1 {
		t.Fatalf("provider migration receipts = %d, want 1", len(recovered.snapshot.HistoryMigrations))
	}

	if _, err := loadDurableBackend(
		testServiceIdentity(),
		store,
		plugin,
		newFakeFIFOFactory(),
		fixedTokenGenerator{},
	); !errors.Is(err, errCorruptState) {
		t.Fatalf("sandbox generation rollback error = %v, want corrupt state", err)
	}
}

func TestGenerationReclaimRequiresEmptyDurableEffectClaims(t *testing.T) {
	backend := newTestBackend(
		t,
		&memoryStateStore{},
		newFakePlugin(false),
		newFakeFIFOFactory(),
	)
	request := providerGenerationReclaim{
		SchemaVersion:      serviceSchemaVersion,
		ProviderID:         testServiceIdentity().ID,
		ProviderGeneration: testServiceIdentity().Generation,
	}
	if err := backend.reclaimGeneration(request); err != nil {
		t.Fatalf("empty generation reclaim: %v", err)
	}
	open := testWriterOpen(false)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	if err := backend.reclaimGeneration(request); !errors.Is(err, errInvalidFence) {
		t.Fatalf("active generation reclaim error = %v, want invalid fence", err)
	}
	if err := backend.finishWriter(context.Background(), open.Request.SessionID, receipt.Token, false); err != nil {
		t.Fatalf("finish writer: %v", err)
	}
	if err := backend.reclaim(terminalReclaim{
		SchemaVersion:      serviceSchemaVersion,
		Kind:               "writerSession",
		EffectID:           open.Request.SessionID,
		ProviderID:         testServiceIdentity().ID,
		ProviderGeneration: testServiceIdentity().Generation,
	}); err != nil {
		t.Fatalf("reclaim writer: %v", err)
	}
	if err := backend.reclaimGeneration(request); err != nil {
		t.Fatalf("terminal generation reclaim: %v", err)
	}
}

func TestUncertainWriterStartCannotRepeatPluginEffect(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(false)
	plugin.startErrors = []error{errUnavailable}
	fifos := newFakeFIFOFactory()
	backend := newTestBackend(t, store, plugin, fifos)
	open := testWriterOpen(false)

	if _, err := backend.openWriter(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("first open error = %v, want unavailable", err)
	}
	observation, err := backend.reconcileWriterOpen(open.Request)
	if err != nil || observation.Observation != observationUncertain {
		t.Fatalf("uncertain observation = %#v, %v", observation, err)
	}
	if _, err := backend.openWriter(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("uncertain replay error = %v, want unavailable", err)
	}
	if got := plugin.startCallCount(); got != 1 {
		t.Fatalf("start calls = %d, want one uncertain effect call", got)
	}
	if got := fifos.openCallCount(); got != 1 {
		t.Fatalf("FIFO opens = %d, want 1", got)
	}

	restarted := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	if _, err := restarted.openWriter(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("restart replay error = %v, want unavailable", err)
	}

	conflict := open
	conflict.Request.SemanticRequestDigest = "sha256:conflict"
	if _, err := backend.openWriter(context.Background(), conflict); !errors.Is(err, errIdempotencyConflict) {
		t.Fatalf("conflict error = %v, want idempotency conflict", err)
	}
	if got := plugin.startCallCount(); got != 1 {
		t.Fatalf("conflict created %d effect calls, want 1", got)
	}
}

func TestRejectedWriterStartReleasesCandidateForSafeReplay(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(false)
	plugin.startErrors = []error{errPluginRequestRejected}
	fifos := newFakeFIFOFactory()
	backend := newTestBackend(t, store, plugin, fifos)
	open := testWriterOpen(false)

	if _, err := backend.openWriter(context.Background(), open); !errors.Is(err, errPluginRequestRejected) {
		t.Fatalf("rejected open error = %v, want plugin rejection", err)
	}
	observation, err := backend.reconcileWriterOpen(open.Request)
	if err != nil || observation.Observation != observationAbsent {
		t.Fatalf("rejected open observation = %#v, %v, want absent", observation, err)
	}
	if len(backend.snapshot.Writers) != 0 || len(backend.writerHandles) != 0 {
		t.Fatalf(
			"rejected writer residue = %d states, %d handles",
			len(backend.snapshot.Writers),
			len(backend.writerHandles),
		)
	}

	if _, err := backend.openWriter(context.Background(), open); err != nil {
		t.Fatalf("safe replay after rejection: %v", err)
	}
	if got := plugin.startCallCount(); got != 2 {
		t.Fatalf("plugin start calls = %d, want rejected call and safe replay", got)
	}
	if got := fifos.openCallCount(); got != 2 {
		t.Fatalf("FIFO opens = %d, want rejected call and safe replay", got)
	}
}

func TestActiveWriterReconstructionFailsVisibleWithoutPluginRestart(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(false)
	open := testWriterOpen(false)
	first := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	if _, err := first.openWriter(context.Background(), open); err != nil {
		t.Fatalf("initial open: %v", err)
	}

	restartedFIFO := newFakeFIFOFactory()
	restarted := newTestBackend(t, store, plugin, restartedFIFO)
	if _, err := restarted.openWriter(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("restart replay error = %v, want unavailable", err)
	}
	if got := plugin.startCallCount(); got != 1 {
		t.Fatalf("restart issued %d plugin starts, want 1", got)
	}
	if got := restartedFIFO.openCallCount(); got != 0 {
		t.Fatalf("uncertain restart FIFO opens = %d, want 0", got)
	}
}

func TestWriterFrameReplayIsSequenceAndDigestStable(t *testing.T) {
	fifos := newFakeFIFOFactory()
	backend := newTestBackend(t, &memoryStateStore{}, newFakePlugin(false), fifos)
	open := testWriterOpen(false)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	first := []byte{0, 0, 0, 1, 1}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 1, first); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 1, first); err != nil {
		t.Fatalf("replayed write: %v", err)
	}
	conflict := []byte{0, 0, 0, 1, 2}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 1, conflict); !errors.Is(err, errIdempotencyConflict) {
		t.Fatalf("conflicting replay error = %v", err)
	}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 2, conflict); err != nil {
		t.Fatalf("second write: %v", err)
	}
	if got := fifos.writeCallCount(open.Request.SessionID); got != 2 {
		t.Fatalf("FIFO writes = %d, want 2", got)
	}
}

func TestWriterFenceRevokesBeforeRemoteStopAndRejectsStaleToken(t *testing.T) {
	store := &memoryStateStore{}
	events := &eventRecorder{}
	plugin := newFakePlugin(false)
	plugin.events = events
	fifos := newFakeFIFOFactory()
	fifos.events = events
	backend := newTestBackend(t, store, plugin, fifos)
	open := testWriterOpen(false)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}

	wrong := append([]byte(nil), receipt.Token...)
	wrong[0] ^= 0xff
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, wrong, 1, []byte{0, 0, 0, 1, 1}); !errors.Is(err, errInvalidToken) {
		t.Fatalf("wrong token error = %v", err)
	}
	if err := backend.finishWriter(context.Background(), open.Request.SessionID, receipt.Token, true); err != nil {
		t.Fatalf("fence writer: %v", err)
	}
	if got, want := events.snapshot(), []string{"fifo-revoke", "plugin-stop"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("fence events = %#v, want %#v", got, want)
	}

	call := testWriterCall(open.Request, receipt.Token)
	observation, digest, err := backend.writerObservation(call)
	if err != nil {
		t.Fatalf("observe fenced writer: %v", err)
	}
	if observation != "writerFenced" || digest == "" {
		t.Fatalf("fenced observation = %q, %q", observation, digest)
	}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 1, []byte{0, 0, 0, 1, 1}); !errors.Is(err, errInvalidFence) {
		t.Fatalf("post-fence write error = %v", err)
	}
}

func TestFencedWriterCanFinalizeAsClosed(t *testing.T) {
	backend := newTestBackend(
		t,
		&memoryStateStore{},
		newFakePlugin(false),
		newFakeFIFOFactory(),
	)
	open := testWriterOpen(false)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	if err := backend.finishWriter(
		context.Background(),
		open.Request.SessionID,
		receipt.Token,
		true,
	); err != nil {
		t.Fatalf("fence writer: %v", err)
	}
	if err := backend.finishWriter(
		context.Background(),
		open.Request.SessionID,
		receipt.Token,
		false,
	); err != nil {
		t.Fatalf("finalize fenced writer: %v", err)
	}

	observation, digest, err := backend.writerObservation(
		testWriterCall(open.Request, receipt.Token),
	)
	if err != nil {
		t.Fatalf("observe finalized writer: %v", err)
	}
	if observation != "closed" || digest != "" {
		t.Fatalf("final observation = %q, %q, want closed", observation, digest)
	}
}

func TestReaderReplayIsStableAndServiceCrashBecomesUncertain(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(true)
	plugin.readFrames = [][]byte{{0, 0, 0, 1, 0x2a}}
	backend := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	open := testReaderOpen()

	receipt, err := backend.openReader(context.Background(), open)
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	observation, err := backend.reconcileReaderOpen(open.Request)
	if err != nil || observation.Observation != observationPrepared || observation.Receipt == nil {
		t.Fatalf("reader observation = %#v, %v", observation, err)
	}
	if !sameToken(receipt.Token, observation.Receipt.Token) {
		t.Fatal("reader reconciliation changed token")
	}
	first, err := backend.nextReader(context.Background(), open.Request.ReaderSessionID, receipt.Token, 1)
	if err != nil {
		t.Fatalf("first reader event: %v", err)
	}
	replay, err := backend.nextReader(context.Background(), open.Request.ReaderSessionID, receipt.Token, 1)
	if err != nil || !reflect.DeepEqual(first, replay) {
		t.Fatalf("reader replay = %#v, %v", replay, err)
	}
	if got := plugin.nextCallCount(); got != 1 {
		t.Fatalf("plugin next calls = %d, want 1", got)
	}

	restarted := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	afterCrash, err := restarted.reconcileReaderOpen(open.Request)
	if err != nil || afterCrash.Observation != observationUncertain {
		t.Fatalf("post-crash reader observation = %#v, %v", afterCrash, err)
	}
	if _, err := restarted.openReader(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("post-crash reader open error = %v", err)
	}
}

func TestReaderStartUncertaintyCannotDuplicateReadStream(t *testing.T) {
	plugin := newFakePlugin(true)
	plugin.readErrors = []error{errUnavailable}
	backend := newTestBackend(t, &memoryStateStore{}, plugin, newFakeFIFOFactory())
	open := testReaderOpen()

	if _, err := backend.openReader(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("first read open error = %v, want unavailable", err)
	}
	observation, err := backend.reconcileReaderOpen(open.Request)
	if err != nil || observation.Observation != observationUncertain {
		t.Fatalf("uncertain reader observation = %#v, %v", observation, err)
	}
	if _, err := backend.openReader(context.Background(), open); !errors.Is(err, errUnavailable) {
		t.Fatalf("uncertain reader replay error = %v, want unavailable", err)
	}
	if got := plugin.readCallCount(); got != 1 {
		t.Fatalf("ReadLogs calls = %d, want 1", got)
	}
}

func TestCapabilityMismatchReleasesUneffectedClaimAndCreatesNoFIFO(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(true)
	fifos := newFakeFIFOFactory()
	backend := newTestBackend(t, store, plugin, fifos)
	open := testWriterOpen(false)

	if _, err := backend.openWriter(context.Background(), open); !errors.Is(err, errCapabilityMismatch) {
		t.Fatalf("capability mismatch error = %v", err)
	}
	if got := fifos.openCallCount(); got != 0 {
		t.Fatalf("FIFO opens = %d, want 0", got)
	}
	observation, err := backend.reconcileWriterOpen(open.Request)
	if err != nil || observation.Observation != observationAbsent {
		t.Fatalf("released mismatch observation = %#v, %v", observation, err)
	}
}

func TestReaderCapabilityMismatchReleasesUneffectedClaim(t *testing.T) {
	store := &memoryStateStore{}
	plugin := newFakePlugin(false)
	backend := newTestBackend(t, store, plugin, newFakeFIFOFactory())
	open := testReaderOpen()

	if _, err := backend.openReader(context.Background(), open); !errors.Is(err, errCapabilityMismatch) {
		t.Fatalf("capability mismatch error = %v", err)
	}
	observation, err := backend.reconcileReaderOpen(open.Request)
	if err != nil || observation.Observation != observationAbsent {
		t.Fatalf("released mismatch observation = %#v, %v", observation, err)
	}
	if got := plugin.readCallCount(); got != 0 {
		t.Fatalf("read calls = %d, want 0", got)
	}
}

func newTestBackend(
	t *testing.T,
	store durableStateStore,
	plugin loggingPlugin,
	fifos fifoFactory,
) *durableBackend {
	t.Helper()
	backend, err := loadDurableBackend(
		testServiceIdentity(),
		store,
		plugin,
		fifos,
		fixedTokenGenerator{},
	)
	if err != nil {
		t.Fatalf("load backend: %v", err)
	}
	return backend
}

func testServiceIdentity() serviceIdentity {
	return serviceIdentity{
		ID:                "io.container.logging.plugin.test",
		Generation:        7,
		SandboxGeneration: 9,
		ContractDigest:    "sha256:test-contract",
	}
}

func testHistoryMigrationRequest() historyMigrationRequest {
	return historyMigrationRequest{
		SchemaVersion:            serviceSchemaVersion,
		ContainerID:              "container-id",
		SourceLeaseGeneration:    2,
		TargetLeaseGeneration:    3,
		ProviderID:               testServiceIdentity().ID,
		SourceProviderGeneration: 6,
		TargetProviderGeneration: testServiceIdentity().Generation,
		ContractDigest:           testServiceIdentity().ContractDigest,
		TerminalHistoryDigest:    "sha256:terminal-history",
	}
}

func testHistoryHandoffExportRequest() historyHandoffExportRequest {
	return historyHandoffExportRequest{
		SchemaVersion:               serviceSchemaVersion,
		TokenID:                     "token",
		ManifestID:                  "manifest",
		ContainerID:                 "container-id",
		SourceStateRootUUID:         "source-root",
		DestinationStateRootUUID:    "destination-root",
		SourceLeaseGeneration:       2,
		SourceProviderID:            testServiceIdentity().ID,
		SourceProviderGeneration:    testServiceIdentity().Generation,
		SourceContractDigest:        testServiceIdentity().ContractDigest,
		TerminalHistoryDigestSHA256: "sha256:terminal-history",
	}
}

func testHistoryHandoffDestinationRequest(
	export historyHandoffExportReceipt,
) historyHandoffDestinationRequest {
	return historyHandoffDestinationRequest{
		SchemaVersion:                 serviceSchemaVersion,
		ExportReceipt:                 export,
		ManifestDigestSHA256:          "sha256:manifest",
		DestinationLeaseGeneration:    1,
		DestinationProviderID:         testServiceIdentity().ID,
		DestinationProviderGeneration: testServiceIdentity().Generation,
		DestinationContractDigest:     testServiceIdentity().ContractDigest,
	}
}

func testWriterOpen(readLogs bool) writerOpen {
	sandbox := uint64(9)
	return writerOpen{
		Request: writerStart{
			SchemaVersion:              serviceSchemaVersion,
			OperationGeneration:        1,
			IdempotencyKey:             "writer-operation",
			SemanticRequestDigest:      "sha256:writer",
			SessionID:                  "writer-session",
			ContainerID:                "container-id",
			LeaseGeneration:            2,
			CandidateProcessGeneration: 3,
			ProviderID:                 testServiceIdentity().ID,
			ProviderGeneration:         testServiceIdentity().Generation,
			CandidateSandboxGeneration: &sandbox,
		},
		Info:             json.RawMessage(`{"ContainerID":"container-id"}`),
		ExpectedReadLogs: readLogs,
	}
}

func testReaderOpen() readerOpen {
	return readerOpen{
		Request: readerStart{
			SchemaVersion:         serviceSchemaVersion,
			OperationGeneration:   4,
			IdempotencyKey:        "reader-operation",
			SemanticRequestDigest: "sha256:reader",
			ReaderSessionID:       "reader-session",
			ContainerID:           "container-id",
			LeaseGeneration:       2,
			ProviderID:            testServiceIdentity().ID,
			ProviderGeneration:    testServiceIdentity().Generation,
			Source:                json.RawMessage(`{"kind":"stoppedContainer"}`),
			Read:                  json.RawMessage(`{"tail":1}`),
		},
		PluginRequest: json.RawMessage(`{"Info":{"ContainerID":"container-id"},"Config":{"Tail":1}}`),
	}
}

func testWriterCall(request writerStart, token []byte) writerCall {
	return writerCall{
		SchemaVersion:      serviceSchemaVersion,
		SessionID:          request.SessionID,
		ContainerID:        request.ContainerID,
		LeaseGeneration:    request.LeaseGeneration,
		ProviderID:         request.ProviderID,
		ProviderGeneration: request.ProviderGeneration,
		Fence: writerFence{
			Kind:                    "active",
			ProcessGeneration:       request.CandidateProcessGeneration,
			ActiveSandboxGeneration: request.CandidateSandboxGeneration,
		},
		Token: append([]byte(nil), token...),
	}
}

type memoryStateStore struct {
	mu   sync.Mutex
	data []byte
}

func (store *memoryStateStore) Load() ([]byte, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	return append([]byte(nil), store.data...), nil
}

func (store *memoryStateStore) Save(data []byte) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	store.data = append([]byte(nil), data...)
	return nil
}

type fixedTokenGenerator struct{}

func (fixedTokenGenerator) Generate(count int) ([]byte, error) {
	return make([]byte, count), nil
}

type fakePlugin struct {
	mu                 sync.Mutex
	readLogs           bool
	startErrors        []error
	startCalls         int
	startPaths         map[string]struct{}
	stopCalls          int
	readFrames         [][]byte
	readErrors         []error
	nextCalls          int
	readCalls          int
	events             *eventRecorder
	capabilitiesCalls  int
	startHonorsContext bool
}

func newFakePlugin(readLogs bool) *fakePlugin {
	return &fakePlugin{readLogs: readLogs, startPaths: make(map[string]struct{})}
}

func (plugin *fakePlugin) Capabilities(context.Context) (pluginCapabilities, error) {
	plugin.mu.Lock()
	plugin.capabilitiesCalls++
	plugin.mu.Unlock()
	return pluginCapabilities{ReadLogs: plugin.readLogs}, nil
}

func (plugin *fakePlugin) capabilitiesCallCount() int {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	return plugin.capabilitiesCalls
}

func (plugin *fakePlugin) StartLogging(ctx context.Context, path string, _ json.RawMessage) error {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	plugin.startCalls++
	plugin.startPaths[path] = struct{}{}
	if plugin.startHonorsContext && ctx.Err() != nil {
		return ctx.Err()
	}
	if len(plugin.startErrors) == 0 {
		return nil
	}
	err := plugin.startErrors[0]
	plugin.startErrors = plugin.startErrors[1:]
	return err
}

func (plugin *fakePlugin) StopLogging(context.Context, string) error {
	plugin.mu.Lock()
	plugin.stopCalls++
	plugin.mu.Unlock()
	if plugin.events != nil {
		plugin.events.append("plugin-stop")
	}
	return nil
}

func (plugin *fakePlugin) ReadLogs(context.Context, json.RawMessage) (pluginReadStream, error) {
	plugin.mu.Lock()
	plugin.readCalls++
	if len(plugin.readErrors) != 0 {
		err := plugin.readErrors[0]
		plugin.readErrors = plugin.readErrors[1:]
		plugin.mu.Unlock()
		return nil, err
	}
	frames := make([][]byte, len(plugin.readFrames))
	for index, frame := range plugin.readFrames {
		frames[index] = append([]byte(nil), frame...)
	}
	plugin.mu.Unlock()
	return &fakeReadStream{frames: frames, plugin: plugin}, nil
}

func (plugin *fakePlugin) readCallCount() int {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	return plugin.readCalls
}

func (plugin *fakePlugin) startCallCount() int {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	return plugin.startCalls
}

func (plugin *fakePlugin) logicalStartCount() int {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	return len(plugin.startPaths)
}

func (plugin *fakePlugin) nextCallCount() int {
	plugin.mu.Lock()
	defer plugin.mu.Unlock()
	return plugin.nextCalls
}

type fakeReadStream struct {
	mu     sync.Mutex
	frames [][]byte
	index  int
	closed bool
	plugin *fakePlugin
}

func (stream *fakeReadStream) Next(context.Context) ([]byte, error) {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if stream.closed || stream.index >= len(stream.frames) {
		return nil, io.EOF
	}
	stream.plugin.mu.Lock()
	stream.plugin.nextCalls++
	stream.plugin.mu.Unlock()
	frame := append([]byte(nil), stream.frames[stream.index]...)
	stream.index++
	return frame, nil
}

func (stream *fakeReadStream) Close() error {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	stream.closed = true
	return nil
}

type fakeFIFOFactory struct {
	mu      sync.Mutex
	handles map[string]*fakeFIFO
	opens   int
	events  *eventRecorder
}

func newFakeFIFOFactory() *fakeFIFOFactory {
	return &fakeFIFOFactory{handles: make(map[string]*fakeFIFO)}
}

func (factory *fakeFIFOFactory) Open(sessionID string, generation uint64) (fifoHandle, error) {
	factory.mu.Lock()
	defer factory.mu.Unlock()
	factory.opens++
	if handle := factory.handles[sessionID]; handle != nil {
		return handle, nil
	}
	handle := &fakeFIFO{path: "/run/docker/logging/" + sessionID, events: factory.events}
	factory.handles[sessionID] = handle
	return handle, nil
}

func (factory *fakeFIFOFactory) openCallCount() int {
	factory.mu.Lock()
	defer factory.mu.Unlock()
	return factory.opens
}

func (factory *fakeFIFOFactory) writeCallCount(sessionID string) int {
	factory.mu.Lock()
	handle := factory.handles[sessionID]
	factory.mu.Unlock()
	if handle == nil {
		return 0
	}
	handle.mu.Lock()
	defer handle.mu.Unlock()
	return handle.writes
}

type fakeFIFO struct {
	mu      sync.Mutex
	path    string
	revoked bool
	events  *eventRecorder
	writes  int
}

func (fifo *fakeFIFO) Path() string {
	return fifo.path
}

func (fifo *fakeFIFO) Write(context.Context, []byte) error {
	fifo.mu.Lock()
	defer fifo.mu.Unlock()
	if fifo.revoked {
		return errInvalidFence
	}
	fifo.writes++
	return nil
}

func (fifo *fakeFIFO) CloseAndRemove() error {
	return nil
}

func (fifo *fakeFIFO) RevokeAndRemove() error {
	fifo.mu.Lock()
	fifo.revoked = true
	fifo.mu.Unlock()
	if fifo.events != nil {
		fifo.events.append("fifo-revoke")
	}
	return nil
}

type eventRecorder struct {
	mu     sync.Mutex
	events []string
}

func (recorder *eventRecorder) append(event string) {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	recorder.events = append(recorder.events, event)
}

func (recorder *eventRecorder) snapshot() []string {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	return append([]string(nil), recorder.events...)
}

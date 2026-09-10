# Bound logging XPC responses when the API server is unavailable

## Problem

The timestamped log-record client sends retrieval and stream-setup requests
without an XPC response timeout. A registered but non-responsive API service can
therefore leave callers waiting indefinitely, including the enhanced-runtime
adapter used by `devcontainer`.

## Expected behaviour

Log-record retrieval and stream setup must accept a caller-selected response
timeout and use the existing Container XPC timeout mechanism. Existing callers
must retain their current source-compatible API and the standard 60-second
registration timeout by default.

## Scope

- Add response-timeout parameters to log-record retrieval, follow, file, and
  decoded-stream entry points.
- Route those requests through the existing bounded XPC send helper.
- Add compile-time API coverage for bounded log-record calls.

## Compatibility

This is an additive API change in the enhanced logging surface. It does not
change stock Apple container behaviour or remove any existing call form.

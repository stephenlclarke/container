<!-- markdownlint-disable MD013 -->

# fix(test): verify prepared runtime at its recorded build revision

## Type of change

Bug fix with regression tests and documentation.

## Implementation and compatibility

After existing source, lock and compiler-input comparisons succeed, prepared runtime verification supplies the recorded product revision to action-graph admission. Raw BEP options must still match that exact revision, and every released archive and unsigned product hash remains required. Neither the consumer verifier nor its recipe identity changes. Historical receipts and build outputs are preserved, with controller and product commits recorded separately.

## Testing

All eleven integration-harness tests pass. The regression initially failed when current admission used a different harness commit; it now passes and still rejects altered unsigned product fingerprints. The actual already-built candidate re-admits under the new harness without compiling it. Earlier setup failures remain retained and restored the host. Only the full integration/coverage attempt is retried with the corrected harness.

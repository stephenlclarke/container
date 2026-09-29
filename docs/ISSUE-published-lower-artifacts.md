<!-- markdownlint-disable MD013 -->

# Qualify against published lower artifacts without rebuilding them

## Current and expected behavior

The full Container qualification currently asks `guest_artifact.py` and `builder_artifact.py` to build or reuse local OCI archives even when exact guest and builder bytes have already been published and qualified. A local cache can hide this repeated work, but it does not prove that a fresh checkout consumed the released lower artifacts. The direct runtime-preparation path has the same local-build fallback.

The normal qualification should import checksum-pinned guest, runc-guest and builder archives from their owning GitHub releases. It must verify the exact source commits, distinct release assets, public qualification sidecars, complete OCI content, executable identities and builder test outputs before writing the existing local receipts. Missing or incompatible published evidence must stop qualification. Explicit source-build commands remain available when preparing a genuinely new lower revision.

## Evidence and remaining work

The unchanged builder archive has a supplemental release that retains its original Q6fe qualification identity and four test files. A real importer run downloaded and verified all three supplemental assets and the Q6fe provenance anchor. The importer and stage-routing tests passed in the 213-test tools suite. The newly built 33a guest variants are not yet published; their exact-head quality and source-matched VM evidence must be accepted before guest locks can be recorded. The current Container source pin remains unchanged in this intermediate checkpoint, and a new complete Q qualification is still required. No historical benchmark is rerun or performance improvement claimed.

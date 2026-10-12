# fix(release): distinguish Swift parameter diagnostics from credentials

## Motivation and implementation

The native public-proof credential scan mistakes a generated Swift parameter assignment for credential material. The scanner now recognizes only a complete numeric-gutter compiler excerpt of `self.identifier = identifier`, with exactly the same unquoted identifier on both sides. Only an assignment-shaped credential match can use that exception; standalone token signatures, literal or different values, extra statements and ordinary log lines still fail. The original raw bytes and hash are retained, with no new normalization.

## Validation

A regression reproduces the original publication refusal, then verifies the complete proof archive retains the exact log and original hash. Eight rejection cases cover ordinary logs, changed values, token signatures, appended credentials, authorization headers and private-key material. The full native artifact test suite also covers the existing publication, evidence and tampering checks.

## Existing layer reuse

The authenticated recipe policy admits one exact old-to-new `native_producer.py` hash pair for this evidence-scan-only correction. No build selection, flags, compiled source, payload or normalization logic changes. All other recipe inputs, package pins, toolchain, lower-chain identities and archive/proof hashes retain their existing validation. Unknown, reverse and additional build-input changes fail. This allows the already published ArgumentParser candidate layer to remain usable; it does not relabel or replace any historical release or benchmark.

## Limits

Foundation must be produced and qualified from the new clean immutable checkpoint before publication. The earlier failed publication plan stays retained. No runtime parity or performance gain is claimed by this exporter correction.

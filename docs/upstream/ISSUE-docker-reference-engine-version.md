# Historical Docker benchmark reuse needs an explicit engine-version boundary

## Motivation

The published Docker benchmark records Engine 29.2.1. The current read-only Colima oracle reports Engine 29.5.2, while the authenticated Docker client, Compose plugin, host/guest identity, source log and configured resources remain unchanged. Reuse admission currently rejects the server-version difference before later qualification stages can run, even though rerunning the archived reference workloads is prohibited.

## Required behavior

- Admit only the unchanged historical Engine 29.2.1 or the explicit historical 29.2.1 to current 29.5.2 server-version pair.
- Keep every other engine identity, source-log, Colima allocation/configuration, context, host lease and qualification-owner check exact.
- Retain the historical and current server versions in admission, acceptance and aggregate comparison evidence.
- State that archived measurements remain Engine 29.2.1 timings and that no Docker workload was replayed.
- Reject reversed, different-patch, different-minor, client, plugin, host, resource or ownership changes.

## Non-goals

- Claim performance equivalence between Docker Engine 29.2.1 and 29.5.2.
- Rerun, regenerate, retime, normalize or waive any historical sample or gate.
- Change Docker workload commands, image, resource settings or timing interpretation.

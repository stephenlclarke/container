<!-- markdownlint-disable MD013 -->

# Prewarmed EOF fixture does not request prewarming

## Problem

The coherent ee7762a6 runtime checkpoint passes all 94 Containers integration cases, then fails prewarmedDedicatedStartClosesFiniteInput after waiting 60 seconds for a bootstrap that CLI create no longer requests by default. CLI prewarming is explicitly selected with --prewarm.

## Expected repair

Request --prewarm in the existing prewarmed test. Keep the log-based successful bootstrap proof, finite stdin, output marker, dedicated isolation and stopped-state assertions unchanged. Cold and shared EOF cases continue exercising their original routes.

## Evidence and remaining work

Retain the failed Run report and all measured ee7762a6 release results. Rerun the affected Run layer and the remaining integration layers against the same released dependency and guest inputs; reuse the already passing Containers layer only after authenticating identical production sources and build inputs. No baseline rebuild or measurement is required.

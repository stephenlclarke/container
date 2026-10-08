<!-- markdownlint-disable MD013 -->

# Prepared runtime comparison

## Problem

Repeating performance validation through the full qualification command unnecessarily repeats source tests, coverage, signing and release submission. The standalone runtime benchmark also prepares both lanes, rebuilding an already measured reference.

## Required behavior

Measure all eight runtime workloads on a verified prepared candidate for seven trials, compare with authenticated retained Apple and Docker measurements, and preserve original binary/source identities. Use the existing unattended host, Colima, service and command leases with complete restoration. No reference workload, notarization or publication should run.

## Acceptance

The new target must preserve the existing prepared-product verification and strict same-fixture tenfold gate. Regression validation must exercise successful and failed unattended startup for the new target and retain the original cleanup behavior.

<!-- markdownlint-disable MD013 -->

# Released SDK prevents registry resource tests from compiling

## Problem

The broader Container 8303b2f9 checkpoint passes its retained-reference runtime comparison and 362 workflow tests, then fails compilation because RegistryResourceTests imports ContainerizationOS with @testable. The released optimized SDK has no testing internals, and RegistryInfo's implicit initializer is internal.

## Expected behavior and repair

Construct registry metadata through the SDK's new public initializer, consume the fresh qualified SDK artifact, and use an ordinary ContainerizationOS import. The finite recipe transition permits reuse of unchanged lower groups while the independent SDK source pin still rejects the old artifact.

## Evidence and remaining work

Preserve the failed checkpoint, 28 successful target reports and all benchmark measurements. Full SDK qualification, actual source quality analysis, fresh artifact publication and upper consumer checkpoint remain required. No historical reference build or benchmark needs repeating.

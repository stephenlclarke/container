# Issue 263: validated builder-shim pin

The enhanced `container` distribution passes DNS configuration to its BuildKit
shim. The image pinned by commit `780a86b995ac` exited before BuildKit startup
because it did not accept those arguments, despite its source-revision label.

The correction pins the previously validated immutable builder image and adds a
Linux CI contract probe that executes the exact digest and verifies every DNS
argument emitted by `BuilderStart`. This prevents a source/image provenance
mismatch from reaching another enhanced runtime release.

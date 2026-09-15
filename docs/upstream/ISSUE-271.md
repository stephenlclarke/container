# Issue 271: refresh matched runtime dependencies

The fork's protected `main` branch still selects older Containerization and
builder-shim artifacts. Container Compose cannot advance its Current matched
stack while Container and Compose require different exact Containerization
revisions, and publishing the older builder image would violate the release
stack's source-to-artifact authority.

Container must advance both dependencies together. Protobuf generation must
also consume the exact builder-shim commit that produced the selected image.
The builder image uses the immutable digest published for that source commit;
the corresponding tag is retained only as discovery metadata.

The release consistency checks remain fail closed. This issue does not relax
the comparison with protected component branches.

Related issue: [#271](https://github.com/stephenlclarke/container/issues/271).

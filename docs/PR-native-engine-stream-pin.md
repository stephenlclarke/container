# PR: align the native Engine stream dependency

## Type of change

- Dependency bug fix.
- Documentation update.

## Motivation and implementation

The manifest and resolved Engine API revision now both select
`6e8c932fc8755a4b922fd239426e9029be0554e0`. The selected transport source passes
its full local suite with warnings treated as errors, including bounded large
uploads and deterministic early-input read resumption. Other dependency
selections are unchanged.

## Validation

Validate the evaluated manifest requirement against the nested resolved source.
Complete downstream Container SDK publication and download admission before the
Devcontainer release build. Full signed runtime parity remains required; this
alignment alone does not authorize stable publication.

Linked issue: [Native Engine stream
dependency](ISSUE-native-engine-stream-pin.md).

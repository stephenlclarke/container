# Compatibility gap: preserve OCI container annotations independently from labels

## Compose surface

`services.<name>.annotations`

## Docker Compose V2 behavior

Docker Compose V2 accepts service annotations in mapping or list form. Annotations are OCI runtime metadata, not container labels. A service may therefore carry a label and an annotation with the same key but different values.

## Existing Apple primitive

`containerization` already exposes `LinuxContainer.Configuration.annotations` and writes it to the generated OCI runtime specification. `container` did not expose that primitive through its resource model or generic `container create` and `container run` commands.

## Required `container` behavior

- Persist OCI annotations on `ContainerConfiguration` separately from `labels`.
- Add repeatable `container create/run --annotation key=value` options.
- Validate annotation values with the existing `key=value` metadata parser.
- Pass the resulting map unchanged to `containerization` when configuring the Linux container.
- Decode older stored configurations without an annotations field as an empty map.

## Non-goals

- Compose-specific code or protocols in the Apple runtime.
- Altering label behavior or merging annotations into labels.
- Windows container semantics.

"""Import only admitted packages, at the container lockfile's exact revisions."""

load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_package")

load(":layers.bzl", "LAYERS")
load(":test_inputs.bzl", "PATCHES", "TEST_DATA")

def _dependencies_impl(ctx):
    for mod in ctx.modules:
        for config in mod.tags.lockfile:
            pins = {p["identity"]: p for p in json.decode(ctx.read(config.path))["pins"]}
            for layer in LAYERS.values():
                identity = layer.package
                pin = pins[identity]
                revision = pin["state"]["revision"]
                if pin["kind"] != "remoteSourceControl" or len(revision) != 40 or any([c not in "0123456789abcdef" for c in revision.elems()]):
                    fail("Expected an immutable source commit for " + identity)
                name = "swiftpkg_" + identity.replace("-", "_").replace(".", "_")
                swift_package(
                    name = name,
                    bazel_package_name = name,
                    remote = pin["location"],
                    commit = revision,
                    version = pin["state"].get("version", ""),
                    publicly_expose_all_targets = True,
                    test_targets = layer.tests + layer.compile_checks,
                    test_data = TEST_DATA.get(identity, {}),
                    patches = PATCHES.get(identity, []),
                    patch_args = ["-p1"],
                )
    return ctx.extension_metadata(reproducible = True)

dependencies = module_extension(
    implementation = _dependencies_impl,
    tag_classes = {"lockfile": tag_class(attrs = {"path": attr.label(mandatory = True)})},
)

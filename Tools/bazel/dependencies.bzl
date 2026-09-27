"""Import only admitted packages, at the container lockfile's exact revisions."""

load("@rules_swift_package_manager//swiftpkg:defs.bzl", "local_swift_package", "swift_package")

load(":layers.bzl", "HOST_TESTS", "LAYERS", "RUNTIME_TESTS")
load(":test_inputs.bzl", "PATCHES", "TEST_DATA", "TEST_DATA_GLOBS", "TEST_TAGS")

def _dependencies_impl(ctx):
    packages = {}
    for layer_name, layer in LAYERS.items():
        packages.setdefault(layer.package, []).extend(layer.tests + layer.compile_checks + HOST_TESTS.get(layer_name, []))
    packages.setdefault("container", []).extend(RUNTIME_TESTS)
    for mod in ctx.modules:
        for config in mod.tags.lockfile:
            pins = {p["identity"]: p for p in json.decode(ctx.read(config.path))["pins"]}
            for identity, test_targets in packages.items():
                name = "swiftpkg_" + identity.replace("-", "_").replace(".", "_")
                options = dict(
                    name = name,
                    bazel_package_name = name,
                    publicly_expose_all_targets = True,
                    test_targets = list({target: True for target in test_targets}),
                    test_data = TEST_DATA.get(identity, {}),
                    test_tags = TEST_TAGS.get(identity, {}),
                    test_data_globs = TEST_DATA_GLOBS.get(identity, {}),
                )
                if identity == "container":
                    local_swift_package(path = ".", **options)
                    continue
                pin = pins[identity]
                revision = pin["state"]["revision"]
                if pin["kind"] != "remoteSourceControl" or len(revision) != 40 or any([c not in "0123456789abcdef" for c in revision.elems()]):
                    fail("Expected an immutable source commit for " + identity)
                env = {}
                if identity == "aws-sdk-swift":
                    # The pinned SDK exposes CloudWatch Logs as service 77 of 432.
                    # Fail closed if an updated manifest needs a different batch index.
                    if revision != "89a20139697f4db31d01ed8adc2fb45df3eea934":
                        fail("Review the CloudWatch Logs SDK batch for the new revision")
                    env = {"AWS_SWIFT_SDK_BATCH_TOTAL": "432", "AWS_SWIFT_SDK_BATCH_NUMBER": "77"}
                swift_package(
                    remote = pin["location"],
                    commit = revision,
                    version = pin["state"].get("version", ""),
                    env = env,
                    init_submodules = identity == "aws-crt-swift",
                    recursive_init_submodules = identity == "aws-crt-swift",
                    patches = PATCHES.get(identity, []),
                    patch_args = ["-p1"],
                    **options
                )
    return ctx.extension_metadata(reproducible = True)

dependencies = module_extension(
    implementation = _dependencies_impl,
    tag_classes = {"lockfile": tag_class(attrs = {"path": attr.label(mandatory = True)})},
)

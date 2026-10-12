"""Build library artifacts as well as modules, including C-only dependencies."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _layer_build_impl(ctx):
    archives = []
    files = []
    for dep in ctx.attr.deps:
        files.append(dep[DefaultInfo].files)
        if CcInfo in dep:
            for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
                for library in linker_input.libraries:
                    artifact = library.pic_static_library or library.static_library or library.dynamic_library
                    if artifact:
                        archives.append(artifact)
    outputs = depset(archives, transitive = files)
    if not outputs.to_list():
        fail("This layer exposes no build artifacts; select its implementation target.")
    return [DefaultInfo(files = outputs)]

layer_build = rule(
    implementation = _layer_build_impl,
    attrs = {"deps": attr.label_list(mandatory = True)},
)

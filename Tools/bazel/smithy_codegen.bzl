"""Run the pinned Smithy Swift generator as a cached Bazel action."""

def _smithy_codegen_impl(ctx):
    outputs = []
    args = ctx.actions.args()
    args.add(ctx.attr.service)
    args.add(ctx.file.model.path)
    args.add("--internal", str(ctx.attr.internal).lower())
    args.add("--sdk-id", ctx.attr.sdk_id)
    if ctx.attr.operations:
        args.add("--operations", ",".join(ctx.attr.operations))
    for suffix, option in [
        ("Schemas", "schemas"),
        ("Serialize", "serialize"),
        ("Deserialize", "deserialize"),
        ("TypeRegistry", "type-registry"),
        ("Operations", "operations"),
    ]:
        output = ctx.actions.declare_file(ctx.label.name + "/" + suffix + ".swift")
        outputs.append(output)
        args.add("--" + option + "-path", output.path)
    ctx.actions.run(
        executable = ctx.executable.generator,
        tools = [ctx.attr.generator[DefaultInfo].files_to_run],
        inputs = [ctx.file.model, ctx.file.settings, ctx.file.header],
        outputs = outputs,
        arguments = [args],
        env = {"SMITHY_CODEGEN_HEADER": ctx.file.header.path},
        mnemonic = "SmithyGenerate",
        progress_message = "Generating Smithy sources for " + ctx.label.name,
    )
    return [DefaultInfo(files = depset(outputs))]

smithy_codegen = rule(
    implementation = _smithy_codegen_impl,
    attrs = {
        "service": attr.string(mandatory = True),
        "sdk_id": attr.string(mandatory = True),
        "internal": attr.bool(),
        "operations": attr.string_list(),
        "settings": attr.label(allow_single_file = True, mandatory = True),
        "model": attr.label(allow_single_file = True, mandatory = True),
        "header": attr.label(
            default = Label("@swiftpkg_smithy_swift//:Sources/SmithyCodegenCore/Resources/DefaultSwiftHeader.txt"),
            allow_single_file = True,
        ),
        "generator": attr.label(
            default = Label("@swiftpkg_smithy_swift//:SmithyCodegenCLI.rspm"),
            executable = True,
            cfg = "exec",
        ),
    },
)

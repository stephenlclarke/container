"""Collect documented module graphs through the package importer's platform wrappers."""

load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftSymbolGraphInfo")
load("@build_bazel_rules_swift//swift:swift_symbol_graph_aspect.bzl", "swift_symbol_graph_aspect")

def _api_symbol_graphs(ctx):
    selected = {}
    for target in ctx.attr.targets:
        for graph in target[SwiftSymbolGraphInfo].transitive_symbol_graphs.to_list():
            if graph.module_name in ctx.attr.modules:
                selected[graph.module_name] = graph.symbol_graph_dir
    missing = [name for name in ctx.attr.modules if name not in selected]
    if missing:
        fail("Documentation modules omitted symbol graphs: " + str(missing))
    destination = ctx.actions.declare_directory(ctx.label.name + ".symbolgraphs")
    arguments = ctx.actions.args()
    arguments.add(destination.path)
    for name in ctx.attr.modules:
        arguments.add_all([selected[name]], expand_directories = True)
    ctx.actions.run_shell(
        inputs = selected.values(),
        outputs = [destination],
        arguments = [arguments],
        command = 'set -eu; output_dir="$1"; shift; mkdir -p "$output_dir"; for source in "$@"; do cp "$source" "$output_dir/$(basename "$source")"; done',
        mnemonic = "CollectContainerAPISymbols",
    )
    return [DefaultInfo(files = depset([destination]))]

api_symbol_graphs = rule(
    implementation = _api_symbol_graphs,
    attrs = {
        "targets": attr.label_list(aspects = [swift_symbol_graph_aspect]),
        "modules": attr.string_list(mandatory = True),
    },
)

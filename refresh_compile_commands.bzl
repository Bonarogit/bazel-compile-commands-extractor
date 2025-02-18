""" refresh_compile_commands rule

When `bazel run`, these rules refresh the compile_commands.json in the root of your Bazel workspace
    [creating compile_commands.json if it doesn't already exist.]

Best explained by concrete example--copy the following and follow the comments:
```Starlark
load("@hedron_compile_commands//:refresh_compile_commands.bzl", "refresh_compile_commands")

refresh_compile_commands(
    name = "refresh_compile_commands",

    # Specify the targets of interest.
        # This will create compile commands entries for all the code compiled by those targets, including transitive dependencies.
            # If you're working on a header-only library, specify a test or binary target that compiles it.
    # If you're doing this manually, you usually want to just specify the top-level output targets you care about.
        # This avoids issues where some targets can't be built on their own; they need configuration by a parent rule. android_binaries using transitions to configure android_libraries are an example.
    # The targets parameter is forgiving in its inputs.
        # You can specify just one target:
            # targets = "//:my_output_binary_target",
        # Or a list of targets:
            # targets = ["//:my_output_1", "//:my_output_2"],
        # Or a dict of targets and any flags required to build:
            # (No need to add flags already in .bazelrc. They're automatically picked up.)
            # targets = {
            #   "//:my_output_1": "--important_flag1 --important_flag2=true",
            #   "//:my_output_2": "",
            # },
        # If you don't specify a target, that's fine (if it works for you); compile_commands.json will default to containing commands used in building all possible targets. But in that case, just bazel run @hedron_compile_commands//:refresh_all
        # Wildcard target patterns (..., *, :all) patterns *are* allowed, like in bazel build
            # For more, see https://docs.bazel.build/versions/main/guide.html#specifying-targets-to-build
        # As are additional targets (+) and subtractions (-), like in bazel query https://docs.bazel.build/versions/main/query.html#expressions

    # Using ccls or another tool that doesn't want or need headers in compile_commands.json?
        # exclude_headers = "all", # By default, we include entries for headers to support clangd, working around https://github.com/clangd/clangd/issues/123
        # ^ excluding headers will speed up compile_commands.json generation *considerably* because we won't need to preprocess your code to figure out which headers you use.
        # However, if you use clangd and are looking for speed, we strongly recommend you follow the instructions below instead, since clangd is going to regularly infer the wrong commands for headers and give you lots of annoyingly unnecessary red squigglies.

    # Need things to run faster? [Either for compile_commands.json generation or clangd indexing.]
    # First: You might be able to refresh compile_commands.json slightly less often, making the current runtime okay.
        # If you're adding files, clangd should make pretty decent guesses at completions, using commands from nearby files. And if you're deleting files, there's not a problem. So you may not need to rerun refresh.py on every change to BUILD files. Instead, maybe refresh becomes something you run every so often when you can spare the time, making the current runtime okay.
        # If that's not enough, read on.
    # If you don't care about the implementations of external dependencies:
        # Then skip adding entries for compilation in external workspaces with
        # exclude_external_sources = True,
        # ^ Defaults to False, so the broadest set of features are supported out of the box, without prematurely optimizing.
    # If you don't care about browsing headers from external workspaces or system headers, except for a CTRL/CMD+click every now and then:
        # Then no need to add entries for their headers, because clangd will correctly infer from the CTRL/CMD+click (but not a quick open or reopen).
        # exclude_headers = "external",
    # Still not fast enough?
        # Make sure you're specifying just the targets you care about by setting `targets`, above.
```
"""


########################################
# Implementation

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

def refresh_compile_commands(
        name,
        targets = None,
        exclude_headers = None,
        exclude_external_sources = False,
        **kwargs):  # For the other common attributes. Tags, compatible_with, etc. https://docs.bazel.build/versions/main/be/common-definitions.html#common-attributes.
    # Convert the various, acceptable target shorthands into the dictionary format
    if not targets:  # Default to all targets in main workspace
        targets = {"@//tensorflow:tensorflow.dll": ""}
    elif type(targets) == "list":  # Allow specifying a list of targets w/o arguments
        targets = {target: "" for target in targets}
    elif type(targets) != "dict":  # Assume they've supplied a single string/label and wrap it
        targets = {targets: ""}

    # Generate runnable python script from template
    script_name = name + ".py"
    _expand_template(name = script_name, labels_to_flags = targets, exclude_headers = exclude_headers, exclude_external_sources = exclude_external_sources, **kwargs)
    native.py_binary(name = name, srcs = [script_name], **kwargs)

def _expand_template_impl(ctx):
    """Inject targets of interest into refresh.template.py, and set it up to be run."""
    script = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        output = script,
        is_executable = True,
        template = ctx.file._script_template,
        substitutions = {
            # Note, don't delete whitespace. Correctly doing multiline indenting.
            "        {target_flag_pairs}": "\n".join(["        {},".format(pair) for pair in ctx.attr.labels_to_flags.items()]),
            "        {windows_default_include_paths}": "\n".join(["        %r," % path for path in find_cpp_toolchain(ctx).built_in_include_directories]),  # find_cpp_toolchain is from https://docs.bazel.build/versions/main/integrating-with-rules-cc.html
            "{exclude_headers}": '"' + str(ctx.attr.exclude_headers) + '"',
            "{exclude_external_sources}": str(ctx.attr.exclude_external_sources),
        },
    )
    return DefaultInfo(files = depset([script]))

_expand_template = rule(
    attrs = {
        "labels_to_flags": attr.string_dict(mandatory = True),  # string keys instead of label_keyed because Bazel doesn't support parsing wildcard target patterns (..., *, :all) in BUILD attributes.
        "exclude_external_sources": attr.bool(default = False),
        "exclude_headers": attr.string(values = ["all", "external", ""]), # "" needed only for compatibility with Bazel < 3.6.0
        "_script_template": attr.label(allow_single_file = True, default = "refresh.template.py"),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),  # For Windows INCLUDE. If this were eliminated, for example by the resolution of https://github.com/clangd/clangd/issues/123, we'd be able to just use a macro and skylib's expand_template rule: https://github.com/bazelbuild/bazel-skylib/pull/330
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],  # Needed for find_cpp_toolchain with --incompatible_enable_cc_toolchain_resolution
    implementation = _expand_template_impl,
)

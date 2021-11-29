# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Propagates unified `SwiftInfo` providers for C/Objective-C targets."""

load("@bazel_skylib//lib:sets.bzl", "sets")
load(":attrs.bzl", "swift_toolchain_attrs")
load(":compiling.bzl", "derive_module_name", "precompile_clang_module")
load(":derived_files.bzl", "derived_files")
load(
    ":feature_names.bzl",
    "SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD",
    "SWIFT_FEATURE_MODULE_MAP_NO_PRIVATE_HEADERS",
)
load(":features.bzl", "configure_features", "is_feature_enabled")
load(":module_maps.bzl", "write_module_map")
load(
    ":providers.bzl",
    "SwiftInfo",
    "SwiftToolchainInfo",
    "create_clang_module",
    "create_module",
    "create_swift_info",
)
load(":utils.bzl", "compilation_context_for_explicit_module_compilation")

_MULTIPLE_TARGET_ASPECT_ATTRS = [
    "deps",
    # TODO(b/151667396): Remove j2objc-specific attributes when possible.
    "exports",
    "runtime_deps",
]

_SINGLE_TARGET_ASPECT_ATTRS = [
    # TODO(b/151667396): Remove j2objc-specific attributes when possible.
    "_jre_lib",
]

_SwiftInteropInfo = provider(
    doc = """\
Contains minimal information required to allow `swift_clang_module_aspect` to
manage the creation of a `SwiftInfo` provider for a C/Objective-C target.
""",
    fields = {
        "exclude_headers": """\
A `list` of `File`s representing headers that should be excluded from the
module, if a module map is being automatically generated based on the headers in
the target's compilation context.
""",
        "module_map": """\
A `File` representing an existing module map that should be used to represent
the module, or `None` if the module map should be generated based on the headers
in the target's compilation context.
""",
        "module_name": """\
A string denoting the name of the module, or `None` if the name should be
derived automatically from the target label.
""",
        "requested_features": """\
A list of features that should be enabled for the target, in addition to those
supplied in the `features` attribute, unless the feature is otherwise marked as
unsupported (either on the target or by the toolchain). This allows the rule
implementation to supply an additional set of fixed features that should always
be enabled when the aspect processes that target; for example, a rule can
request that `swift.emit_c_module` always be enabled for its targets even if it
is not explicitly enabled in the toolchain or on the target directly.
""",
        "suppressed": """\
A `bool` indicating whether the module that the aspect would create for the
target should instead be suppressed.
""",
        "swift_infos": """\
A list of `SwiftInfo` providers from dependencies of the target, which will be
merged with the new `SwiftInfo` created by the aspect.
""",
        "unsupported_features": """\
A list of features that should be disabled for the target, in addition to those
supplied as negations in the `features` attribute. This allows the rule
implementation to supply an additional set of fixed features that should always
be disabled when the aspect processes that target; for example, a rule that
processes frameworks with headers that do not follow strict layering can request
that `swift.strict_module` always be disabled for its targets even if it is
enabled by default in the toolchain.
""",
    },
)

def create_swift_interop_info(
        *,
        exclude_headers = [],
        module_map = None,
        module_name = None,
        requested_features = [],
        suppressed = False,
        swift_infos = [],
        unsupported_features = []):
    """Returns a provider that lets a target expose C/Objective-C APIs to Swift.

    The provider returned by this function allows custom build rules written in
    Starlark to be uninvolved with much of the low-level machinery involved in
    making a Swift-compatible module. Such a target should propagate a `CcInfo`
    provider whose compilation context contains the headers that it wants to
    make into a module, and then also propagate the provider returned from this
    function.

    The simplest usage is for a custom rule to call
    `swift_common.create_swift_interop_info` passing it only the list of
    `SwiftInfo` providers from its dependencies; this tells
    `swift_clang_module_aspect` to derive the module name from the target label
    and create a module map using the headers from the compilation context.

    If the custom rule has reason to provide its own module name or module map,
    then it can do so using the `module_name` and `module_map` arguments.

    When a rule returns this provider, it must provide the full set of
    `SwiftInfo` providers from dependencies that will be merged with the one
    that `swift_clang_module_aspect` creates for the target itself; the aspect
    will not do so automatically. This allows the rule to not only add extra
    dependencies (such as support libraries from implicit attributes) but also
    exclude dependencies if necessary.

    Args:
        exclude_headers: A `list` of `File`s representing headers that should be
            excluded from the module if the module map is generated.
        module_map: A `File` representing an existing module map that should be
            used to represent the module, or `None` (the default) if the module
            map should be generated based on the headers in the target's
            compilation context. If this argument is provided, then
            `module_name` must also be provided.
        module_name: A string denoting the name of the module, or `None` (the
            default) if the name should be derived automatically from the target
            label.
        requested_features: A list of features (empty by default) that should be
            requested for the target, which are added to those supplied in the
            `features` attribute of the target. These features will be enabled
            unless they are otherwise marked as unsupported (either on the
            target or by the toolchain). This allows the rule implementation to
            have additional control over features that should be supported by
            default for all instances of that rule as if it were creating the
            feature configuration itself; for example, a rule can request that
            `swift.emit_c_module` always be enabled for its targets even if it
            is not explicitly enabled in the toolchain or on the target
            directly.
        suppressed: A `bool` indicating whether the module that the aspect would
            create for the target should instead be suppressed.
        swift_infos: A list of `SwiftInfo` providers from dependencies, which
            will be merged with the new `SwiftInfo` created by the aspect.
        unsupported_features: A list of features (empty by default) that should
            be considered unsupported for the target, which are added to those
            supplied as negations in the `features` attribute. This allows the
            rule implementation to have additional control over features that
            should be disabled by default for all instances of that rule as if
            it were creating the feature configuration itself; for example, a
            rule that processes frameworks with headers that do not follow
            strict layering can request that `swift.strict_module` always be
            disabled for its targets even if it is enabled by default in the
            toolchain.

    Returns:
        A provider whose type/layout is an implementation detail and should not
        be relied upon.
    """
    if module_map:
        if not module_name:
            fail("'module_name' must be specified when 'module_map' is " +
                 "specified.")
        if exclude_headers:
            fail("'exclude_headers' may not be specified when 'module_map' " +
                 "is specified.")

    return _SwiftInteropInfo(
        exclude_headers = exclude_headers,
        module_map = module_map,
        module_name = module_name,
        requested_features = requested_features,
        suppressed = suppressed,
        swift_infos = swift_infos,
        unsupported_features = unsupported_features,
    )

def _compute_all_excluded_headers(*, exclude_headers, target):
    """Returns the full set of headers to exclude for a target.

    This function specifically handles the `cc_library` logic around the
    `include_prefix` and `strip_include_prefix` attributes, which cause Bazel to
    create a virtual header (symlink) for every public header in the target. For
    the generated module map to be created, we must exclude both the actual
    header file and the symlink.

    Args:
        exclude_headers: A list of `File`s representing headers that should be
            excluded from the module.
        target: The target to which the aspect is being applied.

    Returns:
        A list containing the complete set of headers that should be excluded,
        including any virtual header symlinks that match a real header in the
        excluded headers list passed into the function.
    """
    exclude_headers_set = sets.make(exclude_headers)
    virtual_exclude_headers = []

    for action in target.actions:
        if action.mnemonic != "Symlink":
            continue

        original_header = action.inputs.to_list()[0]
        virtual_header = action.outputs.to_list()[0]

        if sets.contains(exclude_headers_set, original_header):
            virtual_exclude_headers.append(virtual_header)

    return exclude_headers + virtual_exclude_headers

def _generate_module_map(
        *,
        actions,
        compilation_context,
        dependent_module_names,
        exclude_headers,
        feature_configuration,
        module_name,
        target,
        umbrella_header):
    """Generates the module map file for the given target.

    Args:
        actions: The object used to register actions.
        compilation_context: The C++ compilation context that provides the
            headers for the module.
        dependent_module_names: A `list` of names of Clang modules that are
            direct dependencies of the target whose module map is being written.
        exclude_headers: A `list` of `File`s representing header files to
            exclude, if any, if we are generating the module map.
        feature_configuration: A Swift feature configuration.
        module_name: The name of the module.
        target: The target for which the module map is being generated.
        umbrella_header: A `File` representing an umbrella header that, if
            present, will be written into the module map instead of the list of
            headers in the compilation context.

    Returns: A `File` representing the generated module map.
    """

    # Determine if the toolchain requires module maps to use
    # workspace-relative paths or not, and other features controlling the
    # content permitted in the module map.
    workspace_relative = is_feature_enabled(
        feature_configuration = feature_configuration,
        feature_name = SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD,
    )
    exclude_private_headers = is_feature_enabled(
        feature_configuration = feature_configuration,
        feature_name = SWIFT_FEATURE_MODULE_MAP_NO_PRIVATE_HEADERS,
    )

    if exclude_private_headers:
        private_headers = []
    else:
        private_headers = compilation_context.direct_private_headers

    # Sort dependent module names and the headers to ensure a deterministic
    # order in the output file, in the event the compilation context would ever
    # change this on us. For files, use the execution path as the sorting key.
    def _path_sorting_key(file):
        return file.path

    public_headers = sorted(
        compilation_context.direct_public_headers,
        key = _path_sorting_key,
    )

    module_map_file = derived_files.module_map(
        actions = actions,
        target_name = target.label.name,
    )

    if exclude_headers:
        # If we're excluding headers from the module map, make sure to pick up
        # any virtual header symlinks that might be created, for example, by a
        # `cc_library` using the `include_prefix` and/or `strip_include_prefix`
        # attributes.
        exclude_headers = _compute_all_excluded_headers(
            exclude_headers = exclude_headers,
            target = target,
        )

    write_module_map(
        actions = actions,
        dependent_module_names = sorted(dependent_module_names),
        exclude_headers = sorted(exclude_headers, key = _path_sorting_key),
        exported_module_ids = ["*"],
        module_map_file = module_map_file,
        module_name = module_name,
        private_headers = sorted(private_headers, key = _path_sorting_key),
        public_headers = public_headers,
        public_textual_headers = sorted(
            compilation_context.direct_textual_headers,
            key = _path_sorting_key,
        ),
        umbrella_header = umbrella_header,
        workspace_relative = workspace_relative,
    )
    return module_map_file

def _objc_library_module_info(aspect_ctx):
    """Returns the `module_name` and `module_map` attrs for an `objc_library`.

    Args:
        aspect_ctx: The aspect context.

    Returns:
        A tuple containing the module name (a string) and the module map file (a
        `File`) specified as attributes on the `objc_library`. These values may
        be `None`.
    """
    attr = aspect_ctx.rule.attr

    # TODO(b/195019413): Deprecate the use of these attributes and use
    # `swift_interop_hint` to customize `objc_*` targets' module names and
    # module maps.
    module_name = getattr(attr, "module_name", None)
    module_map_file = None

    module_map_target = getattr(attr, "module_map", None)
    if module_map_target:
        module_map_files = module_map_target.files.to_list()
        if module_map_files:
            module_map_file = module_map_files[0]

    return module_name, module_map_file

# TODO(b/151667396): Remove j2objc-specific knowledge.
def _j2objc_umbrella_workaround(target):
    """Tries to find and return the umbrella header for a J2ObjC target.

    This is an unfortunate hack/workaround needed for J2ObjC, which needs to use
    an umbrella header that `#include`s, rather than `#import`s, the headers in
    the module due to the way they're segmented.

    It's also somewhat ugly in the way that it has to find the umbrella header,
    which is tied to Bazel's built-in module map generation. Since there's not a
    direct umbrella header field in `ObjcProvider`, we scan the target's actions
    to find the one that writes it out. Then, we return it and a new compilation
    context with the direct headers from the `ObjcProvider`, since the generated
    headers are not accessible via `CcInfo`--Java targets to which the J2ObjC
    aspect are applied do not propagate `CcInfo` directly, but a native Bazel
    provider that wraps the `CcInfo`, and we have no access to it from Starlark.

    Args:
        target: The target to which the aspect is being applied.

    Returns:
        A tuple containing two elements:

        *   A `File` representing the umbrella header generated by the target,
            or `None` if there was none.
        *   A `CcCompilationContext` containing the direct generated headers of
            the J2ObjC target (including the umbrella header), or `None` if the
            target did not generate an umbrella header.
    """
    for action in target.actions:
        if action.mnemonic != "UmbrellaHeader":
            continue

        umbrella_header = action.outputs.to_list()[0]
        compilation_context = cc_common.create_compilation_context(
            headers = depset(
                target[apple_common.Objc].direct_headers + [umbrella_header],
            ),
        )
        return umbrella_header, compilation_context

    return None, None

def _module_info_for_target(
        target,
        aspect_ctx,
        compilation_context,
        dependent_module_names,
        exclude_headers,
        feature_configuration,
        module_name,
        umbrella_header):
    """Returns the module name and module map for the target.

    Args:
        target: The target for which the module map is being generated.
        aspect_ctx: The aspect context.
        compilation_context: The C++ compilation context that provides the
            headers for the module.
        dependent_module_names: A `list` of names of Clang modules that are
            direct dependencies of the target whose module map is being written.
        exclude_headers: A `list` of `File`s representing header files to
            exclude, if any, if we are generating the module map.
        feature_configuration: A Swift feature configuration.
        module_name: The module name to prefer (if we're generating a module map
            from `_SwiftInteropInfo`), or None to derive it from other
            properties of the target.
        umbrella_header: A `File` representing an umbrella header that, if
            present, will be written into the module map instead of the list of
            headers in the compilation context.

    Returns:
        A tuple containing the module name (a string) and module map file (a
        `File`) for the target. One or both of these values may be `None`.
    """

    # Ignore `j2objc_library` targets. They exist to apply an aspect to their
    # dependencies, but the modules that should be imported are associated with
    # those dependencies. We'll produce errors if we try to read those headers
    # again from this target and create another module map with them.
    # TODO(b/151667396): Remove j2objc-specific knowledge.
    if aspect_ctx.rule.kind == "j2objc_library":
        return None, None

    # If a target doesn't have any headers, then don't generate a module map for
    # it. Such modules define nothing and only waste space on the compilation
    # command line and add more work for the compiler.
    if not compilation_context or (
        not compilation_context.direct_headers and
        not compilation_context.direct_textual_headers
    ):
        return None, None

    attr = aspect_ctx.rule.attr
    module_map_file = None

    if not module_name:
        if apple_common.Objc not in target:
            return None, None

        if aspect_ctx.rule.kind == "objc_library":
            module_name, module_map_file = _objc_library_module_info(aspect_ctx)

        # If it was an `objc_library` without an explicit module name, or it
        # was some other `Objc`-providing target, derive the module name
        # now.
        if not module_name:
            module_name = derive_module_name(target.label)

    # If we didn't get a module map above, generate it now.
    if not module_map_file:
        module_map_file = _generate_module_map(
            actions = aspect_ctx.actions,
            compilation_context = compilation_context,
            dependent_module_names = dependent_module_names,
            exclude_headers = exclude_headers,
            feature_configuration = feature_configuration,
            module_name = module_name,
            target = target,
            umbrella_header = umbrella_header,
        )

    return module_name, module_map_file

def _handle_module(
        aspect_ctx,
        compilation_context,
        exclude_headers,
        feature_configuration,
        module_map_file,
        module_name,
        swift_infos,
        swift_toolchain,
        target):
    """Processes a C/Objective-C target that is a dependency of a Swift target.

    Args:
        aspect_ctx: The aspect's context.
        compilation_context: The `CcCompilationContext` containing the target's
            headers.
        exclude_headers: A `list` of `File`s representing header files to
            exclude, if any, if we are generating the module map.
        feature_configuration: The current feature configuration.
        module_map_file: The `.modulemap` file that defines the module, or None
            if it should be inferred from other properties of the target (for
            legacy support).
        module_name: The name of the module, or None if it should be inferred
            from other properties of the target (for legacy support).
        swift_infos: The `SwiftInfo` providers of the current target's
            dependencies, which should be merged into the `SwiftInfo` provider
            created and returned for this target.
        swift_toolchain: The Swift toolchain being used to build this target.
        target: The C++ target to which the aspect is currently being applied.

    Returns:
        A list of providers that should be returned by the aspect.
    """
    attr = aspect_ctx.rule.attr

    all_swift_infos = (
        swift_infos + swift_toolchain.clang_implicit_deps_providers.swift_infos
    )

    # Collect the names of Clang modules that the module being built directly
    # depends on.
    dependent_module_names = []
    for swift_info in all_swift_infos:
        for module in swift_info.direct_modules:
            if module.clang:
                dependent_module_names.append(module.name)

    # If we weren't passed a module map (i.e., from a `_SwiftInteropInfo`
    # provider), infer it and the module name based on properties of the rule to
    # support legacy rules.
    if not module_map_file:
        # TODO(b/151667396): Remove j2objc-specific knowledge.
        umbrella_header, new_compilation_context = _j2objc_umbrella_workaround(
            target = target,
        )
        if umbrella_header:
            compilation_context = new_compilation_context

        module_name, module_map_file = _module_info_for_target(
            target = target,
            aspect_ctx = aspect_ctx,
            compilation_context = compilation_context,
            dependent_module_names = dependent_module_names,
            exclude_headers = exclude_headers,
            feature_configuration = feature_configuration,
            module_name = module_name,
            umbrella_header = umbrella_header,
        )

    if not module_map_file:
        if all_swift_infos:
            return [create_swift_info(swift_infos = swift_infos)]
        else:
            return []

    compilation_context_to_compile = (
        compilation_context_for_explicit_module_compilation(
            compilation_contexts = [compilation_context],
            deps = getattr(attr, "deps", []),
        )
    )
    precompiled_module = precompile_clang_module(
        actions = aspect_ctx.actions,
        cc_compilation_context = compilation_context_to_compile,
        feature_configuration = feature_configuration,
        module_map_file = module_map_file,
        module_name = module_name,
        swift_infos = swift_infos,
        swift_toolchain = swift_toolchain,
        target_name = target.label.name,
    )

    providers = [
        create_swift_info(
            modules = [
                create_module(
                    name = module_name,
                    clang = create_clang_module(
                        compilation_context = compilation_context,
                        module_map = module_map_file,
                        precompiled_module = precompiled_module,
                    ),
                ),
            ],
            swift_infos = swift_infos,
        ),
    ]

    if precompiled_module:
        providers.append(
            OutputGroupInfo(
                swift_explicit_module = depset([precompiled_module]),
            ),
        )

    return providers

def _collect_swift_infos_from_deps(aspect_ctx):
    """Collect `SwiftInfo` providers from dependencies.

    Args:
        aspect_ctx: The aspect's context.

    Returns:
        A list of `SwiftInfo` providers from dependencies of the target to which
        the aspect was applied.
    """
    swift_infos = []

    attr = aspect_ctx.rule.attr
    for attr_name in _MULTIPLE_TARGET_ASPECT_ATTRS:
        swift_infos.extend([
            dep[SwiftInfo]
            for dep in getattr(attr, attr_name, [])
            if SwiftInfo in dep
        ])
    for attr_name in _SINGLE_TARGET_ASPECT_ATTRS:
        dep = getattr(attr, attr_name, None)
        if dep and SwiftInfo in dep:
            swift_infos.append(dep[SwiftInfo])

    return swift_infos

def _find_swift_interop_info(target, aspect_ctx):
    """Finds a `_SwiftInteropInfo` provider associated with the target.

    This function first looks at the target itself to determine if it propagated
    a `_SwiftInteropInfo` provider directly (that is, its rule implementation
    function called `swift_common.create_swift_interop_info`). If it did not,
    then the target's `aspect_hints` attribute is checked for a reference to a
    target that propagates `_SwiftInteropInfo` (such as `swift_interop_hint`).

    It is an error if `aspect_hints` contains two or more targets that propagate
    `_SwiftInteropInfo`, or if the target directly propagates the provider and
    there is also any target in `aspect_hints` that propagates it.

    Args:
        target: The target to which the aspect is currently being applied.
        aspect_ctx: The aspect's context.

    Returns:
        A tuple containing two elements:

        -   The `_SwiftInteropInfo` associated with the target, if found;
            otherwise, None.
        -   A list of additional `SwiftInfo` providers that are treated as
            direct dependencies of the target, determined by reading attributes
            from the target if it did not provide `_SwiftInteropInfo` directly.
    """
    if _SwiftInteropInfo in target:
        # If the target's rule implementation directly provides
        # `_SwiftInteropInfo`, then it is that rule's responsibility to collect
        # and merge `SwiftInfo` providers from relevant dependencies.
        interop_target = target
        interop_from_rule = True
        default_swift_infos = []
    else:
        # If the target's rule implementation does not directly provide
        # `_SwiftInteropInfo`, then we need to collect the `SwiftInfo` providers
        # from the default dependencies and returns those. Note that if a custom
        # rule is used as a hint and returns a `_SwiftInteropInfo` that contains
        # `SwiftInfo` providers, then we would consider the providers from the
        # default dependencies and the providers from the hint; they are merged
        # after the call site of this function.
        interop_target = None
        interop_from_rule = False
        default_swift_infos = _collect_swift_infos_from_deps(aspect_ctx)

    # We don't break this loop early when we find a matching hint, because we
    # want to give an error message if there are two aspect hints that provide
    # `_SwiftInteropInfo` (or if both the rule and an aspect hint do).
    for hint in aspect_ctx.rule.attr.aspect_hints:
        if _SwiftInteropInfo in hint:
            if interop_target:
                if interop_from_rule:
                    fail(("Conflicting Swift interop info from the target " +
                          "'{target}' ({rule} rule) and the aspect hint " +
                          "'{hint}'. Only one is allowed.").format(
                        hint = str(hint.label),
                        target = str(target.label),
                        rule = aspect_ctx.rule.kind,
                    ))
                else:
                    fail(("Conflicting Swift interop info from aspect hints " +
                          "'{hint1}' and '{hint2}'. Only one is " +
                          "allowed.").format(
                        hint1 = str(interop_target.label),
                        hint2 = str(hint.label),
                    ))
            interop_target = hint

    if interop_target:
        return interop_target[_SwiftInteropInfo], default_swift_infos
    return None, default_swift_infos

def _compilation_context_for_target(target):
    """Gets the compilation context to use when compiling this target's module.

    This function also handles the special case of a target that propagates an
    `apple_common.Objc` provider in addition to its `CcInfo` provider, where the
    former contains strict include paths that must also be added when compiling
    the module.

    Args:
        target: The target to which the aspect is being applied.

    Returns:
        A `CcCompilationContext` that contains the headers of the target being
        compiled.
    """
    if CcInfo not in target:
        return None

    compilation_context = target[CcInfo].compilation_context

    if apple_common.Objc in target:
        strict_includes = target[apple_common.Objc].strict_include
        if strict_includes:
            compilation_context = cc_common.merge_compilation_contexts(
                compilation_contexts = [
                    compilation_context,
                    cc_common.create_compilation_context(
                        includes = strict_includes,
                    ),
                ],
            )

    return compilation_context

def _swift_clang_module_aspect_impl(target, aspect_ctx):
    # Do nothing if the target already propagates `SwiftInfo`.
    if SwiftInfo in target:
        return []

    requested_features = aspect_ctx.features
    unsupported_features = aspect_ctx.disabled_features

    interop_info, swift_infos = _find_swift_interop_info(target, aspect_ctx)
    if interop_info:
        # If the module should be suppressed, return immediately and propagate
        # nothing (not even transitive dependencies).
        if interop_info.suppressed:
            return []

        exclude_headers = interop_info.exclude_headers
        module_map_file = interop_info.module_map
        module_name = (
            interop_info.module_name or derive_module_name(target.label)
        )
        swift_infos.extend(interop_info.swift_infos)
        requested_features.extend(interop_info.requested_features)
        unsupported_features.extend(interop_info.unsupported_features)
    else:
        exclude_headers = []
        module_map_file = None
        module_name = None

    swift_toolchain = aspect_ctx.attr._toolchain_for_aspect[SwiftToolchainInfo]
    feature_configuration = configure_features(
        ctx = aspect_ctx,
        requested_features = requested_features,
        swift_toolchain = swift_toolchain,
        unsupported_features = unsupported_features,
    )

    if interop_info or apple_common.Objc in target or CcInfo in target:
        return _handle_module(
            aspect_ctx = aspect_ctx,
            compilation_context = _compilation_context_for_target(target),
            exclude_headers = exclude_headers,
            feature_configuration = feature_configuration,
            module_map_file = module_map_file,
            module_name = module_name,
            swift_infos = swift_infos,
            swift_toolchain = swift_toolchain,
            target = target,
        )

    # If it's any other rule, just merge the `SwiftInfo` providers from its
    # deps.
    if swift_infos:
        return [create_swift_info(swift_infos = swift_infos)]

    return []

swift_clang_module_aspect = aspect(
    attr_aspects = _MULTIPLE_TARGET_ASPECT_ATTRS + _SINGLE_TARGET_ASPECT_ATTRS,
    attrs = swift_toolchain_attrs(
        toolchain_attr_name = "_toolchain_for_aspect",
    ),
    doc = """\
Propagates unified `SwiftInfo` providers for targets that represent
C/Objective-C modules.

This aspect unifies the propagation of Clang module artifacts so that Swift
targets that depend on C/Objective-C targets can find the necessary module
artifacts, and so that Swift module artifacts are not lost when passing through
a non-Swift target in the build graph (for example, a `swift_library` that
depends on an `objc_library` that depends on a `swift_library`).

It also manages module map generation for targets that call
`swift_common.create_swift_interop_info` and do not provide their own module
map, and for targets that use the `swift_interop_hint` aspect hint. Note that if
one of these approaches is used to interop with a target such as a `cc_library`,
the headers must be parsable as C, since Swift does not support C++ interop at
this time.

Most users will not need to interact directly with this aspect, since it is
automatically applied to the `deps` attribute of all `swift_binary`,
`swift_library`, and `swift_test` targets. However, some rules may need to
provide custom propagation logic of C/Objective-C module dependencies; for
example, a rule that has a support library as a private attribute would need to
ensure that `SwiftInfo` providers for that library and its dependencies are
propagated to any targets that depend on it, since they would not be propagated
via `deps`. In this case, the custom rule can attach this aspect to that support
library's attribute and then merge its `SwiftInfo` provider with any others that
it propagates for its targets.
""",
    fragments = ["cpp"],
    implementation = _swift_clang_module_aspect_impl,
    required_aspect_providers = [
        [apple_common.Objc],
        [CcInfo],
    ],
)

# Copyright 2017 The Bazel Authors. All rights reserved.
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
"""
Provides functionality to organize debian packages into tarballs.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@io_bazel_rules_docker//docker/package_managers:apt_key.bzl", _apt_key = "key")
load("@io_bazel_rules_docker//docker/package_managers:download_pkgs.bzl", _download_deb_pkgs = "download")

def _input_validation(kwargs):
    allowed_attribues = ["name", "base", "language_layers"]

    for key in kwargs.keys():
        if key not in allowed_attribues:
            fail("Attribute " + key + " is not supported.")

container = [
    ".tar.gz",
    ".tgz",
    ".tar",
    ".tar.xz",
]

generate_deb_tar_attrs = dicts.add(_download_deb_pkgs.attrs, {
    "base": attr.label(allow_files = container),
    "keys": attr.label_list(
        allow_files = True,
    ),
    "packages": attr.string_list(),
})

aggregate_debian_pkgs_attrs = {

    # Declare the following attributes since _download_deb_pkgs.implementation
    # need access those attribute if their overrides are None
    "additional_repos": attr.string_list(),
    "base": attr.label(allow_files = container),
    "language_layers": attr.label_list(),
    "_image_id_extractor": attr.label(
        default = "@io_bazel_rules_docker//contrib:extract_image_id.py",
        allow_single_file = True,
    ),
}

InstallableTarInfo = provider(fields = [
    "installables_tar",
])

def _generate_deb_tar(
        ctx,
        packages = None,
        additional_repos = None,
        keys = None,
        download_pkgs_output_tar = None,
        download_pkgs_output_script = None,
        download_pkgs_output_metadata = None):
    """A function for producing a tarball for a set of debian packages.

    Args:
      ctx: ctx has either generate_deb_tar_attrs or aggregate_debian_pkgs_attrs,
        this depends on the rule that uses this function
      packages: list of packages to fetch and install in the base image.
      additional_repos: list of additional debian package repos to use,
        in sources.list format.
      keys: list of labels of additional gpg keys to use while downloading
        packages.
      download_pkgs_output_tar: output tar file generated by download_pkgs rule to
        override default output_tar
      download_pkgs_output_script: output script generated by download_pkgs rule to
        override default output_script
      download_pkgs_output_metadata: output CSV file generated by download_pkgs
        rule to override default metadata_csv
    """

    # Prepare base image for the download_pkgs rule.
    download_base = ctx.files.base[0]

    # Create an intermediate image with additional gpg keys used to download packages.
    if keys != []:
        image_with_keys = "%s_with_keys" % ctx.attr.name

        # Declare intermediate output file generated by add_apt_key rule.
        image_with_keys_output_executable = ctx.actions.declare_file(image_with_keys)
        image_with_keys_output_tarball = ctx.actions.declare_file(image_with_keys + ".tar")
        image_with_keys_output_layer = ctx.actions.declare_file(image_with_keys + "-layer.tar")
        image_with_keys_output_digest = ctx.actions.declare_file(image_with_keys + ".digest")
        image_with_keys_output_config = ctx.actions.declare_file(image_with_keys + ".json")

        _apt_key.implementation(
            ctx,
            name = image_with_keys,
            image_tar = ctx.files.base[0],
            keys = keys,
            output_executable = image_with_keys_output_executable,
            output_tarball = image_with_keys_output_tarball,
            output_layer = image_with_keys_output_layer,
            output_digest = image_with_keys_output_digest,
            output_config = image_with_keys_output_config,
        )
        download_base = image_with_keys_output_tarball

    # Declare intermediate output file generated by download_pkgs rule.
    output_executable = ctx.actions.declare_file(ctx.attr.name + "-output_executable.sh")
    download_pkgs_output_tar = download_pkgs_output_tar or ctx.attr.name + ".tar"
    download_pkgs_output_script = download_pkgs_output_script or ctx.attr.name + ".sh"
    output_tar = ctx.actions.declare_file(download_pkgs_output_tar)
    output_script = ctx.actions.declare_file(download_pkgs_output_script)
    output_metadata = ctx.actions.declare_file(download_pkgs_output_metadata)

    # download_pkgs rule consumes 'packages' and 'additional_repos'.
    _download_deb_pkgs.implementation(
        ctx,
        image_tar = download_base,
        packages = packages,
        additional_repos = additional_repos,
        output_executable = output_executable,
        output_tar = output_tar,
        output_script = output_script,
        output_metadata = output_metadata,
    )

    return [
        InstallableTarInfo(
            installables_tar = output_tar,
        ),
    ]

def _aggregate_debian_pkgs_impl(ctx):
    """Implementation for the aggregate_debian_pkgs rule.

    aggregate_debian_pkgs rule produces a tarball with all debian packages declared
    in the language_tool_layer(s) this rule depends on.

    Args:
      ctx: ctx only has name, base, and language_layers attributes
    """

    packages = []
    additional_repos = []
    keys = []

    for layer in ctx.attr.language_layers:
        packages.extend(layer.packages)
        additional_repos.extend(layer.additional_repos)
        keys.extend(layer.keys)

    packages = depset(packages).to_list()
    additional_repos = depset(additional_repos).to_list()
    keys = depset(keys).to_list()

    return _generate_deb_tar(
        ctx,
        packages = packages,
        additional_repos = additional_repos,
        keys = keys,
    )

# Export _generate_deb_tar function for other bazel rules to use.
generate = struct(
    attrs = generate_deb_tar_attrs,
    outputs = _download_deb_pkgs.outputs,
    implementation = _generate_deb_tar,
)

aggregate_debian_pkgs_ = rule(
    attrs = aggregate_debian_pkgs_attrs,
    outputs = _download_deb_pkgs.outputs,
    implementation = _aggregate_debian_pkgs_impl,
)

def aggregate_debian_pkgs(**kwargs):
    """Aggregate debian packages from multiple language_tool_layers into a tarball.

    Args:
      **kwargs:
            name: a unique name for this rule.
            base: base os image used for this rule.
            language_layers: a list of language_tool_layer targets.

    Only name, base, and language_layers attributes are allowed in this rule.

    Experimental rule.
    """

    _input_validation(kwargs)

    aggregate_debian_pkgs_(**kwargs)

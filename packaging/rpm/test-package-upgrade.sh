#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
umask 077

if (($# != 4)); then
    printf 'Usage: %s OLD.rpm NEW.rpm OLD_VERSION NEW_VERSION\n' "${0##*/}" >&2
    exit 2
fi
readonly OLD_INPUT=$1 NEW_INPUT=$2 OLD_VERSION=$3 NEW_VERSION=$4
readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
for version in "${OLD_VERSION}" "${NEW_VERSION}"; do
    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Error: invalid package version: %s\n' "${version}" >&2
        exit 2
    }
done
((EUID == 0)) || { printf 'Error: RPM upgrade test must run as root.\n' >&2; exit 77; }
for command_name in dnf mkdir mktemp realpath rm rmdir rpm sha256sum tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done
old_package=$(realpath -e -- "${OLD_INPUT}")
new_package=$(realpath -e -- "${NEW_INPUT}")
[[ ${old_package} == *.rpm && ${new_package} == *.rpm ]] || exit 2
if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: %s must not be installed before the upgrade test.\n' "${PACKAGE_NAME}" >&2
    exit 65
fi
installed=false

if [[ -z ${HOME:-} || ${HOME} != /* ]]; then
    printf 'Error: HOME must be an absolute path for the upgrade test.\n' >&2
    exit 64
fi

data_home=${XDG_DATA_HOME:-${HOME}/.local/share}
if [[ ${data_home} != /* ]]; then
    data_home="${HOME}/.local/share"
fi
readonly data_home

runtime_root="${data_home}/yt-dlp-aria2-downloader/runtime"
readonly runtime_root
runtime_root_created=false
runtime_probe_dir=''

if [[ -e ${runtime_root} || -L ${runtime_root} ]]; then
    if [[ ! -d ${runtime_root} || -L ${runtime_root} ]]; then
        printf 'Error: unsafe pre-existing runtime root: %s\n' \
            "${runtime_root}" >&2
        exit 65
    fi
else
    mkdir -p -- "${runtime_root}" || {
        printf 'Error: unable to create runtime preservation fixture root: %s\n' \
            "${runtime_root}" >&2
        exit 65
    }
    runtime_root_created=true
fi

runtime_probe_dir=$(mktemp -d \
    "${runtime_root}/.package-upgrade-preservation.XXXXXX") || {
    printf '%s\n' \
        'Error: unable to create runtime preservation probe.' >&2
    exit 65
}

printf 'package-upgrade-preservation:%s->%s\n' \
    "${OLD_VERSION}" "${NEW_VERSION}" \
    >"${runtime_probe_dir}/sentinel"

runtime_tree_snapshot() {
    local runtime_parent runtime_name digest

    runtime_parent=${runtime_root%/*}
    runtime_name=${runtime_root##*/}

    digest=$(
        tar \
            --sort=name \
            --mtime='UTC 1970-01-01' \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            --format=gnu \
            -cf - \
            -C "${runtime_parent}" \
            "${runtime_name}" |
            sha256sum
    ) || return 1

    printf '%s\n' "${digest%% *}"
}

assert_runtime_preserved() {
    local stage=$1
    local current_digest
    local snapshot_status=0

    if [[ ! -d ${runtime_root} || -L ${runtime_root} ]]; then
        printf 'Error: runtime root disappeared or became unsafe during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    set +e
    current_digest=$(runtime_tree_snapshot)
    snapshot_status=$?
    set -e

    if ((snapshot_status != 0)); then
        printf 'Error: unable to snapshot runtime tree during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    if [[ ${current_digest} != "${runtime_tree_baseline}" ]]; then
        printf 'Error: per-user runtime tree changed during %s.\n' \
            "${stage}" >&2
        return 65
    fi

    return 0
}

set +e
runtime_tree_baseline=$(runtime_tree_snapshot)
runtime_tree_snapshot_status=$?
set -e

if ((runtime_tree_snapshot_status != 0)); then
    printf '%s\n' \
        'Error: unable to create baseline runtime snapshot.' >&2
    exit 65
fi

cleanup() {
    if [[ ${installed} == true ]]; then
        dnf remove --assumeyes "${PACKAGE_NAME}" >/dev/null 2>&1 || true
    fi

    if [[ -n ${runtime_probe_dir} &&
          ${runtime_probe_dir} == "${runtime_root}/.package-upgrade-preservation."* ]]; then
        if [[ -d ${runtime_root} && ! -L ${runtime_root} ]]; then
            rm -rf -- "${runtime_probe_dir}"
        else
            printf 'Warning: refusing to clean runtime probe through unsafe runtime root: %s\n' \
                "${runtime_root}" >&2
        fi
    fi

    if [[ ${runtime_root_created} == true ]]; then
        rmdir -- "${runtime_root}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False "${old_package}"
installed=true
assert_runtime_preserved 'installation of previous package'
old_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${old_version_output} == \
    "yt-dlp-aria2-downloader version ${OLD_VERSION}" ]]

dnf install --assumeyes --allowerasing --nogpgcheck \
    --setopt=install_weak_deps=False "${new_package}"
assert_runtime_preserved 'package upgrade'
new_version_output=$(/usr/bin/yt-dlp-aria2-downloader --version)
[[ ${new_version_output} == \
    "yt-dlp-aria2-downloader version ${NEW_VERSION}" ]]
[[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]]
[[ -x /usr/libexec/yt-dlp-aria2-downloader/runtime-manager.sh ]]

dnf remove --assumeyes "${PACKAGE_NAME}"
installed=false
assert_runtime_preserved 'package removal'
if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    printf 'Error: RPM remains installed after upgrade/removal.\n' >&2
    exit 65
fi
for path in \
    /usr/libexec/yt-dlp-aria2-downloader \
    "/usr/share/doc/${PACKAGE_NAME}" \
    "/usr/share/licenses/${PACKAGE_NAME}"; do
    [[ ! -e ${path} && ! -L ${path} ]] || {
        printf 'Error: RPM upgrade/removal left a private path: %s\n' "${path}" >&2
        exit 65
    }
done
printf 'RPM upgrade passed: %s -> %s.\n' "${OLD_VERSION}" "${NEW_VERSION}"

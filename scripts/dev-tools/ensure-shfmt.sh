#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/dev-tools/ensure-shfmt.sh
# Purpose     : Provide the exact verified upstream shfmt binary pinned by the project.
# ==============================================================================

set -euo pipefail
umask 077

readonly SHFMT_UPSTREAM_REPOSITORY='mvdan/sh'
SHFMT_DOWNLOAD_TMP=''

cleanup() {
    if [[ -n ${SHFMT_DOWNLOAD_TMP} ]]; then
        rm -f -- "${SHFMT_DOWNLOAD_TMP}" || true
    fi
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    return "${2:-65}"
}

read_pin() {
    local pin_file=$1
    local version_variable=$2
    local amd64_variable=$3
    local arm64_variable=$4
    local key=''
    local value=''
    local pin_version=''
    local pin_amd64_sha=''
    local pin_arm64_sha=''

    while IFS='=' read -r key value || [[ -n ${key} ]]; do
        case ${key} in
            '' | \#*)
                continue
                ;;
            SHFMT_VERSION)
                [[ -z ${pin_version} ]] || {
                    fail 'duplicate SHFMT_VERSION in shfmt pin file'
                    return $?
                }
                pin_version=${value}
                ;;
            SHFMT_LINUX_AMD64_SHA256)
                [[ -z ${pin_amd64_sha} ]] || {
                    fail 'duplicate SHFMT_LINUX_AMD64_SHA256 in shfmt pin file'
                    return $?
                }
                pin_amd64_sha=${value}
                ;;
            SHFMT_LINUX_ARM64_SHA256)
                [[ -z ${pin_arm64_sha} ]] || {
                    fail 'duplicate SHFMT_LINUX_ARM64_SHA256 in shfmt pin file'
                    return $?
                }
                pin_arm64_sha=${value}
                ;;
            *)
                fail "unknown key in shfmt pin file: ${key}"
                return $?
                ;;
        esac
    done <"${pin_file}"

    [[ ${pin_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        fail "invalid pinned shfmt version: ${pin_version:-<empty>}"
        return $?
    }
    [[ ${pin_amd64_sha} =~ ^[0-9a-f]{64}$ ]] || {
        fail 'invalid pinned Linux amd64 shfmt SHA-256'
        return $?
    }
    [[ ${pin_arm64_sha} =~ ^[0-9a-f]{64}$ ]] || {
        fail 'invalid pinned Linux arm64 shfmt SHA-256'
        return $?
    }

    printf -v "${version_variable}" '%s' "${pin_version}"
    printf -v "${amd64_variable}" '%s' "${pin_amd64_sha}"
    printf -v "${arm64_variable}" '%s' "${pin_arm64_sha}"
}

verified_binary() {
    local binary=$1
    local expected_sha=$2
    local expected_version=$3
    local actual_sha=''
    local actual_version=''

    [[ -f ${binary} && ! -L ${binary} ]] || return 1

    actual_sha=$(sha256sum -- "${binary}")
    actual_sha=${actual_sha%% *}
    [[ ${actual_sha} == "${expected_sha}" ]] || return 1

    actual_version=$("${binary}" --version 2>/dev/null) || return 1
    [[ ${actual_version} == "v${expected_version}" ]]
}

require_shfmt_commands() {
    local command_name=''

    for command_name in chmod curl dirname mkdir mktemp mv rm sha256sum uname; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail "required command was not found: ${command_name}" 127
            exit $?
        fi
    done
}

load_shfmt_pin() {
    local version_output_variable=$1
    local amd64_output_variable=$2
    local arm64_output_variable=$3
    local script_dir=''
    local pin_file=''
    local pinned_version=''
    local pinned_amd64_sha=''
    local pinned_arm64_sha=''

    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    pin_file="${script_dir}/shfmt-pin.env"
    [[ -f ${pin_file} && ! -L ${pin_file} && -r ${pin_file} ]] || {
        fail "shfmt pin file is missing, non-regular, symbolic, or unreadable: ${pin_file}" 66
        exit $?
    }

    read_pin "${pin_file}" pinned_version pinned_amd64_sha pinned_arm64_sha
    printf -v "${version_output_variable}" '%s' "${pinned_version}"
    printf -v "${amd64_output_variable}" '%s' "${pinned_amd64_sha}"
    printf -v "${arm64_output_variable}" '%s' "${pinned_arm64_sha}"
}

select_shfmt_platform() {
    local amd64_sha=$1
    local arm64_sha=$2
    local arch_output_variable=$3
    local sha_output_variable=$4
    local os_name=''
    local machine=''
    local selected_arch=''
    local selected_sha=''

    os_name=$(uname -s)
    if [[ ${os_name} != Linux ]]; then
        fail 'the managed shfmt bootstrap currently supports Linux only' 69
        exit $?
    fi

    machine=$(uname -m)
    case ${machine} in
        x86_64 | amd64)
            selected_arch='amd64'
            selected_sha=${amd64_sha}
            ;;
        aarch64 | arm64)
            selected_arch='arm64'
            selected_sha=${arm64_sha}
            ;;
        *)
            fail "unsupported Linux architecture for shfmt: ${machine}" 69
            exit $?
            ;;
    esac
    printf -v "${arch_output_variable}" '%s' "${selected_arch}"
    printf -v "${sha_output_variable}" '%s' "${selected_sha}"
}

resolve_shfmt_cache() {
    local version=$1
    local directory_output_variable=$2
    local binary_output_variable=$3
    local cache_root=''
    local resolved_version_dir=''
    local managed_binary=''

    if [[ -n ${SHFMT_TOOL_ROOT:-} ]]; then
        cache_root=${SHFMT_TOOL_ROOT}
    elif [[ -n ${HOME:-} ]]; then
        cache_root="${HOME}/.local/lib/yt-dlp-aria2-downloader-gui/dev-tools/shfmt"
    else
        fail 'HOME is unavailable; cannot place the managed shfmt tool'
        exit $?
    fi

    [[ ${cache_root} == /* ]] || {
        fail "shfmt tool root must be absolute: ${cache_root}"
        exit $?
    }

    resolved_version_dir="${cache_root}/v${version}"
    managed_binary="${resolved_version_dir}/shfmt"

    if [[ -L ${managed_binary} ]]; then
        fail "refusing symbolic-link shfmt tool entry: ${managed_binary}"
        exit $?
    fi
    printf -v "${directory_output_variable}" '%s' "${resolved_version_dir}"
    printf -v "${binary_output_variable}" '%s' "${managed_binary}"
}

prepare_shfmt_cache() {
    local version_dir=$1
    local binary=$2

    mkdir -p -- "${version_dir}"
    chmod 0700 -- "${version_dir}"

    if [[ -e ${binary} ]]; then
        rm -f -- "${binary}"
    fi
}

download_shfmt_asset() {
    local version=$1
    local asset_arch=$2
    local expected_sha=$3
    local version_dir=$4
    local asset_name=''
    local asset_url=''
    local downloaded_sha=''

    asset_name="shfmt_v${version}_linux_${asset_arch}"
    asset_url="https://github.com/${SHFMT_UPSTREAM_REPOSITORY}/releases/download/v${version}/${asset_name}"
    SHFMT_DOWNLOAD_TMP=$(mktemp "${version_dir}/.shfmt-download.XXXXXX")

    printf 'Downloading verified shfmt v%s (%s)...\n' \
        "${version}" "${asset_arch}" >&2

    if ! curl \
        --fail \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 3 \
        --retry-delay 1 \
        --retry-max-time 180 \
        --silent \
        --show-error \
        --output "${SHFMT_DOWNLOAD_TMP}" \
        "${asset_url}"; then
        fail "unable to download pinned shfmt asset: ${asset_url}" 69
        exit $?
    fi

    downloaded_sha=$(sha256sum -- "${SHFMT_DOWNLOAD_TMP}")
    downloaded_sha=${downloaded_sha%% *}
    if [[ ${downloaded_sha} != "${expected_sha}" ]]; then
        fail "downloaded shfmt SHA-256 mismatch for ${asset_name}" 65
        exit $?
    fi

    chmod 0755 -- "${SHFMT_DOWNLOAD_TMP}"
}

publish_shfmt_binary() {
    local binary=$1
    local expected_sha=$2
    local version=$3

    mv -f -- "${SHFMT_DOWNLOAD_TMP}" "${binary}"
    SHFMT_DOWNLOAD_TMP=''

    # Post-install verification is a predicate with explicit failure handling.
    # shellcheck disable=SC2310
    if ! verified_binary "${binary}" "${expected_sha}" "${version}"; then
        rm -f -- "${binary}" || true
        fail 'downloaded shfmt failed post-install verification' 65
        exit $?
    fi

    printf '%s\n' "${binary}"
}

main() {
    local version=''
    local amd64_sha=''
    local arm64_sha=''
    local asset_arch=''
    local expected_sha=''
    local version_dir=''
    local binary=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    require_shfmt_commands
    load_shfmt_pin version amd64_sha arm64_sha
    select_shfmt_platform "${amd64_sha}" "${arm64_sha}" asset_arch expected_sha
    resolve_shfmt_cache "${version}" version_dir binary

    # Cache verification is a predicate and handles command failures explicitly.
    # shellcheck disable=SC2310
    if verified_binary "${binary}" "${expected_sha}" "${version}"; then
        printf '%s\n' "${binary}"
        return 0
    fi

    prepare_shfmt_cache "${version_dir}" "${binary}"
    download_shfmt_asset "${version}" "${asset_arch}" "${expected_sha}" "${version_dir}"
    publish_shfmt_binary "${binary}" "${expected_sha}" "${version}"
}

main "$@"

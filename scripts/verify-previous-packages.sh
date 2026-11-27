#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/verify-previous-packages.sh
# Purpose     : Authenticate the immutable RPM used for upgrade qualification.
# ==============================================================================

set -Eeuo pipefail

main() {
    if (($# != 2)) || [[ ! $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! $2 =~ ^[a-f0-9]{40}$ ]]; then
        printf 'Usage: %s vMAJOR.MINOR.PATCH COMMIT_SHA\n' "${0##*/}" >&2
        return 64
    fi
    local tag=$1 commit=$2 repo=${GITHUB_REPOSITORY:?}
    local immutable rpm asset name oldest version=${tag#v}
    local -a rpms

    immutable=$(gh release view "${tag}" -R "${repo}" --json isImmutable --jq '.isImmutable')
    if [[ ${immutable} != true ]]; then
        printf 'Error: previous release is not immutable: %s\n' "${tag}" >&2
        return 65
    fi
    gh release verify "${tag}" -R "${repo}"
    mkdir -- previous
    cd -- previous
    gh release download "${tag}" -R "${repo}" --pattern '*.rpm' --pattern SHA256SUMS
    shopt -s nullglob
    rpms=(*.rpm)
    if ((${#rpms[@]} != 1)); then
        printf 'Error: expected exactly one previous RPM, found %d.\n' "${#rpms[@]}" >&2
        return 65
    fi
    rpm=${rpms[0]}
    name="yt-dlp-aria2-downloader-gui-${version}-1"
    oldest=$(printf '%s\n' "${version}" 2.4.5 | sort -V | head -n 1)
    if [[ ${oldest} == "${version}" && ! ${rpm} =~ ^"${name}"\.fc[0-9]+\.noarch\.rpm$ ]] \
        || [[ ${oldest} != "${version}" && ${rpm} != "${name}.fc45.x86_64.rpm" ]]; then
        printf 'Error: previous RPM filename does not match release %s.\n' "${tag}" >&2
        return 65
    fi

    # Immutable releases use the GNU text-mode digest format. Reject competing
    # entries for the same RPM, including alternate binary-mode spellings.
    if ! LC_ALL=C awk -v name="${rpm}" '
        $2 == name || $2 == "*" name {
            count++
            if (length($1) == 64 && $1 ~ /^[[:xdigit:]]+$/ && $0 == $1 "  " name) valid++
        }
        END { exit !(count == 1 && valid == 1) }
    ' SHA256SUMS; then
        printf 'Error: expected one unambiguous SHA256SUMS entry for %s.\n' "${rpm}" >&2
        return 65
    fi
    sha256sum --ignore-missing --check SHA256SUMS
    for asset in "${rpm}" SHA256SUMS; do
        gh release verify-asset "${tag}" "${asset}" -R "${repo}"
        gh attestation verify "${asset}" --repo "${repo}" \
            --signer-workflow "${repo}/.github/workflows/release.yml" \
            --source-digest "${commit}" --source-ref "refs/tags/${tag}"
    done
    sha256sum -- "${rpm}" >PREVIOUS_SHA256SUMS
    sha256sum --check PREVIOUS_SHA256SUMS
}

main "$@"

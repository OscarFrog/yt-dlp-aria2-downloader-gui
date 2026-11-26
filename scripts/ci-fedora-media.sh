#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/ci-fedora-media.sh
# Purpose     : Provision authenticated Fedora 45 media tools for isolated CI jobs.
# ==============================================================================

set -Eeuo pipefail

provision_media() (
    local kernel_arch='' rpm_arch=''
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ ${ID:-} != fedora || ${VERSION_ID:-} != 45 ]] \
        || ! kernel_arch=$(uname -m) || ! rpm_arch=$(rpm -E '%{_arch}') \
        || [[ ${kernel_arch} != x86_64 || ${rpm_arch} != x86_64 ]]; then
        printf '%s\n' 'Error: media provisioning requires Fedora 45 x86_64.' >&2
        exit 69
    fi
    umask 077

    readonly rpmfusion_fingerprint=E9A491A3DE247814E7E067EAE06F8ECDD651FF2E
    readonly rpmfusion_nevra=rpmfusion-free-release-45-2.noarch
    bootstrap_dir=$(mktemp -d)
    gpg_home=$(mktemp -d)
    key_listing=$(mktemp)
    rpm_keyring="${bootstrap_dir}/rpm-keyring"
    trap 'rm -rf -- "${bootstrap_dir}" "${gpg_home}"; rm -f -- "${key_listing}"' EXIT

    chmod 700 -- "${gpg_home}"
    mkdir -p -- "${rpm_keyring}"
    chmod 700 -- "${rpm_keyring}"

    dnf install --assumeyes \
        ca-certificates curl findutils gawk git gnupg2 grep gzip procps-ng \
        python3 python3-pip rpm sed tar unzip util-linux xz

    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors \
        --output "${bootstrap_dir}/RPM-GPG-KEY-rpmfusion-free-fedora-2020" \
        'https://download1.rpmfusion.org/free/fedora/RPM-GPG-KEY-rpmfusion-free-fedora-2020'
    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors \
        --output "${bootstrap_dir}/rpmfusion-free-release-45.noarch.rpm" \
        'https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-45.noarch.rpm'

    gpg --homedir "${gpg_home}" --batch --no-options \
        --with-colons --show-keys --fingerprint \
        "${bootstrap_dir}/RPM-GPG-KEY-rpmfusion-free-fedora-2020" \
        >"${key_listing}"

    primary_count=$(
        awk -F: '$1 == "pub" { count++ } END { print count + 0 }' \
            "${key_listing}"
    )
    primary_fingerprint=$(
        awk -F: \
            '$1 == "pub" { want=1; next }
         want && $1 == "fpr" {
           print toupper($10)
           exit
         }' \
            "${key_listing}"
    )
    if [[ ${primary_count} != 1 ||
        ${primary_fingerprint} != "${rpmfusion_fingerprint}" ]]; then
        printf 'Error: unexpected RPM Fusion bootstrap key: count=%s fingerprint=%s\n' \
            "${primary_count}" "${primary_fingerprint:-<missing>}" >&2
        exit 65
    fi

    signature_state=$(
        LC_ALL=C rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' \
            -- "${bootstrap_dir}/rpmfusion-free-release-45.noarch.rpm"
    )
    if [[ ${signature_state} != signed ]]; then
        printf 'Error: RPM Fusion bootstrap package has no OpenPGP signature.\n' >&2
        exit 65
    fi

    rpmkeys \
        --define "_keyring fs" \
        --define "_keyringpath ${rpm_keyring}" \
        --define "_keyring_lockpath ${rpm_keyring}/.keyring.lock" \
        --define "_rpmlock_path ${rpm_keyring}/.rpm.lock" \
        --import "${bootstrap_dir}/RPM-GPG-KEY-rpmfusion-free-fedora-2020"
    rpmkeys \
        --define "_keyring fs" \
        --define "_keyringpath ${rpm_keyring}" \
        --define "_keyring_lockpath ${rpm_keyring}/.keyring.lock" \
        --define "_rpmlock_path ${rpm_keyring}/.rpm.lock" \
        --checksig "${bootstrap_dir}/rpmfusion-free-release-45.noarch.rpm"

    resolved_nevra=$(
        rpm -qp --qf '%{NEVRA}\n' \
            "${bootstrap_dir}/rpmfusion-free-release-45.noarch.rpm"
    )
    if [[ ${resolved_nevra} != "${rpmfusion_nevra}" ]]; then
        printf 'Error: unexpected RPM Fusion bootstrap package: %s\n' \
            "${resolved_nevra}" >&2
        exit 65
    fi

    rpmkeys --import "${bootstrap_dir}/RPM-GPG-KEY-rpmfusion-free-fedora-2020"
    dnf install --assumeyes --setopt=localpkg_gpgcheck=True \
        "${bootstrap_dir}/rpmfusion-free-release-45.noarch.rpm"
    dnf install --assumeyes aria2 ffmpeg
)

main() {
    provision_media
}

main "$@"

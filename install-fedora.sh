#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : install-fedora.sh
# Purpose     : Verify and install the Fedora RPM and required system dependencies.
# ==============================================================================

set -Eeuo pipefail
umask 022

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly APP_VERSION='2.2.4'
readonly PRIVATE_DIR='/usr/libexec/yt-dlp-aria2-downloader'
readonly RPM_SIGNING_KEY_NAME='RPM-GPG-KEY-OscarFrog'
readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'
readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'

error() {
    printf 'Error: %s\n' "$*" >&2
}

usage() {
    cat >&2 <<EOF
Usage:
  ${0##*/} PACKAGE.rpm
  ${0##*/} --allow-unsigned-dev PACKAGE.rpm

Release RPMs must carry an OpenPGP signature made by the pinned OscarFrog RPM
signing certificate. --allow-unsigned-dev is only for local/CI development RPMs.
EOF
}

run_root() {
    if ((EUID == 0)); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || {
            error 'sudo is required for system package installation.'
            return 127
        }
        sudo "$@"
    fi
}

main() {
    allow_unsigned_dev=false
    if (($# == 2)) && [[ $1 == '--allow-unsigned-dev' ]]; then
        allow_unsigned_dev=true
        shift
    fi
    if (($# != 1)); then
        usage
        exit 2
    fi

    for command_name in awk dnf mktemp rpm rpmkeys realpath; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required installer command is absent: ${command_name}"
            exit 127
        }
    done

    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
        error 'unable to resolve Fedora installer path.'
        exit 66
    }
    readonly SCRIPT_DIR=${script_path%/*}

    rpm_path=$(realpath -e -- "$1") || {
        error "RPM not found: $1"
        exit 66
    }
    [[ ${rpm_path} == *.rpm ]] || {
        error "not an RPM file: ${rpm_path}"
        exit 64
    }

    rpm_identity_output=''
    if ! rpm_identity_output=$(rpm -qp --qf '%{NAME}\n%{VERSION}\n%{ARCH}\n' -- "${rpm_path}"); then
        error 'unable to inspect the RPM metadata.'
        exit 65
    fi
    mapfile -t rpm_identity <<<"${rpm_identity_output}"
    if ((${#rpm_identity[@]} != 3)) \
        || [[ ${rpm_identity[0]} != "${PACKAGE_NAME}" ||
            ${rpm_identity[1]} != "${APP_VERSION}" ||
            ${rpm_identity[2]} != 'noarch' ]]; then
        error "unexpected RPM identity: name=${rpm_identity[0]:-unknown} version=${rpm_identity[1]:-unknown} arch=${rpm_identity[2]:-unknown}"
        exit 65
    fi

    signature_state=$(LC_ALL=C rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' -- "${rpm_path}") || {
        error 'unable to inspect RPM OpenPGP signature metadata.'
        exit 65
    }
    case ${signature_state} in
        signed)
            ;;
        unsigned)
            if [[ ${allow_unsigned_dev} != true ]]; then
                error 'RPM has no OpenPGP signature; refusing release-style installation.'
                error 'Use only an official signed release RPM, or pass --allow-unsigned-dev explicitly for a local development build.'
                exit 65
            fi
            printf '%s\n' 'Warning: installing an explicitly allowed unsigned development RPM; OpenPGP verification is disabled for this transaction.' >&2
            ;;
        *)
            error "unexpected RPM signature state: ${signature_state}"
            exit 65
            ;;
    esac

    key_path=''
    if [[ ${signature_state} == signed ]]; then
        if [[ -f ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} && ! -L ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} ]]; then
            key_path="${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME}"
        elif [[ -f ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} &&
            ! -L ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} ]]; then
            key_path="${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME}"
        else
            error "RPM signing public key is missing: ${RPM_SIGNING_KEY_NAME}"
            exit 66
        fi
    fi

    fedora_version=$(rpm -E %fedora)
    [[ ${fedora_version} =~ ^[0-9]+$ ]] || {
        error 'unable to determine the Fedora release.'
        exit 69
    }
    if ((fedora_version < 44)); then
        error "Fedora 44 or newer is required; found Fedora ${fedora_version}."
        exit 69
    fi

    if [[ ${signature_state} == signed ]]; then
        # GnuPG is a Fedora-repository prerequisite for authenticating the release
        # before any third-party repository is enabled.
        if ! command -v gpg >/dev/null 2>&1; then
            printf 'Installing GnuPG prerequisite for RPM authentication...\n'
            run_root dnf install --assumeyes gnupg2
        fi
        command -v gpg >/dev/null 2>&1 || {
            error 'GnuPG is required to validate the pinned RPM signing certificate.'
            exit 127
        }

        verify_root=$(mktemp -d) || {
            error 'unable to create the isolated RPM verification directory.'
            exit 70
        }
        chmod 700 "${verify_root}" || {
            rm -rf -- "${verify_root}"
            error 'unable to secure the isolated RPM verification directory.'
            exit 70
        }
        gpg_home="${verify_root}/gnupg"
        rpm_verify_keyring="${verify_root}/rpm-keyring"
        gpg_output="${verify_root}/key.colons"
        mkdir -p -- "${gpg_home}" "${rpm_verify_keyring}"
        chmod 700 "${gpg_home}" "${rpm_verify_keyring}"
        trap 'rm -rf -- "${verify_root:-}"' EXIT

        if ! LC_ALL=C gpg \
            --homedir "${gpg_home}" \
            --batch \
            --no-options \
            --with-colons \
            --show-keys \
            --fingerprint \
            "${key_path}" >"${gpg_output}"; then
            error 'unable to inspect the RPM signing public certificate.'
            exit 65
        fi

        primary_count=$(
            awk -F: '$1 == "pub" { count++ } END { print count + 0 }' \
                "${gpg_output}"
        )
        primary_fingerprint=$(
            awk -F: \
                '$1 == "pub" { want=1; next }
                 want && $1 == "fpr" && !found {
                     value=toupper($10); found=1
                 }
                 END { if (found) print value }' \
                "${gpg_output}"
        )
        primary_validity=$(
            awk -F: '$1 == "pub" { print $2; exit }' "${gpg_output}"
        )
        primary_capabilities=$(
            awk -F: '$1 == "pub" { print $12; exit }' "${gpg_output}"
        )
        signing_subkey_count=$(
            awk -F: \
                '$1 == "sub" &&
                 $2 != "r" &&
                 $2 != "e" &&
                 index($12, "s") > 0 {
                     count++
                 }
                 END { print count + 0 }' \
                "${gpg_output}"
        )
        signing_subkey_fingerprint=$(
            awk -F: -v expected="${RPM_SIGNING_SUBKEY_FINGERPRINT}" \
                '$1 == "sub" {
                     want=($2 != "r" && $2 != "e" && index($12, "s") > 0)
                     next
                 }
                 want && $1 == "fpr" {
                     value=toupper($10)
                     if (value == expected) {
                         print value
                         exit
                     }
                     want=0
                 }' \
                "${gpg_output}"
        )

        if [[ ${primary_count} != 1 ]]; then
            error "RPM signing key file must contain exactly one primary certificate; found ${primary_count}."
            exit 65
        fi
        if [[ ${primary_fingerprint} != "${RPM_SIGNING_FINGERPRINT}" ]]; then
            error "unexpected RPM signing primary fingerprint: ${primary_fingerprint:-missing}"
            exit 65
        fi
        if [[ ${primary_validity} == r || ${primary_validity} == e ]]; then
            error 'the pinned RPM signing primary certificate is revoked or expired.'
            exit 65
        fi
        if [[ ${primary_capabilities} != *c* ]]; then
            error 'the pinned RPM primary certificate lacks certification capability.'
            exit 65
        fi
        if [[ ${primary_capabilities} == *s* ]]; then
            error 'the pinned RPM primary certificate must remain certification-only.'
            exit 65
        fi
        if [[ ${signing_subkey_count} != 1 ]]; then
            error "the pinned RPM certificate must contain exactly one usable signing subkey; found ${signing_subkey_count}."
            exit 65
        fi
        if [[ ${signing_subkey_fingerprint} != "${RPM_SIGNING_SUBKEY_FINGERPRINT}" ]]; then
            error "required RPM signing subkey is missing, expired, revoked, or not signing-capable: ${RPM_SIGNING_SUBKEY_FINGERPRINT}"
            exit 65
        fi

        # Verify with RPM 6's filesystem keyring backend. Both the key store and
        # RPM transaction lock are private to this invocation, so pre-existing host
        # RPM keys cannot authorize this package.
        rpmkeys \
            --define "_keyring fs" \
            --define "_keyringpath ${rpm_verify_keyring}" \
            --define "_keyring_lockpath ${rpm_verify_keyring}/.keyring.lock" \
            --define "_rpmlock_path ${rpm_verify_keyring}/.rpm.lock" \
            --import "${key_path}" || {
            error 'unable to import the pinned certificate into the isolated RPM keyring.'
            exit 65
        }
        if ! rpmkeys \
            --define "_keyring fs" \
            --define "_keyringpath ${rpm_verify_keyring}" \
            --define "_keyring_lockpath ${rpm_verify_keyring}/.keyring.lock" \
            --define "_rpmlock_path ${rpm_verify_keyring}/.rpm.lock" \
            --checksig "${rpm_path}"; then
            error 'RPM OpenPGP signature verification failed against the isolated pinned certificate.'
            exit 65
        fi

        rm -rf -- "${verify_root}"
        verify_root=''
        trap - EXIT

        # DNF performs a second verification during the privileged transaction.
        # Import only after the isolated pinned-certificate verification succeeded.
        printf 'Importing pinned OscarFrog RPM signing key: %s\n' \
            "${RPM_SIGNING_FINGERPRINT}"
        run_root rpmkeys --import "${key_path}"
    fi

    if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
        printf 'Enabling RPM Fusion Free...\n'
        run_root dnf install --assumeyes "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm"
    fi

    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        printf 'Replacing Fedora ffmpeg-free with RPM Fusion ffmpeg...\n'
        run_root dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg
    else
        printf 'Installing RPM Fusion ffmpeg and required system dependencies...\n'
        run_root dnf install --assumeyes --allowerasing ffmpeg aria2 python3 zenity curl gnupg2 unzip
    fi

    printf 'Installing %s...\n' "${PACKAGE_NAME}"
    if [[ ${signature_state} == signed ]]; then
        run_root dnf install --assumeyes --allowerasing --setopt=localpkg_gpgcheck=True "${rpm_path}"
    else
        run_root dnf install --assumeyes --allowerasing --setopt=localpkg_gpgcheck=False "${rpm_path}"
    fi

    rpm -q "${PACKAGE_NAME}" >/dev/null
    rpm -q ffmpeg >/dev/null
    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        error 'ffmpeg-free is still installed.'
        exit 65
    fi

    ffmpeg_vendor=$(rpm -q --qf '%{VENDOR}\n' ffmpeg)
    if [[ ${ffmpeg_vendor} != *'RPM Fusion'* ]]; then
        error "ffmpeg is not provided by RPM Fusion: vendor=${ffmpeg_vendor}"
        exit 65
    fi

    for command_name in ffmpeg ffprobe aria2c python3 zenity; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required command is absent after installation: ${command_name}"
            exit 65
        }
    done

    runtime_manager="${PRIVATE_DIR}/runtime-manager.sh"
    [[ -x ${runtime_manager} ]] || {
        error "runtime manager is missing: ${runtime_manager}"
        exit 65
    }

    printf 'Installing/updating verified yt-dlp stable and Deno stable runtimes for the current user...\n'
    "${runtime_manager}" update

    ytdlp_bin=$("${runtime_manager}" path yt-dlp)
    deno_bin=$("${runtime_manager}" path deno)

    "${ytdlp_bin}" --version
    "${deno_bin}" --version | head -n 1

    application_version=$(/usr/bin/yt-dlp-aria2-downloader --version) || {
        error 'unable to read the installed application version.'
        exit 65
    }
    ffmpeg_version=$(ffmpeg -version) || {
        error 'unable to read the installed FFmpeg version.'
        exit 65
    }
    ffmpeg_version=${ffmpeg_version%%$'\n'*}
    aria2_version=$(aria2c --version) || {
        error 'unable to read the installed aria2 version.'
        exit 65
    }
    aria2_version=${aria2_version%%$'\n'*}
    ytdlp_version=$("${ytdlp_bin}" --version) || {
        error 'unable to read the managed yt-dlp version.'
        exit 65
    }
    ytdlp_version=${ytdlp_version%%$'\n'*}
    deno_version=$("${deno_bin}" --version) || {
        error 'unable to read the managed Deno version.'
        exit 65
    }
    deno_version=${deno_version%%$'\n'*}

    printf '\nInstallation completed successfully.\n'
    printf 'Application : %s\n' "${application_version}"
    printf 'FFmpeg      : %s\n' "${ffmpeg_version}"
    printf 'FFmpeg vendor: %s\n' "${ffmpeg_vendor}"
    printf 'aria2       : %s\n' "${aria2_version}"
    printf 'yt-dlp      : %s\n' "${ytdlp_version}"
    printf 'Deno        : %s\n' "${deno_version}"

}

main "$@"

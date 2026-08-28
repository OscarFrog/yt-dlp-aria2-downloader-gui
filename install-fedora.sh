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
readonly APP_VERSION='2.3.3'
readonly PRIVATE_DIR='/usr/libexec/yt-dlp-aria2-downloader'
readonly RPM_SIGNING_KEY_NAME='RPM-GPG-KEY-OscarFrog'
readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'
readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'
readonly RPM_FUSION_SUPPORTED_FEDORA='44'
readonly RPM_FUSION_SIGNING_FINGERPRINT='E9A491A3DE247814E7E067EAE06F8ECDD651FF2E'
readonly RPM_FUSION_RELEASE_NEVRA='rpmfusion-free-release-44-3.noarch'
readonly RPM_FUSION_KEY_URL='https://download1.rpmfusion.org/free/fedora/RPM-GPG-KEY-rpmfusion-free-fedora-2020'
readonly RPM_FUSION_RELEASE_URL='https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm'

ROOT_APPLICATION_STAGE=''
STAGED_APPLICATION_RPM=''
STAGED_APPLICATION_KEY=''

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

root_stage_path_is_safe() {
    local stage_path=${1:-}

    [[ ${stage_path} =~ ^/tmp/yt-dlp-aria2-downloader-(application|rpmfusion)\.[[:alnum:]]{8}$ ]]
}

create_root_stage() {
    local stage_label=$1
    local output_variable=$2
    local resolved_stage_path=''

    case ${stage_label} in
        application | rpmfusion) ;;
        *) return 2 ;;
    esac

    # shellcheck disable=SC2310 # Failure is converted to a staging diagnostic.
    resolved_stage_path=$(run_root mktemp -d --tmpdir=/tmp \
        "yt-dlp-aria2-downloader-${stage_label}.XXXXXXXX") || {
        error "unable to create the root-owned ${stage_label} staging directory."
        exit 70
    }
    # shellcheck disable=SC2310 # This helper is a predicate.
    if ! root_stage_path_is_safe "${resolved_stage_path}"; then
        error "root-owned ${stage_label} staging returned an unsafe path."
        exit 70
    fi
    # Publish the validated path before later setup so every subsequent failure
    # is covered by the caller's EXIT cleanup.
    printf -v "${output_variable}" '%s' "${resolved_stage_path}"
    # shellcheck disable=SC2310 # Failure is converted to a staging diagnostic.
    run_root chmod 700 -- "${resolved_stage_path}" || {
        error "unable to secure the root-owned ${stage_label} staging directory."
        exit 70
    }
}

remove_root_stage() {
    local stage_path=$1

    # shellcheck disable=SC2310 # This helper is a predicate.
    root_stage_path_is_safe "${stage_path}" || {
        error 'refusing to remove an unsafe root-owned staging path.'
        return 70
    }
    run_root rm -rf -- "${stage_path}"
}

stage_root_file() {
    local source_path=$1
    local stage_path=$2
    local destination_name=$3
    local output_variable=$4
    local resolved_staged_path=''

    # shellcheck disable=SC2310 # This helper is a predicate.
    root_stage_path_is_safe "${stage_path}" || return 70
    case ${destination_name} in
        application.rpm | signing-key.asc | rpmfusion-release.rpm | rpmfusion-key.asc) ;;
        *) return 2 ;;
    esac

    resolved_staged_path="${stage_path}/${destination_name}"
    # shellcheck disable=SC2310 # Failure is converted to a staging diagnostic.
    run_root install -m 0600 -- "${source_path}" "${resolved_staged_path}" || {
        error "unable to copy ${destination_name} into root-owned staging."
        exit 70
    }
    printf -v "${output_variable}" '%s' "${resolved_staged_path}"
}

cleanup() {
    local cleanup_status=$?

    trap - EXIT HUP INT TERM
    if [[ -n ${ROOT_APPLICATION_STAGE} ]]; then
        # shellcheck disable=SC2310 # Cleanup is explicitly best-effort on exit.
        if ! remove_root_stage "${ROOT_APPLICATION_STAGE}"; then
            printf 'Warning: unable to remove root-owned application staging: %s\n' \
                "${ROOT_APPLICATION_STAGE}" >&2
        fi
        ROOT_APPLICATION_STAGE=''
        STAGED_APPLICATION_RPM=''
        STAGED_APPLICATION_KEY=''
    fi
    exit "${cleanup_status}"
}

parse_fedora_arguments() {
    local allow_output_variable=$1
    local rpm_output_variable=$2
    local parsed_allow_unsigned_dev=false
    local parsed_rpm_argument=''
    shift 2

    if (($# == 2)) && [[ $1 == '--allow-unsigned-dev' ]]; then
        parsed_allow_unsigned_dev=true
        shift
    fi
    if (($# != 1)); then
        usage
        exit 2
    fi
    parsed_rpm_argument=$1

    printf -v "${allow_output_variable}" '%s' "${parsed_allow_unsigned_dev}"
    printf -v "${rpm_output_variable}" '%s' "${parsed_rpm_argument}"
}

require_fedora_installer_commands() {
    local command_name=''

    for command_name in awk chmod dnf head install mkdir mktemp rm rpm rpmkeys realpath; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required installer command is absent: ${command_name}"
            exit 127
        }
    done
}

initialize_fedora_paths() {
    local rpm_argument=$1
    local output_variable=$2
    local script_path=''
    local resolved_rpm=''

    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
        error 'unable to resolve Fedora installer path.'
        exit 66
    }
    readonly SCRIPT_DIR=${script_path%/*}

    resolved_rpm=$(realpath -e -- "${rpm_argument}") || {
        error "RPM not found: ${rpm_argument}"
        exit 66
    }
    [[ ${resolved_rpm} == *.rpm ]] || {
        error "not an RPM file: ${resolved_rpm}"
        exit 64
    }
    printf -v "${output_variable}" '%s' "${resolved_rpm}"
}

validate_rpm_identity() {
    local rpm_path=$1
    local rpm_identity_output=''
    local -a rpm_identity=()

    # shellcheck disable=SC2310 # Failure is converted to an identity diagnostic.
    if ! rpm_identity_output=$(LC_ALL=C run_root \
        rpm -qp --qf '%{NAME}\n%{VERSION}\n%{ARCH}\n' -- "${rpm_path}"); then
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
}

inspect_rpm_signature() {
    local rpm_path=$1
    local allow_unsigned_dev=$2
    local output_variable=$3
    local execution_context=${4:-user}
    local emit_warning=${5:-true}
    local detected_state=''
    local -a command_prefix=()

    case ${execution_context} in
        user) ;;
        root) command_prefix=(run_root) ;;
        *) return 2 ;;
    esac

    detected_state=$(LC_ALL=C "${command_prefix[@]}" \
        rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' -- "${rpm_path}") || {
        error 'unable to inspect RPM OpenPGP signature metadata.'
        exit 65
    }
    case ${detected_state} in
        signed)
            ;;
        unsigned)
            if [[ ${allow_unsigned_dev} != true ]]; then
                error 'RPM has no OpenPGP signature; refusing release-style installation.'
                error 'Use only an official signed release RPM, or pass --allow-unsigned-dev explicitly for a local development build.'
                exit 65
            fi
            if [[ ${emit_warning} == true ]]; then
                printf '%s\n' 'Warning: installing an explicitly allowed unsigned development RPM; OpenPGP verification is disabled for this transaction.' >&2
            fi
            ;;
        *)
            error "unexpected RPM signature state: ${detected_state}"
            exit 65
            ;;
    esac
    printf -v "${output_variable}" '%s' "${detected_state}"
}

resolve_rpm_signing_key() {
    local signature_state=$1
    local output_variable=$2
    local resolved_key=''

    if [[ ${signature_state} == signed ]]; then
        if [[ -f ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} && ! -L ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} ]]; then
            resolved_key="${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME}"
        elif [[ -f ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} &&
            ! -L ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} ]]; then
            resolved_key="${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME}"
        else
            error "RPM signing public key is missing: ${RPM_SIGNING_KEY_NAME}"
            exit 66
        fi
    fi
    printf -v "${output_variable}" '%s' "${resolved_key}"
}

detect_supported_fedora() {
    local output_variable=$1
    local detected_version=''

    detected_version=$(rpm -E %fedora)
    [[ ${detected_version} =~ ^[0-9]+$ ]] || {
        error 'unable to determine the Fedora release.'
        exit 69
    }
    if [[ ${detected_version} != "${RPM_FUSION_SUPPORTED_FEDORA}" ]]; then
        error "Fedora ${RPM_FUSION_SUPPORTED_FEDORA} is the only qualified release; found Fedora ${detected_version}."
        exit 69
    fi
    printf -v "${output_variable}" '%s' "${detected_version}"
}

ensure_rpm_verification_gpg() {
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
}

inspect_rpm_signing_certificate() {
    local key_path=$1
    local gpg_home=$2
    local output_variable=$3
    local certificate_output=''

    # shellcheck disable=SC2310 # Failure is converted to a certificate diagnostic.
    if ! certificate_output=$(LC_ALL=C run_root gpg \
        --homedir "${gpg_home}" \
        --batch \
        --no-options \
        --with-colons \
        --show-keys \
        --fingerprint \
        "${key_path}"); then
        error 'unable to inspect the RPM signing public certificate.'
        exit 65
    fi
    printf -v "${output_variable}" '%s' "${certificate_output}"
}

validate_rpm_signing_certificate() {
    local gpg_output=$1
    local primary_count primary_fingerprint primary_validity primary_capabilities
    local signing_subkey_count signing_subkey_fingerprint

    primary_count=$(
        awk -F: '$1 == "pub" { count++ } END { print count + 0 }' \
            <<<"${gpg_output}"
    )
    primary_fingerprint=$(
        awk -F: \
            '$1 == "pub" { want=1; next }
             want && $1 == "fpr" && !found {
                 value=toupper($10); found=1
             }
             END { if (found) print value }' \
            <<<"${gpg_output}"
    )
    primary_validity=$(
        awk -F: '$1 == "pub" { print $2; exit }' <<<"${gpg_output}"
    )
    primary_capabilities=$(
        awk -F: '$1 == "pub" { print $12; exit }' <<<"${gpg_output}"
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
            <<<"${gpg_output}"
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
            <<<"${gpg_output}"
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
}

verify_rpm_with_pinned_keyring() {
    local rpm_path=$1
    local key_path=$2
    local rpm_verify_keyring=$3

    # Both the key store and RPM transaction lock are private to this invocation,
    # so pre-existing host RPM keys cannot authorize this package.
    # shellcheck disable=SC2310 # Failure is converted to a keyring diagnostic.
    run_root rpmkeys \
        --define "_keyring fs" \
        --define "_keyringpath ${rpm_verify_keyring}" \
        --define "_keyring_lockpath ${rpm_verify_keyring}/.keyring.lock" \
        --define "_rpmlock_path ${rpm_verify_keyring}/.rpm.lock" \
        --import "${key_path}" || {
        error 'unable to import the pinned certificate into the isolated RPM keyring.'
        exit 65
    }
    # shellcheck disable=SC2310 # Failure is converted to a signature diagnostic.
    if ! run_root rpmkeys \
        --define "_keyring fs" \
        --define "_keyringpath ${rpm_verify_keyring}" \
        --define "_keyring_lockpath ${rpm_verify_keyring}/.keyring.lock" \
        --define "_rpmlock_path ${rpm_verify_keyring}/.rpm.lock" \
        --checksig "${rpm_path}"; then
        error 'RPM OpenPGP signature verification failed against the isolated pinned certificate.'
        exit 65
    fi
}

verify_signed_rpm() {
    local rpm_path=$1
    local key_path=$2
    local root_stage=$3
    local gpg_home="${root_stage}/application-gnupg"
    local rpm_verify_keyring="${root_stage}/application-rpm-keyring"
    local gpg_output=''

    # shellcheck disable=SC2310 # This helper is a predicate.
    root_stage_path_is_safe "${root_stage}" || return 70
    ensure_rpm_verification_gpg
    run_root mkdir -p -- "${gpg_home}" "${rpm_verify_keyring}"
    run_root chmod 700 -- "${gpg_home}" "${rpm_verify_keyring}"

    inspect_rpm_signing_certificate \
        "${key_path}" "${gpg_home}" gpg_output
    validate_rpm_signing_certificate "${gpg_output}"
    verify_rpm_with_pinned_keyring \
        "${rpm_path}" "${key_path}" "${rpm_verify_keyring}"
}

authenticate_signed_rpm() {
    local rpm_path=$1
    local key_path=$2
    local root_stage=$3

    verify_signed_rpm "${rpm_path}" "${key_path}" "${root_stage}"

    # DNF performs a second verification during the privileged transaction.
    # Import only after the isolated pinned-certificate verification succeeded.
    printf 'Importing pinned OscarFrog RPM signing key: %s\n' \
        "${RPM_SIGNING_FINGERPRINT}"
    run_root rpmkeys --import "${key_path}"
}

prepare_application_rpm() {
    local rpm_path=$1
    local key_path=$2
    local expected_signature_state=$3
    local allow_unsigned_dev=$4
    local staged_signature_state=''

    create_root_stage application ROOT_APPLICATION_STAGE
    stage_root_file \
        "${rpm_path}" "${ROOT_APPLICATION_STAGE}" application.rpm \
        STAGED_APPLICATION_RPM
    if [[ ${expected_signature_state} == signed ]]; then
        stage_root_file \
            "${key_path}" "${ROOT_APPLICATION_STAGE}" signing-key.asc \
            STAGED_APPLICATION_KEY
    fi

    # Every authorization decision is repeated against the protected root-owned
    # copies. The original user paths are never reopened by rpmkeys or DNF.
    validate_rpm_identity "${STAGED_APPLICATION_RPM}"
    inspect_rpm_signature \
        "${STAGED_APPLICATION_RPM}" "${allow_unsigned_dev}" \
        staged_signature_state root true
    if [[ ${staged_signature_state} != "${expected_signature_state}" ]]; then
        error 'RPM signature state changed while entering root-owned staging.'
        exit 65
    fi
    if [[ ${staged_signature_state} == signed ]]; then
        authenticate_signed_rpm \
            "${STAGED_APPLICATION_RPM}" \
            "${STAGED_APPLICATION_KEY}" \
            "${ROOT_APPLICATION_STAGE}"
    fi
}

release_application_stage() {
    [[ -n ${ROOT_APPLICATION_STAGE} ]] || return 0
    # shellcheck disable=SC2310 # Failure becomes a fatal cleanup diagnostic.
    remove_root_stage "${ROOT_APPLICATION_STAGE}" || {
        error 'unable to remove root-owned application staging.'
        exit 70
    }
    ROOT_APPLICATION_STAGE=''
    STAGED_APPLICATION_RPM=''
    STAGED_APPLICATION_KEY=''
}

ensure_rpm_fusion_bootstrap_tools() {
    local command_name=''
    local -a missing_packages=()

    command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
    command -v gpg >/dev/null 2>&1 || missing_packages+=(gnupg2)
    if ((${#missing_packages[@]} > 0)); then
        printf 'Installing Fedora-repository bootstrap prerequisites...\n'
        run_root dnf install --assumeyes ca-certificates "${missing_packages[@]}"
    fi
    for command_name in curl gpg; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required RPM Fusion authentication command is absent: ${command_name}"
            exit 127
        }
    done
}

validate_rpm_fusion_certificate() {
    local gpg_output=$1
    local primary_count=''
    local primary_fingerprint=''
    local primary_validity=''

    primary_count=$(
        awk -F: '$1 == "pub" { count++ } END { print count + 0 }' \
            <<<"${gpg_output}"
    )
    primary_fingerprint=$(
        awk -F: \
            '$1 == "pub" { want=1; next }
             want && $1 == "fpr" {
                 print toupper($10)
                 exit
             }' \
            <<<"${gpg_output}"
    )
    primary_validity=$(
        awk -F: '$1 == "pub" { print $2; exit }' <<<"${gpg_output}"
    )

    if [[ ${primary_count} != 1 ||
        ${primary_fingerprint} != "${RPM_FUSION_SIGNING_FINGERPRINT}" ||
        ${primary_validity} == r || ${primary_validity} == e ]]; then
        error "unexpected RPM Fusion bootstrap certificate: count=${primary_count} fingerprint=${primary_fingerprint:-missing} validity=${primary_validity:-missing}"
        exit 65
    fi
}

validate_rpm_fusion_release_identity() {
    local rpm_path=$1
    local resolved_nevra=''

    # shellcheck disable=SC2310 # Failure is converted to an identity diagnostic.
    resolved_nevra=$(LC_ALL=C run_root \
        rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        -- "${rpm_path}") || {
        error 'unable to inspect the RPM Fusion bootstrap package.'
        exit 65
    }
    if [[ ${resolved_nevra} != "${RPM_FUSION_RELEASE_NEVRA}" ]]; then
        error "unexpected RPM Fusion bootstrap package: ${resolved_nevra:-missing}"
        exit 65
    fi
}

enable_rpm_fusion() {
    local fedora_version=$1
    local installed_nevra=''

    if installed_nevra=$(rpm -q --qf \
        '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        rpmfusion-free-release 2>/dev/null); then
        [[ ${installed_nevra} == "${RPM_FUSION_RELEASE_NEVRA}" ]] || {
            error "installed RPM Fusion release package is outside the qualified contract: ${installed_nevra:-missing}"
            exit 65
        }
        return 0
    fi
    [[ ${fedora_version} == "${RPM_FUSION_SUPPORTED_FEDORA}" ]] || {
        error "no authenticated RPM Fusion bootstrap is pinned for Fedora ${fedora_version}."
        exit 69
    }

    ensure_rpm_fusion_bootstrap_tools
    (
        local bootstrap_root=''
        local gpg_output=''
        local key_path=''
        local release_rpm=''
        local root_stage=''
        local staged_key=''
        local staged_rpm=''
        local gpg_home=''
        local rpm_verify_keyring=''

        bootstrap_root=$(mktemp -d) || {
            error 'unable to create the RPM Fusion verification directory.'
            exit 70
        }
        chmod 700 -- "${bootstrap_root}"
        trap 'if [[ -n ${root_stage:-} ]]; then remove_root_stage "${root_stage}" || true; fi; rm -rf -- "${bootstrap_root:-}"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        key_path="${bootstrap_root}/RPM-GPG-KEY-rpmfusion-free-fedora-2020"
        release_rpm="${bootstrap_root}/rpmfusion-free-release-44.noarch.rpm"

        printf 'Downloading authenticated RPM Fusion metadata...\n'
        curl --fail --location --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 120 \
            --retry 3 --retry-all-errors \
            --output "${key_path}" "${RPM_FUSION_KEY_URL}" || {
            error 'unable to download the RPM Fusion signing certificate.'
            exit 69
        }
        curl --fail --location --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 120 \
            --retry 3 --retry-all-errors \
            --output "${release_rpm}" "${RPM_FUSION_RELEASE_URL}" || {
            error 'unable to download the RPM Fusion bootstrap package.'
            exit 69
        }

        create_root_stage rpmfusion root_stage
        stage_root_file \
            "${key_path}" "${root_stage}" rpmfusion-key.asc staged_key
        stage_root_file \
            "${release_rpm}" "${root_stage}" rpmfusion-release.rpm staged_rpm
        gpg_home="${root_stage}/rpmfusion-gnupg"
        rpm_verify_keyring="${root_stage}/rpmfusion-rpm-keyring"
        run_root mkdir -p -- "${gpg_home}" "${rpm_verify_keyring}"
        run_root chmod 700 -- "${gpg_home}" "${rpm_verify_keyring}"

        inspect_rpm_signing_certificate \
            "${staged_key}" "${gpg_home}" gpg_output
        validate_rpm_fusion_certificate "${gpg_output}"
        verify_rpm_with_pinned_keyring \
            "${staged_rpm}" "${staged_key}" "${rpm_verify_keyring}"
        validate_rpm_fusion_release_identity "${staged_rpm}"

        printf 'Importing authenticated RPM Fusion certificate: %s\n' \
            "${RPM_FUSION_SIGNING_FINGERPRINT}"
        run_root rpmkeys --import "${staged_key}"
        printf 'Enabling authenticated RPM Fusion Free...\n'
        run_root dnf install --assumeyes \
            --setopt=localpkg_gpgcheck=True "${staged_rpm}"
        remove_root_stage "${root_stage}"
        root_stage=''
    )
}

install_media_dependencies() {
    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        printf 'Replacing Fedora ffmpeg-free with RPM Fusion ffmpeg...\n'
        run_root dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg
    else
        printf 'Installing RPM Fusion ffmpeg and required system dependencies...\n'
        run_root dnf install --assumeyes --allowerasing ffmpeg aria2 python3 zenity curl gnupg2 unzip
    fi
}

install_application_rpm() {
    local rpm_path=$1
    local signature_state=$2

    printf 'Installing %s...\n' "${PACKAGE_NAME}"
    if [[ ${signature_state} == signed ]]; then
        run_root dnf install --assumeyes --allowerasing --setopt=localpkg_gpgcheck=True "${rpm_path}"
    else
        run_root dnf install --assumeyes --allowerasing --setopt=localpkg_gpgcheck=False "${rpm_path}"
    fi
}

validate_installed_system() {
    local output_variable=$1
    local detected_ffmpeg_vendor=''
    local command_name=''

    rpm -q "${PACKAGE_NAME}" >/dev/null
    rpm -q ffmpeg >/dev/null
    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        error 'ffmpeg-free is still installed.'
        exit 65
    fi

    detected_ffmpeg_vendor=$(rpm -q --qf '%{VENDOR}\n' ffmpeg)
    if [[ ${detected_ffmpeg_vendor} != *'RPM Fusion'* ]]; then
        error "ffmpeg is not provided by RPM Fusion: vendor=${detected_ffmpeg_vendor}"
        exit 65
    fi

    for command_name in ffmpeg ffprobe aria2c python3 zenity; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required command is absent after installation: ${command_name}"
            exit 65
        }
    done
    printf -v "${output_variable}" '%s' "${detected_ffmpeg_vendor}"
}

update_managed_runtimes() {
    local ytdlp_output_variable=$1
    local deno_output_variable=$2
    local runtime_manager=''
    local managed_ytdlp=''
    local managed_deno=''

    runtime_manager="${PRIVATE_DIR}/runtime-manager.sh"
    [[ -x ${runtime_manager} ]] || {
        error "runtime manager is missing: ${runtime_manager}"
        exit 65
    }

    printf 'Installing/updating verified yt-dlp stable and Deno stable runtimes for the current user...\n'
    "${runtime_manager}" update

    managed_ytdlp=$("${runtime_manager}" path yt-dlp)
    managed_deno=$("${runtime_manager}" path deno)

    "${managed_ytdlp}" --version
    "${managed_deno}" --version | head -n 1
    printf -v "${ytdlp_output_variable}" '%s' "${managed_ytdlp}"
    printf -v "${deno_output_variable}" '%s' "${managed_deno}"
}

report_fedora_installation() {
    local ffmpeg_vendor=$1
    local ytdlp_bin=$2
    local deno_bin=$3
    local application_version=''
    local ffmpeg_version=''
    local aria2_version=''
    local ytdlp_version=''
    local deno_version=''

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

main() {
    local allow_unsigned_dev=false
    local rpm_argument=''
    local rpm_path=''
    local signature_state=''
    local key_path=''
    local fedora_version=''
    local ffmpeg_vendor=''
    local ytdlp_bin=''
    local deno_bin=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    parse_fedora_arguments allow_unsigned_dev rpm_argument "$@"
    require_fedora_installer_commands
    initialize_fedora_paths "${rpm_argument}" rpm_path
    inspect_rpm_signature \
        "${rpm_path}" "${allow_unsigned_dev}" signature_state user false
    resolve_rpm_signing_key "${signature_state}" key_path
    detect_supported_fedora fedora_version
    prepare_application_rpm \
        "${rpm_path}" "${key_path}" "${signature_state}" "${allow_unsigned_dev}"
    enable_rpm_fusion "${fedora_version}"
    install_media_dependencies
    install_application_rpm "${STAGED_APPLICATION_RPM}" "${signature_state}"
    release_application_stage
    validate_installed_system ffmpeg_vendor
    update_managed_runtimes ytdlp_bin deno_bin
    report_fedora_installation "${ffmpeg_vendor}" "${ytdlp_bin}" "${deno_bin}"
}

main "$@"

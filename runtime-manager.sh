#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : runtime-manager.sh
# Purpose     : Manage verified per-user yt-dlp and Deno runtimes.
# ==============================================================================

# Predicates in this script are intentionally called from if/!/&&/|| contexts.
# Do not use errexit here: Bash suppresses -e inside functions used as predicates,
# which makes behavior depend on the caller. Every fallible operation below is
# checked explicitly instead; nounset and pipefail remain enabled.
set -uo pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly RUNTIME_OWNER_SENTINEL='.package-runtime-owner-v1'
readonly DENO_RELEASE_REPOSITORY='denoland/deno'
readonly DEFAULT_YTDLP_CHANNEL='stable'
readonly ENGINE_RUNTIME_CONTRACT_VERSION='1'

LOCK_FD=''
VALIDATED_YTDLP_VERSION=''
VALIDATED_DENO_VERSION=''

error() {
    printf 'Error: %s\n' "$*" >&2
}

warning() {
    printf 'Warning: %s\n' "$*" >&2
}

validate_bounded_uint() {
    local name=$1
    local value=$2
    local minimum=$3
    local maximum=$4
    local output_variable=${5:-}
    local normalized=''
    local numeric_value=0

    if [[ ! ${value} =~ ^0*([0-9]+)$ ]]; then
        error "${name} must be an integer between ${minimum} and ${maximum}; found ${value}."
        return 1
    fi
    normalized=${BASH_REMATCH[1]}

    # All configured maxima are intentionally small. Bound digit length before
    # Bash arithmetic so a fixed-width integer overflow can never wrap into range.
    if ((${#normalized} > ${#maximum})); then
        error "${name} must be an integer between ${minimum} and ${maximum}; found ${value}."
        return 1
    fi

    numeric_value=$((10#${normalized}))
    if ((numeric_value < minimum || numeric_value > maximum)); then
        error "${name} must be an integer between ${minimum} and ${maximum}; found ${value}."
        return 1
    fi

    if [[ -n ${output_variable} ]]; then
        printf -v "${output_variable}" '%d' "${numeric_value}" || return 1
    fi
    return 0
}

ensure_private_directory() {
    local path=$1
    local owner=''

    if [[ -L ${path} || (-e ${path} && ! -d ${path}) ]]; then
        error "managed-runtime path exists but is not a safe directory: ${path}"
        return 73
    fi
    if ! mkdir -p -- "${path}"; then
        error "unable to create managed-runtime directory: ${path}"
        return 73
    fi
    if [[ -L ${path} || ! -d ${path} ]]; then
        error "managed-runtime path became unsafe: ${path}"
        return 73
    fi
    owner=$(stat -c '%u' -- "${path}" 2>/dev/null) || {
        error "unable to inspect managed-runtime directory ownership: ${path}"
        return 73
    }
    if [[ ${owner} != "${EUID}" ]]; then
        error "managed-runtime directory is not owned by the current user: ${path}"
        return 73
    fi
    if ! chmod 700 -- "${path}"; then
        error "unable to secure managed-runtime directory: ${path}"
        return 73
    fi
    return 0
}

record_runtime_data_home() {
    local data_home=$1
    local registry_root="${HOME}/.local/share/${APP_ID}"
    local managed_data_root="${data_home}/${APP_ID}"
    local marker="${registry_root}/.package-runtime-data-home-v1"
    local sentinel="${managed_data_root}/${RUNTIME_OWNER_SENTINEL}"
    local marker_temporary=''
    local sentinel_temporary=''

    # The sentinel is a non-secret ownership proof used by RPM final-removal
    # cleanup. It makes a custom marker alone insufficient to authorize deletion.
    if ! ensure_private_directory "${managed_data_root}"; then
        warning 'unable to secure managed data root; custom-XDG RPM cleanup will remain conservative.'
        return 0
    fi

    sentinel_temporary=$(
        mktemp \
            --tmpdir="${managed_data_root}" \
            '.runtime-owner.XXXXXXXX'
    ) || {
        warning 'unable to create runtime ownership sentinel.'
        return 0
    }

    if ! printf 'app=%s
uid=%s
home=%s
data=%s
' \
        "${APP_ID}" "${EUID}" "${HOME}" "${data_home}" \
        >"${sentinel_temporary}"; then
        rm -f -- "${sentinel_temporary}" || true
        warning 'unable to write runtime ownership sentinel.'
        return 0
    fi
    if ! chmod 600 -- "${sentinel_temporary}"; then
        rm -f -- "${sentinel_temporary}" || true
        warning 'unable to secure runtime ownership sentinel.'
        return 0
    fi
    if ! mv -Tf -- "${sentinel_temporary}" "${sentinel}"; then
        rm -f -- "${sentinel_temporary}" || true
        warning 'unable to publish runtime ownership sentinel.'
        return 0
    fi

    if ! ensure_private_directory "${registry_root}"; then
        warning 'unable to create runtime-location registry; RPM final-erase cleanup may not discover a custom XDG_DATA_HOME.'
        return 0
    fi

    marker_temporary=$(
        mktemp \
            --tmpdir="${registry_root}" \
            '.runtime-data-home.XXXXXXXX'
    ) || {
        warning 'unable to create runtime-location marker.'
        return 0
    }

    if ! printf '%s
' "${data_home}" >"${marker_temporary}"; then
        rm -f -- "${marker_temporary}" || true
        warning 'unable to write runtime-location marker.'
        return 0
    fi
    if ! chmod 600 -- "${marker_temporary}"; then
        rm -f -- "${marker_temporary}" || true
        warning 'unable to secure runtime-location marker.'
        return 0
    fi
    if ! mv -Tf -- "${marker_temporary}" "${marker}"; then
        rm -f -- "${marker_temporary}" || true
        warning 'unable to publish runtime-location marker.'
        return 0
    fi

    return 0
}

release_runtime_lock() {
    if [[ -n ${LOCK_FD} ]]; then
        flock --unlock "${LOCK_FD}" 2>/dev/null || true
        exec {LOCK_FD}>&- || true
        LOCK_FD=''
    fi
}

acquire_runtime_lock() {
    if [[ -n ${LOCK_FD} ]]; then
        return 0
    fi
    if [[ -L ${LOCK_FILE} || (-e ${LOCK_FILE} && ! -f ${LOCK_FILE}) ]]; then
        error 'the runtime update lock exists but is not a safe regular file.'
        return 73
    fi
    if ! exec {LOCK_FD}>>"${LOCK_FILE}"; then
        error 'unable to open the runtime update lock.'
        LOCK_FD=''
        return 73
    fi
    if ! chmod 600 -- "${LOCK_FILE}"; then
        release_runtime_lock
        error 'unable to secure the runtime update lock.'
        return 73
    fi
    if ! flock --exclusive --wait "${RUNTIME_LOCK_WAIT_SECONDS}" "${LOCK_FD}"; then
        release_runtime_lock
        return 75
    fi
    return 0
}

run_child() (
    if [[ -n ${LOCK_FD:-} ]]; then
        exec {LOCK_FD}>&- || return 1
    fi
    exec "$@"
)

run_timed_in_dir() (
    local seconds=$1
    local directory=$2
    shift 2

    if [[ -n ${LOCK_FD:-} ]]; then
        exec {LOCK_FD}>&- || return 1
    fi
    cd -- "${directory}" || return 1
    exec timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
)

run_curl() {
    run_child curl \
        --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${CURL_MAX_TIME_SECONDS}" \
        --retry 3 --retry-delay 1 \
        --retry-max-time "${CURL_RETRY_MAX_TIME_SECONDS}" \
        --no-progress-meter \
        "$@"
}

run_timed() {
    local seconds=$1
    shift
    run_child timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
}

component_path() {
    local component=$1
    local path=''

    case ${component} in
        yt-dlp) path="${YTDLP_ROOT}/current/${YTDLP_ASSET}" ;;
        deno) path="${DENO_ROOT}/current/deno" ;;
        *) return 2 ;;
    esac

    [[ -x ${path} ]] || return 1
    printf '%s\n' "${path}"
}

runtime_target_is_safe() {
    local target=${1:-}
    [[ -n ${target} && ${target} != */* && ${target} != .* &&
        ${target} != *$'\n'* && ${target} != *$'\r'* ]]
}

read_runtime_link() {
    local root=$1
    local name=$2
    local output_variable=$3
    local target=''
    local path="${root}/${name}"

    if [[ -L ${path} ]]; then
        target=$(readlink -- "${path}") || {
            error "unable to read runtime link: ${path}"
            return 1
        }
        runtime_target_is_safe "${target}" || {
            error "runtime link has an unsafe target: ${path} -> ${target}"
            return 1
        }
    elif [[ -e ${path} ]]; then
        error "runtime link path is not a symbolic link: ${path}"
        return 1
    fi
    printf -v "${output_variable}" '%s' "${target}" || return 1
    return 0
}

publish_runtime_link() {
    local root=$1
    local name=$2
    local target=$3
    local temporary_link="${root}/.${name}.$$.new"

    runtime_target_is_safe "${target}" || return 1
    [[ -d ${root}/${target} && ! -L ${root}/${target} ]] || return 1
    if [[ -e ${root}/${name} && ! -L ${root}/${name} ]]; then
        error "runtime link path is not replaceable: ${root}/${name}"
        return 1
    fi
    rm -f -- "${temporary_link}" || return 1
    ln -s -- "${target}" "${temporary_link}" || return 1
    if ! mv -Tf -- "${temporary_link}" "${root}/${name}"; then
        rm -f -- "${temporary_link}" || true
        return 1
    fi
    return 0
}

write_activation_journal() {
    local root=$1
    local old_target=$2
    local previous_target=$3
    local new_target=$4
    local journal="${root}/.activation-journal"
    local temporary="${root}/.activation-journal.$$.new"

    [[ -z ${old_target} ]] || runtime_target_is_safe "${old_target}" || return 1
    [[ -z ${previous_target} ]] || runtime_target_is_safe "${previous_target}" || return 1
    runtime_target_is_safe "${new_target}" || return 1

    [[ -n ${old_target} ]] || old_target='-'
    [[ -n ${previous_target} ]] || previous_target='-'
    if ! printf 'old=%s\nprevious=%s\nnew=%s\n' \
        "${old_target}" "${previous_target}" "${new_target}" >"${temporary}"; then
        rm -f -- "${temporary}" || true
        return 1
    fi
    chmod 600 -- "${temporary}" || {
        rm -f -- "${temporary}" || true
        return 1
    }
    mv -Tf -- "${temporary}" "${journal}"
}

recover_activation_transaction() {
    local root=$1
    local journal="${root}/.activation-journal"
    local current_target=''
    local old_target=''
    local previous_before=''
    local new_target=''
    local key=''
    local value=''
    local seen_old=false
    local seen_previous=false
    local seen_new=false

    [[ -e ${journal} || -L ${journal} ]] || {
        rm -f -- "${root}"/.current.*.new "${root}"/.previous.*.new \
            "${root}"/.activation-journal.*.new 2>/dev/null || true
        return 0
    }
    if [[ -L ${journal} || ! -f ${journal} ]]; then
        error "invalid runtime activation journal: ${journal}"
        return 1
    fi

    while IFS='=' read -r key value || [[ -n ${key}${value} ]]; do
        case ${key} in
            old)
                [[ ${seen_old} == false ]] || return 1
                old_target=${value}
                seen_old=true
                ;;
            previous)
                [[ ${seen_previous} == false ]] || return 1
                previous_before=${value}
                seen_previous=true
                ;;
            new)
                [[ ${seen_new} == false ]] || return 1
                new_target=${value}
                seen_new=true
                ;;
            *) return 1 ;;
        esac
    done <"${journal}"

    [[ ${seen_old} == true && ${seen_previous} == true && ${seen_new} == true ]] || {
        error "incomplete runtime activation journal: ${journal}"
        return 1
    }
    [[ ${old_target} != '-' ]] || old_target=''
    [[ ${previous_before} != '-' ]] || previous_before=''
    [[ -z ${old_target} ]] || runtime_target_is_safe "${old_target}" || return 1
    [[ -z ${previous_before} ]] || runtime_target_is_safe "${previous_before}" || return 1
    runtime_target_is_safe "${new_target}" || return 1

    read_runtime_link "${root}" current current_target || return 1
    if [[ ${current_target} == "${new_target}" ]]; then
        if [[ -n ${old_target} ]]; then
            publish_runtime_link "${root}" previous "${old_target}" || return 1
        else
            rm -f -- "${root}/previous" || return 1
        fi
    elif [[ ${current_target} == "${old_target}" ]]; then
        if [[ -n ${previous_before} ]]; then
            publish_runtime_link "${root}" previous "${previous_before}" || return 1
        else
            rm -f -- "${root}/previous" || return 1
        fi
    else
        error "runtime activation journal does not match current state below ${root}."
        return 1
    fi

    rm -f -- "${journal}" "${root}"/.current.*.new "${root}"/.previous.*.new \
        "${root}"/.activation-journal.*.new 2>/dev/null || return 1
    return 0
}

recover_all_activation_transactions() {
    recover_activation_transaction "${YTDLP_ROOT}" || return 1
    recover_activation_transaction "${DENO_ROOT}" || return 1
    return 0
}

activate_version() {
    local root=$1
    local version=$2
    local old_target=''
    local previous_before=''

    runtime_target_is_safe "${version}" || return 1
    [[ -d ${root}/${version} && ! -L ${root}/${version} ]] || return 1
    recover_activation_transaction "${root}" || return 1
    read_runtime_link "${root}" current old_target || return 1
    read_runtime_link "${root}" previous previous_before || return 1

    if [[ ${old_target} == "${version}" ]]; then
        return 0
    fi

    write_activation_journal \
        "${root}" "${old_target}" "${previous_before}" "${version}" || return 1

    if [[ -n ${old_target} ]]; then
        publish_runtime_link "${root}" previous "${old_target}" || return 1
    else
        rm -f -- "${root}/previous" || return 1
    fi
    publish_runtime_link "${root}" current "${version}" || return 1
    rm -f -- "${root}/.activation-journal" || return 1
    return 0
}

is_valid_ytdlp_version() {
    [[ ${1:-} =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}([.][0-9]{6})?$ ]]
}

validate_ytdlp() {
    local candidate=$1
    local help=''
    local impersonation=''
    local option
    local version_output=''

    VALIDATED_YTDLP_VERSION=''

    if [[ ! -x ${candidate} ]]; then
        error "yt-dlp runtime validation failed: candidate is not executable: ${candidate}"
        return 1
    fi

    if ! version_output=$(LC_ALL=C run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${candidate}" --version 2>&1); then
        error 'yt-dlp runtime validation failed: --version could not run.'
        printf '%s\n' "${version_output}" >&2
        return 1
    fi
    version_output=${version_output%%$'\n'*}
    if ! is_valid_ytdlp_version "${version_output}"; then
        error "yt-dlp runtime validation failed: invalid version: ${version_output}."
        return 1
    fi

    if ! help=$(LC_ALL=C run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${candidate}" --help 2>&1); then
        error 'yt-dlp runtime validation failed: --help could not run.'
        return 1
    fi

    # This is the complete option contract used by download-video.sh. Managed
    # runtimes are attested only after this profile succeeds, so the engine does
    # not need to start the same executable a second time merely to inspect it.
    for option in \
        --batch-file \
        --break-match-filters \
        --cookies \
        --cookies-from-browser \
        --dump-single-json \
        --extractor-args \
        --extractor-retries \
        --fixup \
        --fragment-retries \
        --js-runtimes \
        --list-impersonate-targets \
        --load-info-json \
        --no-clean-info-json \
        --no-overwrites \
        --no-post-overwrites \
        --no-update \
        --parse-metadata \
        --print \
        --print-to-file \
        --progress-delta \
        --progress-template \
        --retries \
        --retry-sleep \
        --skip-download \
        --socket-timeout; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?${option}([=[:space:]]|$)" \
            <<<"${help}"; then
            error "yt-dlp runtime validation failed: required option is absent: ${option}"
            return 1
        fi
    done

    if ! impersonation=$(LC_ALL=C run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${candidate}" --list-impersonate-targets 2>&1); then
        error 'yt-dlp runtime validation failed: unable to enumerate impersonation targets.'
        printf '%s\n' "${impersonation}" >&2
        return 1
    fi

    if ! grep -E \
        '^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+curl_cffi[^[:space:]]*([[:space:]]|$)' \
        <<<"${impersonation}" \
        | grep -Eiv '\((unavailable|not available)\)' >/dev/null; then
        error 'yt-dlp runtime validation failed: no usable curl_cffi impersonation target.'
        printf '%s\n' "${impersonation}" >&2
        return 1
    fi

    VALIDATED_YTDLP_VERSION=${version_output}
    return 0
}

parse_deno_version() {
    local candidate=$1
    local output_variable=$2
    local output=''
    local first_line=''
    local parsed_version=''

    [[ -x ${candidate} ]] || return 1
    output=$(LC_ALL=C run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${candidate}" --version 2>/dev/null) || return 1
    first_line=${output%%$'\n'*}

    if [[ ! ${first_line} =~ ^deno[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?)([[:space:]]|$) ]]; then
        return 1
    fi
    parsed_version=${BASH_REMATCH[1]}

    printf -v "${output_variable}" '%s' "${parsed_version}" || return 1
    return 0
}

validate_deno() {
    local candidate=$1
    local version=''
    local major=''
    local minor=''
    local supported=false

    VALIDATED_DENO_VERSION=''

    if ! parse_deno_version "${candidate}" version; then
        return 1
    fi

    if [[ ! ${version} =~ ^([0-9]+)\.([0-9]+)\.[0-9]+ ]]; then
        return 1
    fi
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}

    [[ ${major} =~ ^0*([0-9]+)$ ]] || return 1
    major=${BASH_REMATCH[1]}
    [[ ${minor} =~ ^0*([0-9]+)$ ]] || return 1
    minor=${BASH_REMATCH[1]}

    # The minimum is Deno 2.3.0. Compare normalized decimal components
    # without Bash arithmetic so arbitrarily long version components cannot
    # overflow fixed-width shell integers.
    if ((${#major} > 1)); then
        supported=true
    else
        case ${major} in
            [3-9])
                supported=true
                ;;
            2)
                if ((${#minor} > 1)); then
                    supported=true
                else
                    case ${minor} in
                        [3-9]) supported=true ;;
                        *) ;;
                    esac
                fi
                ;;
            *) ;;
        esac
    fi

    [[ ${supported} == true ]] || return 1
    VALIDATED_DENO_VERSION=${version}
    return 0
}

install_ytdlp_candidate() {
    local candidate=$1
    local expected_version=$2
    local version=''
    local version_dir=''
    local staged=''

    validate_ytdlp "${candidate}" || return 1
    version=${VALIDATED_YTDLP_VERSION}
    if [[ ${version} != "${expected_version}" ]]; then
        error "yt-dlp candidate version ${version} does not match resolved release ${expected_version}."
        return 1
    fi
    [[ ${version} =~ ${YTDLP_CHANNEL_VERSION_PATTERN} ]] || {
        error "yt-dlp candidate version does not match selected ${YTDLP_CHANNEL} channel: ${version}"
        return 1
    }

    version_dir="${YTDLP_ROOT}/${version}"
    if [[ -L ${version_dir} || (-e ${version_dir} && ! -d ${version_dir}) ]]; then
        error "unsafe yt-dlp version directory: ${version_dir}"
        return 1
    fi
    mkdir -p -- "${version_dir}" || return 1
    chmod 700 -- "${version_dir}" || return 1
    staged="${version_dir}/.${YTDLP_ASSET}.$$.new"
    install -m 0755 -- "${candidate}" "${staged}" || return 1
    validate_ytdlp "${staged}" || {
        rm -f -- "${staged}" || true
        return 1
    }
    mv -Tf -- "${staged}" "${version_dir}/${YTDLP_ASSET}" || {
        rm -f -- "${staged}" || true
        return 1
    }
    validate_ytdlp "${version_dir}/${YTDLP_ASSET}" || return 1
    activate_version "${YTDLP_ROOT}" "${version}"
}

install_deno_candidate() {
    local candidate=$1
    local version=''
    local version_dir=''
    local staged=''

    validate_deno "${candidate}" || return 1
    version=${VALIDATED_DENO_VERSION}

    version_dir="${DENO_ROOT}/${version}"
    if [[ -L ${version_dir} || (-e ${version_dir} && ! -d ${version_dir}) ]]; then
        error "unsafe Deno version directory: ${version_dir}"
        return 1
    fi
    mkdir -p -- "${version_dir}" || return 1
    chmod 700 -- "${version_dir}" || return 1
    staged="${version_dir}/.deno.$$.new"
    install -m 0755 -- "${candidate}" "${staged}" || return 1
    validate_deno "${staged}" || {
        rm -f -- "${staged}" || true
        return 1
    }
    mv -Tf -- "${staged}" "${version_dir}/deno" || {
        rm -f -- "${staged}" || true
        return 1
    }
    validate_deno "${version_dir}/deno" || return 1
    activate_version "${DENO_ROOT}" "${version}"
}

latest_ytdlp_version() {
    local output_variable=$1
    local effective_url=''
    local resolved_version=''

    if ! effective_url=$(run_curl --silent --show-error \
        --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/${YTDLP_RELEASE_REPOSITORY}/releases/latest"); then
        return 1
    fi
    resolved_version=${effective_url##*/}
    [[ ${resolved_version} =~ ${YTDLP_CHANNEL_VERSION_PATTERN} ]] || return 1
    printf -v "${output_variable}" '%s' "${resolved_version}" || return 1
    return 0
}

latest_deno_version() {
    local output_variable=$1
    local effective_url=''
    local tag=''
    local resolved_version=''

    if ! effective_url=$(run_curl --silent --show-error \
        --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/${DENO_RELEASE_REPOSITORY}/releases/latest"); then
        return 1
    fi
    tag=${effective_url##*/}
    [[ ${tag} =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || return 1
    resolved_version=${BASH_REMATCH[1]}
    printf -v "${output_variable}" '%s' "${resolved_version}" || return 1
    return 0
}

cleanup_ytdlp_bootstrap_work() {
    local work=$1
    local gpg_home=$2

    if [[ -n ${gpg_home} ]]; then
        if [[ -d ${gpg_home} && ! -L ${gpg_home} ]]; then
            run_timed 5 gpgconf --homedir "${gpg_home}" --kill gpg-agent \
                >/dev/null 2>&1 || true
        fi
        rm -rf -- "${gpg_home}" || true
    fi
    if [[ -n ${work} ]]; then
        rm -rf -- "${work}" || true
    fi
}

bootstrap_ytdlp_version() {
    local version=$1
    local work=''
    local gpg_home=''
    local sums_line=''
    local gpg_output=''
    local base_url=''

    [[ ${version} =~ ${YTDLP_CHANNEL_VERSION_PATTERN} ]] || return 1
    base_url="https://github.com/${YTDLP_RELEASE_REPOSITORY}/releases/download/${version}"
    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.yt-dlp-bootstrap.XXXXXXXX') || return 1
    gpg_home=$(mktemp -d --tmpdir=/tmp '.yt-dlp-gpg.XXXXXXXX') || {
        rm -rf -- "${work}" || true
        return 1
    }
    if ! chmod 700 -- "${gpg_home}"; then
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi

    if ! run_curl -o "${work}/${YTDLP_ASSET}" "${base_url}/${YTDLP_ASSET}" \
        || ! run_curl -o "${work}/SHA2-256SUMS" "${base_url}/SHA2-256SUMS" \
        || ! run_curl -o "${work}/SHA2-256SUMS.sig" "${base_url}/SHA2-256SUMS.sig"; then
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi

    if ! gpg_output=$(run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" \
        gpg --batch --homedir "${gpg_home}" --import "${YTDLP_PUBLIC_KEY}" 2>&1); then
        error 'yt-dlp bootstrap failed: unable to import the signing key.'
        printf '%s\n' "${gpg_output}" >&2
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi
    if ! gpg_output=$(run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" \
        gpg --batch --homedir "${gpg_home}" \
        --verify "${work}/SHA2-256SUMS.sig" "${work}/SHA2-256SUMS" 2>&1); then
        error 'yt-dlp bootstrap failed: SHA-256 manifest signature verification failed.'
        printf '%s\n' "${gpg_output}" >&2
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi

    sums_line=$(grep -E \
        "^[[:xdigit:]]{64}[[:space:]]+\\*?${YTDLP_ASSET}$" \
        "${work}/SHA2-256SUMS" || true)
    if [[ -z ${sums_line} ]]; then
        error "yt-dlp bootstrap failed: SHA-256 manifest has no entry for ${YTDLP_ASSET}."
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi
    if ! printf '%s\n' "${sums_line}" >"${work}/CHECKSUM"; then
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi
    if ! run_timed_in_dir "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${work}" \
        sha256sum --check CHECKSUM; then
        error "yt-dlp bootstrap failed: SHA-256 verification failed for ${YTDLP_ASSET}."
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi

    if ! chmod 0755 -- "${work}/${YTDLP_ASSET}"; then
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi
    if ! install_ytdlp_candidate "${work}/${YTDLP_ASSET}" "${version}"; then
        error 'yt-dlp bootstrap failed: downloaded runtime failed validation or activation.'
        cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
        return 1
    fi
    cleanup_ytdlp_bootstrap_work "${work}" "${gpg_home}"
    return 0
}

bootstrap_ytdlp() {
    local latest_version=''
    latest_ytdlp_version latest_version || return 1
    bootstrap_ytdlp_version "${latest_version}"
}

bootstrap_deno_version() {
    local version=$1
    local work=''
    local checksum_file=''
    local checksum_line=''
    local base_url=''

    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    base_url="https://github.com/${DENO_RELEASE_REPOSITORY}/releases/download/v${version}"
    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.deno-bootstrap.XXXXXXXX') || return 1
    checksum_file="${DENO_ASSET}.sha256sum"

    if ! run_curl -o "${work}/${DENO_ASSET}" "${base_url}/${DENO_ASSET}" \
        || ! run_curl -o "${work}/${checksum_file}" "${base_url}/${checksum_file}"; then
        rm -rf -- "${work}" || true
        return 1
    fi
    checksum_line=$(grep -E \
        "^[[:xdigit:]]{64}[[:space:]]+\\*?${DENO_ASSET}$" \
        "${work}/${checksum_file}" || true)
    if [[ -z ${checksum_line} ]]; then
        error 'Deno bootstrap failed: release checksum entry is missing or malformed.'
        rm -rf -- "${work}" || true
        return 1
    fi
    printf '%s\n' "${checksum_line}" >"${work}/CHECKSUM" || {
        rm -rf -- "${work}" || true
        return 1
    }
    if ! run_timed_in_dir "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${work}" \
        sha256sum --check CHECKSUM >/dev/null \
        || ! run_timed_in_dir "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" "${work}" \
            unzip -q -- "${DENO_ASSET}" deno; then
        error 'Deno bootstrap failed: checksum verification or extraction failed.'
        rm -rf -- "${work}" || true
        return 1
    fi
    chmod 0755 -- "${work}/deno" || {
        rm -rf -- "${work}" || true
        return 1
    }
    if ! install_deno_candidate "${work}/deno"; then
        error 'Deno bootstrap failed: downloaded runtime failed validation or activation.'
        rm -rf -- "${work}" || true
        return 1
    fi
    rm -rf -- "${work}" || return 1
    return 0
}

bootstrap_deno() {
    local latest_version=''
    latest_deno_version latest_version || return 1
    bootstrap_deno_version "${latest_version}"
}

update_ytdlp() {
    local current=''
    local current_version=''
    local latest_version=''

    current=$(component_path yt-dlp) || return 1
    current_version=$(LC_ALL=C run_timed "${RUNTIME_VALIDATE_TIMEOUT_SECONDS}" \
        "${current}" --version 2>/dev/null) || return 1
    current_version=${current_version%%$'\n'*}
    is_valid_ytdlp_version "${current_version}" || return 1
    latest_ytdlp_version latest_version || return 1
    [[ ${current_version} != "${latest_version}" ]] || return 0
    bootstrap_ytdlp_version "${latest_version}"
}

update_deno() {
    local current=''
    local current_version=''
    local latest_version=''

    current=$(component_path deno) || return 1
    parse_deno_version "${current}" current_version || return 1
    latest_deno_version latest_version || return 1
    [[ ${current_version} != "${latest_version}" ]] || return 0
    bootstrap_deno_version "${latest_version}"
}

ensure_runtime() {
    if ! component_path yt-dlp >/dev/null 2>&1; then
        printf 'Installing the current yt-dlp %s runtime...\n' "${YTDLP_CHANNEL}" >&2
        bootstrap_ytdlp || {
            error 'unable to install the initial yt-dlp runtime.'
            return 1
        }
    fi
    if ! component_path deno >/dev/null 2>&1; then
        printf 'Installing the current Deno stable runtime...\n' >&2
        bootstrap_deno || {
            error 'unable to install the initial Deno runtime.'
            return 1
        }
    fi
    return 0
}

validate_active_runtimes() {
    local active_ytdlp=''
    local active_deno=''

    active_ytdlp=$(component_path yt-dlp) || return 1
    active_deno=$(component_path deno) || return 1
    validate_ytdlp "${active_ytdlp}" || return 1
    validate_deno "${active_deno}" || return 1
    return 0
}

require_runtime() {
    if ! validate_active_runtimes; then
        error 'verified managed yt-dlp and Deno runtimes are required but are missing or invalid.'
        return 69
    fi
    return 0
}

rollback_component() {
    local component=$1
    local root=''
    local asset=''
    local previous_target=''
    local previous_path=''

    case ${component} in
        yt-dlp)
            root=${YTDLP_ROOT}
            asset=${YTDLP_ASSET}
            ;;
        deno)
            root=${DENO_ROOT}
            asset='deno'
            ;;
        *)
            error "unknown runtime component for rollback: ${component}"
            return 2
            ;;
    esac

    [[ -L ${root}/previous ]] || {
        error "no previous ${component} runtime is available."
        return 1
    }
    previous_target=$(readlink -- "${root}/previous") || return 1
    runtime_target_is_safe "${previous_target}" || {
        error "invalid previous ${component} runtime target."
        return 1
    }
    previous_path="${root}/${previous_target}/${asset}"
    [[ -x ${previous_path} ]] || {
        error "previous ${component} runtime is missing or not executable."
        return 1
    }

    case ${component} in
        yt-dlp) validate_ytdlp "${previous_path}" || return 1 ;;
        deno) validate_deno "${previous_path}" || return 1 ;;
        *) return 2 ;;
    esac

    activate_version "${root}" "${previous_target}" || return 1
    printf 'Rolled back %s to %s.\n' "${component}" "${previous_target}" >&2
    return 0
}

recover_invalid_active_runtime() {
    local component=$1
    local active=''

    if active=$(component_path "${component}"); then
        case ${component} in
            yt-dlp) validate_ytdlp "${active}" && return 0 ;;
            deno) validate_deno "${active}" && return 0 ;;
            *) return 2 ;;
        esac
    fi

    warning "the active ${component} runtime is invalid; attempting rollback."
    rollback_component "${component}" || return 1
    return 0
}

recover_invalid_active_runtimes() {
    recover_invalid_active_runtime yt-dlp || {
        error 'the active yt-dlp runtime is invalid and rollback failed.'
        return 1
    }
    recover_invalid_active_runtime deno || {
        error 'the active Deno runtime is invalid and rollback failed.'
        return 1
    }
}

acquire_runtime_lock_or_use_active() {
    local output_variable=$1
    local acquisition_error=$2
    local lock_status=0

    printf -v "${output_variable}" '%s' false
    if acquire_runtime_lock; then
        printf -v "${output_variable}" '%s' true
        return 0
    else
        lock_status=$?
    fi

    if ((lock_status == 75)) && validate_active_runtimes; then
        warning 'another runtime update is in progress; using the active verified runtimes.'
        return 0
    fi
    if ((lock_status == 75)); then
        error 'runtime update lock timed out and no valid active runtimes are available.'
    else
        error "${acquisition_error}"
    fi
    return "${lock_status}"
}

update_runtime() {
    local lock_acquired=false

    acquire_runtime_lock_or_use_active lock_acquired \
        'unable to acquire the runtime update lock safely.' || return $?
    [[ ${lock_acquired} == true ]] || return 0

    recover_all_activation_transactions || {
        error 'unable to recover an interrupted runtime activation.'
        return 1
    }
    ensure_runtime || return 1

    if ! update_ytdlp; then
        warning 'yt-dlp update check failed; keeping the last verified runtime.'
    fi
    if ! update_deno; then
        warning 'Deno update check failed; keeping the last verified runtime.'
    fi

    recover_invalid_active_runtimes
}

ensure_runtime_locked() {
    local lock_acquired=false

    acquire_runtime_lock_or_use_active lock_acquired \
        'unable to acquire the runtime update lock.' || return $?
    [[ ${lock_acquired} == true ]] || return 0

    recover_all_activation_transactions || return 1
    ensure_runtime || return 1

    recover_invalid_active_runtimes
}

rollback_runtime_locked() {
    local component=$1
    local lock_status=0
    if acquire_runtime_lock; then
        lock_status=0
    else
        lock_status=$?
        error 'unable to acquire the runtime update lock.'
        return "${lock_status}"
    fi
    recover_all_activation_transactions || return 1
    rollback_component "${component}"
}

initialize_runtime_layout() {
    local output_variable=$1
    local data_home=''

    if [[ -z ${HOME:-} || ${HOME} != /* || ${HOME} == / ||
        ${HOME} == *$'\n'* || ${HOME} == *$'\r'* ]]; then
        error 'HOME must be a safe absolute non-root path.'
        return 64
    fi

    data_home=${XDG_DATA_HOME:-${HOME}/.local/share}
    if [[ ${data_home} != /* || ${data_home} == / ||
        ${data_home} == *$'\n'* || ${data_home} == *$'\r'* ]]; then
        data_home="${HOME}/.local/share"
    fi
    readonly RUNTIME_ROOT="${data_home}/${APP_ID}/runtime"
    readonly YTDLP_ROOT="${RUNTIME_ROOT}/yt-dlp"
    readonly DENO_ROOT="${RUNTIME_ROOT}/deno"
    readonly LOCK_FILE="${RUNTIME_ROOT}/update.lock"
    printf -v "${output_variable}" '%s' "${data_home}"
}

initialize_runtime_policy() {
    local setting=''
    local setting_name=''
    local setting_value=''
    local setting_min=''
    local setting_max=''

    YTDLP_CHANNEL=${YTDLP_ARIA2_YTDLP_CHANNEL:-${DEFAULT_YTDLP_CHANNEL}}
    case ${YTDLP_CHANNEL} in
        stable)
            YTDLP_RELEASE_REPOSITORY='yt-dlp/yt-dlp'
            YTDLP_CHANNEL_VERSION_PATTERN='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$'
            ;;
        nightly)
            YTDLP_RELEASE_REPOSITORY='yt-dlp/yt-dlp-nightly-builds'
            YTDLP_CHANNEL_VERSION_PATTERN='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$'
            ;;
        *)
            error "unsupported yt-dlp channel: ${YTDLP_CHANNEL}; expected stable or nightly."
            return 64
            ;;
    esac
    readonly YTDLP_CHANNEL YTDLP_RELEASE_REPOSITORY YTDLP_CHANNEL_VERSION_PATTERN

    RUNTIME_LOCK_WAIT_SECONDS=${YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS:-15}
    CURL_CONNECT_TIMEOUT_SECONDS=${YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS:-15}
    CURL_MAX_TIME_SECONDS=${YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS:-180}
    CURL_RETRY_MAX_TIME_SECONDS=${YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS:-300}
    RUNTIME_VALIDATE_TIMEOUT_SECONDS=${YTDLP_ARIA2_RUNTIME_VALIDATE_TIMEOUT_SECONDS:-30}
    for setting in \
        "RUNTIME_LOCK_WAIT_SECONDS:${RUNTIME_LOCK_WAIT_SECONDS}:1:300" \
        "CURL_CONNECT_TIMEOUT_SECONDS:${CURL_CONNECT_TIMEOUT_SECONDS}:1:300" \
        "CURL_MAX_TIME_SECONDS:${CURL_MAX_TIME_SECONDS}:10:1800" \
        "CURL_RETRY_MAX_TIME_SECONDS:${CURL_RETRY_MAX_TIME_SECONDS}:10:3600" \
        "RUNTIME_VALIDATE_TIMEOUT_SECONDS:${RUNTIME_VALIDATE_TIMEOUT_SECONDS}:5:120"; do
        IFS=: read -r setting_name setting_value setting_min setting_max <<<"${setting}"
        validate_bounded_uint "${setting_name}" "${setting_value}" \
            "${setting_min}" "${setting_max}" "${setting_name}" || return 64
    done
    readonly RUNTIME_LOCK_WAIT_SECONDS CURL_CONNECT_TIMEOUT_SECONDS
    readonly CURL_MAX_TIME_SECONDS CURL_RETRY_MAX_TIME_SECONDS
    readonly RUNTIME_VALIDATE_TIMEOUT_SECONDS
}

initialize_runtime_platform() {
    local script_path=''
    local machine_arch=''
    local command_name=''

    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
        error 'unable to resolve runtime manager path.'
        return 66
    }
    readonly SCRIPT_DIR=${script_path%/*}

    if [[ -f ${SCRIPT_DIR}/keys/yt-dlp-public.key ]]; then
        YTDLP_PUBLIC_KEY=${SCRIPT_DIR}/keys/yt-dlp-public.key
    elif [[ -f ${SCRIPT_DIR}/packaging/keys/yt-dlp-public.key ]]; then
        YTDLP_PUBLIC_KEY=${SCRIPT_DIR}/packaging/keys/yt-dlp-public.key
    else
        error 'yt-dlp signing key is missing.'
        return 66
    fi
    readonly YTDLP_PUBLIC_KEY

    machine_arch=$(uname -m)
    case ${machine_arch} in
        x86_64)
            readonly YTDLP_ASSET='yt-dlp_linux'
            readonly DENO_TARGET='x86_64-unknown-linux-gnu'
            ;;
        aarch64)
            readonly YTDLP_ASSET='yt-dlp_linux_aarch64'
            readonly DENO_TARGET='aarch64-unknown-linux-gnu'
            ;;
        *)
            error "unsupported architecture: ${machine_arch}"
            return 69
            ;;
    esac
    readonly DENO_ASSET="deno-${DENO_TARGET}.zip"

    for command_name in \
        bash curl flock gpg gpgconf grep install ln mkdir mktemp mv readlink realpath rm \
        sha256sum stat timeout uname unzip; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            error "required runtime-manager command is absent: ${command_name}"
            return 127
        }
    done
}

prepare_runtime_storage() {
    local data_home=$1

    ensure_private_directory "${RUNTIME_ROOT}" || return $?
    ensure_private_directory "${YTDLP_ROOT}" || return $?
    ensure_private_directory "${DENO_ROOT}" || return $?
    record_runtime_data_home "${data_home}"
    trap release_runtime_lock EXIT
}

print_runtime_versions() {
    require_runtime || return $?
    printf 'yt-dlp %s (%s)\n' "${VALIDATED_YTDLP_VERSION}" "${YTDLP_CHANNEL}"
    printf 'Deno %s\n' "${VALIDATED_DENO_VERSION}"
}

# Prepare both managed runtimes and emit the exact validation result consumed
# by download-video.sh. Values are line-safe because runtime layout validation
# rejects line breaks before any managed path is constructed.
print_engine_runtime_attestation() {
    local action=$1
    local ytdlp=''
    local deno=''

    case ${action} in
        require)
            require_runtime || return $?
            ;;
        update)
            update_runtime || return $?
            ;;
        *)
            error 'prepare requires an action: update or require.'
            return 2
            ;;
    esac

    ytdlp=$(component_path yt-dlp) || return 69
    deno=$(component_path deno) || return 69
    if [[ -z ${VALIDATED_YTDLP_VERSION} || -z ${VALIDATED_DENO_VERSION} ]]; then
        error 'managed runtime validation did not produce a complete engine attestation.'
        return 69
    fi

    printf 'runtime-contract=%s\n' "${ENGINE_RUNTIME_CONTRACT_VERSION}"
    printf 'yt-dlp-path=%s\n' "${ytdlp}"
    printf 'yt-dlp-version=%s\n' "${VALIDATED_YTDLP_VERSION}"
    printf 'deno-path=%s\n' "${deno}"
    printf 'deno-version=%s\n' "${VALIDATED_DENO_VERSION}"
}

dispatch_runtime_command() {
    local command=${1:-}

    case ${command} in
        require)
            require_runtime
            ;;
        ensure)
            ensure_runtime_locked
            ;;
        update)
            update_runtime
            ;;
        prepare)
            (($# == 2)) || {
                error 'prepare requires exactly one action: update or require.'
                exit 2
            }
            print_engine_runtime_attestation "$2"
            ;;
        path)
            (($# == 2)) || {
                error 'path requires exactly one component: yt-dlp or deno.'
                exit 2
            }
            case $2 in
                yt-dlp | deno)
                    component_path "$2"
                    ;;
                *)
                    error "unknown runtime component for path: $2"
                    exit 2
                    ;;
            esac
            ;;
        rollback)
            rollback_runtime_locked "${2:-}"
            ;;
        versions)
            print_runtime_versions
            ;;
        *)
            printf 'Usage: %s {require|ensure|update|prepare update|prepare require|path yt-dlp|path deno|rollback yt-dlp|rollback deno|versions}\n' \
                "${0##*/}" >&2
            exit 2
            ;;
    esac
}

main() {
    local runtime_data_home=''

    initialize_runtime_layout runtime_data_home || exit $?
    initialize_runtime_policy || exit $?
    initialize_runtime_platform || exit $?
    prepare_runtime_storage "${runtime_data_home}" || exit $?
    dispatch_runtime_command "$@"
}

main "$@"

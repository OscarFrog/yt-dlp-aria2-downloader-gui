#!/usr/bin/env bash
# Predicates in this script are intentionally called from if/!/&&/|| contexts.
# Do not use errexit here: Bash suppresses -e inside functions used as predicates,
# which makes behavior depend on the caller. Every fallible operation below is
# checked explicitly instead; nounset and pipefail remain enabled.
set -uo pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly DENO_CHANNEL='stable'
readonly DEFAULT_YTDLP_CHANNEL='stable'

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

    if [[ ! ${value} =~ ^[0-9]+$ ]] ||
        ((10#${value} < minimum || 10#${value} > maximum)); then
        error "${name} must be an integer between ${minimum} and ${maximum}; found ${value}."
        return 1
    fi
    return 0
}

if [[ -z ${HOME:-} || ${HOME} != /* ]]; then
    error 'HOME must be an absolute path.'
    exit 64
fi

data_home=${XDG_DATA_HOME:-${HOME}/.local/share}
if [[ ${data_home} != /* ]]; then
    data_home="${HOME}/.local/share"
fi
readonly RUNTIME_ROOT="${data_home}/${APP_ID}/runtime"
readonly YTDLP_ROOT="${RUNTIME_ROOT}/yt-dlp"
readonly DENO_ROOT="${RUNTIME_ROOT}/deno"
readonly LOCK_FILE="${RUNTIME_ROOT}/update.lock"

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
    exit 64
    ;;
esac
readonly YTDLP_CHANNEL YTDLP_RELEASE_REPOSITORY YTDLP_CHANNEL_VERSION_PATTERN

RUNTIME_LOCK_WAIT_SECONDS=${YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS:-15}
CURL_CONNECT_TIMEOUT_SECONDS=${YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS:-15}
CURL_MAX_TIME_SECONDS=${YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS:-180}
CURL_RETRY_MAX_TIME_SECONDS=${YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS:-300}
DENO_CHECK_TIMEOUT_SECONDS=${YTDLP_ARIA2_DENO_CHECK_TIMEOUT_SECONDS:-90}
DENO_UPDATE_TIMEOUT_SECONDS=${YTDLP_ARIA2_DENO_UPDATE_TIMEOUT_SECONDS:-240}
for setting in \
    "RUNTIME_LOCK_WAIT_SECONDS:${RUNTIME_LOCK_WAIT_SECONDS}:1:300" \
    "CURL_CONNECT_TIMEOUT_SECONDS:${CURL_CONNECT_TIMEOUT_SECONDS}:1:300" \
    "CURL_MAX_TIME_SECONDS:${CURL_MAX_TIME_SECONDS}:10:1800" \
    "CURL_RETRY_MAX_TIME_SECONDS:${CURL_RETRY_MAX_TIME_SECONDS}:10:3600" \
    "DENO_CHECK_TIMEOUT_SECONDS:${DENO_CHECK_TIMEOUT_SECONDS}:5:900" \
    "DENO_UPDATE_TIMEOUT_SECONDS:${DENO_UPDATE_TIMEOUT_SECONDS}:10:1800"; do
    IFS=: read -r setting_name setting_value setting_min setting_max <<<"${setting}"
    validate_bounded_uint "${setting_name}" "${setting_value}" \
        "${setting_min}" "${setting_max}" || exit 64
done
readonly RUNTIME_LOCK_WAIT_SECONDS CURL_CONNECT_TIMEOUT_SECONDS
readonly CURL_MAX_TIME_SECONDS CURL_RETRY_MAX_TIME_SECONDS
readonly DENO_CHECK_TIMEOUT_SECONDS DENO_UPDATE_TIMEOUT_SECONDS

script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
    error 'unable to resolve runtime manager path.'
    exit 66
}
readonly SCRIPT_DIR=${script_path%/*}

if [[ -f ${SCRIPT_DIR}/keys/yt-dlp-public.key ]]; then
    YTDLP_PUBLIC_KEY=${SCRIPT_DIR}/keys/yt-dlp-public.key
elif [[ -f ${SCRIPT_DIR}/packaging/keys/yt-dlp-public.key ]]; then
    YTDLP_PUBLIC_KEY=${SCRIPT_DIR}/packaging/keys/yt-dlp-public.key
else
    error 'yt-dlp signing key is missing.'
    exit 66
fi
readonly YTDLP_PUBLIC_KEY

machine_arch=$(uname -m)
readonly machine_arch
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
    exit 69
    ;;
esac
readonly DENO_ASSET="deno-${DENO_TARGET}.zip"

for command_name in \
    bash curl flock gpg grep install ln mkdir mktemp mv readlink realpath rm \
    sha256sum timeout uname unzip; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        error "required runtime-manager command is absent: ${command_name}"
        exit 127
    }
done

if ! mkdir -p -- "${YTDLP_ROOT}" "${DENO_ROOT}"; then
    error 'unable to create the managed-runtime directories.'
    exit 73
fi
if ! chmod 700 -- "${RUNTIME_ROOT}" "${YTDLP_ROOT}" "${DENO_ROOT}"; then
    error 'unable to secure the managed-runtime directories.'
    exit 73
fi

LOCK_FD=''
release_runtime_lock() {
    if [[ -n ${LOCK_FD} ]]; then
        flock --unlock "${LOCK_FD}" 2>/dev/null || true
        exec {LOCK_FD}>&- || true
        LOCK_FD=''
    fi
}
trap release_runtime_lock EXIT

acquire_runtime_lock() {
    if [[ -n ${LOCK_FD} ]]; then
        return 0
    fi
    if ! exec {LOCK_FD}>>"${LOCK_FILE}"; then
        error 'unable to open the runtime update lock.'
        LOCK_FD=''
        return 1
    fi
    chmod 600 -- "${LOCK_FILE}" || {
        release_runtime_lock
        return 1
    }
    if ! flock --exclusive --wait "${RUNTIME_LOCK_WAIT_SECONDS}" "${LOCK_FD}"; then
        release_runtime_lock
        return 75
    fi
    return 0
}

run_child() (
    if [[ -n ${LOCK_FD:-} ]]; then
        exec {LOCK_FD}>&-
    fi
    exec "$@"
)

run_curl() {
    run_child curl \
        --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${CURL_MAX_TIME_SECONDS}" \
        --retry 3 --retry-delay 1 \
        --retry-max-time "${CURL_RETRY_MAX_TIME_SECONDS}" \
        "$@"
}

run_timed() {
    local seconds=$1
    shift
    run_child timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
}

run_in_dir() (
    local directory=$1
    shift

    if [[ -n ${LOCK_FD:-} ]]; then
        exec {LOCK_FD}>&- || return 1
    fi
    cd -- "${directory}" || return 1
    exec "$@"
)

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

activate_version() {
    local root=$1
    local version=$2
    local old_target=''
    local temporary_link="${root}/.current.$$.new"
    local previous_link="${root}/.previous.$$.new"
    local publish_previous=false

    if [[ -L ${root}/current ]]; then
        old_target=$(readlink -- "${root}/current") || return 1
        if [[ ${old_target} == */* || ${old_target} == .* ]]; then
            error "invalid active runtime link below ${root}."
            return 1
        fi
    fi

    rm -f -- "${temporary_link}" "${previous_link}" || return 1
    if [[ -n ${old_target} && ${old_target} != "${version}" &&
        -d ${root}/${old_target} ]]; then
        ln -s -- "${old_target}" "${previous_link}" || return 1
        publish_previous=true
    fi
    ln -s -- "${version}" "${temporary_link}" || {
        rm -f -- "${previous_link}" || true
        return 1
    }

    # Publish the previous pointer before switching current. If the final
    # current rename fails, both current and previous still refer to a verified
    # old runtime; the active runtime is never left half-published.
    if [[ ${publish_previous} == true ]] &&
        ! mv -Tf -- "${previous_link}" "${root}/previous"; then
        rm -f -- "${temporary_link}" "${previous_link}" || true
        return 1
    fi
    if ! mv -Tf -- "${temporary_link}" "${root}/current"; then
        rm -f -- "${temporary_link}" || true
        return 1
    fi

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

    if [[ ! -x ${candidate} ]]; then
        error "yt-dlp runtime validation failed: candidate is not executable: ${candidate}"
        return 1
    fi

    if ! version_output=$(LC_ALL=C run_child "${candidate}" --version 2>&1); then
        error 'yt-dlp runtime validation failed: --version could not run.'
        printf '%s\n' "${version_output}" >&2
        return 1
    fi
    version_output=${version_output%%$'\n'*}
    if ! is_valid_ytdlp_version "${version_output}"; then
        error "yt-dlp runtime validation failed: invalid version: ${version_output}."
        return 1
    fi

    if ! help=$(LC_ALL=C run_child "${candidate}" --help 2>&1); then
        error 'yt-dlp runtime validation failed: --help could not run.'
        return 1
    fi

    for option in \
        --break-match-filters \
        --js-runtimes \
        --list-impersonate-targets \
        --no-update; do
        if ! grep -Fq -- "${option}" <<<"${help}"; then
            error "yt-dlp runtime validation failed: required option is absent: ${option}"
            return 1
        fi
    done

    if ! impersonation=$(LC_ALL=C run_child "${candidate}" --list-impersonate-targets 2>&1); then
        error 'yt-dlp runtime validation failed: unable to enumerate impersonation targets.'
        printf '%s\n' "${impersonation}" >&2
        return 1
    fi

    if ! grep -E \
        '^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+curl_cffi[^[:space:]]*([[:space:]]|$)' \
        <<<"${impersonation}" |
        grep -Eiv '\((unavailable|not available)\)' >/dev/null; then
        error 'yt-dlp runtime validation failed: no usable curl_cffi impersonation target.'
        printf '%s\n' "${impersonation}" >&2
        return 1
    fi

    return 0
}

parse_deno_version() {
    local candidate=$1
    local output_variable=$2
    local output=''
    local first_line=''
    local parsed_version=''

    [[ -x ${candidate} ]] || return 1
    output=$(LC_ALL=C run_child "${candidate}" --version 2>/dev/null) || return 1
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
    local major=0
    local minor=0
    local patch=0

    if ! parse_deno_version "${candidate}" version; then
        return 1
    fi

    if [[ ! ${version} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        return 1
    fi
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}

    if ((10#${major} > 2 ||
        (10#${major} == 2 && 10#${minor} > 3) ||
        (10#${major} == 2 && 10#${minor} == 3 && 10#${patch} >= 0))); then
        return 0
    fi

    return 1
}

install_ytdlp_candidate() {
    local candidate=$1
    local version=''
    local version_dir=''

    if ! validate_ytdlp "${candidate}"; then
        return 1
    fi

    version=$(LC_ALL=C run_child "${candidate}" --version) || return 1
    version=${version%%$'\n'*}
    is_valid_ytdlp_version "${version}" || return 1

    version_dir="${YTDLP_ROOT}/${version}"
    if [[ ! -x ${version_dir}/${YTDLP_ASSET} ]]; then
        mkdir -p -- "${version_dir}" || return 1
        install -m 0755 -- "${candidate}" "${version_dir}/${YTDLP_ASSET}" || return 1
    fi

    activate_version "${YTDLP_ROOT}" "${version}"
}

install_deno_candidate() {
    local candidate=$1
    local version=''
    local version_dir=''

    if ! validate_deno "${candidate}"; then
        return 1
    fi
    if ! parse_deno_version "${candidate}" version; then
        return 1
    fi

    version_dir="${DENO_ROOT}/${version}"
    if [[ ! -x ${version_dir}/deno ]]; then
        mkdir -p -- "${version_dir}" || return 1
        install -m 0755 -- "${candidate}" "${version_dir}/deno" || return 1
    fi

    activate_version "${DENO_ROOT}" "${version}"
}

bootstrap_ytdlp() {
    local work=''
    local gpg_home=''
    local sums_line=''
    local gpg_output=''
    local base_url="https://github.com/${YTDLP_RELEASE_REPOSITORY}/releases/latest/download"

    work=$(mktemp -d --tmpdir=/tmp '.yt-dlp-bootstrap.XXXXXXXX') || return 1
    gpg_home="${work}/gnupg"
    if ! mkdir -m 700 -- "${gpg_home}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! run_curl -o "${work}/${YTDLP_ASSET}" "${base_url}/${YTDLP_ASSET}" ||
       ! run_curl -o "${work}/SHA2-256SUMS" "${base_url}/SHA2-256SUMS" ||
       ! run_curl -o "${work}/SHA2-256SUMS.sig" "${base_url}/SHA2-256SUMS.sig"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! gpg_output=$(run_child gpg --batch --homedir "${gpg_home}" \
        --import "${YTDLP_PUBLIC_KEY}" 2>&1); then
        error 'yt-dlp bootstrap failed: unable to import the signing key.'
        printf '%s\n' "${gpg_output}" >&2
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! gpg_output=$(run_child gpg --batch --homedir "${gpg_home}" \
        --verify "${work}/SHA2-256SUMS.sig" "${work}/SHA2-256SUMS" 2>&1); then
        error 'yt-dlp bootstrap failed: SHA-256 manifest signature verification failed.'
        printf '%s\n' "${gpg_output}" >&2
        rm -rf -- "${work}" || true
        return 1
    fi

    sums_line=$(grep -E \
        "^[[:xdigit:]]{64}[[:space:]]+\\*?${YTDLP_ASSET}$" \
        "${work}/SHA2-256SUMS" || true)
    if [[ -z ${sums_line} ]]; then
        error "yt-dlp bootstrap failed: SHA-256 manifest has no entry for ${YTDLP_ASSET}."
        rm -rf -- "${work}" || true
        return 1
    fi

    printf '%s\n' "${sums_line}" >"${work}/CHECKSUM" || {
        rm -rf -- "${work}" || true
        return 1
    }
    if ! run_in_dir "${work}" sha256sum --check CHECKSUM; then
        error "yt-dlp bootstrap failed: SHA-256 verification failed for ${YTDLP_ASSET}."
        rm -rf -- "${work}" || true
        return 1
    fi

    chmod 0755 -- "${work}/${YTDLP_ASSET}" || {
        rm -rf -- "${work}" || true
        return 1
    }
    if ! install_ytdlp_candidate "${work}/${YTDLP_ASSET}"; then
        error 'yt-dlp bootstrap failed: downloaded runtime failed validation or activation.'
        rm -rf -- "${work}" || true
        return 1
    fi

    rm -rf -- "${work}" || return 1
    return 0
}

bootstrap_deno() {
    local work=''
    local checksum_file=''
    local checksum_line=''
    local base_url='https://github.com/denoland/deno/releases/latest/download'

    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.deno-bootstrap.XXXXXXXX') || return 1
    checksum_file="${DENO_ASSET}.sha256sum"

    if ! run_curl -o "${work}/${DENO_ASSET}" "${base_url}/${DENO_ASSET}" ||
       ! run_curl -o "${work}/${checksum_file}" "${base_url}/${checksum_file}"; then
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
    if ! run_in_dir "${work}" sha256sum --check CHECKSUM >/dev/null ||
       ! run_in_dir "${work}" unzip -q -- "${DENO_ASSET}"; then
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

latest_ytdlp_version() {
    local output_variable=$1
    local effective_url=''
    local version=''

    if ! effective_url=$(run_curl --silent --show-error \
        --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/${YTDLP_RELEASE_REPOSITORY}/releases/latest"); then
        return 1
    fi

    version=${effective_url##*/}
    [[ ${version} =~ ${YTDLP_CHANNEL_VERSION_PATTERN} ]] || return 1
    printf -v "${output_variable}" '%s' "${version}" || return 1
    return 0
}

update_ytdlp() {
    local current=''
    local current_version=''
    local latest_version=''

    if ! current=$(component_path yt-dlp); then
        return 1
    fi
    current_version=$(LC_ALL=C run_child "${current}" --version 2>/dev/null) || return 1
    current_version=${current_version%%$'\n'*}

    if ! latest_ytdlp_version latest_version; then
        return 1
    fi
    if [[ ${current_version} == "${latest_version}" ]]; then
        return 0
    fi

    bootstrap_ytdlp
}

update_deno() {
    local current=''
    local check_output=''
    local work=''
    local candidate=''
    local install_status=0

    if ! current=$(component_path deno); then
        return 1
    fi

    if ! check_output=$(LC_ALL=C run_timed "${DENO_CHECK_TIMEOUT_SECONDS}" \
        "${current}" upgrade --dry-run "${DENO_CHANNEL}" 2>&1); then
        return 1
    fi
    if [[ ${check_output} != *'Would upgrade to version '* ]]; then
        return 0
    fi

    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.deno-update.XXXXXXXX') || return 1
    candidate="${work}/deno"

    if ! LC_ALL=C run_timed "${DENO_UPDATE_TIMEOUT_SECONDS}" \
        "${current}" upgrade --output "${candidate}" --quiet "${DENO_CHANNEL}"; then
        rm -rf -- "${work}" || true
        return 1
    fi
    chmod 0755 -- "${candidate}" || {
        rm -rf -- "${work}" || true
        return 1
    }

    if install_deno_candidate "${candidate}"; then
        install_status=0
    else
        install_status=$?
    fi
    rm -rf -- "${work}" || {
        ((install_status == 0)) || return "${install_status}"
        return 1
    }
    return "${install_status}"
}

ensure_runtime() {
    if ! component_path yt-dlp >/dev/null 2>&1; then
        printf 'Installing the current yt-dlp %s runtime...\n' "${YTDLP_CHANNEL}" >&2
        if ! bootstrap_ytdlp; then
            error 'unable to install the initial yt-dlp runtime.'
            return 1
        fi
    fi

    if ! component_path deno >/dev/null 2>&1; then
        printf 'Installing the current Deno stable runtime...\n' >&2
        if ! bootstrap_deno; then
            error 'unable to install the initial Deno runtime.'
            return 1
        fi
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
    [[ ${previous_target} != */* && ${previous_target} != .* ]] || {
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

update_runtime() {
    local lock_status=0

    if acquire_runtime_lock; then
        lock_status=0
    else
        lock_status=$?
        if ((lock_status == 75)) && validate_active_runtimes; then
            warning 'another runtime update is in progress; using the active verified runtimes.'
            return 0
        fi
        error 'unable to acquire the runtime update lock.'
        return "${lock_status}"
    fi

    if ! ensure_runtime; then
        return 1
    fi

    if ! update_ytdlp; then
        warning 'yt-dlp update check failed; keeping the last verified runtime.'
    fi
    if ! update_deno; then
        warning 'Deno update check failed; keeping the last verified runtime.'
    fi

    recover_invalid_active_runtime yt-dlp || {
        error 'the active yt-dlp runtime is invalid and rollback failed.'
        return 1
    }
    recover_invalid_active_runtime deno || {
        error 'the active Deno runtime is invalid and rollback failed.'
        return 1
    }

    return 0
}

ensure_runtime_locked() {
    if ! acquire_runtime_lock; then
        error 'unable to acquire the runtime update lock.'
        return 75
    fi
    ensure_runtime
}

rollback_runtime_locked() {
    local component=$1
    if ! acquire_runtime_lock; then
        error 'unable to acquire the runtime update lock.'
        return 75
    fi
    rollback_component "${component}"
}

case ${1:-} in
ensure)
    ensure_runtime_locked
    ;;
update)
    update_runtime
    ;;
path)
    component_path "${2:-}"
    ;;
rollback)
    rollback_runtime_locked "${2:-}"
    ;;
versions)
    ytdlp=''
    deno=''
    ytdlp_version=''
    deno_version=''

    if ! ytdlp=$(component_path yt-dlp); then
        error 'managed yt-dlp runtime is not installed.'
        exit 69
    fi
    if ! deno=$(component_path deno); then
        error 'managed Deno runtime is not installed.'
        exit 69
    fi

    ytdlp_version=$(LC_ALL=C run_child "${ytdlp}" --version) || {
        error 'unable to read the managed yt-dlp version.'
        exit 69
    }
    if ! parse_deno_version "${deno}" deno_version; then
        error 'unable to read the managed Deno version.'
        exit 69
    fi

    printf 'yt-dlp %s (%s)\n' "${ytdlp_version%%$'\n'*}" "${YTDLP_CHANNEL}"
    printf 'Deno %s\n' "${deno_version}"
    ;;
*)
    printf 'Usage: %s {ensure|update|path yt-dlp|path deno|rollback yt-dlp|rollback deno|versions}\n' \
        "${0##*/}" >&2
    exit 2
    ;;
esac

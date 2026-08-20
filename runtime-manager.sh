#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly DENO_CHANNEL='stable'

error() {
    printf 'Error: %s\n' "$*" >&2
}

warning() {
    printf 'Warning: %s\n' "$*" >&2
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
    curl flock gpg grep install ln mkdir mktemp mv readlink realpath rm \
    sha256sum uname unzip; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        error "required runtime-manager command is absent: ${command_name}"
        exit 127
    }
done

mkdir -p -- "${YTDLP_ROOT}" "${DENO_ROOT}"
chmod 700 -- "${RUNTIME_ROOT}" "${YTDLP_ROOT}" "${DENO_ROOT}"

exec {LOCK_FD}>>"${LOCK_FILE}"
chmod 600 -- "${LOCK_FILE}"
flock --exclusive "${LOCK_FD}"

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

    if [[ -L ${root}/current ]]; then
        old_target=$(readlink -- "${root}/current") || return 1
    fi

    rm -f -- "${temporary_link}" "${previous_link}" || return 1
    ln -s -- "${version}" "${temporary_link}" || return 1
    if ! mv -Tf -- "${temporary_link}" "${root}/current"; then
        rm -f -- "${temporary_link}" || true
        return 1
    fi

    if [[ -n ${old_target} && ${old_target} != "${version}" &&
        -d ${root}/${old_target} ]]; then
        ln -s -- "${old_target}" "${previous_link}" || return 1
        if ! mv -Tf -- "${previous_link}" "${root}/previous"; then
            rm -f -- "${previous_link}" || true
            return 1
        fi
    fi

    return 0
}

validate_ytdlp() {
    local candidate=$1
    local help=''
    local impersonation=''
    local option

    [[ -x ${candidate} ]] || return 1
    LC_ALL=C "${candidate}" --version >/dev/null 2>&1 || return 1
    help=$(LC_ALL=C "${candidate}" --help 2>&1) || return 1

    for option in \
        --break-match-filters \
        --js-runtimes \
        --list-impersonate-targets \
        --no-update; do
        grep -Fq -- "${option}" <<<"${help}" || return 1
    done

    impersonation=$(LC_ALL=C "${candidate}" --list-impersonate-targets 2>&1) ||
        return 1
    # Current yt-dlp renders concrete targets as versioned client names such
    # as Chrome-133 or Firefox-147. Validate the table structurally instead of
    # assuming an unversioned browser-family token.
    if ! grep -E \
        '^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+curl_cffi[^[:space:]]*([[:space:]]|$)' \
        <<<"${impersonation}" |
        grep -Eiv '\((unavailable|not available)\)' >/dev/null; then
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
    output=$(LC_ALL=C "${candidate}" --version 2>/dev/null) || return 1
    first_line=${output%%$'\n'*}

    # Deno 2.9.x prints metadata after the semantic version, for example:
    # "deno 2.9.5 (stable, release, x86_64-unknown-linux-gnu)".
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

    # parse_deno_version is a complete predicate with explicit error handling.
    # shellcheck disable=SC2310
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

    # validate_ytdlp is a complete predicate: every failure is handled
    # explicitly inside the function, so errexit suppression is intentional.
    # shellcheck disable=SC2310
    if ! validate_ytdlp "${candidate}"; then
        return 1
    fi

    version=$(LC_ALL=C "${candidate}" --version) || return 1
    version=${version%%$'\n'*}
    [[ ${version} =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}([.][0-9]{6})?$ ]] ||
        return 1

    version_dir="${YTDLP_ROOT}/${version}"
    if [[ ! -x ${version_dir}/${YTDLP_ASSET} ]]; then
        mkdir -p -- "${version_dir}" || return 1
        install -m 0755 -- "${candidate}" "${version_dir}/${YTDLP_ASSET}" ||
            return 1
    fi

    # activate_version handles each filesystem failure explicitly.
    # shellcheck disable=SC2310
    if ! activate_version "${YTDLP_ROOT}" "${version}"; then
        return 1
    fi

    return 0
}

install_deno_candidate() {
    local candidate=$1
    local version=''
    local version_dir=''

    # validate_deno is a complete predicate with explicit error handling.
    # shellcheck disable=SC2310
    if ! validate_deno "${candidate}"; then
        return 1
    fi

    # Keep only Deno's semantic version for the managed directory name. Current
    # Deno releases append channel/build/architecture metadata to --version.
    # shellcheck disable=SC2310
    if ! parse_deno_version "${candidate}" version; then
        return 1
    fi

    version_dir="${DENO_ROOT}/${version}"
    if [[ ! -x ${version_dir}/deno ]]; then
        mkdir -p -- "${version_dir}" || return 1
        install -m 0755 -- "${candidate}" "${version_dir}/deno" || return 1
    fi

    # activate_version handles each filesystem failure explicitly.
    # shellcheck disable=SC2310
    if ! activate_version "${DENO_ROOT}" "${version}"; then
        return 1
    fi

    return 0
}

bootstrap_ytdlp() {
    local work=''
    local gpg_home=''
    local sums_line=''

    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.yt-dlp-bootstrap.XXXXXXXX') ||
        return 1
    gpg_home="${work}/gnupg"
    if ! mkdir -m 700 -- "${gpg_home}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        -o "${work}/${YTDLP_ASSET}" \
        "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/${YTDLP_ASSET}" ||
       ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        -o "${work}/SHA2-256SUMS" \
        'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/SHA2-256SUMS' ||
       ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        -o "${work}/SHA2-256SUMS.sig" \
        'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/SHA2-256SUMS.sig'; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! gpg --batch --homedir "${gpg_home}" \
        --import "${YTDLP_PUBLIC_KEY}" >/dev/null 2>&1 ||
       ! gpg --batch --homedir "${gpg_home}" \
        --verify "${work}/SHA2-256SUMS.sig" \
        "${work}/SHA2-256SUMS" >/dev/null 2>&1; then
        rm -rf -- "${work}" || true
        return 1
    fi

    sums_line=$(grep -E \
        "^[[:xdigit:]]{64}[[:space:]]+\*?${YTDLP_ASSET}$" \
        "${work}/SHA2-256SUMS" || true)
    if [[ -z ${sums_line} ]]; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! printf '%s\n' "${sums_line}" >"${work}/CHECKSUM"; then
        rm -rf -- "${work}" || true
        return 1
    fi
    if ! (
        cd -- "${work}" &&
        sha256sum --check CHECKSUM >/dev/null
    ); then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! chmod 0755 -- "${work}/${YTDLP_ASSET}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    # install_ytdlp_candidate validates the candidate and handles failures.
    # shellcheck disable=SC2310
    if ! install_ytdlp_candidate "${work}/${YTDLP_ASSET}"; then
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

    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.deno-bootstrap.XXXXXXXX') ||
        return 1
    checksum_file="${DENO_ASSET}.sha256sum"

    if ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        -o "${work}/${DENO_ASSET}" \
        "https://github.com/denoland/deno/releases/latest/download/${DENO_ASSET}" ||
       ! curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 \
        -o "${work}/${checksum_file}" \
        "https://github.com/denoland/deno/releases/latest/download/${checksum_file}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    checksum_line=$(grep -E \
        "^[[:xdigit:]]{64}[[:space:]]+\*?${DENO_ASSET}$" \
        "${work}/${checksum_file}" || true)
    if [[ -z ${checksum_line} ]]; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! printf '%s\n' "${checksum_line}" >"${work}/CHECKSUM"; then
        rm -rf -- "${work}" || true
        return 1
    fi
    if ! (
        cd -- "${work}" &&
        sha256sum --check CHECKSUM >/dev/null &&
        unzip -q -- "${DENO_ASSET}"
    ); then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! chmod 0755 -- "${work}/deno"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    # install_deno_candidate validates the candidate and handles failures.
    # shellcheck disable=SC2310
    if ! install_deno_candidate "${work}/deno"; then
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

    if ! effective_url=$(curl \
        --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 2 --retry-delay 1 \
        --output /dev/null \
        --write-out '%{url_effective}' \
        'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest'); then
        return 1
    fi

    version=${effective_url##*/}
    [[ ${version} =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$ ]] ||
        return 1

    printf -v "${output_variable}" '%s' "${version}" || return 1
    return 0
}

update_ytdlp() {
    local current=''
    local current_version=''
    local latest_version=''

    # component_path is an explicit predicate.
    # shellcheck disable=SC2310
    if ! current=$(component_path yt-dlp); then
        return 1
    fi

    current_version=$(LC_ALL=C "${current}" --version 2>/dev/null) || return 1
    current_version=${current_version%%$'\n'*}

    # latest_ytdlp_version reports its result through an output variable and
    # handles every network/parse failure explicitly.
    # shellcheck disable=SC2310
    if ! latest_ytdlp_version latest_version; then
        return 1
    fi

    if [[ ${current_version} == "${latest_version}" ]]; then
        return 0
    fi

    # bootstrap_ytdlp is the final command: its explicit status becomes ours.
    bootstrap_ytdlp
}

update_deno() {
    local current=''
    local check_output=''
    local work=''
    local candidate=''
    local install_status=0

    # component_path is an explicit predicate.
    # shellcheck disable=SC2310
    if ! current=$(component_path deno); then
        return 1
    fi

    if ! check_output=$(LC_ALL=C "${current}" \
        upgrade --dry-run "${DENO_CHANNEL}" 2>&1); then
        return 1
    fi

    if [[ ${check_output} != *'Would upgrade to version '* ]]; then
        return 0
    fi

    work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}" '.deno-update.XXXXXXXX') ||
        return 1
    candidate="${work}/deno"

    if ! LC_ALL=C "${current}" upgrade \
        --output "${candidate}" --quiet "${DENO_CHANNEL}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    if ! chmod 0755 -- "${candidate}"; then
        rm -rf -- "${work}" || true
        return 1
    fi

    # The installer is a complete predicate and all failures are explicit.
    # shellcheck disable=SC2310
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
    # component_path is a pure predicate with explicit statuses.
    # shellcheck disable=SC2310
    if ! component_path yt-dlp >/dev/null 2>&1; then
        printf 'Installing the current yt-dlp nightly runtime...\n' >&2
        # bootstrap_ytdlp handles all failures explicitly.
        # shellcheck disable=SC2310
        if ! bootstrap_ytdlp; then
            error 'unable to install the initial yt-dlp runtime.'
            return 1
        fi
    fi

    # component_path is a pure predicate with explicit statuses.
    # shellcheck disable=SC2310
    if ! component_path deno >/dev/null 2>&1; then
        printf 'Installing the current Deno stable runtime...\n' >&2
        # bootstrap_deno handles all failures explicitly.
        # shellcheck disable=SC2310
        if ! bootstrap_deno; then
            error 'unable to install the initial Deno runtime.'
            return 1
        fi
    fi

    return 0
}

update_runtime() {
    local active_ytdlp=''
    local active_deno=''

    # ensure_runtime performs explicit failure handling internally.
    # shellcheck disable=SC2310
    if ! ensure_runtime; then
        return 1
    fi

    # Update checks are deliberately best-effort. A verified previous runtime
    # remains usable when an upstream service or the network is unavailable.
    # shellcheck disable=SC2310
    if ! update_ytdlp; then
        warning 'yt-dlp update check failed; keeping the last verified runtime.'
    fi
    # shellcheck disable=SC2310
    if ! update_deno; then
        warning 'Deno update check failed; keeping the last verified runtime.'
    fi

    # component_path is a pure predicate.
    # shellcheck disable=SC2310
    if ! active_ytdlp=$(component_path yt-dlp); then
        error 'unable to resolve the active yt-dlp runtime.'
        return 1
    fi
    # shellcheck disable=SC2310
    if ! active_deno=$(component_path deno); then
        error 'unable to resolve the active Deno runtime.'
        return 1
    fi

    # Both validators explicitly handle every command failure.
    # shellcheck disable=SC2310
    if ! validate_ytdlp "${active_ytdlp}"; then
        error 'the active yt-dlp runtime is invalid.'
        return 1
    fi
    # shellcheck disable=SC2310
    if ! validate_deno "${active_deno}"; then
        error 'the active Deno runtime is invalid.'
        return 1
    fi

    return 0
}

case ${1:-} in
ensure)
    ensure_runtime
    ;;
update)
    update_runtime
    ;;
path)
    component_path "${2:-}"
    ;;
versions)
    ytdlp=''
    deno=''
    ytdlp_version=''
    deno_version=''

    # component_path is a pure predicate with explicit status handling.
    # shellcheck disable=SC2310
    if ! ytdlp=$(component_path yt-dlp); then
        error 'managed yt-dlp runtime is not installed.'
        exit 69
    fi

    # component_path is a pure predicate with explicit status handling.
    # shellcheck disable=SC2310
    if ! deno=$(component_path deno); then
        error 'managed Deno runtime is not installed.'
        exit 69
    fi

    ytdlp_version=$(LC_ALL=C "${ytdlp}" --version) || {
        error 'unable to read the managed yt-dlp version.'
        exit 69
    }

    # parse_deno_version is a complete predicate and writes deno_version
    # through printf -v after validating the complete command result.
    # shellcheck disable=SC2310
    if ! parse_deno_version "${deno}" deno_version; then
        error 'unable to read the managed Deno version.'
        exit 69
    fi

    printf 'yt-dlp %s\n' "${ytdlp_version}"
    printf 'Deno %s\n' "${deno_version}"
    ;;
*)
    printf 'Usage: %s {ensure|update|path yt-dlp|path deno|versions}\n' \
        "${0##*/}" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/runtime-manager-hardening-integration.sh
# Purpose     : Stress runtime-manager locking, recovery and hardening behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly RUNTIME_MANAGER="${PROJECT_DIR}/runtime-manager.sh"
# shellcheck disable=SC1090 # Resolve the shared library from the repository root.
source "${PROJECT_DIR}/tests/lib/assert.sh"

TEST_ROOT=''
HOLDER_PID=''
HOME_DIR=''
DATA_HOME=''
MOCK_BIN=''
URL_LOG=''
FD_LEAK_MARKER=''
NETWORK_MARKER=''
YTDLP_NETWORK_MARKER=''
GPGCONF_LOG=''
YTDLP_EXEC_PATH_LOG=''
YTDLP_ASSET=''
ROLLBACK_RUNS=${RUNTIME_HARDENING_ROLLBACK_RUNS:-3}
CONTENTION_RUNS=${RUNTIME_HARDENING_CONTENTION_RUNS:-3}
runtime_root=''
ytdlp_root=''
deno_root=''
runtime_env=()

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${HOLDER_PID} ]]; then
        kill -TERM -- "${HOLDER_PID}" 2>/dev/null || true
        wait "${HOLDER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}

validate_hardening_run_count() {
    local variable_name=$1
    local environment_name=$2
    local value=${!variable_name}

    [[ ${value} =~ ^[0-9]{1,3}$ ]] || {
        printf 'Error: %s must be an integer between 1 and 100.\n' \
            "${environment_name}" >&2
        exit 64
    }
    value=$((10#${value}))
    ((value >= 1 && value <= 100)) || {
        printf 'Error: %s must be between 1 and 100.\n' \
            "${environment_name}" >&2
        exit 64
    }
    printf -v "${variable_name}" '%d' "${value}"
    readonly "${variable_name}"
}

make_ytdlp() {
    local path=$1 version=$2
    mkdir -p -- "${path%/*}"
    cat >"${path}" <<EOF_YTDLP
#!/usr/bin/env bash
set -euo pipefail
if [[ -n \${MOCK_YTDLP_EXEC_PATH_LOG:-} ]]; then
    printf '%s\\n' "\$0" >>"\${MOCK_YTDLP_EXEC_PATH_LOG}"
fi
for fd_path in /proc/\$\$/fd/*; do
    target=\$(readlink -- "\${fd_path}" 2>/dev/null || true)
    [[ \${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"\${MOCK_FD_LEAK_MARKER:?}"
done
operation=''
seen_ignore_config=false
seen_no_plugin_dirs=false
seen_no_update=false
for argument in "\$@"; do
    case \${argument} in
    --ignore-config) seen_ignore_config=true ;;
    --no-plugin-dirs) seen_no_plugin_dirs=true ;;
    --no-update) seen_no_update=true ;;
    --version | --help | --list-impersonate-targets) operation=\${argument} ;;
    *) exit 64 ;;
    esac
done
if [[ -f \${HOME}/.config/yt-dlp/config &&
    \${seen_ignore_config} != true ]]; then
    : >"\${MOCK_YTDLP_NETWORK_MARKER:?}"
    exit 98
fi
if [[ \${MOCK_REQUIRE_YTDLP_ISOLATION:-0} == 1 ]]; then
    [[ \${seen_ignore_config} == true && \${seen_no_plugin_dirs} == true &&
        \${seen_no_update} == true && \${YTDLP_NO_PLUGINS:-} == 1 ]] || exit 68
fi
if [[ \${MOCK_YTDLP_OVERSIZED_HELP:-0} == 1 && \${operation} == --help ]]; then
    printf '%*s\n' 300000 oversized-help
    exit 0
fi
case \${operation} in
--version) printf '%s\\n' '${version}' ;;
--help)
    printf '%s\\n' \\
    '--audio-format FORMAT' \\
    '--batch-file FILE' \\
    '--break-match-filters FILTER' \\
    '--color POLICY' \\
    '--concurrent-fragments N' \\
    '--continue' \\
    '--cookies FILE' \\
    '--cookies-from-browser BROWSER' \\
    '--downloader PROTOCOL:NAME' \\
    '--dump-single-json' \\
    '--embed-metadata' \\
    '--extract-audio' \\
    '--extractor-args KEY:ARGS' \\
    '--extractor-retries RETRIES' \\
    '--fixup POLICY' \\
    '--format FORMAT' \\
    '--fragment-retries RETRIES' \\
    '--ignore-config' \\
    '--js-runtimes RUNTIME' \\
    '--list-impersonate-targets' \\
    '--load-info-json FILE' \\
    '--merge-output-format FORMAT' \\
    '--no-clean-info-json' \\
    '--no-overwrites' \\
    '--no-playlist' \\
    '--no-plugin-dirs' \\
    '--no-post-overwrites' \\
    '--no-update' \\
    '--newline' \\
    '--output TEMPLATE' \\
    '--parse-metadata FROM:TO' \\
    '--print TEMPLATE' \\
    '--print-to-file TEMPLATE FILE' \\
    '--progress' \\
    '--progress-delta SECONDS' \\
    '--progress-template TEMPLATE' \\
    '--remux-video FORMAT' \\
    '--retries RETRIES' \\
    '--retry-sleep EXPR' \\
    '--skip-download' \\
    '--socket-timeout SECONDS'
    if [[ \${MOCK_YTDLP_OMIT_AUDIO_QUALITY:-0} != 1 ]]; then
        printf '%s\\n' '--audio-quality QUALITY'
    fi
    ;;
--list-impersonate-targets) printf '%s\\n' 'Chrome-140 Linux curl_cffi' ;;
*) exit 64 ;;
esac
EOF_YTDLP
    chmod 0755 -- "${path}"
}

make_deno() {
    local path=$1 version=$2
    mkdir -p -- "${path%/*}"
    cat >"${path}" <<EOF_DENO
#!/usr/bin/env bash
set -euo pipefail
for fd_path in /proc/\$\$/fd/*; do
    target=\$(readlink -- "\${fd_path}" 2>/dev/null || true)
    [[ \${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"\${MOCK_FD_LEAK_MARKER:?}"
done
if [[ \${MOCK_DENO_PROBE_FAILURE:-0} == 1 ]]; then
    printf '%s\n' 'mock Deno probe failure' >&2
    printf '%*s\n' 300000 oversized-deno-diagnostic >&2
    exit 93
fi
printf '%s\\n' 'deno ${version} (stable, release, test-target)' 'v8 0.0.0' 'typescript 0.0.0'
EOF_DENO
    chmod 0755 -- "${path}"
}

initialize_runtime_hardening_workspace() {
    local command_name=''

    validate_hardening_run_count \
        ROLLBACK_RUNS RUNTIME_HARDENING_ROLLBACK_RUNS
    validate_hardening_run_count \
        CONTENTION_RUNS RUNTIME_HARDENING_CONTENTION_RUNS

    for command_name in bash chmod env find flock grep ln mkdir mktemp readlink rm rmdir sed sha256sum sleep stat uname; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required test command is absent: %s\n' "${command_name}" >&2
            exit 127
        }
    done

    TEST_ROOT=$(mktemp -d)
    readonly TEST_ROOT
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    readonly HOME_DIR="${TEST_ROOT}/home"
    readonly DATA_HOME="${TEST_ROOT}/data"
    readonly MOCK_BIN="${TEST_ROOT}/bin"
    readonly URL_LOG="${TEST_ROOT}/urls.log"
    readonly FD_LEAK_MARKER="${TEST_ROOT}/fd-leak"
    readonly NETWORK_MARKER="${TEST_ROOT}/network-called"
    readonly YTDLP_NETWORK_MARKER="${TEST_ROOT}/ytdlp-network-called"
    readonly GPGCONF_LOG="${TEST_ROOT}/gpgconf.log"
    readonly YTDLP_EXEC_PATH_LOG="${TEST_ROOT}/ytdlp-exec-paths.log"
    mkdir -p -- "${HOME_DIR}" "${DATA_HOME}" "${MOCK_BIN}"

    case $(uname -m) in
        x86_64) YTDLP_ASSET='yt-dlp_linux' ;;
        aarch64) YTDLP_ASSET='yt-dlp_linux_aarch64' ;;
        *)
            printf 'SKIP: unsupported test architecture.\n'
            exit 0
            ;;
    esac
    readonly YTDLP_ASSET
}

write_runtime_hardening_mocks() {
    cat >"${MOCK_BIN}/gpg" <<'EOF_GPG'
#!/usr/bin/env bash
set -euo pipefail
for fd_path in /proc/$$/fd/*; do
    target=$(readlink -- "${fd_path}" 2>/dev/null || true)
    [[ ${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"${MOCK_FD_LEAK_MARKER:?}"
done
if [[ ${MOCK_GPG_VERIFY_FAIL:-0} == 1 ]]; then
    for arg in "$@"; do
        if [[ ${arg} == --verify ]]; then
            printf '%s\n' 'mock OpenPGP verification failure' >&2
            exit 91
        fi
    done
fi
exit 0
EOF_GPG
    chmod 0755 -- "${MOCK_BIN}/gpg"

    cat >"${MOCK_BIN}/gpgconf" <<'EOF_GPGCONF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GPGCONF_LOG:?}"
printf '%s\n' "$*" >>"${MOCK_GPGCONF_LOG}"
EOF_GPGCONF
    chmod 0755 -- "${MOCK_BIN}/gpgconf"

    cat >"${MOCK_BIN}/unzip" <<'EOF_UNZIP'
#!/usr/bin/env bash
set -euo pipefail
for fd_path in /proc/$$/fd/*; do
    target=$(readlink -- "${fd_path}" 2>/dev/null || true)
    [[ ${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"${MOCK_FD_LEAK_MARKER:?}"
done
archive=''
requested_deno=false
for arg in "$@"; do
    [[ ${arg} == *.zip ]] && archive=${arg}
    [[ ${arg} == deno ]] && requested_deno=true
done
[[ -n ${archive} && ${requested_deno} == true ]]
version=${MOCK_DENO_ASSET_VERSION_OVERRIDE:-$(sed -n 's/^deno-archive=//p' "${archive}")}
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
if [[ ${MOCK_DENO_SYMLINK_MEMBER:-0} == 1 ]]; then
    ln -s -- /bin/true deno
    exit 0
fi
cat >deno <<EOF_DENO
#!/usr/bin/env bash
set -euo pipefail
for fd_path in /proc/\$\$/fd/*; do
    target=\$(readlink -- "\${fd_path}" 2>/dev/null || true)
    [[ \${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"\${MOCK_FD_LEAK_MARKER:?}"
done
printf '%s\\n' 'deno ${version} (stable, release, test-target)' 'v8 0.0.0' 'typescript 0.0.0'
EOF_DENO
chmod 0755 deno
EOF_UNZIP
    chmod 0755 -- "${MOCK_BIN}/unzip"

    cat >"${MOCK_BIN}/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == --disable ]] || exit 95
for fd_path in /proc/$$/fd/*; do
    target=$(readlink -- "${fd_path}" 2>/dev/null || true)
    [[ ${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"${MOCK_FD_LEAK_MARKER:?}"
done
: "${MOCK_URL_LOG:?}"
output=''
url=''
write_out=''
previous=''
seen_no_progress=false
for arg in "$@"; do
    if [[ ${previous} == output ]]; then output=${arg}; previous=''; continue; fi
    if [[ ${previous} == writeout ]]; then write_out=${arg}; previous=''; continue; fi
    case ${arg} in
    -o|--output) previous=output ;;
    --write-out) previous=writeout ;;
    --no-progress-meter) seen_no_progress=true ;;
    https://*) url=${arg} ;;
    esac
done
if [[ ${MOCK_REQUIRE_NO_PROGRESS:-0} == 1 && ${seen_no_progress} != true ]]; then
    exit 96
fi
printf '%s\n' "${url}" >>"${MOCK_URL_LOG}"
if [[ ${MOCK_YTDLP_NETWORK_FORBIDDEN:-0} == 1 &&
    (${url} == 'https://github.com/yt-dlp/yt-dlp/releases/latest' ||
        ${url} == 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest') ]]; then
    : >"${MOCK_YTDLP_NETWORK_MARKER:?}"
    exit 98
fi
if [[ ${MOCK_NETWORK_FORBIDDEN:-0} == 1 ]]; then
    : >"${MOCK_NETWORK_MARKER:?}"
    exit 97
fi
if [[ ${url} == 'https://github.com/yt-dlp/yt-dlp/releases/latest' ]]; then
    printf '%s' "${MOCK_YTDLP_EFFECTIVE_URL_OVERRIDE:-https://github.com/yt-dlp/yt-dlp/releases/tag/${MOCK_YTDLP_STABLE_VERSION:?}}"
    exit 0
fi
if [[ ${url} == 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest' ]]; then
    printf '%s' "${MOCK_YTDLP_EFFECTIVE_URL_OVERRIDE:-https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/tag/${MOCK_YTDLP_NIGHTLY_VERSION:?}}"
    exit 0
fi
if [[ ${url} == 'https://github.com/denoland/deno/releases/latest' ]]; then
    printf '%s' "${MOCK_DENO_EFFECTIVE_URL_OVERRIDE:-https://github.com/denoland/deno/releases/tag/v${MOCK_DENO_LATEST_VERSION:?}}"
    exit 0
fi
[[ -n ${output} ]] || exit 64
case ${url} in
*/yt-dlp/yt-dlp/releases/download/*/*|*/yt-dlp/yt-dlp-nightly-builds/releases/download/*/*)
    version=${url#*/releases/download/}; version=${version%%/*}; name=${url##*/}
    case ${name} in
    yt-dlp_linux|yt-dlp_linux_aarch64)
        candidate_version=${MOCK_YTDLP_ASSET_VERSION_OVERRIDE:-${version}}
        cat >"${output}" <<EOF_YTDLP
#!/usr/bin/env bash
set -euo pipefail
if [[ -n \${MOCK_YTDLP_EXEC_PATH_LOG:-} ]]; then
    printf '%s\\n' "\$0" >>"\${MOCK_YTDLP_EXEC_PATH_LOG}"
fi
for fd_path in /proc/\$\$/fd/*; do
    target=\$(readlink -- "\${fd_path}" 2>/dev/null || true)
    [[ \${target} != */yt-dlp-aria2-downloader/runtime/update.lock ]] || : >"\${MOCK_FD_LEAK_MARKER:?}"
done
operation=''
seen_ignore_config=false
seen_no_plugin_dirs=false
seen_no_update=false
for argument in "\$@"; do
    case \${argument} in
    --ignore-config) seen_ignore_config=true ;;
    --no-plugin-dirs) seen_no_plugin_dirs=true ;;
    --no-update) seen_no_update=true ;;
    --version | --help | --list-impersonate-targets) operation=\${argument} ;;
    *) exit 64 ;;
    esac
done
if [[ -f \${HOME}/.config/yt-dlp/config &&
    \${seen_ignore_config} != true ]]; then
    : >"\${MOCK_YTDLP_NETWORK_MARKER:?}"
    exit 98
fi
if [[ \${MOCK_REQUIRE_YTDLP_ISOLATION:-0} == 1 ]]; then
    [[ \${seen_ignore_config} == true && \${seen_no_plugin_dirs} == true &&
        \${seen_no_update} == true && \${YTDLP_NO_PLUGINS:-} == 1 ]] || exit 68
fi
case \${operation} in
--version) printf '%s\\n' '${candidate_version}' ;;
--help) printf '%s\\n' \\
    '--audio-format FORMAT' \\
    '--audio-quality QUALITY' \\
    '--batch-file FILE' \\
    '--break-match-filters FILTER' \\
    '--color POLICY' \\
    '--concurrent-fragments N' \\
    '--continue' \\
    '--cookies FILE' \\
    '--cookies-from-browser BROWSER' \\
    '--downloader PROTOCOL:NAME' \\
    '--dump-single-json' \\
    '--embed-metadata' \\
    '--extract-audio' \\
    '--extractor-args KEY:ARGS' \\
    '--extractor-retries RETRIES' \\
    '--fixup POLICY' \\
    '--format FORMAT' \\
    '--fragment-retries RETRIES' \\
    '--ignore-config' \\
    '--js-runtimes RUNTIME' \\
    '--list-impersonate-targets' \\
    '--load-info-json FILE' \\
    '--merge-output-format FORMAT' \\
    '--no-clean-info-json' \\
    '--no-overwrites' \\
    '--no-playlist' \\
    '--no-plugin-dirs' \\
    '--no-post-overwrites' \\
    '--no-update' \\
    '--newline' \\
    '--output TEMPLATE' \\
    '--parse-metadata FROM:TO' \\
    '--print TEMPLATE' \\
    '--print-to-file TEMPLATE FILE' \\
    '--progress' \\
    '--progress-delta SECONDS' \\
    '--progress-template TEMPLATE' \\
    '--remux-video FORMAT' \\
    '--retries RETRIES' \\
    '--retry-sleep EXPR' \\
    '--skip-download' \\
    '--socket-timeout SECONDS' ;;
--list-impersonate-targets) printf '%s\\n' 'Chrome-140 Linux curl_cffi' ;;
*) exit 64 ;;
esac
EOF_YTDLP
        ;;
    SHA2-256SUMS)
        dir=${output%/*}; asset=${MOCK_YTDLP_ASSET:?}
        hash=$(sha256sum -- "${dir}/${asset}"); hash=${hash%% *}
        printf '%s *%s\n' "${hash}" "${asset}" >"${output}"
        ;;
    SHA2-256SUMS.sig) printf 'mock signature\n' >"${output}" ;;
    *) exit 64 ;;
    esac
    ;;
*/denoland/deno/releases/download/v*/*)
    version=${url#*/releases/download/v}; version=${version%%/*}; name=${url##*/}
    case ${name} in
    deno-*.zip) printf 'deno-archive=%s\n' "${version}" >"${output}" ;;
    *.sha256sum)
        dir=${output%/*}; archive=${name%.sha256sum}
        hash=$(sha256sum -- "${dir}/${archive}"); hash=${hash%% *}
        printf '%s *%s\n' "${hash}" "${archive}" >"${output}"
        ;;
    *) exit 64 ;;
    esac
    ;;
*) exit 64 ;;
esac
EOF_CURL
    chmod 0755 -- "${MOCK_BIN}/curl"
}

initialize_runtime_hardening_fixtures() {
    runtime_root="${DATA_HOME}/yt-dlp-aria2-downloader/runtime"
    ytdlp_root="${runtime_root}/yt-dlp"
    deno_root="${runtime_root}/deno"
    mkdir -p -- "${ytdlp_root}" "${deno_root}"
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" 2026.06.09
    make_ytdlp "${ytdlp_root}/2026.03.17/${YTDLP_ASSET}" 2026.03.17
    make_deno "${deno_root}/2.8.0/deno" 2.8.0
    make_deno "${deno_root}/2.7.0/deno" 2.7.0
    ln -s 2026.06.09 "${ytdlp_root}/current"
    ln -s 2026.03.17 "${ytdlp_root}/previous"
    ln -s 2.8.0 "${deno_root}/current"
    ln -s 2.7.0 "${deno_root}/previous"

    runtime_env=(env HOME="${HOME_DIR}" XDG_DATA_HOME="${DATA_HOME}" PATH="${MOCK_BIN}:${PATH}"
        MOCK_URL_LOG="${URL_LOG}" MOCK_FD_LEAK_MARKER="${FD_LEAK_MARKER}"
        MOCK_NETWORK_MARKER="${NETWORK_MARKER}" MOCK_YTDLP_NETWORK_MARKER="${YTDLP_NETWORK_MARKER}"
        MOCK_GPGCONF_LOG="${GPGCONF_LOG}" MOCK_YTDLP_EXEC_PATH_LOG="${YTDLP_EXEC_PATH_LOG}"
        MOCK_REQUIRE_NO_PROGRESS=1 MOCK_REQUIRE_YTDLP_ISOLATION=1
        MOCK_YTDLP_ASSET="${YTDLP_ASSET}"
        MOCK_YTDLP_STABLE_VERSION=2026.07.04 MOCK_YTDLP_NIGHTLY_VERSION=2026.08.20.123456
        MOCK_DENO_LATEST_VERSION=2.9.5 YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS=1
        YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS=2 YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS=10
        YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS=10 YTDLP_ARIA2_RUNTIME_VALIDATE_TIMEOUT_SECONDS=5)
}

test_runtime_setting_bounds() {
    local validation_bin="${TEST_ROOT}/validation-bin"
    local validation_external_marker="${TEST_ROOT}/validation-external-called"
    local wrapped_command=''
    local setting_pair=''
    local environment_name=''
    local diagnostic_name=''
    local overflow_value=''
    local validation_error=''
    local status=0

    mkdir -p -- "${validation_bin}"
    for wrapped_command in curl flock timeout; do
        cat >"${validation_bin}/${wrapped_command}" <<'EOF_VALIDATION_EXTERNAL'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_VALIDATION_EXTERNAL_MARKER:?}"
printf '%s\n' "${0##*/}" >>"${MOCK_VALIDATION_EXTERNAL_MARKER}"
exit 99
EOF_VALIDATION_EXTERNAL
        chmod 0755 -- "${validation_bin}/${wrapped_command}"
    done

    for setting_pair in \
        'YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS:RUNTIME_LOCK_WAIT_SECONDS' \
        'YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS:CURL_CONNECT_TIMEOUT_SECONDS' \
        'YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS:CURL_MAX_TIME_SECONDS' \
        'YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS:CURL_RETRY_MAX_TIME_SECONDS' \
        'YTDLP_ARIA2_RUNTIME_VALIDATE_TIMEOUT_SECONDS:RUNTIME_VALIDATE_TIMEOUT_SECONDS'; do
        IFS=: read -r environment_name diagnostic_name <<<"${setting_pair}"
        for overflow_value in \
            18446744073709551617 \
            99999999999999999999999999999999999999; do
            rm -f -- "${validation_external_marker}"
            status=0
            validation_error=''
            validation_error=$(
                "${runtime_env[@]}" \
                    PATH="${validation_bin}:${MOCK_BIN}:/usr/bin:/bin" \
                    MOCK_VALIDATION_EXTERNAL_MARKER="${validation_external_marker}" \
                    "${environment_name}=${overflow_value}" \
                    "${RUNTIME_MANAGER}" versions 2>&1
            ) || status=$?
            [[ ${status} == 64 ]] \
                || fail "${environment_name} overflow ${overflow_value} returned ${status}, expected 64"
            grep -Fq \
                "${diagnostic_name} must be an integer between" \
                <<<"${validation_error}" \
                || fail "${environment_name} overflow diagnostic is missing"
            [[ ! -e ${validation_external_marker} ]] \
                || fail "${environment_name} overflow reached an external timeout/lock command"
        done
    done
}

test_runtime_command_and_lock_errors() {
    local chmod_race_bin="${TEST_ROOT}/chmod-race-bin"
    local chmod_race_data="${TEST_ROOT}/chmod-race-data"
    local chmod_race_lock="${chmod_race_data}/yt-dlp-aria2-downloader/runtime/update.lock"
    local chmod_race_marker="${TEST_ROOT}/chmod-race-triggered"
    local failure_bin="${TEST_ROOT}/flock-failure-bin"
    local invalid_data_home="${TEST_ROOT}/invalid-rollback-data"
    local invalid_lock="${invalid_data_home}/yt-dlp-aria2-downloader/runtime/update.lock"
    local lock_error=''
    local lock_status=0
    local rollback_error=''
    local rollback_status=0

    rollback_error=$(
        "${runtime_env[@]}" XDG_DATA_HOME="${invalid_data_home}" \
            "${RUNTIME_MANAGER}" rollback yt-dlp extra 2>&1
    ) || rollback_status=$?
    [[ ${rollback_status} == 2 ]] \
        || fail "invalid rollback arity returned ${rollback_status}, expected 2"
    grep -Fq 'rollback requires exactly one component' <<<"${rollback_error}" \
        || fail 'invalid rollback arity diagnostic is missing'
    [[ ! -e ${invalid_lock} ]] \
        || fail 'invalid rollback invocation acquired the runtime lock'

    mkdir -p -- "${failure_bin}"
    cat >"${failure_bin}/flock" <<'EOF_FLOCK_FAILURE'
#!/usr/bin/env bash
if [[ " $* " == *' --unlock '* ]]; then
    exit 0
fi
exit 70
EOF_FLOCK_FAILURE
    chmod 0755 -- "${failure_bin}/flock"
    lock_error=$(
        "${runtime_env[@]}" PATH="${failure_bin}:${MOCK_BIN}:${PATH}" \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || lock_status=$?
    [[ ${lock_status} == 70 ]] \
        || fail "operational flock failure returned ${lock_status}, expected 70"
    ! grep -Fq 'another runtime update is in progress' <<<"${lock_error}" \
        || fail 'operational flock failure was misreported as contention'

    mkdir -p -- "${chmod_race_bin}"
    cat >"${chmod_race_bin}/chmod" <<'EOF_CHMOD_RACE'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    if [[ ${argument} == /proc/*/fd/* && ! -e ${MOCK_CHMOD_RACE_MARKER:?} ]]; then
        rm -f -- "${MOCK_RUNTIME_LOCK_PATH:?}"
        printf '%s\n' replacement >"${MOCK_RUNTIME_LOCK_PATH}"
        : >"${MOCK_CHMOD_RACE_MARKER}"
        break
    fi
done
exec /usr/bin/chmod "$@"
EOF_CHMOD_RACE
    chmod 0755 -- "${chmod_race_bin}/chmod"
    lock_status=0
    lock_error=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${chmod_race_data}" \
            PATH="${chmod_race_bin}:${MOCK_BIN}:${PATH}" \
            MOCK_RUNTIME_LOCK_PATH="${chmod_race_lock}" \
            MOCK_CHMOD_RACE_MARKER="${chmod_race_marker}" \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || lock_status=$?
    [[ ${lock_status} == 73 ]] \
        || fail "replaced lock path returned ${lock_status}, expected 73"
    grep -Fq 'runtime update lock changed while it was being secured' \
        <<<"${lock_error}" || fail 'replaced lock path diagnostic is missing'
    assert_file_contains "${chmod_race_lock}" replacement \
        'replacement lock path content'
}

test_xdg_data_home_hardening() {
    local canonical_data_home="${TEST_ROOT}/canonical-data"
    local dotdot_parent="${TEST_ROOT}/dotdot-parent"
    local recorded_data_home=''
    local shared_data_home="${TEST_ROOT}/shared-data"
    local symlink_data_home="${TEST_ROOT}/symlink-xdg"
    local symlink_target="${TEST_ROOT}/symlink-xdg-target"
    local status=0

    mkdir -p -- "${canonical_data_home}" "${dotdot_parent}"
    "${runtime_env[@]}" \
        XDG_DATA_HOME="${dotdot_parent}/../canonical-data" \
        "${RUNTIME_MANAGER}" path yt-dlp >/dev/null 2>&1 || status=$?
    [[ ${status} == 1 ]] || fail "canonical dotdot path returned ${status}, expected 1"
    IFS= read -r recorded_data_home \
        <"${HOME_DIR}/.local/share/yt-dlp-aria2-downloader/.package-runtime-data-home-v1" \
        || fail 'canonical XDG data-home marker is missing'
    assert_equals "${canonical_data_home}" "${recorded_data_home}" \
        'dotdot XDG data home was not recorded canonically'

    mkdir -p -- "${shared_data_home}"
    chmod 0777 -- "${shared_data_home}"
    status=0
    "${runtime_env[@]}" XDG_DATA_HOME="${shared_data_home}" \
        "${RUNTIME_MANAGER}" versions >/dev/null 2>&1 || status=$?
    [[ ${status} == 73 ]] \
        || fail "shared-writable XDG data home returned ${status}, expected 73"
    [[ ! -e ${shared_data_home}/yt-dlp-aria2-downloader ]] \
        || fail 'shared-writable XDG data home received managed state'

    mkdir -p -- "${symlink_target}"
    ln -s -- "${symlink_target}" "${symlink_data_home}"
    status=0
    "${runtime_env[@]}" XDG_DATA_HOME="${symlink_data_home}" \
        "${RUNTIME_MANAGER}" path yt-dlp >/dev/null 2>&1 || status=$?
    [[ ${status} == 1 ]] \
        || fail "canonical symlinked XDG data home returned ${status}, expected 1"
    [[ -d ${symlink_target}/yt-dlp-aria2-downloader/runtime ]] \
        || fail 'symlinked XDG data home was not anchored at its physical target'
    IFS= read -r recorded_data_home \
        <"${HOME_DIR}/.local/share/yt-dlp-aria2-downloader/.package-runtime-data-home-v1" \
        || fail 'physical XDG data-home marker is missing'
    assert_equals "${symlink_target}" "${recorded_data_home}" \
        'symlinked XDG data home was not recorded by its physical path'
}

test_bounded_runtime_probes() {
    local diagnostic=''
    local diagnostic_size=0
    local status=0

    diagnostic=$(
        MOCK_YTDLP_OVERSIZED_HELP=1 MOCK_NETWORK_FORBIDDEN=1 \
            "${runtime_env[@]}" "${RUNTIME_MANAGER}" require 2>&1
    ) || status=$?
    [[ ${status} == 69 ]] \
        || fail "oversized yt-dlp help returned ${status}, expected 69"
    grep -Fq 'exceeded the 262144-byte output limit' <<<"${diagnostic}" \
        || fail 'oversized yt-dlp help diagnostic is missing'
    diagnostic_size=${#diagnostic}
    ((diagnostic_size < 20000)) \
        || fail "oversized yt-dlp diagnostic was not bounded: ${diagnostic_size}"
    ! find "${runtime_root}" -maxdepth 1 -name '.runtime-probe.*' -print -quit \
        | grep -q . || fail 'yt-dlp probe capture was not removed'

    status=0
    diagnostic=$(
        MOCK_YTDLP_OMIT_AUDIO_QUALITY=1 MOCK_NETWORK_FORBIDDEN=1 \
            "${runtime_env[@]}" "${RUNTIME_MANAGER}" require 2>&1
    ) || status=$?
    [[ ${status} == 69 ]] \
        || fail "incomplete managed yt-dlp capability set returned ${status}, expected 69"
    grep -Fq 'required option is absent: --audio-quality' <<<"${diagnostic}" \
        || fail 'managed yt-dlp capability contract omitted --audio-quality'

    status=0
    diagnostic=$(
        MOCK_DENO_PROBE_FAILURE=1 MOCK_NETWORK_FORBIDDEN=1 \
            "${runtime_env[@]}" "${RUNTIME_MANAGER}" require 2>&1
    ) || status=$?
    [[ ${status} == 69 ]] \
        || fail "failed Deno probe returned ${status}, expected 69"
    grep -Fq 'Deno runtime validation failed: --version exited with status' \
        <<<"${diagnostic}" || fail 'bounded Deno failure diagnostic is missing'
    diagnostic_size=${#diagnostic}
    ((diagnostic_size < 20000)) \
        || fail "Deno failure diagnostic was not bounded: ${diagnostic_size}"

    make_deno "${deno_root}/suffix-version/deno" '2.9.5+metadata'
    rm -f -- "${deno_root}/current"
    ln -s suffix-version "${deno_root}/current"
    status=0
    diagnostic=$(
        MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" \
            "${RUNTIME_MANAGER}" require 2>&1
    ) || status=$?
    [[ ${status} == 69 ]] \
        || fail "suffixed managed Deno version returned ${status}, expected 69"
    grep -Fq 'stable X.Y.Z version' <<<"${diagnostic}" \
        || fail 'suffixed managed Deno version diagnostic is missing'
    rm -f -- "${deno_root}/current"
    ln -s 2.8.0 "${deno_root}/current"
}

test_oversized_deno_versions() {
    local deno_overflow_case=''
    local deno_overflow_name=''
    local deno_overflow_version=''

    # Deno version comparison must remain correct even when a syntactically
    # valid component is wider than Bash's fixed-width arithmetic.
    for deno_overflow_case in 'overflow-major:18446744073709551618.0.0' 'overflow-minor:2.18446744073709551618.0'; do
        IFS=: read -r deno_overflow_name deno_overflow_version <<<"${deno_overflow_case}"
        make_deno "${deno_root}/${deno_overflow_name}/deno" "${deno_overflow_version}"
        rm -f -- "${deno_root}/current"
        ln -s -- "${deno_overflow_name}" "${deno_root}/current"
        MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" require >/dev/null || fail "Deno oversized semantic version was rejected: ${deno_overflow_version}"
    done
    rm -f -- "${deno_root}/current"
    ln -s 2.8.0 "${deno_root}/current"
}

test_invalid_runtime_path() {
    local path_status=0
    local path_error=''
    local prepare_status=0
    local prepare_error=''

    # Invalid path requests must fail with a precise usage diagnostic.
    path_error=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" path invalid-component 2>&1
    ) || path_status=$?
    [[ ${path_status} == 2 ]] \
        || fail "invalid path component returned ${path_status}, expected 2"
    grep -Fq 'unknown runtime component for path:' <<<"${path_error}" \
        || fail 'invalid path component diagnostic is missing'

    prepare_error=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" prepare invalid-action 2>&1
    ) || prepare_status=$?
    [[ ${prepare_status} == 2 ]] \
        || fail "invalid prepare action returned ${prepare_status}, expected 2"
    grep -Fq 'prepare requires an action: update or require.' <<<"${prepare_error}" \
        || fail 'invalid prepare action diagnostic is missing'
}

test_mismatched_ytdlp_candidate() {
    local mismatch_data_home="${TEST_ROOT}/version-mismatch-data"
    local mismatch_ytdlp_root="${mismatch_data_home}/yt-dlp-aria2-downloader/runtime/yt-dlp"
    local mismatch_status=0
    local mismatch_error=''

    # A downloaded executable whose own version does not match the immutable
    # release tag must never be activated.
    rm -rf -- "${mismatch_data_home}"
    mismatch_error=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${mismatch_data_home}" \
            MOCK_YTDLP_ASSET_VERSION_OVERRIDE=2026.07.05 \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || mismatch_status=$?
    [[ ${mismatch_status} == 1 ]] \
        || fail "mismatched yt-dlp candidate returned ${mismatch_status}, expected 1"
    grep -Fq 'does not match resolved release' <<<"${mismatch_error}" \
        || fail 'mismatched yt-dlp candidate diagnostic is missing'
    [[ ! -L ${mismatch_ytdlp_root}/current ]] \
        || fail 'mismatched yt-dlp candidate was activated'
}

test_mismatched_deno_candidate() {
    local mismatch_data_home="${TEST_ROOT}/deno-version-mismatch-data"
    local mismatch_deno_root="${mismatch_data_home}/yt-dlp-aria2-downloader/runtime/deno"
    local mismatch_status=0
    local mismatch_error=''

    # A checksum-valid archive remains bound to the exact release tag used to
    # obtain it. The executable inside may not silently select another version.
    rm -rf -- "${mismatch_data_home}"
    mismatch_error=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${mismatch_data_home}" \
            MOCK_DENO_ASSET_VERSION_OVERRIDE=2.8.0 \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || mismatch_status=$?
    [[ ${mismatch_status} == 1 ]] \
        || fail "mismatched Deno candidate returned ${mismatch_status}, expected 1"
    grep -Fq 'does not match resolved release' <<<"${mismatch_error}" \
        || fail 'mismatched Deno candidate diagnostic is missing'
    [[ ! -L ${mismatch_deno_root}/current ]] \
        || fail 'mismatched Deno candidate was activated'
}

test_release_location_and_archive_hardening() {
    local deno_redirect_data="${TEST_ROOT}/deno-redirect-data"
    local deno_redirect_root="${deno_redirect_data}/yt-dlp-aria2-downloader/runtime/deno"
    local symlink_member_data="${TEST_ROOT}/deno-symlink-member-data"
    local symlink_member_root="${symlink_member_data}/yt-dlp-aria2-downloader/runtime/deno"
    local ytdlp_redirect_data="${TEST_ROOT}/ytdlp-redirect-data"
    local ytdlp_redirect_root="${ytdlp_redirect_data}/yt-dlp-aria2-downloader/runtime/yt-dlp"
    local error_output=''
    local status=0

    error_output=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${ytdlp_redirect_data}" \
            MOCK_YTDLP_EFFECTIVE_URL_OVERRIDE='https://example.invalid/yt-dlp/releases/tag/2026.07.04' \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "cross-host yt-dlp redirect returned ${status}, expected 1"
    grep -Fq 'escaped the expected GitHub repository' <<<"${error_output}" \
        || fail 'cross-host yt-dlp redirect diagnostic is missing'
    [[ ! -L ${ytdlp_redirect_root}/current ]] \
        || fail 'cross-host yt-dlp redirect activated a runtime'

    status=0
    error_output=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${deno_redirect_data}" \
            MOCK_DENO_EFFECTIVE_URL_OVERRIDE='https://example.invalid/deno/releases/tag/v2.9.5' \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "cross-host Deno redirect returned ${status}, expected 1"
    grep -Fq 'Deno latest-release lookup escaped the expected GitHub repository' \
        <<<"${error_output}" || fail 'cross-host Deno redirect diagnostic is missing'
    [[ ! -L ${deno_redirect_root}/current ]] \
        || fail 'cross-host Deno redirect activated a runtime'

    status=0
    error_output=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${symlink_member_data}" \
            MOCK_DENO_SYMLINK_MEMBER=1 \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "symlink Deno archive member returned ${status}, expected 1"
    grep -Fq 'extracted deno member is not a regular file' <<<"${error_output}" \
        || fail 'symlink Deno archive member diagnostic is missing'
    [[ ! -L ${symlink_member_root}/current ]] \
        || fail 'symlink Deno archive member was activated'
}

test_symlinked_managed_data_root() {
    local symlink_data_home="${TEST_ROOT}/symlink-data"
    local sentinel_root="${TEST_ROOT}/symlink-sentinel"
    local sentinel_mode=''
    local status=0

    # The application root must be rejected before mkdir -p can follow it and
    # create or chmod runtime paths in an unrelated target tree.
    mkdir -p -- "${symlink_data_home}" "${sentinel_root}"
    chmod 0750 -- "${sentinel_root}"
    printf 'unchanged\n' >"${sentinel_root}/sentinel"
    ln -s -- "${sentinel_root}" \
        "${symlink_data_home}/yt-dlp-aria2-downloader"

    "${runtime_env[@]}" XDG_DATA_HOME="${symlink_data_home}" \
        "${RUNTIME_MANAGER}" versions >/dev/null 2>&1 || status=$?
    [[ ${status} == 73 ]] \
        || fail "symlinked managed data root returned ${status}, expected 73"
    [[ ! -e ${sentinel_root}/runtime ]] \
        || fail 'symlinked managed data root created runtime state in its target'
    assert_file_contains "${sentinel_root}/sentinel" unchanged \
        'symlink target sentinel content'
    sentinel_mode=$(stat -c '%a' -- "${sentinel_root}")
    [[ ${sentinel_mode} == 750 ]] \
        || fail 'symlinked managed data root changed target permissions'
}

test_signature_failure_bootstrap() {
    local verify_fail_data_home="${TEST_ROOT}/verify-fail-data"
    local verify_fail_runtime_root="${verify_fail_data_home}/yt-dlp-aria2-downloader/runtime"
    local verify_fail_ytdlp_root="${verify_fail_runtime_root}/yt-dlp"
    local verify_failure_status=0
    local verify_failure_error=''
    local unverified_candidates=''

    # A fresh bootstrap must refuse a yt-dlp candidate whose signed manifest
    # cannot be verified. Import remains successful; only --verify is mutated.
    rm -rf -- "${verify_fail_data_home}"
    verify_failure_error=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${verify_fail_data_home}" \
            MOCK_GPG_VERIFY_FAIL=1 \
            "${RUNTIME_MANAGER}" ensure 2>&1
    ) || verify_failure_status=$?

    [[ ${verify_failure_status} == 1 ]] \
        || fail "signature-failure bootstrap returned ${verify_failure_status}, expected 1"
    grep -Fq \
        'yt-dlp bootstrap failed: SHA-256 manifest signature verification failed.' \
        <<<"${verify_failure_error}" \
        || fail 'signature-failure bootstrap missed the canonical verification diagnostic'
    [[ ! -L ${verify_fail_ytdlp_root}/current ]] \
        || fail 'signature-failure bootstrap activated an unverified yt-dlp runtime'
    [[ ! -L ${verify_fail_runtime_root}/deno/current ]] \
        || fail 'signature-failure bootstrap unexpectedly reached Deno activation'
    if [[ -d ${verify_fail_ytdlp_root} ]]; then
        unverified_candidates=$(
            find "${verify_fail_ytdlp_root}" -type f -name "${YTDLP_ASSET}" -print
        ) || fail 'unable to inspect signature-failure yt-dlp artifacts'
        [[ -z ${unverified_candidates} ]] \
            || fail 'signature-failure bootstrap retained an unverified yt-dlp candidate'
    fi
}

test_fresh_runtime_bootstrap() {
    local fresh_data_home="${TEST_ROOT}/fresh-data"
    local fresh_runtime_root="${fresh_data_home}/yt-dlp-aria2-downloader/runtime"
    local fresh_ytdlp_root="${fresh_runtime_root}/yt-dlp"
    local fresh_deno_root="${fresh_runtime_root}/deno"

    # A completely empty managed-runtime tree must bootstrap both components.
    # This exercises the bootstrap paths, not only already-installed updates.
    rm -rf -- "${fresh_data_home}"
    : >"${URL_LOG}"
    : >"${GPGCONF_LOG}"
    : >"${YTDLP_EXEC_PATH_LOG}"
    rm -f -- "${FD_LEAK_MARKER}" "${NETWORK_MARKER}" "${YTDLP_NETWORK_MARKER}"

    "${runtime_env[@]}" \
        XDG_DATA_HOME="${fresh_data_home}" \
        "${RUNTIME_MANAGER}" ensure >/dev/null

    assert_link_target \
        "${fresh_ytdlp_root}/current" \
        2026.07.04 \
        'fresh yt-dlp bootstrap failed'

    assert_link_target \
        "${fresh_deno_root}/current" \
        2.9.5 \
        'fresh Deno bootstrap failed'

    grep -Fq \
        '/yt-dlp/yt-dlp/releases/download/2026.07.04/' \
        "${URL_LOG}" \
        || fail 'fresh yt-dlp bootstrap did not use its exact release tag'

    grep -Fq \
        '/denoland/deno/releases/download/v2.9.5/' \
        "${URL_LOG}" \
        || fail 'fresh Deno bootstrap did not use its exact release tag'

    [[ ! -e ${FD_LEAK_MARKER} ]] \
        || fail 'fresh bootstrap leaked the runtime lock to a child process'

    grep -Fq -- "${fresh_runtime_root}/.yt-dlp-bootstrap." "${YTDLP_EXEC_PATH_LOG}" \
        || fail 'fresh yt-dlp bootstrap did not execute its candidate below RUNTIME_ROOT'
    ! grep -Fq -- '/tmp/.yt-dlp-bootstrap.' "${YTDLP_EXEC_PATH_LOG}" \
        || fail 'fresh yt-dlp bootstrap still executed a candidate from /tmp'
    grep -Fq -- '--kill gpg-agent' "${GPGCONF_LOG}" \
        || fail 'fresh yt-dlp bootstrap did not terminate its ephemeral gpg-agent'
    grep -Fq -- '--homedir /tmp/.yt-dlp-gpg.' "${GPGCONF_LOG}" \
        || fail 'gpg-agent cleanup did not target the short bootstrap homedir'
}

test_no_network_require() {
    local status=0

    # Strict no-network require mode: both success and missing-runtime failure must
    # happen without invoking curl or an updater requested by personal yt-dlp
    # configuration.
    mkdir -p -- "${HOME_DIR}/.config/yt-dlp"
    printf '%s\n' '--update' >"${HOME_DIR}/.config/yt-dlp/config"
    rm -f -- "${NETWORK_MARKER}" "${YTDLP_NETWORK_MARKER}" "${URL_LOG}"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" require
    [[ ! -e ${NETWORK_MARKER} ]] || fail 'require mode invoked the network'
    [[ ! -e ${YTDLP_NETWORK_MARKER} ]] \
        || fail 'require mode honored personal yt-dlp update configuration'
    rm -f -- "${deno_root}/current"
    status=0
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" require >/dev/null 2>&1 || status=$?
    [[ ${status} == 69 ]] || fail "missing-runtime require returned ${status}, expected 69"
    [[ ! -e ${NETWORK_MARKER} ]] || fail 'failed require mode invoked the network'
    ln -s 2.8.0 "${deno_root}/current"
}

test_invalid_active_runtime_recovery() {
    local require_status=0

    # `ensure` must validate an executable active runtime and recover locally
    # instead of accepting a corrupted current target.
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" malformed-version
    rm -f -- "${NETWORK_MARKER}" "${URL_LOG}"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null
    [[ ! -e ${NETWORK_MARKER} ]] || fail 'ensure consulted the network while recovering an invalid active yt-dlp'
    assert_link_target "${ytdlp_root}/current" 2026.03.17 'ensure did not roll back an invalid active yt-dlp runtime'

    # Restore the canonical state before independently qualifying update recovery.
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" 2026.06.09
    rm -f -- "${ytdlp_root}/current" "${ytdlp_root}/previous"
    ln -s 2026.06.09 "${ytdlp_root}/current"
    ln -s 2026.03.17 "${ytdlp_root}/previous"

    # A malformed active yt-dlp version must be recovered locally before any
    # yt-dlp update lookup is attempted.
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" malformed-version
    rm -f -- "${YTDLP_NETWORK_MARKER}" "${URL_LOG}"
    "${runtime_env[@]}" \
        MOCK_YTDLP_NETWORK_FORBIDDEN=1 \
        MOCK_DENO_LATEST_VERSION=2.8.0 \
        "${RUNTIME_MANAGER}" update >/dev/null
    [[ ! -e ${YTDLP_NETWORK_MARKER} ]] \
        || fail 'malformed active yt-dlp consulted the network before local recovery'
    assert_link_target "${ytdlp_root}/current" 2026.03.17 \
        'malformed active yt-dlp was not rolled back locally'

    # Restore the canonical state for the remaining update/rollback scenarios.
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" 2026.06.09
    rm -f -- "${ytdlp_root}/current" "${ytdlp_root}/previous"
    ln -s 2026.06.09 "${ytdlp_root}/current"
    ln -s 2026.03.17 "${ytdlp_root}/previous"

    # With no usable previous target, mutating modes reinstall through the
    # authenticated bootstrap while strict require remains offline and read-only.
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" malformed-version
    rm -f -- "${ytdlp_root}/previous" "${NETWORK_MARKER}" "${URL_LOG}"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" \
        "${RUNTIME_MANAGER}" require >/dev/null 2>&1 || require_status=$?
    [[ ${require_status} == 69 ]] \
        || fail "invalid no-previous require returned ${require_status}, expected 69"
    [[ ! -e ${NETWORK_MARKER} ]] \
        || fail 'invalid no-previous require invoked the network'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.07.04 \
        'ensure did not reinstall an invalid yt-dlp runtime without previous'

    make_deno "${deno_root}/2.8.0/deno" malformed-version
    rm -f -- "${deno_root}/previous"
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null
    assert_link_target "${deno_root}/current" 2.9.5 \
        'ensure did not reinstall an invalid Deno runtime without previous'

    # Restore the canonical pre-update state for the remaining scenarios.
    rm -f -- "${ytdlp_root}/current" "${ytdlp_root}/previous" \
        "${deno_root}/current" "${deno_root}/previous"
    rm -rf -- "${ytdlp_root}/2026.07.04" "${deno_root}/2.9.5"
    make_ytdlp "${ytdlp_root}/2026.06.09/${YTDLP_ASSET}" 2026.06.09
    make_deno "${deno_root}/2.8.0/deno" 2.8.0
    ln -s 2026.06.09 "${ytdlp_root}/current"
    ln -s 2026.03.17 "${ytdlp_root}/previous"
    ln -s 2.8.0 "${deno_root}/current"
    ln -s 2.7.0 "${deno_root}/previous"
}

test_runtime_updates() {
    local deno_inode_after=''
    local deno_inode_before=''
    local stable_inode_after=''
    local stable_inode_before=''
    local downgrade_error=''

    # Scenario group: exact-tag stable update, Deno update, nightly opt-in, then stable.
    : >"${URL_LOG}"
    rm -f -- "${FD_LEAK_MARKER}"
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.07.04 'stable update failed'
    assert_link_target "${deno_root}/current" 2.9.5 'Deno update failed'
    stable_inode_before=$(stat -c '%d:%i' -- \
        "${ytdlp_root}/2026.07.04/${YTDLP_ASSET}")
    deno_inode_before=$(stat -c '%d:%i' -- "${deno_root}/2.9.5/deno")
    grep -Fq '/releases/download/2026.07.04/' "${URL_LOG}" || fail 'yt-dlp exact tag URL missing'
    grep -Fq '/releases/download/v2.9.5/' "${URL_LOG}" || fail 'Deno exact tag URL missing'
    ! grep -Fq '/releases/latest/download/' "${URL_LOG}" || fail 'latest/download TOCTOU path remains'
    [[ ! -e ${FD_LEAK_MARKER} ]] || fail 'runtime update lock leaked into a child process'

    downgrade_error=$(
        "${runtime_env[@]}" \
            MOCK_YTDLP_STABLE_VERSION=2026.06.09 \
            MOCK_DENO_LATEST_VERSION=2.8.0 \
            "${RUNTIME_MANAGER}" update 2>&1
    ) || fail 'same-channel downgrade refusal failed'
    assert_link_target "${ytdlp_root}/current" 2026.07.04 \
        'same-channel yt-dlp downgrade was activated'
    assert_link_target "${deno_root}/current" 2.9.5 \
        'Deno downgrade was activated'
    grep -Fq 'refusing to downgrade the active stable yt-dlp runtime' \
        <<<"${downgrade_error}" || fail 'yt-dlp downgrade refusal diagnostic is missing'
    grep -Fq 'refusing to downgrade the active Deno runtime' \
        <<<"${downgrade_error}" || fail 'Deno downgrade refusal diagnostic is missing'

    YTDLP_ARIA2_YTDLP_CHANNEL=nightly "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.08.20.123456 'stable -> nightly failed'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.07.04 'nightly -> stable failed'
    assert_link_target "${ytdlp_root}/previous" 2026.08.20.123456 'nightly rollback target missing'
    stable_inode_after=$(stat -c '%d:%i' -- \
        "${ytdlp_root}/2026.07.04/${YTDLP_ASSET}") \
        || fail 'unable to inspect reactivated yt-dlp identity'
    assert_equals "${stable_inode_before}" "${stable_inode_after}" \
        'reactivating stable yt-dlp replaced immutable runtime bytes'

    "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback deno >/dev/null
    assert_link_target "${deno_root}/current" 2.8.0 \
        'Deno rollback did not select the prior runtime'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${deno_root}/current" 2.9.5 \
        'Deno update did not reactivate the current release'
    deno_inode_after=$(stat -c '%d:%i' -- "${deno_root}/2.9.5/deno") \
        || fail 'unable to inspect reactivated Deno identity'
    assert_equals "${deno_inode_before}" "${deno_inode_after}" \
        'reactivating Deno replaced immutable runtime bytes'
}

test_repeated_rollbacks() {
    local iteration=0

    # Repeated double-rollbacks must always return to the exact initial state.
    for ((iteration = 1; iteration <= ROLLBACK_RUNS; iteration++)); do
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
        assert_link_target "${ytdlp_root}/current" 2026.08.20.123456 "rollback A failed at ${iteration}"
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
        assert_link_target "${ytdlp_root}/current" 2026.07.04 "rollback B failed at ${iteration}"
    done
}

test_invalid_rollback_targets() {
    local status=0
    local rollback_error=''

    # Missing, unsafe, and invalid previous targets must fail with the exact
    # rollback status and the canonical validator diagnostics.
    rm -f -- "${ytdlp_root}/previous"
    status=0
    rollback_error=''
    rollback_error=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "missing previous rollback returned ${status}, expected 1"
    grep -Fq 'no previous yt-dlp runtime is available.' <<<"${rollback_error}" \
        || fail 'missing previous rollback diagnostic is not canonical'

    ln -s ../escape "${ytdlp_root}/previous"
    status=0
    rollback_error=''
    rollback_error=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "unsafe previous rollback returned ${status}, expected 1"
    grep -Fq 'invalid previous yt-dlp runtime target.' <<<"${rollback_error}" \
        || fail 'unsafe previous rollback diagnostic is not canonical'

    rm -f -- "${ytdlp_root}/previous"
    ln -s $'2026.08.20.123456\ninvalid' "${ytdlp_root}/previous"
    status=0
    rollback_error=''
    rollback_error=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp 2>&1
    ) || status=$?
    [[ ${status} == 1 ]] \
        || fail "newline-bearing previous rollback returned ${status}, expected 1"
    grep -Fq 'invalid previous yt-dlp runtime target.' <<<"${rollback_error}" \
        || fail 'rollback did not reject the newline target at the canonical validator'

    rm -f -- "${ytdlp_root}/previous"
    ln -s 2026.08.20.123456 "${ytdlp_root}/previous"
}

test_activation_journal_recovery() {
    # Scenario: journal recovery repairs previous after commit and restores the
    # pre-activation previous pointer after an interrupted activation.
    printf 'old=2026.08.20.123456\nprevious=2026.03.17\nnew=2026.07.04\n' >"${ytdlp_root}/.activation-journal"
    rm -f -- "${ytdlp_root}/previous"
    ln -s 2026.03.17 "${ytdlp_root}/previous"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null
    assert_link_target "${ytdlp_root}/previous" 2026.08.20.123456 'committed journal recovery failed'
    [[ ! -e ${ytdlp_root}/.activation-journal ]] || fail 'committed journal was not cleared'

    rm -f -- "${ytdlp_root}/current" "${ytdlp_root}/previous"
    ln -s 2026.08.20.123456 "${ytdlp_root}/current"
    ln -s 2026.08.20.123456 "${ytdlp_root}/previous"
    printf 'old=2026.08.20.123456\nprevious=2026.03.17\nnew=2026.07.04\n' >"${ytdlp_root}/.activation-journal"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null
    assert_link_target "${ytdlp_root}/previous" 2026.03.17 'aborted journal recovery failed'
}

test_runtime_lock_hardening() {
    local status=0
    local iteration=0
    local ready=''
    local holder=''

    # Distinguish lock path errors (73) from contention (75), then repeatedly
    # exercise the fallback with verified active runtimes and no network.
    rm -f -- "${runtime_root}/update.lock"
    mkdir "${runtime_root}/update.lock"
    status=0
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null 2>&1 || status=$?
    [[ ${status} == 73 ]] || fail "unsafe lock path returned ${status}, expected 73"
    rmdir "${runtime_root}/update.lock"

    for ((iteration = 1; iteration <= CONTENTION_RUNS; iteration++)); do
        ready="${TEST_ROOT}/lock-ready-${iteration}"
        (
            exec 9>>"${runtime_root}/update.lock"
            flock --exclusive 9
            : >"${ready}"
            sleep 5
        ) &
        holder=$!
        HOLDER_PID=${holder}
        for _ in {1..250}; do
            [[ -e ${ready} ]] && break
            kill -0 -- "${holder}" 2>/dev/null \
                || fail "lock holder ${iteration} exited before publishing readiness"
            sleep 0.02
        done
        [[ -e ${ready} ]] \
            || fail "lock holder ${iteration} did not start within 5 seconds"
        MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null 2>"${TEST_ROOT}/lock-${iteration}.err" \
            || fail "contention fallback ${iteration} failed"
        grep -Fq 'another runtime update is in progress' "${TEST_ROOT}/lock-${iteration}.err" \
            || fail "contention diagnostic ${iteration} missing"

        if ((iteration == 1)); then
            MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null 2>"${TEST_ROOT}/lock-ensure.err" || fail 'ensure did not reuse valid active runtimes during lock contention'
            grep -Fq 'another runtime update is in progress; using the active verified runtimes.' "${TEST_ROOT}/lock-ensure.err" || fail 'ensure contention fallback diagnostic is missing'
        fi

        kill -TERM -- "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
        HOLDER_PID=''
    done
}

main() {
    initialize_runtime_hardening_workspace
    write_runtime_hardening_mocks
    initialize_runtime_hardening_fixtures
    test_runtime_setting_bounds
    test_runtime_command_and_lock_errors
    test_xdg_data_home_hardening
    test_bounded_runtime_probes
    test_oversized_deno_versions
    test_invalid_runtime_path
    test_mismatched_ytdlp_candidate
    test_mismatched_deno_candidate
    test_release_location_and_archive_hardening
    test_symlinked_managed_data_root
    test_signature_failure_bootstrap
    test_fresh_runtime_bootstrap
    test_no_network_require
    test_invalid_active_runtime_recovery
    test_runtime_updates
    test_repeated_rollbacks
    test_invalid_rollback_targets
    test_activation_journal_recovery
    test_runtime_lock_hardening

    printf 'Runtime-manager hardening integration passed.\n'
}

main "$@"

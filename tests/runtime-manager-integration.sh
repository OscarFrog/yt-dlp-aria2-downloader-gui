#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/runtime-manager-integration.sh
# Purpose     : Exercise normal runtime-manager installation and rollback behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
RUNTIME_MANAGER=${RUNTIME_MANAGER_UNDER_TEST:-${PROJECT_DIR}/runtime-manager.sh}
readonly RUNTIME_MANAGER
# shellcheck disable=SC1090 # Resolve the shared library from the repository root.
source "${PROJECT_DIR}/tests/lib/assert.sh"

TEST_ROOT=''
HOME_DIR=''
DATA_HOME=''
MOCK_BIN=''
CURL_LOG=''
PROBE_LOG=''
LOCK_LEAK_MARKER=''
runtime_root=''
ytdlp_root=''
deno_root=''
runtime_env=()

cleanup() {
    rm -rf -- "${TEST_ROOT}" || true
}

make_ytdlp() {
    local path=$1
    local version=$2
    mkdir -p -- "${path%/*}"
    cat >"${path}" <<EOF_YTDLP
#!/usr/bin/env bash
set -euo pipefail
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
[[ \${seen_ignore_config} == true && \${seen_no_plugin_dirs} == true &&
    \${seen_no_update} == true && \${YTDLP_NO_PLUGINS:-} == 1 ]] || exit 68
case \${operation} in
--version)
    [[ -z \${MOCK_RUNTIME_PROBE_LOG:-} ]] \
        || printf '%s\n' 'yt-dlp:--version' >>"\${MOCK_RUNTIME_PROBE_LOG}"
    printf '%s\\n' '${version}'
    ;;
--help)
    [[ -z \${MOCK_RUNTIME_PROBE_LOG:-} ]] \
        || printf '%s\n' 'yt-dlp:--help' >>"\${MOCK_RUNTIME_PROBE_LOG}"
    printf '%s\\n' \\
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
        '--socket-timeout SECONDS'
    ;;
--list-impersonate-targets)
    [[ -z \${MOCK_RUNTIME_PROBE_LOG:-} ]] \
        || printf '%s\n' 'yt-dlp:--list-impersonate-targets' >>"\${MOCK_RUNTIME_PROBE_LOG}"
    printf '%s\\n' 'Chrome-140 Linux curl_cffi'
    ;;
*)
    exit 64
    ;;
esac
EOF_YTDLP
    chmod 0755 -- "${path}"
}

make_deno() {
    local path=$1
    local version=$2
    mkdir -p -- "${path%/*}"
    cat >"${path}" <<EOF_DENO
#!/usr/bin/env bash
set -euo pipefail
case \${1:-} in
--version)
    [[ -z \${MOCK_RUNTIME_PROBE_LOG:-} ]] \
        || printf '%s\n' 'deno:--version' >>"\${MOCK_RUNTIME_PROBE_LOG}"
    printf '%s\\n' 'deno ${version} (stable, release, x86_64-unknown-linux-gnu)'
    printf '%s\\n' 'v8 0.0.0' 'typescript 0.0.0'
    ;;
upgrade)
    exit 7
    ;;
*)
    exit 64
    ;;
esac
EOF_DENO
    chmod 0755 -- "${path}"
}

prepare_runtime_manager_fixture() {
    local command_name

    for command_name in bash chmod env flock grep ln mkdir mktemp readlink rm timeout; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required test command is absent: %s\n' "${command_name}" >&2
            exit 127
        }
    done
    [[ -x ${RUNTIME_MANAGER} ]] || fail "runtime manager is not executable: ${RUNTIME_MANAGER}"

    TEST_ROOT=$(mktemp -d)
    readonly TEST_ROOT

    readonly HOME_DIR="${TEST_ROOT}/home"
    readonly DATA_HOME="${TEST_ROOT}/data"
    readonly MOCK_BIN="${TEST_ROOT}/bin"
    readonly CURL_LOG="${TEST_ROOT}/curl.args"
    readonly PROBE_LOG="${TEST_ROOT}/runtime-probes.log"
    readonly LOCK_LEAK_MARKER="${TEST_ROOT}/lock-leaked"
    mkdir -p -- "${HOME_DIR}" "${DATA_HOME}" "${MOCK_BIN}"

    cat >"${MOCK_BIN}/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_CURL_LOG:?}"
printf '%s\n' "$@" >>"${MOCK_CURL_LOG}"
for fd_path in /proc/$$/fd/*; do
    target=$(readlink -- "${fd_path}" 2>/dev/null || true)
    if [[ ${target} == */yt-dlp-aria2-downloader/runtime/update.lock ]]; then
        : >"${MOCK_LOCK_LEAK_MARKER:?}"
    fi
done
exit 7
EOF_CURL
    chmod 0755 -- "${MOCK_BIN}/curl"

    runtime_root="${DATA_HOME}/yt-dlp-aria2-downloader/runtime"
    ytdlp_root="${runtime_root}/yt-dlp"
    deno_root="${runtime_root}/deno"
    mkdir -p -- "${ytdlp_root}" "${deno_root}"
    make_ytdlp "${ytdlp_root}/2026.07.04/yt-dlp_linux" '2026.07.04'
    make_ytdlp "${ytdlp_root}/2026.06.09/yt-dlp_linux" '2026.06.09'
    make_deno "${deno_root}/2.9.5/deno" '2.9.5'
    make_deno "${deno_root}/2.8.0/deno" '2.8.0'
    ln -s -- '2026.07.04' "${ytdlp_root}/current"
    ln -s -- '2026.06.09' "${ytdlp_root}/previous"
    ln -s -- '2.9.5' "${deno_root}/current"
    ln -s -- '2.8.0' "${deno_root}/previous"

    runtime_env=(
        env
        HOME="${HOME_DIR}"
        XDG_DATA_HOME="${DATA_HOME}"
        PATH="${MOCK_BIN}:${PATH}"
        MOCK_CURL_LOG="${CURL_LOG}"
        MOCK_RUNTIME_PROBE_LOG="${PROBE_LOG}"
        MOCK_LOCK_LEAK_MARKER="${LOCK_LEAK_MARKER}"
        YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS=1
        YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS=2
        YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS=10
        YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS=10
        YTDLP_ARIA2_DENO_CHECK_TIMEOUT_SECONDS=5
        YTDLP_ARIA2_DENO_UPDATE_TIMEOUT_SECONDS=10
    )
}

test_runtime_paths_and_locking() {
    local attested_version=''
    local actual_deno actual_ytdlp expected_attestation expected_ytdlp
    local fallback_attestation lock_holder_pid lock_holder_ready
    local probe_count=0

    expected_ytdlp="${ytdlp_root}/2026.07.04/yt-dlp_linux"
    actual_ytdlp=$("${runtime_env[@]}" "${RUNTIME_MANAGER}" path yt-dlp)
    [[ ${actual_ytdlp} == "${expected_ytdlp}" ]] || fail 'managed yt-dlp path is incorrect'
    actual_deno=$("${runtime_env[@]}" "${RUNTIME_MANAGER}" path deno)
    [[ ${actual_deno} == "${deno_root}/2.9.5/deno" ]] || fail 'managed Deno path is incorrect'

    expected_attestation=$(printf \
        'runtime-contract=1\nyt-dlp-path=%s\nyt-dlp-version=2026.07.04\ndeno-path=%s\ndeno-version=2.9.5' \
        "${expected_ytdlp}" "${deno_root}/2.9.5/deno")
    : >"${CURL_LOG}"
    : >"${PROBE_LOG}"
    actual_ytdlp=$("${runtime_env[@]}" "${RUNTIME_MANAGER}" prepare require)
    assert_equals "${expected_attestation}" "${actual_ytdlp}" \
        'strict runtime preparation attestation'
    [[ ! -s ${CURL_LOG} ]] || fail 'prepare require invoked the network'
    probe_count=$(grep -Fxc -- 'yt-dlp:--version' "${PROBE_LOG}") \
        || probe_count=0
    assert_equals 1 "${probe_count}" \
        'prepare require yt-dlp version probe count'
    probe_count=$(grep -Fxc -- 'yt-dlp:--help' "${PROBE_LOG}") \
        || probe_count=0
    assert_equals 1 "${probe_count}" \
        'prepare require yt-dlp help probe count'
    probe_count=$(grep -Fxc -- 'yt-dlp:--list-impersonate-targets' "${PROBE_LOG}") \
        || probe_count=0
    assert_equals 1 "${probe_count}" \
        'prepare require yt-dlp impersonation probe count'
    probe_count=$(grep -Fxc -- 'deno:--version' "${PROBE_LOG}") \
        || probe_count=0
    assert_equals 1 "${probe_count}" \
        'prepare require Deno version probe count'

    # An attested path names the validated immutable version, not the mutable
    # activation link. A later rollback must not change what an existing engine
    # process will execute.
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
    attested_version=$(YTDLP_NO_PLUGINS=1 "${expected_ytdlp}" \
        --ignore-config --no-plugin-dirs --no-update --version) \
        || fail 'attested yt-dlp path could not execute after rollback'
    assert_equals '2026.07.04' "${attested_version}" \
        'attested yt-dlp path changed after rollback'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null

    # Read-only lookups must not wait behind an updater because current is an
    # atomically published symlink.
    lock_holder_ready="${TEST_ROOT}/lock-holder-ready"
    (
        exec 9>>"${runtime_root}/update.lock"
        flock --exclusive 9
        : >"${lock_holder_ready}"
        sleep 6
    ) &
    lock_holder_pid=$!
    for _ in {1..250}; do
        [[ -e ${lock_holder_ready} ]] && break
        kill -0 -- "${lock_holder_pid}" 2>/dev/null \
            || fail 'lock holder exited before publishing readiness'
        sleep 0.02
    done
    [[ -e ${lock_holder_ready} ]] || fail 'lock holder did not start within 5 seconds'
    timeout 2s "${runtime_env[@]}" "${RUNTIME_MANAGER}" path yt-dlp >/dev/null \
        || fail 'path lookup blocked behind the runtime update lock'

    # update has a bounded lock wait. With valid active runtimes it must fall back
    # to those verified runtimes instead of failing the application launch.
    fallback_attestation=$(
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" prepare update \
            2>"${TEST_ROOT}/lock-fallback.err"
    ) || fail 'prepare update did not fall back to active runtimes during lock contention'
    assert_equals "${expected_attestation}" "${fallback_attestation}" \
        'lock-contention runtime preparation attestation'
    grep -Fq -- 'another runtime update is in progress' "${TEST_ROOT}/lock-fallback.err" \
        || fail 'lock-contention fallback diagnostic is missing'
    kill -TERM -- "${lock_holder_pid}" 2>/dev/null || true
    wait "${lock_holder_pid}" 2>/dev/null || true

    if ! (
        exec 9>>"${runtime_root}/update.lock"
        flock --exclusive --nonblock 9
    ); then
        fail 'runtime update lock remained held after the lock holder stopped'
    fi
}

test_runtime_offline_and_rollback() {
    local curl_first_argument=''
    local required_curl_option

    # Network failure after bootstrap must preserve the verified active runtimes.
    : >"${CURL_LOG}"
    rm -f -- "${LOCK_LEAK_MARKER}"
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null 2>"${TEST_ROOT}/offline.err" \
        || fail 'offline update did not preserve verified active runtimes'
    assert_link_target "${ytdlp_root}/current" '2026.07.04' \
        'offline update changed the active yt-dlp runtime'
    assert_link_target "${deno_root}/current" '2.9.5' \
        'offline update changed the active Deno runtime'
    [[ ! -e ${LOCK_LEAK_MARKER} ]] \
        || fail 'runtime update lock leaked into the curl child process'
    for required_curl_option in --connect-timeout --max-time --retry-max-time; do
        grep -Fqx -- "${required_curl_option}" "${CURL_LOG}" \
            || fail "curl runtime bound is missing: ${required_curl_option}"
    done
    IFS= read -r curl_first_argument <"${CURL_LOG}" \
        || fail 'curl invocation log is empty'
    [[ ${curl_first_argument} == --disable ]] \
        || fail 'curl did not disable personal configuration before every other option'

    # previous is a real rollback target. Rollback swaps current/previous only after
    # validating the target runtime.
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
    assert_link_target "${ytdlp_root}/current" '2026.06.09' \
        'yt-dlp rollback did not activate the previous runtime'
    assert_link_target "${ytdlp_root}/previous" '2026.07.04' \
        'yt-dlp rollback did not preserve the replaced runtime'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback deno >/dev/null
    assert_link_target "${deno_root}/current" '2.8.0' \
        'Deno rollback did not activate the previous runtime'

    # A corrupted current runtime is recovered from a verified previous runtime.
    rm -f -- "${ytdlp_root}/current"
    ln -s -- '2026.07.04' "${ytdlp_root}/current"
    rm -f -- "${ytdlp_root}/previous"
    ln -s -- '2026.06.09' "${ytdlp_root}/previous"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${ytdlp_root}/2026.07.04/yt-dlp_linux"
    chmod 0755 -- "${ytdlp_root}/2026.07.04/yt-dlp_linux"
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null 2>"${TEST_ROOT}/rollback.err" \
        || fail 'invalid active yt-dlp runtime was not recovered from previous'
    assert_link_target "${ytdlp_root}/current" '2026.06.09' \
        'automatic yt-dlp rollback selected the wrong runtime'
}

test_runtime_bootstrap_and_architecture() {
    local aarch_bin aarch_data aarch_path empty_data

    # First bootstrap without a network and without existing runtimes must fail
    # rather than creating or activating an unverified placeholder.
    empty_data="${TEST_ROOT}/empty-data"
    mkdir -p -- "${empty_data}"
    if env HOME="${HOME_DIR}" XDG_DATA_HOME="${empty_data}" \
        PATH="${MOCK_BIN}:${PATH}" MOCK_CURL_LOG="${CURL_LOG}" \
        MOCK_LOCK_LEAK_MARKER="${LOCK_LEAK_MARKER}" \
        YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS=2 \
        YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS=10 \
        YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS=10 \
        "${RUNTIME_MANAGER}" update >/dev/null 2>&1; then
        fail 'initial offline bootstrap unexpectedly succeeded'
    fi
    [[ ! -L ${empty_data}/yt-dlp-aria2-downloader/runtime/yt-dlp/current ]] \
        || fail 'initial offline bootstrap published an unverified yt-dlp runtime'
    [[ ! -L ${empty_data}/yt-dlp-aria2-downloader/runtime/deno/current ]] \
        || fail 'initial offline bootstrap published an unverified Deno runtime'

    # Architecture mapping is tested hermetically for aarch64 without requiring an
    # ARM runner.
    aarch_data="${TEST_ROOT}/aarch-data"
    aarch_bin="${TEST_ROOT}/aarch-bin"
    mkdir -p -- "${aarch_data}/yt-dlp-aria2-downloader/runtime/yt-dlp/2026.07.04" \
        "${aarch_data}/yt-dlp-aria2-downloader/runtime/deno/2.9.5" "${aarch_bin}"
    make_ytdlp "${aarch_data}/yt-dlp-aria2-downloader/runtime/yt-dlp/2026.07.04/yt-dlp_linux_aarch64" '2026.07.04'
    make_deno "${aarch_data}/yt-dlp-aria2-downloader/runtime/deno/2.9.5/deno" '2.9.5'
    ln -s -- '2026.07.04' "${aarch_data}/yt-dlp-aria2-downloader/runtime/yt-dlp/current"
    ln -s -- '2.9.5' "${aarch_data}/yt-dlp-aria2-downloader/runtime/deno/current"
    cat >"${aarch_bin}/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
[[ ${1:-} == '-m' ]] || exit 64
printf '%s\n' aarch64
EOF_UNAME
    chmod 0755 -- "${aarch_bin}/uname"
    aarch_path=$(env HOME="${HOME_DIR}" XDG_DATA_HOME="${aarch_data}" \
        PATH="${aarch_bin}:${MOCK_BIN}:${PATH}" MOCK_CURL_LOG="${CURL_LOG}" \
        MOCK_LOCK_LEAK_MARKER="${LOCK_LEAK_MARKER}" \
        "${RUNTIME_MANAGER}" path yt-dlp)
    [[ ${aarch_path} == */2026.07.04/yt-dlp_linux_aarch64 ]] \
        || fail 'aarch64 yt-dlp asset mapping is incorrect'

}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    prepare_runtime_manager_fixture
    test_runtime_paths_and_locking
    test_runtime_offline_and_rollback
    test_runtime_bootstrap_and_architecture
    printf 'Runtime-manager integration passed.\n'
}

main "$@"

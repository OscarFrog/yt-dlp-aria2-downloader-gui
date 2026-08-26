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

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_link_target() {
    local link_path=$1
    local expected=$2
    local label=$3
    local actual=''

    if ! actual=$(readlink -- "${link_path}"); then
        fail "${label}: unable to read link ${link_path}"
    fi
    [[ ${actual} == "${expected}" ]] \
        || fail "${label}: expected ${expected}, found ${actual}"
}

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${HOLDER_PID} ]]; then
        kill -TERM -- "${HOLDER_PID}" 2>/dev/null || true
        wait "${HOLDER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
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
case \${1:-} in
--version) printf '%s\\n' '${version}' ;;
--help) printf '%s\\n' --break-match-filters --js-runtimes --list-impersonate-targets --no-update ;;
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
printf '%s\\n' 'deno ${version} (stable, release, test-target)' 'v8 0.0.0' 'typescript 0.0.0'
EOF_DENO
    chmod 0755 -- "${path}"
}

main() {
    for command_name in bash chmod env find flock grep ln mkdir mktemp readlink rm rmdir sed sha256sum sleep stat uname; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            printf 'Error: required test command is absent: %s\n' "${command_name}" >&2
            exit 127
        }
    done

    TEST_ROOT=$(mktemp -d)
    readonly TEST_ROOT
    HOLDER_PID=''
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
archive=${!#}
version=$(sed -n 's/^deno-archive=//p' "${archive}")
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
    printf 'https://github.com/yt-dlp/yt-dlp/releases/tag/%s' "${MOCK_YTDLP_STABLE_VERSION:?}"
    exit 0
fi
if [[ ${url} == 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest' ]]; then
    printf 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/tag/%s' "${MOCK_YTDLP_NIGHTLY_VERSION:?}"
    exit 0
fi
if [[ ${url} == 'https://github.com/denoland/deno/releases/latest' ]]; then
    printf 'https://github.com/denoland/deno/releases/tag/v%s' "${MOCK_DENO_LATEST_VERSION:?}"
    exit 0
fi
[[ -n ${output} ]] || exit 64
case ${url} in
*/yt-dlp/yt-dlp/releases/download/*/*|*/yt-dlp/yt-dlp-nightly-builds/releases/download/*/*)
    version=${url#*/releases/download/}; version=${version%%/*}; name=${url##*/}
    case ${name} in
    yt-dlp_linux|yt-dlp_linux_aarch64)
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
case \${1:-} in
--version) printf '%s\\n' '${version}' ;;
--help) printf '%s\\n' --break-match-filters --js-runtimes --list-impersonate-targets --no-update ;;
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
        MOCK_REQUIRE_NO_PROGRESS=1 MOCK_YTDLP_ASSET="${YTDLP_ASSET}"
        MOCK_YTDLP_STABLE_VERSION=2026.07.04 MOCK_YTDLP_NIGHTLY_VERSION=2026.08.20.123456
        MOCK_DENO_LATEST_VERSION=2.9.5 YTDLP_ARIA2_RUNTIME_LOCK_WAIT_SECONDS=1
        YTDLP_ARIA2_RUNTIME_CONNECT_TIMEOUT_SECONDS=2 YTDLP_ARIA2_RUNTIME_MAX_TIME_SECONDS=10
        YTDLP_ARIA2_RUNTIME_RETRY_MAX_TIME_SECONDS=10 YTDLP_ARIA2_RUNTIME_VALIDATE_TIMEOUT_SECONDS=5)

    # A completely empty managed-runtime tree must bootstrap both components.
    # This specifically exercises ensure_runtime -> bootstrap_ytdlp/bootstrap_deno,
    # rather than only the already-installed update paths.
    FRESH_DATA_HOME="${TEST_ROOT}/fresh-data"
    fresh_runtime_root="${FRESH_DATA_HOME}/yt-dlp-aria2-downloader/runtime"
    fresh_ytdlp_root="${fresh_runtime_root}/yt-dlp"
    fresh_deno_root="${fresh_runtime_root}/deno"

    # A fresh bootstrap must refuse a yt-dlp candidate whose signed manifest
    # cannot be verified. Import remains successful; only --verify is mutated.
    VERIFY_FAIL_DATA_HOME="${TEST_ROOT}/verify-fail-data"
    verify_fail_runtime_root="${VERIFY_FAIL_DATA_HOME}/yt-dlp-aria2-downloader/runtime"
    verify_fail_ytdlp_root="${verify_fail_runtime_root}/yt-dlp"
    verify_failure_status=0
    verify_failure_error=''
    unverified_candidates=''

    rm -rf -- "${VERIFY_FAIL_DATA_HOME}"
    verify_failure_error=$(
        "${runtime_env[@]}" \
            XDG_DATA_HOME="${VERIFY_FAIL_DATA_HOME}" \
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

    rm -rf -- "${FRESH_DATA_HOME}"
    : >"${URL_LOG}"
    : >"${GPGCONF_LOG}"
    : >"${YTDLP_EXEC_PATH_LOG}"
    rm -f -- "${FD_LEAK_MARKER}" "${NETWORK_MARKER}" "${YTDLP_NETWORK_MARKER}"

    "${runtime_env[@]}" \
        XDG_DATA_HOME="${FRESH_DATA_HOME}" \
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

    # Strict no-network require mode: both success and missing-runtime failure must
    # happen without invoking curl.
    rm -f -- "${NETWORK_MARKER}" "${URL_LOG}"
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" require
    [[ ! -e ${NETWORK_MARKER} ]] || fail 'require mode invoked the network'
    rm -f -- "${deno_root}/current"
    status=0
    MOCK_NETWORK_FORBIDDEN=1 "${runtime_env[@]}" "${RUNTIME_MANAGER}" require >/dev/null 2>&1 || status=$?
    [[ ${status} == 69 ]] || fail "missing-runtime require returned ${status}, expected 69"
    [[ ! -e ${NETWORK_MARKER} ]] || fail 'failed require mode invoked the network'
    ln -s 2.8.0 "${deno_root}/current"

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

    # Scenario group: exact-tag stable update, Deno update, nightly opt-in, then stable.
    : >"${URL_LOG}"
    rm -f -- "${FD_LEAK_MARKER}"
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.07.04 'stable update failed'
    assert_link_target "${deno_root}/current" 2.9.5 'Deno update failed'
    grep -Fq '/releases/download/2026.07.04/' "${URL_LOG}" || fail 'yt-dlp exact tag URL missing'
    grep -Fq '/releases/download/v2.9.5/' "${URL_LOG}" || fail 'Deno exact tag URL missing'
    ! grep -Fq '/releases/latest/download/' "${URL_LOG}" || fail 'latest/download TOCTOU path remains'
    [[ ! -e ${FD_LEAK_MARKER} ]] || fail 'runtime update lock leaked into a child process'

    YTDLP_ARIA2_YTDLP_CHANNEL=nightly "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.08.20.123456 'stable -> nightly failed'
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" update >/dev/null
    assert_link_target "${ytdlp_root}/current" 2026.07.04 'nightly -> stable failed'
    assert_link_target "${ytdlp_root}/previous" 2026.08.20.123456 'nightly rollback target missing'

    # Ten double-rollbacks must always return to the exact initial state.
    for ((iteration = 1; iteration <= 10; iteration++)); do
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
        assert_link_target "${ytdlp_root}/current" 2026.08.20.123456 "rollback A failed at ${iteration}"
        "${runtime_env[@]}" "${RUNTIME_MANAGER}" rollback yt-dlp >/dev/null
        assert_link_target "${ytdlp_root}/current" 2026.07.04 "rollback B failed at ${iteration}"
    done

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

    # Distinguish lock path errors (73) from contention (75), then stress the
    # contention fallback ten times with verified active runtimes and no network.
    rm -f -- "${runtime_root}/update.lock"
    mkdir "${runtime_root}/update.lock"
    status=0
    "${runtime_env[@]}" "${RUNTIME_MANAGER}" ensure >/dev/null 2>&1 || status=$?
    [[ ${status} == 73 ]] || fail "unsafe lock path returned ${status}, expected 73"
    rmdir "${runtime_root}/update.lock"

    for ((iteration = 1; iteration <= 10; iteration++)); do
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
        kill -TERM -- "${holder}" 2>/dev/null || true
        wait "${holder}" 2>/dev/null || true
        HOLDER_PID=''
    done

    printf 'Runtime-manager hardening integration passed.\n'

}

main "$@"

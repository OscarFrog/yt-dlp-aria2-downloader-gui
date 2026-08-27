#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video.sh
# Purpose     : Download one complete MKV video or the best native audio track.
# ==============================================================================

set -euo pipefail
umask 077

readonly VERSION="2.2.4"
readonly MIN_YT_DLP_VERSION="2026.06.09"
readonly MIN_ARIA2_VERSION="1.37.0"
readonly MIN_DENO_VERSION="2.3.0"
readonly SCRIPT_NAME="${0##*/}"
readonly YTDLP_NO_PLUGINS=1
export YTDLP_NO_PLUGINS
readonly PRIVATE_ARIA2_STAGING_MARKER='.yt-dlp-aria2-owner-v1'
readonly PRIVATE_ARIA2_STAGING_MARKER_VALUE='yt-dlp-aria2-private-staging-v1'

VERSION_AT_LEAST=false
VERSION_PARSE_VALID=false
ARIA2_SUPPORTS_NO_NETRC=false
JS_RUNTIME_AVAILABLE=false
RESULT_FILE_TMP=''
INTERNAL_PATH_FILE_TMP=''
HLS_REMUX_TMP=''
HLS_SOURCE_TO_CLEAN=''
YTDLP_BATCH_FILE_TMP=''
PRIVATE_ARIA2_STAGING=''
PRIVATE_ARIA2_PLAN=''
PRIVATE_ARIA2_COOKIE_JAR=''
PRIVATE_ARIA2_INPUT=''
PRIVATE_ARIA2_MANIFEST=''
OUTPUT_LOCK_FD=''
OUTPUT_LOCK_FILE=''
OUTPUT_LOCK_ROOT=''
DOWNLOAD_WORKER_PID=''
DOWNLOAD_WORKER_PGID=''
DOWNLOAD_PGID_FILE=''
DOWNLOAD_STATUS=125
REQUESTED_EXIT_STATUS=''
SHUTDOWN_REQUESTED=false
REUSE_CURRENT_SESSION=${YTDLP_ARIA2_SUPERVISED_SESSION:-false}
case ${REUSE_CURRENT_SESSION} in
    true | false) ;;
    *) REUSE_CURRENT_SESSION=false ;;
esac

cleanup() {
    local status=$?

    trap - EXIT HUP INT TERM
    trap '' HUP INT TERM

    if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]]; then
        if declare -F stop_download_worker >/dev/null 2>&1; then
            # shellcheck disable=SC2310 # Cleanup intentionally tolerates failure.
            stop_download_worker || true
        fi
    fi
    if [[ -n ${DOWNLOAD_PGID_FILE} ]]; then
        rm -f -- "${DOWNLOAD_PGID_FILE}" "${DOWNLOAD_PGID_FILE}.tmp" || true
    fi
    if [[ -n ${RESULT_FILE_TMP} ]]; then
        rm -f -- "${RESULT_FILE_TMP}" || true
    fi
    if [[ -n ${INTERNAL_PATH_FILE_TMP} ]]; then
        rm -f -- "${INTERNAL_PATH_FILE_TMP}" || true
    fi
    if [[ -n ${HLS_REMUX_TMP} ]]; then
        rm -f -- "${HLS_REMUX_TMP}" || true
    fi
    if [[ -n ${YTDLP_BATCH_FILE_TMP} ]]; then
        rm -f -- "${YTDLP_BATCH_FILE_TMP}" || true
    fi
    if [[ -n ${PRIVATE_ARIA2_STAGING} &&
        (-e ${PRIVATE_ARIA2_STAGING} || -L ${PRIVATE_ARIA2_STAGING}) ]]; then
        # shellcheck disable=SC2310 # Cleanup preserves staging that no longer validates.
        if ! remove_private_aria2_staging_candidate \
            "${PRIVATE_ARIA2_STAGING}" true; then
            printf 'Warning: preserving ambiguous active private aria2 staging directory: %s\n' \
                "${PRIVATE_ARIA2_STAGING##*/}" >&2
        fi
    fi
    if [[ -n ${OUTPUT_LOCK_FD} ]]; then
        flock --unlock "${OUTPUT_LOCK_FD}" 2>/dev/null || true
        exec {OUTPUT_LOCK_FD}>&- 2>/dev/null || true
    fi
    exit "${status}"
}

request_shutdown() {
    local signal_name=$1
    local exit_status=$2

    if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
        if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]] \
            && declare -F signal_download_worker >/dev/null 2>&1; then
            signal_download_worker KILL
        fi
        return 0
    fi

    SHUTDOWN_REQUESTED=true
    REQUESTED_EXIT_STATUS=${exit_status}
    if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]] \
        && declare -F signal_download_worker >/dev/null 2>&1; then
        signal_download_worker "${signal_name}"
        return 0
    fi

    exit "${exit_status}"
}

usage() {
    cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} [OPTIONS] VIDEO_URL

Options:
  -o, --output-dir DIR       Destination directory.
  -m, --mode MODE            video or audio (default: video).
                             video: complete best-quality video in MKV.
                             audio: best available audio track; preserve the
                                    source codec/container whenever possible.
      --machine-progress     Emit stable YTDLP_PLAN and progress records.
      --youtube-hls-firefox  For YouTube video mode, use Firefox cookies and
                             web_safari HLS formats before remuxing to MKV.
      --result-file FILE     Write the final media path to FILE.
      --url-file FILE        Read the single URL from a private regular file.
                             This avoids exposing it in the GUI process list.
  -h, --help                 Display this help.
  -V, --version              Display the version.

Examples:
  ${SCRIPT_NAME} 'https://example.com/video'
  ${SCRIPT_NAME} --output-dir "${HOME}/Videos" 'https://example.com/video'
  ${SCRIPT_NAME} --mode audio --output-dir "${HOME}/Music" 'https://example.com/video'
EOF_USAGE
}

error() {
    printf 'Error: %s\n' "$*" >&2
}

emit_machine_postprocess() {
    local status=$1
    local processor=$2

    if [[ ${MACHINE_PROGRESS} == true ]]; then
        printf 'YTDLP_POSTPROCESS|%s|%s\n' "${status}" "${processor}"
    fi
}

normalize_decimal_component() {
    local output_variable=$1
    local value=$2

    # Strip all leading zeroes without converting the external decimal string.
    # Bash arithmetic uses fixed-width integers, so conversion must happen only
    # after a caller has proved that the value is representable.
    value=${value#"${value%%[!0]*}"}
    [[ -n ${value} ]] || value=0
    printf -v "${output_variable}" '%s' "${value}"
}

compare_decimal_components() {
    local output_variable=$1
    local left=$2
    local right=$3
    local result=0
    local LC_ALL=C

    if ((${#left} > ${#right})); then
        result=1
    elif ((${#left} < ${#right})); then
        result=-1
    elif [[ ${left} > ${right} ]]; then
        result=1
    elif [[ ${left} < ${right} ]]; then
        result=-1
    fi

    printf -v "${output_variable}" '%d' "${result}"
}

compare_versions() {
    local current=$1
    local minimum=$2
    local current_triplet=''
    local current_major=''
    local current_minor=''
    local current_patch=''
    local current_suffix=''
    local current_is_prerelease=false
    local minimum_major=''
    local minimum_minor=''
    local minimum_patch=''
    local major_comparison=0
    local minor_comparison=0
    local patch_comparison=0

    VERSION_AT_LEAST=false
    VERSION_PARSE_VALID=false

    # Installed versions may contain a suffix; the configured minimum below
    # must remain a strict three-component version. Components stay as decimal
    # strings until their mathematical order has been established.
    if [[ ! ${current} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        return 0
    fi
    current_triplet=${BASH_REMATCH[0]}
    normalize_decimal_component current_major "${BASH_REMATCH[1]}"
    normalize_decimal_component current_minor "${BASH_REMATCH[2]}"
    normalize_decimal_component current_patch "${BASH_REMATCH[3]}"
    current_suffix=${current#"${current_triplet}"}
    if [[ ${current_suffix} =~ ^-(alpha|beta|pre|preview|rc)([.0-9-]|$) ]]; then
        current_is_prerelease=true
    fi

    if [[ ! ${minimum} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 0
    fi
    normalize_decimal_component minimum_major "${BASH_REMATCH[1]}"
    normalize_decimal_component minimum_minor "${BASH_REMATCH[2]}"
    normalize_decimal_component minimum_patch "${BASH_REMATCH[3]}"
    VERSION_PARSE_VALID=true

    compare_decimal_components major_comparison "${current_major}" "${minimum_major}"
    compare_decimal_components minor_comparison "${current_minor}" "${minimum_minor}"
    compare_decimal_components patch_comparison "${current_patch}" "${minimum_patch}"

    if [[ ${current_is_prerelease} == true ]] \
        && ((major_comparison == 0 && minor_comparison == 0 && patch_comparison == 0)); then
        return 0
    fi

    if ((major_comparison > 0 || (major_comparison == 0 && minor_comparison > 0) || (\
        major_comparison == 0 && minor_comparison == 0 && patch_comparison >= 0))); then
        VERSION_AT_LEAST=true
    fi
}

check_runtime_compatibility() {
    local yt_dlp_version
    local deno_name=''
    local deno_version=''
    local deno_output=''
    local _=''
    local yt_dlp_help
    local aria2_version_line
    local aria2_version
    local aria2_help
    local required_option
    local setsid_help

    if ! yt_dlp_version=$(LC_ALL=C "${YTDLP_BIN}" --version 2>/dev/null); then
        error 'unable to determine the yt-dlp version.'
        return 1
    fi
    yt_dlp_version=${yt_dlp_version%%$'\n'*}
    compare_versions "${yt_dlp_version}" "${MIN_YT_DLP_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the yt-dlp version: ${yt_dlp_version:-unknown}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "yt-dlp ${MIN_YT_DLP_VERSION} or later is required; found ${yt_dlp_version}."
        return 1
    fi

    JS_RUNTIME_AVAILABLE=false
    if [[ -n ${DENO_BIN:-} && -x ${DENO_BIN} ]] \
        && deno_output=$(LC_ALL=C "${DENO_BIN}" --version 2>/dev/null); then
        IFS=' ' read -r deno_name deno_version _ <<<"${deno_output%%$'\n'*}"
        if [[ ${deno_name} == deno && -n ${deno_version} ]]; then
            compare_versions "${deno_version}" "${MIN_DENO_VERSION}"
            if [[ ${VERSION_PARSE_VALID} == true && ${VERSION_AT_LEAST} == true ]]; then
                JS_RUNTIME_AVAILABLE=true
            fi
        fi
    fi
    if [[ ${IS_YOUTUBE_URL} == true && ${JS_RUNTIME_AVAILABLE} != true ]]; then
        error "Deno ${MIN_DENO_VERSION} or later is required for YouTube extraction."
        return 1
    fi

    if ! yt_dlp_help=$(LC_ALL=C "${YTDLP_BIN}" --help 2>&1); then
        error 'unable to inspect yt-dlp capabilities.'
        return 1
    fi
    for required_option in \
        --cookies-from-browser \
        --extractor-args \
        --print \
        --progress-template \
        --progress-delta \
        --print-to-file \
        --parse-metadata \
        --cookies \
        --dump-single-json \
        --load-info-json \
        --no-clean-info-json \
        --skip-download \
        --fixup \
        --batch-file \
        --socket-timeout \
        --retries \
        --fragment-retries \
        --extractor-retries \
        --retry-sleep \
        --no-overwrites \
        --no-post-overwrites \
        --break-match-filters \
        --no-update; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" <<<"${yt_dlp_help}"; then
            error "this yt-dlp build does not support ${required_option}."
            return 1
        fi
    done
    if [[ ${JS_RUNTIME_AVAILABLE} == true ]]; then
        required_option='--js-runtimes'
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" <<<"${yt_dlp_help}"; then
            error "this yt-dlp build does not support ${required_option}."
            return 1
        fi
    fi

    if ! aria2_version_line=$(LC_ALL=C aria2c --version 2>/dev/null); then
        error 'unable to determine the aria2c version.'
        return 1
    fi
    aria2_version_line=${aria2_version_line%%$'\n'*}
    if [[ ! ${aria2_version_line} =~ ^aria2[[:space:]]+version[[:space:]]+([^[:space:]]+) ]]; then
        error "unable to parse the aria2c version: ${aria2_version_line:-unknown}."
        return 1
    fi
    aria2_version=${BASH_REMATCH[1]}
    compare_versions "${aria2_version}" "${MIN_ARIA2_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the aria2c version: ${aria2_version}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "aria2c ${MIN_ARIA2_VERSION} or later is required; found ${aria2_version}."
        return 1
    fi

    if ! aria2_help=$(LC_ALL=C aria2c --help=#all 2>&1); then
        error 'unable to inspect aria2c capabilities.'
        return 1
    fi
    for required_option in \
        --file-allocation \
        --no-conf \
        --input-file \
        --dir \
        --load-cookies \
        --allow-overwrite \
        --max-concurrent-downloads \
        --auto-file-renaming \
        --enable-color \
        --truncate-console-readout \
        --summary-interval \
        --show-console-readout \
        --stderr; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|\[|$)" \
            <<<"${aria2_help}"; then
            error "this aria2c build does not support ${required_option}."
            return 1
        fi
    done

    ARIA2_SUPPORTS_NO_NETRC=false
    if grep -Eq -- \
        '^[[:space:]]*(-[^,[:space:]]+,[[:space:]]+)?--no-netrc([=[:space:]]|\[|$)' \
        <<<"${aria2_help}"; then
        ARIA2_SUPPORTS_NO_NETRC=true
    fi

    if ! setsid_help=$(LC_ALL=C setsid --help 2>&1); then
        error 'unable to inspect setsid capabilities.'
        return 1
    fi
    for required_option in --fork --wait; do
        if ! grep -Eq -- \
            "^[[:space:]]*(-[^[:space:]]+,[[:space:]]+)?${required_option}([=[:space:]]|$)" \
            <<<"${setsid_help}"; then
            error "this version of setsid does not support ${required_option}."
            return 1
        fi
    done
}

require_value() {
    local option_name=$1
    local option_value=${2-}

    if [[ -z ${option_value} ]]; then
        error "option ${option_name} requires a value."
        exit 2
    fi
}

resolve_lock_root() {
    local candidate=''
    local owner=''
    local mode=''

    if [[ -n ${XDG_RUNTIME_DIR:-} && ${XDG_RUNTIME_DIR} == /* &&
        -d ${XDG_RUNTIME_DIR} && ! -L ${XDG_RUNTIME_DIR} ]]; then
        owner=$(stat -c '%u' -- "${XDG_RUNTIME_DIR}" 2>/dev/null || true)
        mode=$(stat -c '%a' -- "${XDG_RUNTIME_DIR}" 2>/dev/null || true)
        if [[ ${owner} == "${EUID}" && ${mode} == 700 ]]; then
            candidate="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"
        fi
    fi

    if [[ -z ${candidate} ]]; then
        candidate="/tmp/yt-dlp-aria2-downloader-${EUID}"
    fi

    if mkdir -m 700 -- "${candidate}" 2>/dev/null; then
        :
    elif [[ ! -d ${candidate} || -L ${candidate} ]]; then
        error 'the download-lock path exists but is not a safe directory.'
        return 73
    fi

    owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null || true)
    if [[ ${owner} != "${EUID}" ]]; then
        error 'the download-lock directory is not owned by the current user.'
        return 73
    fi
    if ! chmod 700 -- "${candidate}"; then
        error 'unable to secure the download-lock directory.'
        return 73
    fi

    OUTPUT_LOCK_ROOT=${candidate}
    return 0
}

acquire_output_lock() {
    local output_dir=$1
    local lock_key

    resolve_lock_root

    if ! lock_key=$(printf '%s\0' "${output_dir}" | sha256sum); then
        error 'unable to derive the destination lock identifier.'
        return 73
    fi
    lock_key=${lock_key%% *}
    if [[ ! ${lock_key} =~ ^[[:xdigit:]]{64}$ ]]; then
        error 'invalid destination lock identifier.'
        return 73
    fi

    OUTPUT_LOCK_FILE="${OUTPUT_LOCK_ROOT}/${lock_key}.lock"
    if [[ -L ${OUTPUT_LOCK_FILE} ||
        (-e ${OUTPUT_LOCK_FILE} && ! -f ${OUTPUT_LOCK_FILE}) ]]; then
        error 'the destination lock exists but is not a regular file.'
        return 73
    fi
    if ! exec {OUTPUT_LOCK_FD}>>"${OUTPUT_LOCK_FILE}"; then
        error 'unable to open the destination lock.'
        return 73
    fi
    if ! chmod 600 -- "${OUTPUT_LOCK_FILE}"; then
        error 'unable to secure the destination lock.'
        return 73
    fi
    if ! flock --exclusive --nonblock "${OUTPUT_LOCK_FD}"; then
        error "another download is already using the destination directory: ${output_dir}"
        return 75
    fi

    return 0
}

process_is_running() {
    local pid=$1
    local process_stat=''
    local process_state=''

    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "${pid}" 2>/dev/null || return 1

    if [[ -r /proc/${pid}/stat ]]; then
        if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
            return 0
        fi
        process_state=${process_stat##*) }
        process_state=${process_state%% *}
        [[ ${process_state} != Z && ${process_state} != X ]]
        return
    fi

    return 0
}

recover_download_pgid() {
    local candidate=''
    local children=''
    local children_file=''
    local -a child_pids=()

    if [[ -n ${DOWNLOAD_PGID_FILE} && -f ${DOWNLOAD_PGID_FILE} ]]; then
        if { IFS= read -r candidate <"${DOWNLOAD_PGID_FILE}"; } 2>/dev/null \
            && [[ ${candidate} =~ ^[1-9][0-9]*$ ]] \
            && kill -0 -- "-${candidate}" 2>/dev/null; then
            DOWNLOAD_WORKER_PGID=${candidate}
            return 0
        fi
    fi

    if [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
        children_file="/proc/${DOWNLOAD_WORKER_PID}/task/${DOWNLOAD_WORKER_PID}/children"
        if [[ -r ${children_file} ]] \
            && { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } 2>/dev/null; then
            read -r -a child_pids <<<"${children}"
            for candidate in "${child_pids[@]}"; do
                [[ ${candidate} =~ ^[1-9][0-9]*$ ]] || continue
                if kill -0 -- "-${candidate}" 2>/dev/null; then
                    DOWNLOAD_WORKER_PGID=${candidate}
                    return 0
                fi
            done
        fi
    fi

    return 1
}

signal_download_worker() {
    local signal_name=$1
    local group_signaled=false

    # When the GUI already created the session, the entire outer process group
    # receives its signal directly. Avoid signaling our own group recursively;
    # target the direct child only as a best-effort fallback.
    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
        if [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
            kill "-${signal_name}" -- "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
        fi
        return 0
    fi

    if [[ -z ${DOWNLOAD_WORKER_PGID} ]]; then
        # shellcheck disable=SC2310 # A missing PGID is an expected race.
        recover_download_pgid || true
    fi

    if [[ -n ${DOWNLOAD_WORKER_PGID} ]]; then
        if kill "-${signal_name}" -- "-${DOWNLOAD_WORKER_PGID}" 2>/dev/null; then
            group_signaled=true
        else
            DOWNLOAD_WORKER_PGID=''
        fi
    fi

    if [[ ${signal_name} == KILL || ${group_signaled} == false ]] \
        && [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
        kill "-${signal_name}" -- "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
    fi

    return 0
}

wait_for_download_pgid() {
    local attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        # shellcheck disable=SC2310 # Predicate success means the PGID is ready.
        if recover_download_pgid; then
            return 0
        fi
        # shellcheck disable=SC2310 # Predicate failure means the supervisor exited.
        if [[ -n ${DOWNLOAD_WORKER_PID} ]] \
            && ! process_is_running "${DOWNLOAD_WORKER_PID}"; then
            return 1
        fi
        sleep 0.1
    done

    return 1
}

wait_for_download_exit() {
    local attempts=$1
    local attempt
    local supervisor_alive=false
    local group_alive=false

    for ((attempt = 0; attempt < attempts; attempt++)); do
        supervisor_alive=false
        group_alive=false

        if [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
            # shellcheck disable=SC2310 # Predicate success means it is still alive.
            if process_is_running "${DOWNLOAD_WORKER_PID}"; then
                supervisor_alive=true
            else
                wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
                DOWNLOAD_WORKER_PID=''
            fi
        fi

        if [[ -n ${DOWNLOAD_WORKER_PGID} ]]; then
            if kill -0 -- "-${DOWNLOAD_WORKER_PGID}" 2>/dev/null; then
                group_alive=true
            else
                DOWNLOAD_WORKER_PGID=''
            fi
        fi

        if [[ ${supervisor_alive} == false && ${group_alive} == false ]]; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

stop_download_worker() {
    if [[ -z ${DOWNLOAD_WORKER_PID} && -z ${DOWNLOAD_WORKER_PGID} ]]; then
        return 0
    fi

    signal_download_worker TERM
    # shellcheck disable=SC2310 # Bounded wait is intentionally a predicate.
    if wait_for_download_exit 30; then
        return 0
    fi

    signal_download_worker KILL
    wait_for_download_exit 20
}

run_supervised_command() {
    local worker_status=0
    local -a worker_command=("$@")

    DOWNLOAD_STATUS=125
    DOWNLOAD_WORKER_PID=''
    DOWNLOAD_WORKER_PGID=''
    DOWNLOAD_PGID_FILE=''

    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
        # The GUI has already placed this engine and every descendant in one
        # dedicated session. Do not create a nested session that the GUI could
        # lose after an emergency SIGKILL of this wrapper.
        LC_ALL=C "${worker_command[@]}" &
        DOWNLOAD_WORKER_PID=$!
    else
        if ! DOWNLOAD_PGID_FILE=$(mktemp \
            --tmpdir="${OUTPUT_LOCK_ROOT}" \
            '.worker-pgid.XXXXXXXX'); then
            error 'unable to create the command process-group file.'
            return 0
        fi

        # Standalone CLI mode needs its own session so signals sent only to the
        # wrapper PID can be relayed to the complete command tree.
        # shellcheck disable=SC2016
        LC_ALL=C setsid --fork --wait bash -c '
            set -euo pipefail
            pgid_file=$1
            shift
            pgid_temporary="${pgid_file}.tmp"
            printf "%s\n" "$$" >"${pgid_temporary}" || exit 125
            mv -Tf -- "${pgid_temporary}" "${pgid_file}" || exit 125
            exec "$@"
        ' bash "${DOWNLOAD_PGID_FILE}" "${worker_command[@]}" &
        DOWNLOAD_WORKER_PID=$!

        # A command may fail before the PGID probe observes its group. Preserve
        # the real command status instead of converting a legitimate fast
        # failure into the internal startup status 125.
        # shellcheck disable=SC2310
        if ! wait_for_download_pgid; then
            worker_status=0
            # shellcheck disable=SC2310
            if ! process_is_running "${DOWNLOAD_WORKER_PID}"; then
                wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || worker_status=$?
                DOWNLOAD_WORKER_PID=''
                DOWNLOAD_WORKER_PGID=''
                DOWNLOAD_STATUS=${worker_status}
                rm -f -- \
                    "${DOWNLOAD_PGID_FILE}" \
                    "${DOWNLOAD_PGID_FILE}.tmp" || true
                DOWNLOAD_PGID_FILE=''
                return 0
            fi

            if [[ ${SHUTDOWN_REQUESTED} != true ]]; then
                error 'unable to determine the command process group.'
            fi
            # shellcheck disable=SC2310
            stop_download_worker || true
            if [[ -n ${REQUESTED_EXIT_STATUS} ]]; then
                DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS}
            fi
            rm -f -- \
                "${DOWNLOAD_PGID_FILE}" \
                "${DOWNLOAD_PGID_FILE}.tmp" || true
            DOWNLOAD_PGID_FILE=''
            return 0
        fi
    fi

    worker_status=0
    wait "${DOWNLOAD_WORKER_PID}" || worker_status=$?

    if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
        # shellcheck disable=SC2310
        if ! wait_for_download_exit 100; then
            signal_download_worker KILL
            # shellcheck disable=SC2310
            wait_for_download_exit 30 || true
        fi
        DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS:-143}
    else
        DOWNLOAD_WORKER_PID=''
        DOWNLOAD_WORKER_PGID=''
        DOWNLOAD_STATUS=${worker_status}
    fi

    if [[ -n ${DOWNLOAD_PGID_FILE} ]]; then
        rm -f -- \
            "${DOWNLOAD_PGID_FILE}" \
            "${DOWNLOAD_PGID_FILE}.tmp" || true
        DOWNLOAD_PGID_FILE=''
    fi
    return 0
}

private_aria2_staging_candidate_is_safe() {
    local candidate=$1
    local require_marker=$2
    local candidate_name=${candidate##*/}
    local candidate_owner=''
    local candidate_mode=''
    local candidate_parent=''
    local entry=''
    local entry_name=''
    local entry_owner=''
    local entry_mode=''
    local marker_value=''
    local marker_size=''
    local marker_seen=false
    local legacy_plan_seen=false
    local legacy_cookie_seen=false

    [[ ${candidate_name} =~ ^[.]yt-dlp-aria2[.][A-Za-z0-9]{8}$ ]] || return 1
    [[ ! -L ${candidate} && -d ${candidate} ]] || return 1

    candidate_owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null) || return 1
    candidate_mode=$(stat -c '%a' -- "${candidate}" 2>/dev/null) || return 1
    [[ ${candidate_owner} == "${EUID}" && ${candidate_mode} == 700 ]] || return 1

    candidate_parent=$(realpath -e -- "${candidate}/.." 2>/dev/null) || return 1
    [[ ${candidate_parent} == "${OUTPUT_DIR}" ]] || return 1

    while IFS= read -r -d '' entry; do
        entry_name=${entry##*/}
        [[ ! -L ${entry} && -f ${entry} ]] || return 1

        entry_owner=$(stat -c '%u' -- "${entry}" 2>/dev/null) || return 1
        entry_mode=$(stat -c '%a' -- "${entry}" 2>/dev/null) || return 1
        [[ ${entry_owner} == "${EUID}" && ${entry_mode} == 600 ]] || return 1

        case ${entry_name} in
            "${PRIVATE_ARIA2_STAGING_MARKER}")
                [[ ${require_marker} == true && ${marker_seen} == false ]] || return 1
                marker_size=$(stat -c '%s' -- "${entry}" 2>/dev/null) || return 1
                [[ ${marker_size} == "$((${#PRIVATE_ARIA2_STAGING_MARKER_VALUE} + 1))" ]] \
                    || return 1
                marker_value=''
                IFS= read -r marker_value <"${entry}" || return 1
                [[ ${marker_value} == "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" ]] \
                    || return 1
                marker_seen=true
                ;;
            plan.json)
                legacy_plan_seen=true
                ;;
            cookies.txt)
                legacy_cookie_seen=true
                ;;
            aria2.input | manifest.json | \
                item-[0-9][0-9][0-9].download | \
                item-[0-9][0-9][0-9].download.aria2)
                ;;
            *)
                return 1
                ;;
        esac
    done < <(
        find "${candidate}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true
    )

    if [[ ${require_marker} == true ]]; then
        [[ ${marker_seen} == true ]]
    else
        [[ ${marker_seen} == false &&
            ${legacy_plan_seen} == true &&
            ${legacy_cookie_seen} == true ]]
    fi
}

remove_private_aria2_staging_candidate() {
    local candidate=$1
    local require_marker=$2
    local entry=''

    # shellcheck disable=SC2310 # Predicate explicitly handles failures; validation failure stops deletion.
    private_aria2_staging_candidate_is_safe "${candidate}" "${require_marker}" \
        || return 1

    while IFS= read -r -d '' entry; do
        [[ ! -L ${entry} && -f ${entry} ]] || return 1
        rm -f -- "${entry}" || return 1
    done < <(
        find "${candidate}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true
    )

    rmdir -- "${candidate}"
}

recover_abandoned_private_aria2_staging() {
    local candidate=''
    local marker_path=''
    local require_marker=false

    while IFS= read -r -d '' candidate; do
        require_marker=false
        marker_path="${candidate}/${PRIVATE_ARIA2_STAGING_MARKER}"

        if [[ -e ${marker_path} || -L ${marker_path} ]]; then
            require_marker=true
        fi

        # shellcheck disable=SC2310 # Validation failure is the preserve path.
        if private_aria2_staging_candidate_is_safe \
            "${candidate}" "${require_marker}"; then
            if ! remove_private_aria2_staging_candidate \
                "${candidate}" "${require_marker}"; then
                printf 'Warning: unable to remove validated private aria2 staging: %s\n' \
                    "${candidate##*/}" >&2
            fi
        else
            printf 'Warning: preserving ambiguous private aria2 staging directory: %s\n' \
                "${candidate##*/}" >&2
        fi
    done < <(
        find "${OUTPUT_DIR}" \
            -mindepth 1 -maxdepth 1 \
            -name '.yt-dlp-aria2.????????' \
            -print0 2>/dev/null || true
    )
}

cleanup_stale_temporary_files() {
    local stale_file
    local -a stale_files=()

    while IFS= read -r -d '' stale_file; do
        stale_files+=("${stale_file}")
    done < <(
        # Stale-file cleanup is best-effort. An inaccessible destination must
        # not abort an otherwise valid download session.
        find "${OUTPUT_DIR}" -maxdepth 1 -type f -uid "${EUID}" \
            \( -name '.yt-dlp-remux.*.mkv' -o -name '.yt-dlp-path.*' \) \
            -mmin +1440 -print0 2>/dev/null || true
    )
    if ((${#stale_files[@]} > 0)); then
        rm -f -- "${stale_files[@]}" || true
    fi
}

probe_stream() {
    local output_variable=$1
    local final_path=$2
    local stream_selector=$3
    local probe_output=''
    local detected_present=false

    # Initialize the caller-visible result before probing so an ffprobe
    # failure cannot leave a stale result from a previous stream selector.
    printf -v "${output_variable}" '%s' false
    if ! probe_output=$(
        timeout --signal=TERM --kill-after=2s 15s \
            ffprobe -v error \
            -select_streams "${stream_selector}" \
            -show_entries stream=index \
            -of csv=p=0 \
            "${final_path}" 2>/dev/null
    ); then
        return 1
    fi
    if grep -Eq '^[0-9]+$' <<<"${probe_output}"; then
        detected_present=true
    fi

    # Bash variables are dynamically scoped. The callee must not declare a
    # local variable with the caller-provided output name, otherwise printf -v
    # updates the callee's shadowing variable instead of the caller's result.
    printf -v "${output_variable}" '%s' "${detected_present}"
    return 0
}

probe_duration_microseconds() {
    local output_variable=$1
    local media_path=$2
    local duration=''
    local seconds=''
    local fraction=''
    local duration_microseconds=''
    local seconds_bound_comparison=1

    if duration=$(
        timeout --signal=TERM --kill-after=2s 15s \
            ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "${media_path}" 2>/dev/null
    ); then
        duration=${duration%%$'\n'*}
        if [[ ${duration} =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
            seconds=${BASH_REMATCH[1]}
            fraction=${BASH_REMATCH[3]:-0}
            fraction="${fraction}000000"
            fraction=${fraction:0:6}
            normalize_decimal_component seconds "${seconds}"
            compare_decimal_components \
                seconds_bound_comparison "${seconds}" '9000000000000'
            if ((seconds_bound_comparison <= 0)); then
                duration_microseconds=$((\
                    10#${seconds} * 1000000 + 10#${fraction}))
            fi
        fi
    fi

    printf -v "${output_variable}" '%s' "${duration_microseconds}"
    return 0
}

validate_stream_tail_reaches_target() {
    local media_path=$1
    local selector=$2
    local seek_seconds=$3
    local target_seconds=$4
    local -a probe_statuses=()

    # Exit status contract:
    #   0 = the selected stream reaches the acceptance threshold
    #   1 = probe succeeded but the selected stream ends before the threshold
    #   2 = FFprobe/parser failure; fail closed
    LC_ALL=C timeout --signal=TERM --kill-after=2s 15s \
        ffprobe -v error \
        -read_intervals "${seek_seconds}%" \
        -select_streams "${selector}" \
        -show_packets \
        -show_entries packet=pts_time,dts_time,duration_time \
        -of json \
        "${media_path}" 2>/dev/null \
        | python3 -c '
import json
import sys
from decimal import Decimal, InvalidOperation

threshold = Decimal(sys.argv[1])
try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)

for packet in payload.get("packets", []):
    raw_timestamp = packet.get("pts_time")
    if raw_timestamp in (None, "N/A"):
        raw_timestamp = packet.get("dts_time")
    if raw_timestamp in (None, "N/A"):
        continue

    try:
        timestamp = Decimal(str(raw_timestamp))
    except (InvalidOperation, ValueError):
        continue
    if not timestamp.is_finite():
        continue

    packet_duration = Decimal(0)
    raw_duration = packet.get("duration_time")
    if raw_duration not in (None, "N/A"):
        try:
            candidate = Decimal(str(raw_duration))
            if candidate.is_finite() and candidate > 0:
                packet_duration = candidate
        except (InvalidOperation, ValueError):
            pass

    if timestamp + packet_duration >= threshold:
        raise SystemExit(0)

raise SystemExit(1)
' "${target_seconds}"

    probe_statuses=("${PIPESTATUS[@]}")
    if ((${#probe_statuses[@]} != 2 || probe_statuses[0] != 0)); then
        return 2
    fi

    case ${probe_statuses[1]} in
        0 | 1) return "${probe_statuses[1]}" ;;
        *) return 2 ;;
    esac
}

validate_media_tail_consistency() {
    local media_path=$1
    local mode=$2
    local timeline=''
    local start_microseconds=''
    local duration_microseconds=''
    local tolerance_microseconds=0
    local target_microseconds=0
    local seek_microseconds=0
    local max_positive_start=0
    local target_seconds=''
    local seek_seconds=''
    local timeline_status=0
    local tail_probe_status=0

    timeline=$(
        timeout --signal=TERM --kill-after=2s 15s \
            ffprobe -v error \
            -show_entries format=start_time,duration \
            -of json \
            "${media_path}" 2>/dev/null \
            | python3 -c '
import json
import sys
from decimal import Decimal, InvalidOperation

try:
    payload = json.load(sys.stdin)
    format_info = payload.get("format") or {}
    start = Decimal(str(format_info["start_time"]))
    duration = Decimal(str(format_info["duration"]))
except (KeyError, TypeError, ValueError, InvalidOperation, json.JSONDecodeError):
    raise SystemExit(0)

limit = Decimal("9000000000000")
if (
    not start.is_finite()
    or not duration.is_finite()
    or duration <= 0
    or abs(start) > limit
    or duration > limit
):
    raise SystemExit(0)

scale = Decimal(1000000)
print(int(start * scale), int(duration * scale))
'
    )
    timeline_status=$?
    ((timeline_status == 0)) || return 1

    [[ -n ${timeline} ]] || return 0
    read -r start_microseconds duration_microseconds <<<"${timeline}"
    [[ ${start_microseconds} =~ ^-?[0-9]+$ ]] || return 0
    [[ ${duration_microseconds} =~ ^[0-9]+$ ]] || return 0

    tolerance_microseconds=$((duration_microseconds / 50))
    if ((tolerance_microseconds < 1000000)); then
        tolerance_microseconds=1000000
    fi
    if ((duration_microseconds <= tolerance_microseconds)); then
        return 0
    fi

    target_microseconds=$((duration_microseconds - tolerance_microseconds))

    if ((start_microseconds > 0)); then
        max_positive_start=$((9000000000000000000 - target_microseconds))
        if ((start_microseconds > max_positive_start)); then
            return 0
        fi
    fi
    target_microseconds=$((start_microseconds + target_microseconds))
    if ((target_microseconds <= 0)); then
        return 0
    fi

    seek_microseconds=$((target_microseconds - 10000000))
    if ((seek_microseconds < 0)); then
        seek_microseconds=0
    fi

    printf -v target_seconds '%d.%06d' \
        "$((target_microseconds / 1000000))" \
        "$((target_microseconds % 1000000))"
    printf -v seek_seconds '%d.%06d' \
        "$((seek_microseconds / 1000000))" \
        "$((seek_microseconds % 1000000))"

    case ${mode} in
        video)
            validate_stream_tail_reaches_target \
                "${media_path}" 'V:0' "${seek_seconds}" "${target_seconds}"
            tail_probe_status=$?
            case ${tail_probe_status} in
                0) return 0 ;;
                1) ;;
                *) return 1 ;;
            esac

            validate_stream_tail_reaches_target \
                "${media_path}" 'a:0' "${seek_seconds}" "${target_seconds}"
            tail_probe_status=$?
            ((tail_probe_status == 0)) || return 1
            return 0
            ;;
        audio)
            validate_stream_tail_reaches_target \
                "${media_path}" 'a:0' "${seek_seconds}" "${target_seconds}"
            tail_probe_status=$?
            ((tail_probe_status == 0)) || return 1
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_final_media_file() {
    local final_path=$1
    local mode=$2
    local stream_present=false
    local probe_status=0
    local tail_status=0

    [[ -f ${final_path} && -s ${final_path} ]] || return 1

    case ${mode} in
        video)
            probe_stream stream_present "${final_path}" 'V:0'
            probe_status=$?
            ((probe_status == 0)) || return 1
            [[ ${stream_present} == true ]] || return 1
            probe_stream stream_present "${final_path}" 'a:0'
            probe_status=$?
            ((probe_status == 0)) || return 1
            [[ ${stream_present} == true ]] || return 1
            ;;
        audio)
            probe_stream stream_present "${final_path}" 'a:0'
            probe_status=$?
            ((probe_status == 0)) || return 1
            [[ ${stream_present} == true ]] || return 1
            probe_stream stream_present "${final_path}" 'V:0'
            probe_status=$?
            ((probe_status == 0)) || return 1
            [[ ${stream_present} == false ]] || return 1
            ;;
        *)
            return 2
            ;;
    esac

    validate_media_tail_consistency "${final_path}" "${mode}"
    tail_status=$?
    ((tail_status == 0)) || return 1
    return 0
}

normalize_path_record() {
    local record_file=$1
    local output_dir=$2
    local candidate=''
    local final_path=''

    [[ -f ${record_file} ]] || return 1
    while IFS= read -r candidate || [[ -n ${candidate} ]]; do
        if [[ -n ${candidate} ]]; then
            final_path=${candidate}
        fi
    done <"${record_file}"

    [[ -n ${final_path} ]] || return 1
    if ! final_path=$(realpath -e -- "${final_path}" 2>/dev/null); then
        return 1
    fi
    [[ -f ${final_path} ]] || return 1
    if [[ ${output_dir} != / && ${final_path} != "${output_dir}"/* ]]; then
        return 1
    fi

    printf '%s\n' "${final_path}" >"${record_file}" || return 2
    return 0
}

main() {
    trap cleanup EXIT
    trap 'request_shutdown HUP 129' HUP
    trap 'request_shutdown INT 130' INT
    trap 'request_shutdown TERM 143' TERM

    OUTPUT_DIR=''
    MODE='video'
    MACHINE_PROGRESS=false
    YOUTUBE_HLS_FIREFOX=false
    RESULT_FILE=''
    URL_FILE=''
    URL=''
    IS_YOUTUBE_URL=false
    POSITIONAL_ARGUMENTS=()

    while (($# > 0)); do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            -V | --version)
                printf '%s version %s\n' "${SCRIPT_NAME}" "${VERSION}"
                exit 0
                ;;
            -o | --output-dir)
                require_value "$1" "${2-}"
                OUTPUT_DIR=$2
                shift 2
                ;;
            --output-dir=*)
                OUTPUT_DIR=${1#*=}
                require_value '--output-dir' "${OUTPUT_DIR}"
                shift
                ;;
            -m | --mode)
                require_value "$1" "${2-}"
                MODE=$2
                shift 2
                ;;
            --mode=*)
                MODE=${1#*=}
                require_value '--mode' "${MODE}"
                shift
                ;;
            --machine-progress)
                MACHINE_PROGRESS=true
                shift
                ;;
            --youtube-hls-firefox)
                YOUTUBE_HLS_FIREFOX=true
                shift
                ;;
            --result-file)
                require_value "$1" "${2-}"
                RESULT_FILE=$2
                shift 2
                ;;
            --result-file=*)
                RESULT_FILE=${1#*=}
                require_value '--result-file' "${RESULT_FILE}"
                shift
                ;;
            --url-file)
                require_value "$1" "${2-}"
                URL_FILE=$2
                shift 2
                ;;
            --url-file=*)
                URL_FILE=${1#*=}
                require_value '--url-file' "${URL_FILE}"
                shift
                ;;
            --)
                shift
                POSITIONAL_ARGUMENTS+=("$@")
                break
                ;;
            -*)
                error "unknown option: $1"
                usage >&2
                exit 2
                ;;
            *)
                POSITIONAL_ARGUMENTS+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n ${URL_FILE} ]]; then
        if ((${#POSITIONAL_ARGUMENTS[@]} != 0)); then
            error 'do not combine --url-file with a positional URL.'
            exit 2
        fi
        if [[ -L ${URL_FILE} || ! -f ${URL_FILE} || ! -r ${URL_FILE} ]]; then
            error 'the URL file must be a readable regular file and not a symbolic link.'
            exit 2
        fi
        url_file_owner=''
        if ! url_file_owner=$(stat -c '%u' -- "${URL_FILE}" 2>/dev/null); then
            error 'unable to determine the URL file owner.'
            exit 2
        fi
        if [[ ${url_file_owner} != "${EUID}" ]]; then
            error 'the URL file must be owned by the current user.'
            exit 2
        fi
        URL=''
        url_line_count=0
        while IFS= read -r url_line || [[ -n ${url_line} ]]; do
            ((url_line_count += 1))
            if ((url_line_count == 1)); then
                URL=${url_line}
            fi
        done <"${URL_FILE}"
        if ((url_line_count != 1)); then
            error 'the URL file must contain exactly one line.'
            exit 2
        fi
    else
        if ((${#POSITIONAL_ARGUMENTS[@]} == 0)); then
            error 'a video URL is required.'
            usage >&2
            exit 2
        fi
        if ((${#POSITIONAL_ARGUMENTS[@]} != 1)); then
            error 'exactly one video URL is required.'
            usage >&2
            exit 2
        fi
        URL=${POSITIONAL_ARGUMENTS[0]}
    fi

    if [[ ${URL} == *$'\n'* || ${URL} == *$'\r'* ]]; then
        error 'the URL must not contain line breaks.'
        exit 2
    fi
    if [[ ! ${URL} =~ ^https?://[^[:space:]]+$ ]]; then
        error 'provide a URL beginning with http:// or https://.'
        exit 2
    fi

    url_authority=${URL#*://}
    url_authority=${url_authority%%/*}
    url_authority=${url_authority%%\?*}
    url_authority=${url_authority%%\#*}
    if [[ ${url_authority} == *@* ]]; then
        error 'URLs containing user information are not accepted.'
        exit 2
    fi
    URL_HOST=${url_authority%%:*}
    URL_HOST=${URL_HOST,,}
    URL_HOST=${URL_HOST%.}
    case ${URL_HOST} in
        youtube.com | *.youtube.com | youtu.be | *.youtu.be | \
            youtube-nocookie.com | *.youtube-nocookie.com)
            IS_YOUTUBE_URL=true
            ;;
        *)
            IS_YOUTUBE_URL=false
            ;;
    esac
    readonly URL_HOST IS_YOUTUBE_URL

    case ${MODE} in
        video | audio) ;;
        *)
            error '--mode must be video or audio.'
            exit 2
            ;;
    esac

    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        if [[ ${MODE} != video ]]; then
            error '--youtube-hls-firefox is available only with --mode video.'
            exit 2
        fi

        if [[ ${IS_YOUTUBE_URL} != true ]]; then
            error '--youtube-hls-firefox requires a YouTube URL.'
            exit 2
        fi
    fi

    for command_name in aria2c ffmpeg ffprobe python3 sed stdbuf tr realpath grep mktemp mv rm rmdir chmod flock mkdir sha256sum stat setsid sleep timeout find; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            error "required command \"${command_name}\" was not found."
            exit 127
        fi
    done

    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
        error 'unable to resolve the engine path.'
        exit 66
    }
    script_dir=${script_path%/*}
    runtime_manager="${script_dir}/runtime-manager.sh"
    private_aria2_helper="${script_dir}/private-aria2-plan.py"

    if [[ -L ${private_aria2_helper} ||
        ! -f ${private_aria2_helper} ||
        ! -r ${private_aria2_helper} ]]; then
        error "private aria2 helper is missing or unsafe: ${private_aria2_helper}"
        exit 66
    fi
    readonly private_aria2_helper

    if [[ ${YTDLP_ARIA2_SKIP_RUNTIME_UPDATE:-0} == 1 ]]; then
        YTDLP_BIN=${YTDLP_ARIA2_YTDLP_BIN:-$(command -v yt-dlp 2>/dev/null || true)}
        DENO_BIN=${YTDLP_ARIA2_DENO_BIN:-$(command -v deno 2>/dev/null || true)}
    else
        if [[ ! -x ${runtime_manager} ]]; then
            error "runtime manager is missing: ${runtime_manager}"
            exit 66
        fi
        runtime_action='update'
        case ${YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE:-1} in
            1 | '') ;;
            0) runtime_action='require' ;;
            *)
                error 'YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE must be 0 or 1.'
                exit 64
                ;;
        esac
        if ! "${runtime_manager}" "${runtime_action}"; then
            error 'unable to initialize the managed yt-dlp and Deno runtimes.'
            exit 69
        fi
        YTDLP_BIN=$("${runtime_manager}" path yt-dlp) || {
            error 'unable to resolve the managed yt-dlp runtime.'
            exit 69
        }
        DENO_BIN=$("${runtime_manager}" path deno) || {
            error 'unable to resolve the managed Deno runtime.'
            exit 69
        }
    fi
    readonly YTDLP_BIN DENO_BIN

    if [[ ! -x ${YTDLP_BIN} ]]; then
        error 'the selected yt-dlp runtime is not executable.'
        exit 127
    fi

    # Keep this as a simple command: placing it in an if/|| context would disable
    # errexit inside the function body under Bash's documented rules.
    check_runtime_compatibility
    readonly ARIA2_SUPPORTS_NO_NETRC

    if [[ -z ${OUTPUT_DIR} ]]; then
        OUTPUT_DIR=${PWD}
    fi

    if [[ ${OUTPUT_DIR} == *$'\n'* || ${OUTPUT_DIR} == *$'\r'* ]]; then
        error 'the destination path must not contain line breaks.'
        exit 2
    fi

    if [[ ! -d ${OUTPUT_DIR} ]]; then
        error "destination directory does not exist: ${OUTPUT_DIR}"
        exit 1
    fi

    if ! OUTPUT_DIR=$(realpath -e -- "${OUTPUT_DIR}"); then
        error 'unable to resolve the destination directory.'
        exit 1
    fi
    readonly OUTPUT_DIR

    # --output is an yt-dlp output template. Escape literal percent signs from the
    # real destination path so directories containing '%' are handled correctly.
    OUTPUT_DIR_TEMPLATE=${OUTPUT_DIR//%/%%}
    readonly OUTPUT_DIR_TEMPLATE

    if [[ ! -w ${OUTPUT_DIR} || ! -x ${OUTPUT_DIR} ]]; then
        error "destination directory is not writable: ${OUTPUT_DIR}"
        exit 13
    fi

    # Keep one same-user writer per canonical destination directory. The lock is
    # stored in a private local runtime directory, so no marker is written into the
    # user's media directory and an interrupted process releases it automatically.
    acquire_output_lock "${OUTPUT_DIR}"
    recover_abandoned_private_aria2_staging
    cleanup_stale_temporary_files

    if [[ -n ${RESULT_FILE} ]]; then
        if [[ ${RESULT_FILE} == *$'\n'* || ${RESULT_FILE} == *$'\r'* ]]; then
            error 'the result-file path must not contain line breaks.'
            exit 2
        fi

        result_parent=${RESULT_FILE%/*}
        if [[ ${result_parent} == "${RESULT_FILE}" ]]; then
            result_parent='.'
        elif [[ -z ${result_parent} ]]; then
            result_parent='/'
        fi

        if [[ ! -d ${result_parent} || ! -w ${result_parent} || ! -x ${result_parent} ]]; then
            error 'the result-file directory is not writable.'
            exit 13
        fi

        if [[ -e ${RESULT_FILE} || -L ${RESULT_FILE} ]]; then
            error 'the result-file already exists; refusing to overwrite it.'
            exit 13
        fi

        if ! RESULT_FILE_TMP=$(mktemp \
            --tmpdir="${result_parent}" \
            '.yt-dlp-result.XXXXXXXX'); then
            error 'unable to create the temporary result file.'
            exit 13
        fi
    fi

    if [[ -z ${RESULT_FILE_TMP} ]]; then
        # Always retain the final yt-dlp path internally. This permits uniform
        # FFprobe validation for ordinary CLI runs as well as GUI and HLS runs.
        if ! INTERNAL_PATH_FILE_TMP=$(mktemp \
            --tmpdir="${OUTPUT_DIR}" \
            '.yt-dlp-path.XXXXXXXX'); then
            error 'unable to create the internal result-path file.'
            exit 13
        fi
    fi

    if ! YTDLP_BATCH_FILE_TMP=$(mktemp \
        --tmpdir="${OUTPUT_LOCK_ROOT}" \
        '.url-batch.XXXXXXXX'); then
        error 'unable to create the private yt-dlp URL batch file.'
        exit 13
    fi
    if ! printf '%s\n' "${URL}" >"${YTDLP_BATCH_FILE_TMP}" \
        || ! chmod 600 -- "${YTDLP_BATCH_FILE_TMP}"; then
        error 'unable to secure the private yt-dlp URL batch file.'
        exit 13
    fi
    unset URL

    if ! PRIVATE_ARIA2_STAGING=$(mktemp -d \
        --tmpdir="${OUTPUT_DIR}" \
        '.yt-dlp-aria2.XXXXXXXX'); then
        error 'unable to create the private aria2 staging directory.'
        exit 13
    fi
    if ! chmod 700 -- "${PRIVATE_ARIA2_STAGING}"; then
        error 'unable to secure the private aria2 staging directory.'
        exit 13
    fi

    PRIVATE_ARIA2_STAGING_MARKER_PATH="${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
    if ! printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
        >"${PRIVATE_ARIA2_STAGING_MARKER_PATH}" \
        || ! chmod 600 -- "${PRIVATE_ARIA2_STAGING_MARKER_PATH}"; then
        error 'unable to initialize private aria2 staging ownership metadata.'
        exit 13
    fi

    PRIVATE_ARIA2_PLAN="${PRIVATE_ARIA2_STAGING}/plan.json"
    PRIVATE_ARIA2_COOKIE_JAR="${PRIVATE_ARIA2_STAGING}/cookies.txt"
    PRIVATE_ARIA2_INPUT="${PRIVATE_ARIA2_STAGING}/aria2.input"
    PRIVATE_ARIA2_MANIFEST="${PRIVATE_ARIA2_STAGING}/manifest.json"

    if ! : >"${PRIVATE_ARIA2_PLAN}" \
        || ! printf '%s\n' '# Netscape HTTP Cookie File' \
            >"${PRIVATE_ARIA2_COOKIE_JAR}" \
        || ! chmod 600 -- \
            "${PRIVATE_ARIA2_PLAN}" \
            "${PRIVATE_ARIA2_COOKIE_JAR}"; then
        error 'unable to initialize private transfer metadata.'
        exit 13
    fi

    printf '%s version %s\n' "${SCRIPT_NAME}" "${VERSION}"
    printf 'Download directory: %s\n' "${OUTPUT_DIR}"
    printf 'Mode: %s\n' "${MODE}"
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        printf '%s\n' 'YouTube access: Firefox cookies with web_safari HLS'
    fi

    ARIA2_ARGUMENTS='-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true'
    if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then
        ARIA2_ARGUMENTS+=' --no-netrc=true'
    fi
    ARIA2_ARGUMENTS+=' --allow-overwrite=false --auto-file-renaming=false --max-concurrent-downloads=1'
    ARIA2_ARGUMENTS+=' --console-log-level=warn --enable-color=false --truncate-console-readout=false'
    if [[ ${MACHINE_PROGRESS} == true ]]; then
        # yt-dlp does not currently expose aria2c transfer progress through its
        # own progress hooks. yt-dlp captures stderr from external downloaders and
        # normally replays it only on failure, so aria2c's periodic readout must
        # remain on stdout to reach the GUI log during a successful transfer.
        ARIA2_ARGUMENTS+=' --summary-interval=1 --show-console-readout=true --stderr=false'
    else
        ARIA2_ARGUMENTS+=' --summary-interval=0'
    fi
    readonly ARIA2_ARGUMENTS
    read -r -a ARIA2_DIRECT_OPTIONS <<<"${ARIA2_ARGUMENTS}"
    readonly -a ARIA2_DIRECT_OPTIONS

    YT_DLP_OPTIONS=(
        --ignore-config
        --no-update
        --no-playlist
        --break-match-filters '!playlist_index'
        --no-overwrites
        --no-post-overwrites
        --cookies "${PRIVATE_ARIA2_COOKIE_JAR}"
        --embed-metadata
        --parse-metadata ':(?P<meta_purl>)'
        --parse-metadata ':(?P<meta_comment>)'
        --socket-timeout 30
        --retries 10
        --fragment-retries 10
        --extractor-retries 3
        --retry-sleep 2
        --output "${OUTPUT_DIR_TEMPLATE}/%(title).160B [%(id).64B].%(ext)s"
        --continue
        --progress-delta 1
        # Fragmented DASH/HLS transfers remain on yt-dlp's native downloader.
        # Direct HTTP(S) transfers are classified and delegated to aria2 below
        # through a private input file, never through aria2 argv.
        --downloader 'dash,m3u8:native'
        --concurrent-fragments 1
    )

    if [[ ${JS_RUNTIME_AVAILABLE} == true ]]; then
        YT_DLP_OPTIONS+=(--js-runtimes "deno:${DENO_BIN}")
    fi

    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        # This explicit profile reads the authenticated Firefox session and asks
        # YouTube's web_safari client for HLS formats. Current yt-dlp guidance notes
        # that these HLS URLs do not require a GVS PO Token at this time.
        YT_DLP_OPTIONS+=(
            --cookies-from-browser firefox
            --extractor-args 'youtube:player_client=web_safari'
            --fixup force
        )
    fi

    if [[ ${MODE} == 'video' ]]; then
        # Keep both container options. --merge-output-format covers separate
        # video/audio streams, while --remux-video covers the combined-format fallback.
        if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
            VIDEO_FORMAT='(bv*+ba/b)[protocol^=m3u8]'
        else
            VIDEO_FORMAT='bv*+ba/b'
        fi
        YT_DLP_OPTIONS+=(--format "${VIDEO_FORMAT}")
        # The authenticated HLS profile must let yt-dlp run FixupM3u8 before this
        # wrapper performs its final MKV remux. Scheduling VideoRemuxer here would
        # make yt-dlp treat the fixup as redundant and skip it.
        if [[ ${YOUTUBE_HLS_FIREFOX} != true ]]; then
            YT_DLP_OPTIONS+=(
                --merge-output-format mkv
                --remux-video mkv
            )
        fi
    else
        # Match the dedicated download-audio.sh behavior: select the best
        # audio-only stream, fall back to the best combined stream when necessary,
        # extract audio, and preserve the source codec/container whenever possible.
        YT_DLP_OPTIONS+=(
            --format 'ba/b'
            --extract-audio
            --audio-format best
            --audio-quality 0
        )
    fi

    PLAN_OPTIONS=(
        "${YT_DLP_OPTIONS[@]}"
        --skip-download
        --no-clean-info-json
        --dump-single-json
    )

    run_supervised_command \
        "${YTDLP_BIN}" \
        "${PLAN_OPTIONS[@]}" \
        --batch-file "${YTDLP_BATCH_FILE_TMP}" \
        >"${PRIVATE_ARIA2_PLAN}"

    plan_status=${DOWNLOAD_STATUS}
    if ((plan_status != 0)); then
        printf '\nDownload failed during format planning with exit code %d.\n' \
            "${plan_status}" >&2
        exit "${plan_status}"
    fi

    classification_output=''
    if ! classification_output=$(python3 \
        "${private_aria2_helper}" classify \
        --plan "${PRIVATE_ARIA2_PLAN}"); then
        error 'unable to classify the selected download transport.'
        exit 65
    fi
    if [[ -z ${classification_output} ]]; then
        error 'the private transfer classifier returned no output.'
        exit 65
    fi

    PRIVATE_TRANSPORT=''
    PRIVATE_TRANSFER_COUNT=''
    while IFS= read -r classification_line; do
        case ${classification_line} in
            transport=*)
                if [[ -n ${PRIVATE_TRANSPORT} ]]; then
                    error 'the private transfer classifier returned duplicate transports.'
                    exit 65
                fi
                PRIVATE_TRANSPORT=${classification_line#transport=}
                ;;
            transfer_count=*)
                if [[ -n ${PRIVATE_TRANSFER_COUNT} ]]; then
                    error 'the private transfer classifier returned duplicate transfer counts.'
                    exit 65
                fi
                PRIVATE_TRANSFER_COUNT=${classification_line#transfer_count=}
                if [[ ! ${PRIVATE_TRANSFER_COUNT} =~ ^([1-9]|1[0-6])$ ]]; then
                    error 'the private transfer classifier returned an invalid transfer count.'
                    exit 65
                fi
                ;;
            *)
                error 'the private transfer classifier returned unexpected output.'
                exit 65
                ;;
        esac
    done <<<"${classification_output}"

    if [[ -z ${PRIVATE_TRANSPORT} ]]; then
        error 'the private transfer classifier did not return a transport.'
        exit 65
    fi
    if [[ -z ${PRIVATE_TRANSFER_COUNT} ]]; then
        error 'the private transfer classifier did not return a transfer count.'
        exit 65
    fi

    case ${PRIVATE_TRANSPORT} in
        direct | native) ;;
        *)
            error 'the private transfer classifier returned an invalid transport.'
            exit 65
            ;;
    esac

    if [[ ${MACHINE_PROGRESS} == true ]]; then
        YT_DLP_OPTIONS+=(
            --newline
            --progress
            --color never
            --print 'before_dl:YTDLP_PLAN|%(id|unknown)s|%(format_id|unknown)s|%(requested_formats.0.format_id|)s|%(requested_formats.1.format_id|)s'
            --progress-template 'download:YTDLP_PROGRESS_V2|%(info.id|unknown)s|%(info.format_id|unknown)s|%(progress.status|unknown)s|%(progress.downloaded_bytes|0)s|%(progress.total_bytes|0)s|%(progress.total_bytes_estimate|0)s|%(progress.fragment_index|0)s|%(progress.fragment_count|0)s|%(progress._percent_str|)s|%(progress._speed_str|)s|%(progress._eta_str|)s'
            --progress-template 'postprocess:YTDLP_POSTPROCESS|%(progress.status|unknown)s|%(progress.postprocessor|unknown)s'
        )
    fi

    PATH_RECORD_TMP=${RESULT_FILE_TMP:-${INTERNAL_PATH_FILE_TMP}}
    if [[ -n ${PATH_RECORD_TMP} ]]; then
        # The FILE argument is itself an output template, so literal % characters
        # in the temporary path must be doubled.
        path_record_template=${PATH_RECORD_TMP//%/%%}
        YT_DLP_OPTIONS+=(
            --print-to-file 'after_move:%(filepath)s' "${path_record_template}"
        )
    fi

    if [[ ${PRIVATE_TRANSPORT} == direct ]]; then
        # The separate PLAN pass used by the private direct path does not emit
        # yt-dlp's before_dl machine event. Publish the exact non-secret item
        # count so the GUI can reserve every transfer before aria2 starts.
        if [[ ${MACHINE_PROGRESS} == true ]]; then
            printf 'ARIA2_PLAN|%s\n' "${PRIVATE_TRANSFER_COUNT}"
        fi
        if ! python3 "${private_aria2_helper}" build \
            --plan "${PRIVATE_ARIA2_PLAN}" \
            --output-dir "${OUTPUT_DIR}" \
            --staging-dir "${PRIVATE_ARIA2_STAGING}" \
            --aria2-input "${PRIVATE_ARIA2_INPUT}" \
            --manifest "${PRIVATE_ARIA2_MANIFEST}" \
            >/dev/null; then
            error 'unable to build the private aria2 transfer plan.'
            exit 65
        fi

        # aria2 diagnostics can contain the URI on failures. Keep progress
        # output, but redact every HTTP(S) token before it reaches CLI/GUI logs.
        run_supervised_command bash -c '
            set -o pipefail
            "$@" 2>&1 |
                stdbuf -o0 tr "\r" "\n" | sed -u -E "s#https?://[^[:space:]]+#[REDACTED_URL]#g"
        ' bash \
            aria2c \
            --input-file="${PRIVATE_ARIA2_INPUT}" \
            --dir="${PRIVATE_ARIA2_STAGING}" \
            --load-cookies="${PRIVATE_ARIA2_COOKIE_JAR}" \
            "${ARIA2_DIRECT_OPTIONS[@]}"

        aria2_status=${DOWNLOAD_STATUS}

        if ! rm -f -- "${PRIVATE_ARIA2_INPUT}"; then
            error 'unable to remove the private aria2 input file.'
            exit 13
        fi
        PRIVATE_ARIA2_INPUT=''

        if ((aria2_status == 0)); then
            commit_status=0
            python3 "${private_aria2_helper}" commit \
                --manifest "${PRIVATE_ARIA2_MANIFEST}" \
                >/dev/null || commit_status=$?

            if ((commit_status != 0)); then
                if ((commit_status == 1)); then
                    error 'final media destination already exists; refusing to overwrite it.'
                    exit "${commit_status}"
                fi

                error 'unable to publish the completed aria2 transfer.'
                exit 65
            fi

            run_supervised_command "${YTDLP_BIN}" \
                "${YT_DLP_OPTIONS[@]}" \
                --load-info-json "${PRIVATE_ARIA2_PLAN}"
        else
            DOWNLOAD_STATUS=${aria2_status}
        fi
    else
        run_supervised_command \
            "${YTDLP_BIN}" \
            "${YT_DLP_OPTIONS[@]}" \
            --batch-file "${YTDLP_BATCH_FILE_TMP}"
    fi

    if ! rm -f -- "${YTDLP_BATCH_FILE_TMP}"; then
        error 'unable to remove the private yt-dlp URL batch file.'
        exit 13
    fi
    YTDLP_BATCH_FILE_TMP=''
    if ((DOWNLOAD_STATUS == 0)); then
        if [[ -n ${PATH_RECORD_TMP} ]]; then
            set +e
            normalize_path_record "${PATH_RECORD_TMP}" "${OUTPUT_DIR}"
            path_record_status=$?
            set -e
            case ${path_record_status} in
                0) ;;
                1)
                    error 'yt-dlp did not report a valid final media path inside the destination directory.'
                    exit 1
                    ;;
                *)
                    error 'unable to normalize the final media path record.'
                    exit 13
                    ;;
            esac
        fi

        if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
            hls_source_path=$(<"${PATH_RECORD_TMP}") || {
                error 'unable to read the repaired HLS file path.'
                exit 13
            }

            hls_source_dir=${hls_source_path%/*}
            if [[ ${hls_source_dir} == "${hls_source_path}" ]]; then
                hls_source_dir='.'
            fi
            hls_source_name=${hls_source_path##*/}
            hls_source_stem=${hls_source_name%.*}
            hls_final_path="${hls_source_dir}/${hls_source_stem}.mkv"

            if [[ -e ${hls_final_path} || -L ${hls_final_path} ]]; then
                error "the final MKV already exists; refusing to overwrite it: ${hls_final_path}"
                exit 13
            fi

            emit_machine_postprocess started FFmpegVideoRemuxer
            hls_source_duration_us=''
            probe_duration_microseconds \
                hls_source_duration_us "${hls_source_path}" 2>/dev/null
            if [[ ! ${hls_source_duration_us} =~ ^[1-9][0-9]*$ ]]; then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error 'unable to determine the repaired HLS source duration; refusing an unverifiable remux.'
                printf 'The repaired HLS intermediate was retained at: %s\n' \
                    "${hls_source_path}" >&2
                exit 65
            fi
            if [[ ${MACHINE_PROGRESS} == true ]]; then
                printf 'FFMPEG_PROGRESS_DURATION|%s\n' "${hls_source_duration_us}"
            fi
            if ! HLS_REMUX_TMP=$(mktemp \
                --tmpdir="${hls_source_dir}" \
                --suffix='.mkv' \
                '.yt-dlp-remux.XXXXXXXX'); then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error 'unable to create the temporary MKV file.'
                exit 13
            fi

            run_supervised_command \
                ffmpeg \
                -hide_banner \
                -loglevel warning \
                -nostdin \
                -nostats \
                -stats_period 0.5 \
                -progress pipe:1 \
                -i "${hls_source_path}" \
                -map 0 \
                -dn \
                -ignore_unknown \
                -c copy \
                -y \
                "${HLS_REMUX_TMP}"
            ffmpeg_status=${DOWNLOAD_STATUS}
            if ((ffmpeg_status != 0)); then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error "unable to remux the repaired HLS file into MKV (FFmpeg status ${ffmpeg_status})."
                printf 'The repaired HLS intermediate was retained at: %s\n' \
                    "${hls_source_path}" >&2
                exit "${ffmpeg_status}"
            fi

            hls_final_duration_us=''
            probe_duration_microseconds \
                hls_final_duration_us "${HLS_REMUX_TMP}" 2>/dev/null
            if [[ ! ${hls_final_duration_us} =~ ^[1-9][0-9]*$ ]]; then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error 'unable to determine the remuxed MKV duration; refusing to publish an unverifiable result.'
                printf 'The repaired HLS intermediate was retained at: %s\n' \
                    "${hls_source_path}" >&2
                exit 65
            fi
            if ((hls_final_duration_us < hls_source_duration_us)); then
                # Stream-copy remuxes may shift/drop a small amount of timestamp
                # padding. Permit 2% loss, with a 0.5 s floor and 5 s ceiling, but
                # fail closed on a materially shortened result. This is deliberately
                # metadata-only validation; do not decode the complete media again.
                hls_duration_tolerance_us=$((hls_source_duration_us / 50))
                if ((hls_duration_tolerance_us < 500000)); then
                    hls_duration_tolerance_us=500000
                elif ((hls_duration_tolerance_us > 5000000)); then
                    hls_duration_tolerance_us=5000000
                fi
                hls_duration_loss_us=$((hls_source_duration_us - hls_final_duration_us))
                if ((hls_duration_loss_us > hls_duration_tolerance_us)); then
                    emit_machine_postprocess error FFmpegVideoRemuxer
                    error 'the remuxed MKV is substantially shorter than the repaired HLS source.'
                    printf 'Source duration: %s us; remuxed duration: %s us; allowed loss: %s us.\n' \
                        "${hls_source_duration_us}" \
                        "${hls_final_duration_us}" \
                        "${hls_duration_tolerance_us}" >&2
                    printf 'The repaired HLS intermediate was retained at: %s\n' \
                        "${hls_source_path}" >&2
                    exit 65
                fi
            fi

            if ! mv -nT -- "${HLS_REMUX_TMP}" "${hls_final_path}"; then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error 'unable to publish the final MKV file.'
                exit 13
            fi
            if [[ -e ${HLS_REMUX_TMP} || -L ${HLS_REMUX_TMP} ]]; then
                emit_machine_postprocess error FFmpegVideoRemuxer
                error "the final MKV appeared during publication; refusing to overwrite it: ${hls_final_path}"
                exit 13
            fi
            HLS_REMUX_TMP=''
            if ! printf '%s\n' "${hls_final_path}" >"${PATH_RECORD_TMP}"; then
                error 'unable to record the final MKV path.'
                printf 'The repaired HLS intermediate was retained at: %s\n' \
                    "${hls_source_path}" >&2
                exit 13
            fi
            emit_machine_postprocess finished FFmpegVideoRemuxer
            if [[ ${hls_source_path} != "${hls_final_path}" ]]; then
                HLS_SOURCE_TO_CLEAN=${hls_source_path}
            fi
        fi

        final_media_path=''
        if ! { IFS= read -r final_media_path <"${PATH_RECORD_TMP}"; } 2>/dev/null \
            || [[ -z ${final_media_path} ]]; then
            error 'unable to read the final media path for validation.'
            exit 13
        fi

        emit_machine_postprocess started MediaValidation

        # Call the validation function outside a conditional context. Bash disables
        # errexit throughout a function invoked by if, !, &&, or ||, which could
        # otherwise hide an unexpected failure inside the validation routine.
        set +e
        validate_final_media_file \
            "${final_media_path}" "${MODE}"
        validation_status=$?
        set -e

        if ((validation_status != 0)); then
            emit_machine_postprocess error MediaValidation
            error "the final media file failed FFprobe validation: ${final_media_path}"
            printf '%s\n' \
                'The media file was retained for diagnosis and was not published as a successful result.' >&2
            if [[ -n ${HLS_SOURCE_TO_CLEAN} ]]; then
                printf 'The repaired HLS intermediate was retained at: %s\n' \
                    "${HLS_SOURCE_TO_CLEAN}" >&2
            fi
            exit 65
        fi
        emit_machine_postprocess finished MediaValidation

        if [[ -n ${RESULT_FILE} ]]; then
            if ! mv -nT -- "${RESULT_FILE_TMP}" "${RESULT_FILE}"; then
                error 'unable to publish the result file.'
                exit 13
            fi
            if [[ -e ${RESULT_FILE_TMP} || -L ${RESULT_FILE_TMP} ]]; then
                error 'the result file appeared during publication; refusing to overwrite it.'
                exit 13
            fi
            RESULT_FILE_TMP=''
        elif [[ -n ${INTERNAL_PATH_FILE_TMP} ]]; then
            if ! rm -f -- "${INTERNAL_PATH_FILE_TMP}"; then
                error 'unable to remove the internal result-path file.'
                exit 13
            fi
            INTERNAL_PATH_FILE_TMP=''
        fi

        if [[ -n ${HLS_SOURCE_TO_CLEAN} ]]; then
            if ! rm -f -- "${HLS_SOURCE_TO_CLEAN}"; then
                printf 'Warning: unable to remove the repaired HLS intermediate: %s\n' \
                    "${HLS_SOURCE_TO_CLEAN}" >&2
            fi
            HLS_SOURCE_TO_CLEAN=''
        fi
        printf '\nDownload completed successfully.\n'
    else
        status=${DOWNLOAD_STATUS}
        printf '\nDownload failed with exit code %d.\n' "${status}" >&2
        exit "${status}"
    fi

}

main "$@"

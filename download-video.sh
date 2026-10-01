#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : download-video.sh
# Purpose     : Download one complete MKV video or the best native audio track.
# ==============================================================================

set -euo pipefail
# Keep asynchronous children in this shell's process group until an explicit
# setsid call. This makes the no-fork worker-registration contract deterministic.
set +m
umask 077

readonly VERSION="2.4.0"
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
ARIA2_HTTPS_DIRECT_SAFE=true
FINAL_MEDIA_VALIDATION_REASON=''
PROBE_OUTPUT_FILE=''
MEDIA_TAIL_VALIDATION_REASON=''
JS_RUNTIME_AVAILABLE=false
MANAGED_RUNTIME_ATTESTED=false
MANAGED_YTDLP_VERSION=''
MANAGED_DENO_VERSION=''
RESULT_FILE_TMP=''
RESULT_FILE_PARENT=''
RESULT_FILE_PARENT_IDENTITY=''
INTERNAL_PATH_FILE_TMP=''
PATH_RECORD_TMP=''
PATH_RECORD_FD=''
PATH_RECORD_FD_PATH=''
PATH_RECORD_IDENTITY=''
HLS_REMUX_TMP=''
HLS_REMUX_TMP_IDENTITY=''
HLS_REMUX_FD=''
HLS_REMUX_FD_PATH=''
HLS_SOURCE_TO_CLEAN=''
HLS_SOURCE_TO_CLEAN_IDENTITY=''
YTDLP_BATCH_FILE_TMP=''
PRIVATE_ARIA2_METADATA=''
PRIVATE_ARIA2_METADATA_IDENTITY=''
PRIVATE_ARIA2_METADATA_FD=''
PRIVATE_ARIA2_METADATA_CLEANUP_SAFE=true
MEDIA_WORKSPACE=''
MEDIA_WORKSPACE_IDENTITY=''
MEDIA_WORKSPACE_FD=''
MEDIA_WORKSPACE_CLEANUP_SAFE=true
MEDIA_RETAINED_PATH=''
MEDIA_RETAINED_IDENTITY=''
MEDIA_RETAINED_PATHS=()
MEDIA_RETAINED_IDENTITIES=()
FINAL_OUTPUT_DIR=''
FINAL_OUTPUT_IDENTITY=''
FINAL_OUTPUT_FD=''
PRIVATE_ARIA2_STAGING=''
PRIVATE_ARIA2_STAGING_IDENTITY=''
PRIVATE_ARIA2_STAGING_FD=''
PRIVATE_ARIA2_PLAN=''
PRIVATE_ARIA2_PLAN_IDENTITY=''
PRIVATE_ARIA2_COOKIE_JAR=''
PRIVATE_ARIA2_COOKIE_JAR_IDENTITY=''
PRIVATE_ARIA2_INPUT=''
PRIVATE_ARIA2_INPUT_IDENTITY=''
PRIVATE_ARIA2_MANIFEST=''
PRIVATE_ARIA2_MANIFEST_IDENTITY=''
OUTPUT_LOCK_FD=''
OUTPUT_LOCK_FILE=''
OUTPUT_LOCK_ROOT=''
RESOURCE_LOCK_ROOT=''
RESOURCE_STATE_FILE=''
RESOURCE_STATE_ACTIVE=false
RESOURCE_COMPLETED_PATH=''
RESOURCE_LOCK_FDS=()
DOWNLOAD_WORKER_PID=''
DOWNLOAD_WORKER_START_TIME=''
DOWNLOAD_WORKER_PGID=''
DOWNLOAD_WORKER_PGID_START_TIME=''
DOWNLOAD_SESSION_ID=''
DOWNLOAD_PGID_FILE=''
DOWNLOAD_READY_FILE=''
DOWNLOAD_STATUS=125
DOWNLOAD_WAITED_STATUS=''
DOWNLOAD_FORCE_STOP=false
REQUESTED_EXIT_STATUS=''
SHUTDOWN_REQUESTED=false
DEFERRED_SIGNAL_NAME=''
DEFERRED_SIGNAL_STATUS=''
SIGNAL_REGISTRATION_ACTIVE=false
REGISTRATION_ESCALATION_REQUESTED=false
RUNTIME_ATTESTATION_TMP=''
REUSE_CURRENT_SESSION=${YTDLP_ARIA2_SUPERVISED_SESSION:-false}
case ${REUSE_CURRENT_SESSION} in
    true | false) ;;
    *) REUSE_CURRENT_SESSION=false ;;
esac

cleanup() {
    local status=$?
    local active_staging_metadata_safe=true
    local active_media_staging_safe=true
    local current_staging_identity=''

    trap - EXIT HUP INT TERM
    trap '' HUP INT TERM

    if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]]; then
        if declare -F stop_download_worker >/dev/null 2>&1; then
            # A descendant may still be using every private file after a
            # bounded shutdown fails. Preserve state and, after admission, keep
            # this reservation owner alive until the consumers have stopped.
            # shellcheck disable=SC2310 # Failed quiescence selects preservation.
            if ! stop_download_worker; then
                printf '%s\n' \
                    'Warning: command shutdown could not be confirmed; preserving active temporary files.' >&2
                if [[ ${RESOURCE_STATE_ACTIVE} == true ]]; then
                    # An external tool may close inherited descriptors. Keep
                    # the engine's historical shared lock too: an older engine
                    # cannot understand our active ownership checkpoint.
                    printf '%s\n' 'Warning: retaining reservation descriptors until consumers stop.' >&2
                    # shellcheck disable=SC2310 # Uncertain presence keeps this owner alive.
                    while ! wait_for_download_exit 10; do :; done
                else
                    exit "${status}"
                fi
            fi
        else
            printf '%s\n' \
                'Warning: command shutdown helper is unavailable; preserving active temporary files.' >&2
            exit "${status}"
        fi
    fi
    if [[ ${RESOURCE_STATE_ACTIVE} == true ]]; then
        if ! python3 "${PRIVATE_ARIA2_HELPER}" resource-state --action save \
            --state "${RESOURCE_STATE_FILE}" --registry "${RESOURCE_LOCK_ROOT}" \
            --completed-path "${RESOURCE_COMPLETED_PATH}"; then
            printf '%s\n' 'Warning: resource ownership checkpoint failed; ambiguous media will not be resumed.' >&2
        fi
    fi
    if [[ -n ${DOWNLOAD_PGID_FILE} ]]; then
        rm -f -- "${DOWNLOAD_PGID_FILE}" "${DOWNLOAD_PGID_FILE}.tmp" || true
    fi
    if [[ -n ${DOWNLOAD_READY_FILE} ]]; then
        rm -f -- "${DOWNLOAD_READY_FILE}" "${DOWNLOAD_READY_FILE}.tmp" || true
    fi
    if [[ -n ${RUNTIME_ATTESTATION_TMP} ]]; then
        rm -f -- "${RUNTIME_ATTESTATION_TMP}" || true
    fi
    if [[ -n ${PATH_RECORD_TMP} ]]; then
        if declare -F remove_owned_path_record_temp >/dev/null 2>&1; then
            # shellcheck disable=SC2310 # Cleanup preserves a changed inode.
            if ! remove_owned_path_record_temp "${PATH_RECORD_TMP}"; then
                if [[ -n ${PRIVATE_ARIA2_METADATA} &&
                    ${PATH_RECORD_TMP%/*} == "${PRIVATE_ARIA2_METADATA}" ]]; then
                    active_staging_metadata_safe=false
                fi
                printf 'Warning: preserving a changed temporary path record: %s\n' \
                    "${PATH_RECORD_TMP}" >&2
            fi
        else
            if [[ -n ${PRIVATE_ARIA2_METADATA} &&
                ${PATH_RECORD_TMP%/*} == "${PRIVATE_ARIA2_METADATA}" ]]; then
                active_staging_metadata_safe=false
            fi
            printf 'Warning: preserving an unverified temporary path record: %s\n' \
                "${PATH_RECORD_TMP}" >&2
        fi
    fi
    if [[ -n ${PATH_RECORD_FD} ]]; then
        { exec {PATH_RECORD_FD}>&-; } 2>/dev/null || true
    fi
    if [[ -n ${HLS_REMUX_TMP} ]]; then
        if declare -F remove_owned_hls_remux_temp >/dev/null 2>&1; then
            # shellcheck disable=SC2310 # Cleanup preserves a changed inode.
            if ! remove_owned_hls_remux_temp; then
                MEDIA_WORKSPACE_CLEANUP_SAFE=false
            fi
        else
            MEDIA_WORKSPACE_CLEANUP_SAFE=false
            printf 'Warning: preserving an unverified temporary HLS remux: %s\n' \
                "${HLS_REMUX_TMP}" >&2
        fi
    fi
    if [[ -n ${HLS_REMUX_FD} ]]; then
        close_hls_remux_fd
    fi
    if [[ -n ${YTDLP_BATCH_FILE_TMP} ]]; then
        rm -f -- "${YTDLP_BATCH_FILE_TMP}" || true
    fi
    if [[ -n ${PRIVATE_ARIA2_METADATA} &&
        (-e ${PRIVATE_ARIA2_METADATA} || -L ${PRIVATE_ARIA2_METADATA}) ]]; then
        if declare -F remove_active_private_aria2_sensitive_metadata \
            >/dev/null 2>&1; then
            # shellcheck disable=SC2310 # A changed identity is the preserve path.
            if ! remove_active_private_aria2_sensitive_metadata; then
                active_staging_metadata_safe=false
                printf 'Warning: preserving ambiguous private aria2 authentication metadata: %s\n' \
                    "${PRIVATE_ARIA2_METADATA##*/}" >&2
            fi
        fi
        # Identity changes are external state, even under a known basename.
        if [[ ${active_staging_metadata_safe} == true &&
            ${PRIVATE_ARIA2_METADATA_CLEANUP_SAFE} == true ]]; then
            if ! python3 "${PRIVATE_ARIA2_HELPER}" cleanup-workspace \
                --path "${PRIVATE_ARIA2_METADATA}" \
                --identity "${PRIVATE_ARIA2_METADATA_IDENTITY}"; then
                printf 'Warning: preserving ambiguous private metadata directory: %s\n' \
                    "${PRIVATE_ARIA2_METADATA}" >&2
            fi
        fi
    fi
    if [[ -n ${PRIVATE_ARIA2_STAGING} &&
        (-e ${PRIVATE_ARIA2_STAGING} || -L ${PRIVATE_ARIA2_STAGING}) ]]; then
        # shellcheck disable=SC2310 # Changed or unknown staging is preserved.
        if ! get_path_identity current_staging_identity "${PRIVATE_ARIA2_STAGING}" directory \
            || [[ ${current_staging_identity} != "${PRIVATE_ARIA2_STAGING_IDENTITY}" ]] \
            || ! remove_private_aria2_staging_candidate "${PRIVATE_ARIA2_STAGING}"; then
            active_media_staging_safe=false
            printf 'Warning: preserving ambiguous active private aria2 staging directory: %s\n' \
                "${PRIVATE_ARIA2_STAGING##*/}" >&2
        fi
    fi
    if [[ -n ${MEDIA_WORKSPACE} && ${active_media_staging_safe} == true &&
        ${MEDIA_WORKSPACE_CLEANUP_SAFE} == true ]]; then
        local -a retained_options=()
        local keep_index
        for keep_index in "${!MEDIA_RETAINED_PATHS[@]}"; do
            retained_options+=(--keep "${MEDIA_RETAINED_PATHS[keep_index]}"
                --keep-identity "${MEDIA_RETAINED_IDENTITIES[keep_index]}")
        done
        if [[ -n ${MEDIA_RETAINED_PATH} ]]; then
            retained_options+=(--keep "${MEDIA_RETAINED_PATH}"
                --keep-identity "${MEDIA_RETAINED_IDENTITY}")
        fi
        if ! python3 "${PRIVATE_ARIA2_HELPER}" cleanup-workspace \
            --path "${MEDIA_WORKSPACE}" --identity "${MEDIA_WORKSPACE_IDENTITY}" \
            "${retained_options[@]}"; then
            printf 'Warning: local media workspace cleanup was incomplete: %s\n' \
                "${MEDIA_WORKSPACE}" >&2
        fi
    fi
    local resource_fd
    for resource_fd in "${RESOURCE_LOCK_FDS[@]}"; do
        exec {resource_fd}>&- 2>/dev/null || true
    done
    if [[ -n ${OUTPUT_LOCK_FD} ]]; then
        exec {OUTPUT_LOCK_FD}>&- 2>/dev/null || true
    fi
    exit "${status}"
}

request_shutdown() {
    local signal_name=$1
    local exit_status=$2

    if [[ ${SIGNAL_REGISTRATION_ACTIVE} == true ]]; then
        if [[ -z ${DEFERRED_SIGNAL_STATUS} ]]; then
            DEFERRED_SIGNAL_STATUS=${exit_status}
            DEFERRED_SIGNAL_NAME=${signal_name}
        else
            REGISTRATION_ESCALATION_REQUESTED=true
            if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]] \
                && declare -F signal_download_worker >/dev/null 2>&1; then
                signal_download_worker KILL
            fi
        fi
        return 0
    fi

    if [[ -n ${DEFERRED_SIGNAL_STATUS} ]]; then
        REQUESTED_EXIT_STATUS=${DEFERRED_SIGNAL_STATUS}
        SHUTDOWN_REQUESTED=true
        DEFERRED_SIGNAL_NAME=''
        DEFERRED_SIGNAL_STATUS=''
        if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]] \
            && declare -F signal_download_worker >/dev/null 2>&1; then
            signal_download_worker KILL
            return 0
        fi
        exit "${REQUESTED_EXIT_STATUS}"
    fi

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

begin_signal_registration() {
    REGISTRATION_ESCALATION_REQUESTED=false
    SIGNAL_REGISTRATION_ACTIVE=true
}

finish_signal_registration() {
    local deferred_name=''
    local deferred_status=''

    SIGNAL_REGISTRATION_ACTIVE=false
    deferred_name=${DEFERRED_SIGNAL_NAME}
    deferred_status=${DEFERRED_SIGNAL_STATUS}
    if [[ -n ${deferred_status} ]]; then
        REQUESTED_EXIT_STATUS=${deferred_status}
        SHUTDOWN_REQUESTED=true
    fi
    REGISTRATION_ESCALATION_REQUESTED=false
    DEFERRED_SIGNAL_NAME=''
    DEFERRED_SIGNAL_STATUS=''
    if [[ -n ${deferred_status} ]]; then
        if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]] \
            && declare -F signal_download_worker >/dev/null 2>&1; then
            signal_download_worker "${deferred_name}"
            return 0
        fi
        exit "${deferred_status}"
    fi
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

print_human_line() {
    (($# == 1)) || return 2
    if [[ ${MACHINE_PROGRESS:-false} == true ]]; then
        printf '%s\n' "$1" >&2
    else
        printf '%s\n' "$1"
    fi
}

emit_machine_postprocess() {
    local status=$1
    local processor=$2

    if [[ ${MACHINE_PROGRESS} == true ]]; then
        printf 'YTDLP_POSTPROCESS|%s|%s\n' "${status}" "${processor}"
    fi
}

normalize_decimal_component() {
    local decimal_output_variable=$1
    local decimal_value=$2

    # Strip all leading zeroes without converting the external decimal string.
    # Bash arithmetic uses fixed-width integers, so conversion must happen only
    # after a caller has proved that the value is representable.
    decimal_value=${decimal_value#"${decimal_value%%[!0]*}"}
    [[ -n ${decimal_value} ]] || decimal_value=0
    printf -v "${decimal_output_variable}" '%s' "${decimal_value}"
}

compare_decimal_components() {
    local decimal_output_variable=$1
    local decimal_left=$2
    local decimal_right=$3
    local decimal_result=0
    local LC_ALL=C

    if ((${#decimal_left} > ${#decimal_right})); then
        decimal_result=1
    elif ((${#decimal_left} < ${#decimal_right})); then
        decimal_result=-1
    elif [[ ${decimal_left} > ${decimal_right} ]]; then
        decimal_result=1
    elif [[ ${decimal_left} < ${decimal_right} ]]; then
        decimal_result=-1
    fi

    printf -v "${decimal_output_variable}" '%d' "${decimal_result}"
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

check_ytdlp_version() {
    local yt_dlp_version=$1

    compare_versions "${yt_dlp_version}" "${MIN_YT_DLP_VERSION}"
    if [[ ${VERSION_PARSE_VALID} != true ]]; then
        error "unable to parse the yt-dlp version: ${yt_dlp_version:-unknown}."
        return 1
    fi
    if [[ ${VERSION_AT_LEAST} != true ]]; then
        error "yt-dlp ${MIN_YT_DLP_VERSION} or later is required; found ${yt_dlp_version}."
        return 1
    fi
}

check_deno_version() {
    local deno_version=$1

    JS_RUNTIME_AVAILABLE=false
    if [[ -n ${deno_version} ]]; then
        compare_versions "${deno_version}" "${MIN_DENO_VERSION}"
        if [[ ${VERSION_PARSE_VALID} == true && ${VERSION_AT_LEAST} == true ]]; then
            JS_RUNTIME_AVAILABLE=true
        fi
    fi
    if [[ ${IS_YOUTUBE_URL} == true && ${JS_RUNTIME_AVAILABLE} != true ]]; then
        error "Deno ${MIN_DENO_VERSION} or later is required for YouTube extraction."
        return 1
    fi
}

check_ytdlp_runtime() {
    local yt_dlp_version=''

    if ! yt_dlp_version=$(LC_ALL=C "${YTDLP_BIN}" \
        --ignore-config --no-plugin-dirs --no-update --version 2>/dev/null); then
        error 'unable to determine the yt-dlp version.'
        return 1
    fi
    check_ytdlp_version "${yt_dlp_version%%$'\n'*}"
}

check_deno_runtime() {
    local deno_name=''
    local deno_version=''
    local deno_output=''
    local _=''

    if [[ -n ${DENO_BIN:-} && -x ${DENO_BIN} ]] \
        && deno_output=$(LC_ALL=C "${DENO_BIN}" --version 2>/dev/null); then
        IFS=' ' read -r deno_name deno_version _ <<<"${deno_output%%$'\n'*}"
        if [[ ${deno_name} != deno ]]; then
            deno_version=''
        fi
    fi
    check_deno_version "${deno_version}"
}

check_ytdlp_capabilities() {
    local required_option
    local yt_dlp_help

    if ! yt_dlp_help=$(LC_ALL=C "${YTDLP_BIN}" \
        --ignore-config --no-plugin-dirs --no-update --help 2>&1); then
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
        --ignore-config \
        --no-plugin-dirs \
        --extractor-retries \
        --retry-sleep \
        --no-playlist \
        --no-overwrites \
        --no-post-overwrites \
        --break-match-filters \
        --embed-metadata \
        --output \
        --continue \
        --downloader \
        --concurrent-fragments \
        --format \
        --merge-output-format \
        --remux-video \
        --extract-audio \
        --audio-format \
        --audio-quality \
        --newline \
        --progress \
        --color \
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
}

check_aria2_runtime() {
    local aria2_version
    local aria2_version_line
    local aria2_version_output

    if ! aria2_version_output=$(LC_ALL=C aria2c --version 2>/dev/null); then
        error 'unable to determine the aria2c version.'
        return 1
    fi
    aria2_version_line=${aria2_version_output}
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

    # aria2 1.37.x with GnuTLS predates upstream Extended Key Usage
    # certificate validation hardening. Keep the application functional by
    # routing HTTPS through yt-dlp's native transport on affected builds.
    ARIA2_HTTPS_DIRECT_SAFE=true
    compare_versions "${aria2_version}" '1.38.0'
    if [[ ${VERSION_PARSE_VALID} == true && ${VERSION_AT_LEAST} != true ]] \
        && grep -Fq 'GnuTLS/' <<<"${aria2_version_output}"; then
        ARIA2_HTTPS_DIRECT_SAFE=false
    fi
}

check_aria2_capabilities() {
    local aria2_help
    local required_option

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
}

check_setsid_capabilities() {
    local setsid_help

    if ! setsid_help=$(LC_ALL=C setsid --help 2>&1); then
        error 'unable to inspect setsid capabilities.'
        return 1
    fi
    if ! grep -Eq -- \
        '^[[:space:]]*(-[^[:space:]]+,[[:space:]]+)?--wait([=[:space:]]|$)' \
        <<<"${setsid_help}"; then
        error 'this version of setsid does not support --wait.'
        return 1
    fi
}

check_env_capabilities() {
    if ! LC_ALL=C env \
        --ignore-signal=HUP \
        --ignore-signal=INT \
        --ignore-signal=TERM \
        bash -c 'exit 0' </dev/null >/dev/null 2>&1; then
        error 'this version of env does not support --ignore-signal.'
        return 1
    fi
    if ! LC_ALL=C env \
        --default-signal=HUP \
        --default-signal=INT \
        --default-signal=TERM \
        bash -c 'exit 0' </dev/null >/dev/null 2>&1; then
        error 'this version of env does not support --default-signal.'
        return 1
    fi
}

check_runtime_compatibility() {
    if [[ ${MANAGED_RUNTIME_ATTESTED} == true ]]; then
        check_ytdlp_version "${MANAGED_YTDLP_VERSION}"
        check_deno_version "${MANAGED_DENO_VERSION}"
    else
        check_ytdlp_runtime
        check_deno_runtime
        check_ytdlp_capabilities
    fi
    check_aria2_runtime
    check_aria2_capabilities
}

# Parse the line-safe, versioned contract emitted by the adjacent runtime
# manager. Reject extra or reordered fields so diagnostics can never be
# mistaken for executable paths.
parse_managed_runtime_attestation() {
    local attestation=$1
    local -a fields=()

    mapfile -t fields <<<"${attestation}"
    if ((${#fields[@]} != 5)) \
        || [[ ${fields[0]} != 'runtime-contract=1' ]] \
        || [[ ${fields[1]} != yt-dlp-path=* ]] \
        || [[ ${fields[2]} != yt-dlp-version=* ]] \
        || [[ ${fields[3]} != deno-path=* ]] \
        || [[ ${fields[4]} != deno-version=* ]]; then
        error 'the managed runtime attestation is malformed or unsupported.'
        return 1
    fi

    YTDLP_BIN=${fields[1]#yt-dlp-path=}
    MANAGED_YTDLP_VERSION=${fields[2]#yt-dlp-version=}
    DENO_BIN=${fields[3]#deno-path=}
    MANAGED_DENO_VERSION=${fields[4]#deno-version=}
    if [[ -z ${YTDLP_BIN} || -z ${MANAGED_YTDLP_VERSION} ||
        -z ${DENO_BIN} || -z ${MANAGED_DENO_VERSION} ]]; then
        error 'the managed runtime attestation contains an empty value.'
        return 1
    fi
    MANAGED_RUNTIME_ATTESTED=true
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
    local output_variable=${1:-OUTPUT_LOCK_ROOT}
    local prefer_runtime=${2:-true}
    local candidate=''
    local -a root_options=()

    if [[ ${prefer_runtime} != true ]]; then
        root_options+=(--no-runtime)
    fi
    # The shared Python allocator verifies the actual local filesystem and
    # owner-only access before any URL, cookie or subprocess temporary is written.
    if ! candidate=$(python3 "${PRIVATE_ARIA2_HELPER}" private-root \
        "${root_options[@]}"); then
        error 'no safe local private directory is available for download metadata.'
        return 73
    fi
    [[ ${candidate} == /* && -d ${candidate} && ! -L ${candidate} ]] || return 73
    printf -v "${output_variable}" '%s' "${candidate}"
}

acquire_output_lock() {
    local output_dir=$1
    local lock_key
    local destination_lock_root=''

    # shellcheck disable=SC2310 # Failure is converted to a lock setup status.
    if ! resolve_lock_root || [[ -z ${OUTPUT_LOCK_ROOT} ]]; then
        error 'unable to resolve the download-lock directory.'
        return 73
    fi

    # Every invocation must lock the same inode, including launches with
    # different XDG_RUNTIME_DIR values. Keep private work files under the
    # existing runtime root, but place destination locks in a stable UID root.
    # shellcheck disable=SC2310 # Failure is converted to a lock setup status.
    if ! resolve_lock_root destination_lock_root false; then
        return 73
    fi

    if ! lock_key=$(printf '%s\0' "${output_dir}" | sha256sum); then
        error 'unable to derive the destination lock identifier.'
        return 73
    fi
    lock_key=${lock_key%% *}
    if [[ ! ${lock_key} =~ ^[[:xdigit:]]{64}$ ]]; then
        error 'invalid destination lock identifier.'
        return 73
    fi

    RESOURCE_LOCK_ROOT=${destination_lock_root}
    OUTPUT_LOCK_FILE="${destination_lock_root}/${lock_key}.lock"
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
    if ! flock --shared --nonblock "${OUTPUT_LOCK_FD}"; then
        error "another download is already using the destination directory: ${output_dir}"
        return 75
    fi

    return 0
}

acquire_resource_reservations() {
    local reservation_keys='' lock_mode lock_key resource_fd lock_path
    local replay_output_template=''
    local opened_identity visible_identity status=0
    local -a profile_options=()
    [[ ${YOUTUBE_HLS_FIREFOX} != true ]] || profile_options+=(--hls)
    RESOURCE_STATE_FILE="${PRIVATE_ARIA2_METADATA}/resources.json"
    reservation_keys=$(python3 "${PRIVATE_ARIA2_HELPER}" resource-plan \
        --plan "${PRIVATE_ARIA2_PLAN}" --state "${RESOURCE_STATE_FILE}" \
        --url-file "${YTDLP_BATCH_FILE_TMP}" --mode "${MODE}" \
        --output-dir "${OUTPUT_DIR}" --final-output-dir "${FINAL_OUTPUT_DIR}" \
        --final-output-identity "${FINAL_OUTPUT_IDENTITY}" "${profile_options[@]}") || return $?
    while read -r lock_mode lock_key; do
        [[ ${lock_mode} == shared || ${lock_mode} == exclusive ]] || return 65
        [[ ${lock_key} =~ ^[a-f0-9]{64}$ ]] || return 65
        lock_path="${RESOURCE_LOCK_ROOT}/resource-${lock_key}.lock"
        [[ ! -L ${lock_path} && (! -e ${lock_path} || -f ${lock_path}) ]] || return 73
        begin_signal_registration
        if ! exec {resource_fd}>>"${lock_path}"; then
            finish_signal_registration
            return 73
        fi
        RESOURCE_LOCK_FDS+=("${resource_fd}")
        opened_identity=$(stat -Lc '%d:%i:%u' -- "/proc/${BASHPID}/fd/${resource_fd}")
        visible_identity=$(stat -c '%d:%i:%u' -- "${lock_path}")
        if [[ ${opened_identity} != "${visible_identity}" || ${opened_identity##*:} != "${EUID}" ]]; then
            finish_signal_registration
            return 73
        fi
        status=0
        flock "--${lock_mode}" --nonblock --conflict-exit-code 75 "${resource_fd}" || status=$?
        if ((status != 0)); then
            finish_signal_registration
            if ((status == 75)); then
                error 'media resources are currently reserved by another download; retry after it finishes.'
                return 75
            fi
            error 'unable to acquire the media resource reservation safely.'
            return 73
        fi
        finish_signal_registration
    done <<<"${reservation_keys}"
    begin_signal_registration
    # Register cleanup before the helper can publish an active checkpoint.
    # Its transaction identity makes cleanup a no-op if admission never commits
    # or was refused; a signal after commit must not strand an active record.
    RESOURCE_STATE_ACTIVE=true
    python3 "${PRIVATE_ARIA2_HELPER}" resource-state --action admit \
        --state "${RESOURCE_STATE_FILE}" --registry "${RESOURCE_LOCK_ROOT}" || status=$?
    finish_signal_registration
    if ((status == 1)); then
        error 'media destination already exists or contains an ambiguous input; preserving it.'
    fi
    if ((status == 0)); then
        # Loading an info JSON can transform its title again (notably for live
        # media). Bind direct replay as well as native transfer to the admitted
        # basename, before any media command can write outside its family.
        replay_output_template=$(python3 "${PRIVATE_ARIA2_HELPER}" check-native-final \
            --plan "${PRIVATE_ARIA2_PLAN}" --output-dir "${OUTPUT_DIR}" \
            --final-output-dir "${FINAL_OUTPUT_DIR}" \
            --final-output-identity "${FINAL_OUTPUT_IDENTITY}" --mode "${MODE}" \
            --ownership "${RESOURCE_STATE_FILE}") || return $?
        [[ -n ${replay_output_template} && ${replay_output_template} != *$'\n'* ]] || return 65
        YT_DLP_OPTIONS+=(--output "${replay_output_template}")
    fi
    return "${status}"
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
        [[ ${process_state} != Z && ${process_state} != X ]] || return 1
        return 0
    fi

    return 0
}

process_is_session_group_leader() {
    (($# == 4)) || return 2
    local pid=$1
    local expected_parent=$2
    local output_variable=$3
    local allow_zombie=$4
    local process_stat=''
    local process_state=''
    local process_parent=''
    local process_group=''
    local process_session=''
    local process_start_time=''
    local -a process_fields=()

    # A negative kill target is trusted only after proving the complete Linux
    # session-leader identity that was adopted from the current worker tree.
    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r /proc/${pid}/stat ]] || return 1
    if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        return 1
    fi
    read -r -a process_fields <<<"${process_stat##*) }"
    ((${#process_fields[@]} > 19)) || return 1
    process_state=${process_fields[0]}
    process_parent=${process_fields[1]}
    process_group=${process_fields[2]}
    process_session=${process_fields[3]}
    process_start_time=${process_fields[19]}

    [[ ${process_state} != X ]] || return 1
    if [[ ${allow_zombie} != true && ${process_state} == Z ]]; then
        return 1
    fi
    [[ ${process_group} == "${pid}" && ${process_session} == "${pid}" ]] \
        || return 1
    [[ -z ${expected_parent} || ${process_parent} == "${expected_parent}" ]] \
        || return 1
    [[ ${process_start_time} =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "-${pid}" 2>/dev/null || return 1
    printf -v "${output_variable}" '%s' "${process_start_time}" || return 1
    return 0
}

process_is_direct_child_of() {
    (($# == 4)) || return 2
    local pid=$1
    local expected_parent=$2
    local output_variable=$3
    local allow_zombie=$4
    local process_stat=''
    local process_state=''
    local process_parent=''
    local process_start_time=''
    local -a process_fields=()

    [[ ${pid} =~ ^[1-9][0-9]*$ && ${expected_parent} =~ ^[1-9][0-9]*$ ]] \
        || return 1
    [[ -r /proc/${pid}/stat ]] || return 1
    if ! { IFS= read -r process_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        return 1
    fi
    read -r -a process_fields <<<"${process_stat##*) }"
    ((${#process_fields[@]} > 19)) || return 1
    process_state=${process_fields[0]}
    process_parent=${process_fields[1]}
    process_start_time=${process_fields[19]}

    [[ ${process_state} != X ]] || return 1
    if [[ ${allow_zombie} != true && ${process_state} == Z ]]; then
        return 1
    fi
    [[ ${process_parent} == "${expected_parent}" ]] || return 1
    [[ ${process_start_time} =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v "${output_variable}" '%s' "${process_start_time}" || return 1
    return 0
}

download_worker_is_current() {
    local allow_zombie=$1
    local current_start_time=''

    [[ -n ${DOWNLOAD_WORKER_PID} && -n ${DOWNLOAD_WORKER_START_TIME} ]] \
        || return 1
    # shellcheck disable=SC2310 # Failure revokes direct-child authority.
    process_is_direct_child_of \
        "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
        current_start_time "${allow_zombie}" || return 1
    [[ ${current_start_time} == "${DOWNLOAD_WORKER_START_TIME}" ]]
}

download_group_is_current() {
    local current_start_time=''

    [[ -n ${DOWNLOAD_WORKER_PGID} &&
        -n ${DOWNLOAD_WORKER_PGID_START_TIME} ]] || return 1
    # shellcheck disable=SC2310 # Failure revokes process-group authority.
    process_is_session_group_leader \
        "${DOWNLOAD_WORKER_PGID}" '' current_start_time true || return 1
    [[ ${current_start_time} == "${DOWNLOAD_WORKER_PGID_START_TIME}" ]]
}

# A zombie leader can retain live sibling threads and their shared FDs.
process_threads_are_quiescent() {
    local pid=$1 expected_start=$2 task_path task_stat task_observation
    local tasks="" previous_tasks=""
    local -a fields=()

    for task_observation in 1 2; do
        tasks=""
        for task_path in /proc/"${pid}"/task/[0-9]*/stat; do
            if ! { IFS= read -r task_stat <"${task_path}"; } 2>/dev/null; then
                return 1
            fi
            read -r -a fields <<<"${task_stat##*) }"
            ((${#fields[@]} > 19)) || return 1
            [[ ${fields[0]} == Z || ${fields[0]} == X ]] || return 1
            tasks+="${task_path}:${fields[19]} "
        done
        [[ -n ${tasks} ]] || return 1
        [[ ${task_observation} != 2 || ${tasks} == "${previous_tasks}" ]] || return 1
        previous_tasks=${tasks}
    done
    if ! { IFS= read -r task_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        return 1
    fi
    read -r -a fields <<<"${task_stat##*) }"
    [[ ${fields[19]:-} == "${expected_start}" ]]
}

download_group_has_live_member() {
    local process_path=''
    local process_stat=''
    local observation members='' previous_members='' inventory_self_seen=false
    local -a process_fields=()

    local session_id=${DOWNLOAD_SESSION_ID:-${DOWNLOAD_WORKER_PGID}}
    [[ -n ${session_id} ]] || return 1
    # A member may fork after glob expansion and become a zombie before its
    # stat is read. Only two unchanged, complete quiescent inventories suffice.
    for observation in 1 2; do
        members=''
        inventory_self_seen=false
        for process_path in /proc/[1-9]*/stat; do
            if [[ ${process_path} == /proc/"${BASHPID}"/stat ]]; then
                inventory_self_seen=true
                continue
            fi
            process_stat=''
            if ! { IFS= read -r process_stat <"${process_path}"; } 2>/dev/null; then
                [[ ! -d ${process_path%/stat} ]] || return 0
                continue
            fi
            process_fields=()
            read -r -a process_fields <<<"${process_stat##*) }"
            ((${#process_fields[@]} > 19)) || return 0
            [[ ${process_fields[3]} == "${session_id}" ]] || continue
            [[ ${process_fields[0]} == Z || ${process_fields[0]} == X ]] || return 0
            # shellcheck disable=SC2310 # Any live task or uncertain read vetoes cleanup.
            process_threads_are_quiescent "${process_stat%% *}" "${process_fields[19]}" || return 0
            members+="${process_path}:${process_fields[19]} "
        done
        [[ ${inventory_self_seen} == true ]] || return 0
        if [[ ${observation} == 2 && ${members} != "${previous_members}" ]]; then
            return 0
        fi
        previous_members=${members}
    done
    return 1
}

download_group_is_absent() {
    [[ ${DOWNLOAD_WORKER_PGID} =~ ^[1-9][0-9]*$ ]] || return 1

    # After losing the leader, require ESRCH or stable zombie-only inventories.
    # EPERM or incomplete observation preserves state. Signal zero grants no
    # authority to send a real signal to this possibly recycled group.
    python3 - "${DOWNLOAD_WORKER_PGID}" <<'PY_GROUP_ABSENT'
import os
from pathlib import Path
import sys

def process_paths():
    """An explicit directory scan must fail, rather than silently match nothing."""
    paths = [entry / 'stat' for entry in Path('/proc').iterdir()
             if entry.name.isdecimal()]
    if Path(f'/proc/{os.getpid()}/stat') not in paths:
        raise OSError('incomplete process inventory')
    return paths


def process_quiescent(pid, start):
    """A zombie thread-group leader can still have running sibling threads."""
    previous = None
    for attempt in (0, 1):
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        if fields[19] != str(start) or fields[0] not in ('Z', 'X'):
            return False
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            row = (task / 'stat').read_text().rsplit(') ', 1)[1].split()
            if row[0] not in ('Z', 'X'):
                return False
            tasks.add((task.name, row[19]))
        if not tasks or (attempt and tasks != previous):
            return False
        previous = tasks
    return True

number = int(sys.argv[1])
try:
    os.kill(-number, 0)
except ProcessLookupError:
    sys.exit(0)
except OSError:
    sys.exit(1)
# An orphaned zombie still makes kill(0) succeed, but owns no live descriptor
# and cannot create a new child. Require a complete observation and revalidate
# the positive zombie witnesses instead of waiting for an external reaper.
zombies = []
try:
    for path in process_paths():
        try:
            fields = path.read_text().rsplit(') ', 1)[1].split()
        except FileNotFoundError:
            continue
        if int(fields[2]) == number or int(fields[3]) == number:
            if not process_quiescent(path.parent.name, fields[19]):
                sys.exit(1)
            zombies.append((path, fields[19]))
    if not zombies:
        sys.exit(1)
    # A member can fork after the first /proc enumeration and then become a
    # zombie. A second complete inventory must match before witnesses grant
    # quiescence; checking only the previously enumerated PIDs misses that child.
    repeated = []
    for path in process_paths():
        try:
            fields = path.read_text().rsplit(') ', 1)[1].split()
        except FileNotFoundError:
            continue
        if int(fields[2]) == number or int(fields[3]) == number:
            if not process_quiescent(path.parent.name, fields[19]):
                sys.exit(1)
            repeated.append((path, fields[19]))
    if set(repeated) != set(zombies):
        sys.exit(1)
    for path, start in zombies:
        try:
            fields = path.read_text().rsplit(') ', 1)[1].split()
        except FileNotFoundError:
            continue
        if fields[19] != start or not process_quiescent(path.parent.name, start):
            sys.exit(1)
except (OSError, ValueError, IndexError):
    sys.exit(1)
sys.exit(0)
PY_GROUP_ABSENT
}

get_path_identity() {
    local identity_output_variable=$1
    local path=$2
    local path_kind=$3
    local identity=''

    case ${path_kind} in
        directory)
            [[ ! -L ${path} && -d ${path} ]] || return 1
            ;;
        regular-file)
            [[ ! -L ${path} && -f ${path} ]] || return 1
            ;;
        *)
            return 2
            ;;
    esac

    identity=$(stat -c '%d:%i' -- "${path}" 2>/dev/null) || return 1
    [[ ${identity} =~ ^[0-9]+:[0-9]+$ ]] || return 1
    printf -v "${identity_output_variable}" '%s' "${identity}"
}

open_private_path_record() {
    local record_path=$1
    local opened_identity=''

    # shellcheck disable=SC2310 # Failure rejects an unauthenticated record.
    get_path_identity PATH_RECORD_IDENTITY "${record_path}" regular-file \
        || return 1
    exec {PATH_RECORD_FD}<>"${record_path}" || return 1
    PATH_RECORD_FD_PATH="/proc/${BASHPID}/fd/${PATH_RECORD_FD}"
    opened_identity=$(stat -Lc '%d:%i' -- "${PATH_RECORD_FD_PATH}" 2>/dev/null) \
        || return 1
    [[ ${opened_identity} == "${PATH_RECORD_IDENTITY}" ]] || return 1
}

path_record_temp_identity_matches() {
    local record_path=$1
    local current_identity=''

    [[ -n ${PATH_RECORD_IDENTITY} ]] || return 1
    # shellcheck disable=SC2310 # Failure is the false identity predicate.
    get_path_identity current_identity "${record_path}" regular-file \
        || return 1
    [[ ${current_identity} == "${PATH_RECORD_IDENTITY}" ]]
}

remove_owned_path_record_temp() {
    local record_path=$1

    if [[ ! -e ${record_path} && ! -L ${record_path} ]]; then
        return 0
    fi
    # shellcheck disable=SC2310 # A changed pathname is external state.
    path_record_temp_identity_matches "${record_path}" || return 1
    rm -f -- "${record_path}"
}

recover_download_pgid() {
    local candidate=''
    local candidate_start_time=''
    local expected_parent=''
    local children=''
    local children_file=''
    local -a child_pids=()

    if [[ -n ${DOWNLOAD_PGID_FILE} && -f ${DOWNLOAD_PGID_FILE} ]]; then
        if { IFS= read -r candidate <"${DOWNLOAD_PGID_FILE}"; } 2>/dev/null \
            && [[ ${candidate} =~ ^[1-9][0-9]*$ ]]; then
            if [[ ${candidate} == "${DOWNLOAD_WORKER_PID}" ]]; then
                expected_parent=${BASHPID}
            else
                expected_parent=${DOWNLOAD_WORKER_PID}
            fi
            candidate_start_time=''
            # shellcheck disable=SC2310 # Failure rejects an unauthenticated PGID.
            if process_is_session_group_leader \
                "${candidate}" "${expected_parent}" \
                candidate_start_time false; then
                DOWNLOAD_WORKER_PGID=${candidate}
                DOWNLOAD_WORKER_PGID_START_TIME=${candidate_start_time}
                return 0
            fi
        fi
    fi

    if [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
        children_file="/proc/${DOWNLOAD_WORKER_PID}/task/${DOWNLOAD_WORKER_PID}/children"
        if [[ -r ${children_file} ]] \
            && { IFS= read -r children <"${children_file}" || [[ -n ${children} ]]; } 2>/dev/null; then
            read -r -a child_pids <<<"${children}"
            for candidate in "${child_pids[@]}"; do
                [[ ${candidate} =~ ^[1-9][0-9]*$ ]] || continue
                candidate_start_time=''
                # shellcheck disable=SC2310 # Failure rejects an unrelated child.
                if process_is_session_group_leader \
                    "${candidate}" "${DOWNLOAD_WORKER_PID}" \
                    candidate_start_time false; then
                    DOWNLOAD_WORKER_PGID=${candidate}
                    DOWNLOAD_WORKER_PGID_START_TIME=${candidate_start_time}
                    return 0
                fi
            done
        fi
    fi

    return 1
}

signal_owned_process() {
    python3 -I -B - "$@" <<'PY_SIGNAL_OWNED'
import os
from pathlib import Path
import signal
import sys

pid, start, session, name = sys.argv[1:]
descriptor = None
try:
    descriptor = os.pidfd_open(int(pid))
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    if fields[19] != start or fields[3] != session:
        sys.exit(1)
    signal.pidfd_send_signal(descriptor, getattr(signal, 'SIG' + name))
except (AttributeError, OSError, ValueError, IndexError):
    sys.exit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)
PY_SIGNAL_OWNED
}

# Keep an authenticated parent frozen while its same-session children stop.
# pidfds pin delivery; a child in a private SID keeps its supervisor alive.
escalate_owned_process() {
    python3 -I -B - "$@" <<'PY_ESCALATE_OWNED'
import os
from pathlib import Path
import signal
import sys
import time

def process_paths():
    """An explicit directory scan must fail, rather than silently match nothing."""
    paths = [entry / 'stat' for entry in Path('/proc').iterdir()
             if entry.name.isdecimal()]
    if Path(f'/proc/{os.getpid()}/stat') not in paths:
        raise OSError('incomplete process inventory')
    return paths


def process_quiescent(pid, start):
    """A zombie thread-group leader can still have running sibling threads."""
    previous = None
    for attempt in (0, 1):
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        if fields[19] != str(start) or fields[0] not in ('Z', 'X'):
            return False
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            row = (task / 'stat').read_text().rsplit(') ', 1)[1].split()
            if row[0] not in ('Z', 'X'):
                return False
            tasks.add((task.name, row[19]))
        if not tasks or (attempt and tasks != previous):
            return False
        previous = tasks
    return True


def process_fields(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()


def frozen_children(pid):
    previous_tasks = None
    children = set()
    for observation in range(2):
        tasks = set()
        for task in Path(f'/proc/{pid}/task').iterdir():
            fields = (task / 'stat').read_text().rsplit(') ', 1)[1].split()
            if fields[0] not in ('T', 't', 'Z', 'X'):
                raise ValueError('thread is not stopped')
            tasks.add((task.name, fields[19]))
            # Children belong to the thread that created them. A frozen parent
            # cannot create another thread or child between inspection and KILL.
            children.update(map(int, (task / 'children').read_text().split()))
        if not tasks or (observation and tasks != previous_tasks):
            raise ValueError('thread inventory changed')
        previous_tasks = tasks
    return children


def other_session_members_quiescent(pid, session):
    previous = None
    for observation in range(2):
        members = set()
        for path in process_paths():
            if path.parent.name == str(pid):
                continue
            try:
                fields = path.read_text().rsplit(') ', 1)[1].split()
            except FileNotFoundError:
                continue
            if int(fields[3]) == session:
                if not process_quiescent(path.parent.name, fields[19]):
                    return False
                members.add((path, fields[19]))
        if observation and members != previous:
            return False
        previous = members
    return True


def retire(pid, expected_start, expected_session):
    descriptor = os.pidfd_open(pid)
    stopped = False

    def identity():
        fields = process_fields(pid)
        if int(fields[19]) != expected_start or int(fields[3]) != expected_session:
            raise ValueError('identity changed')
        return fields[0]

    try:
        if identity() in ('Z', 'X') and process_quiescent(pid, expected_start):
            return True
        signal.pidfd_send_signal(descriptor, signal.SIGSTOP)
        stopped = True
        deadline = time.monotonic() + .05
        while True:
            state = identity()
            if state in ('T', 't', 'Z', 'X'):
                try:
                    children = frozen_children(pid)
                    break
                except ValueError:
                    # A dead main thread stays Z while its siblings finish the
                    # group stop. Use the same original stop deadline for them.
                    if time.monotonic() >= deadline:
                        raise
            if time.monotonic() >= deadline:
                return False
            time.sleep(.005)
        for child in children:
            try:
                fields = process_fields(child)
            except FileNotFoundError:
                continue
            if int(fields[3]) != expected_session:
                # A timed helper pins a different SID even after its direct
                # child becomes a zombie. Only that helper can finish its wait.
                return False
            if not process_quiescent(child, fields[19]):
                # Keep this parent frozen: otherwise a startup wrapper can
                # recreate a sleep between two outer escalation attempts.
                retire(child, int(fields[19]), expected_session)
        if children:
            for child in frozen_children(pid):
                try:
                    fields = process_fields(child)
                except FileNotFoundError:
                    continue
                if int(fields[3]) != expected_session or not process_quiescent(child, fields[19]):
                    return False
        if pid == expected_session and not other_session_members_quiescent(pid, expected_session):
            return False
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        stopped = False
        return True
    finally:
        if stopped:
            # A timed helper interprets CONT as force only after its first
            # graceful request; ordinary parents are simply allowed to resume.
            try:
                signal.pidfd_send_signal(descriptor, signal.SIGCONT)
            except OSError:
                pass
        os.close(descriptor)


try:
    retire(*map(int, sys.argv[1:]))
except (AttributeError, OSError, ValueError, IndexError, RecursionError):
    sys.exit(1)
PY_ESCALATE_OWNED
}

signal_download_session_members() {
    local signal_name=$1 session_id=$2
    local process_path process_stat process_pid start_time
    local -a fields=() current=()

    for process_path in /proc/[1-9]*/stat; do
        [[ ${process_path} != /proc/"${BASHPID}"/stat ]] || continue
        if ! { IFS= read -r process_stat <"${process_path}"; } 2>/dev/null; then
            continue
        fi
        read -r -a fields <<<"${process_stat##*) }"
        ((${#fields[@]} > 19)) || continue
        [[ ${fields[3]} == "${session_id}" ]] || continue
        # shellcheck disable=SC2310 # A zombie main thread can still own running tasks.
        if [[ ${fields[0]} == Z || ${fields[0]} == X ]] \
            && process_threads_are_quiescent "${process_stat%% *}" "${fields[19]}"; then
            continue
        fi
        # Graceful signals may use the ordinary standalone group. KILL is
        # individual: a supervising helper must retain its pinned children.
        [[ ${signal_name} == KILL || ${REUSE_CURRENT_SESSION} == true || ${fields[2]} != "${session_id}" ]] || continue
        process_pid=${process_stat%% *}
        start_time=${fields[19]}
        if ! { IFS= read -r process_stat <"${process_path}"; } 2>/dev/null; then
            continue
        fi
        read -r -a current <<<"${process_stat##*) }"
        [[ ${current[19]:-} == "${start_time}" && ${current[3]:-} == "${session_id}" ]] || continue
        if [[ ${signal_name} == KILL ]]; then
            # shellcheck disable=SC2310 # Failed force delivery retains the quiescence veto.
            escalate_owned_process "${process_pid}" "${start_time}" "${session_id}" || true
        else
            # shellcheck disable=SC2310 # Failed delivery retains the independent presence veto.
            signal_owned_process "${process_pid}" "${start_time}" "${session_id}" "${signal_name}" || true
        fi
    done
}

signal_download_worker() {
    local signal_name=$1
    local candidate_start_time=''
    local group_signaled=false
    [[ ${signal_name} != KILL ]] || DOWNLOAD_FORCE_STOP=true

    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
        if [[ ${DOWNLOAD_SESSION_ID} == "${BASHPID}" ]]; then
            signal_download_session_members "${signal_name}" "${DOWNLOAD_SESSION_ID}"
        fi
        return 0
    fi

    if [[ -z ${DOWNLOAD_WORKER_PGID} ]]; then
        # In the no-fork topology the registered worker is already the group
        # leader before marker publication. Use that identity only for urgent
        # signaling: readiness must still wait until the inner env has restored
        # default dispositions and the worker has published its marker.
        candidate_start_time=''
        # shellcheck disable=SC2310 # Failure leaves discovery to the PGID record.
        if [[ -n ${DOWNLOAD_WORKER_PID} ]] \
            && process_is_session_group_leader \
                "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
                candidate_start_time false; then
            DOWNLOAD_WORKER_PGID=${DOWNLOAD_WORKER_PID}
            DOWNLOAD_WORKER_PGID_START_TIME=${candidate_start_time}
        fi
    fi

    if [[ -z ${DOWNLOAD_WORKER_PGID} ]]; then
        # shellcheck disable=SC2310 # A missing PGID is an expected race.
        recover_download_pgid || true
    fi

    if [[ -n ${DOWNLOAD_WORKER_PGID} ]]; then
        # Holding the authenticated sentinel leader alive across graceful
        # signals prevents its numeric process-group identity from being recycled.
        # shellcheck disable=SC2310 # Either predicate may safely revoke authority.
        if download_group_is_current && download_group_has_live_member; then
            # Escalate subgroups while the retained leader still authenticates
            # this session; main-group KILL can destroy that authority first.
            signal_download_session_members "${signal_name}" "${DOWNLOAD_WORKER_PGID}"
            if [[ ${signal_name} == KILL ]]; then
                group_signaled=true
            elif kill "-${signal_name}" -- "-${DOWNLOAD_WORKER_PGID}" 2>/dev/null; then
                group_signaled=true
            fi
        fi
        # Failed authority or delivery is not proof of quiescence. Retain the
        # observed group so wait/cleanup can still veto resource removal.
    fi

    [[ ${signal_name} != KILL || ${group_signaled} != true ]] || return 0
    if [[ ${signal_name} == KILL || ${group_signaled} == false ]] \
        && [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
        # shellcheck disable=SC2310 # Direct fallback requires the original child.
        if ! download_worker_is_current false; then
            return 0
        fi
        if [[ ${signal_name} == KILL ]]; then
            local worker_session=''
            local -a fields=()
            if { IFS= read -r worker_session <"/proc/${DOWNLOAD_WORKER_PID}/stat"; } 2>/dev/null; then
                read -r -a fields <<<"${worker_session##*) }"
                ((${#fields[@]} > 3)) || return 0
                # shellcheck disable=SC2310 # Failed force delivery retains the quiescence veto.
                escalate_owned_process "${DOWNLOAD_WORKER_PID}" "${DOWNLOAD_WORKER_START_TIME}" "${fields[3]}" || true
            fi
        else
            kill "-${signal_name}" -- "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
        fi
    fi

    return 0
}

wait_for_download_pgid() {
    local attempt

    for ((attempt = 0; attempt < 500; attempt++)); do
        if [[ ${REGISTRATION_ESCALATION_REQUESTED} == true ]]; then
            signal_download_worker KILL
            return 1
        fi
        # shellcheck disable=SC2310 # Predicate success means the PGID is ready.
        if recover_download_pgid; then
            return 0
        fi
        # shellcheck disable=SC2310 # Predicate failure means the worker exited.
        if [[ -n ${DOWNLOAD_WORKER_PID} ]] \
            && ! process_is_running "${DOWNLOAD_WORKER_PID}"; then
            return 1
        fi
        sleep 0.01
    done

    return 1
}

wait_for_download_ready() {
    local attempt
    local candidate=''

    for ((attempt = 0; attempt < 500; attempt++)); do
        if [[ ${REGISTRATION_ESCALATION_REQUESTED} == true ]]; then
            signal_download_worker KILL
            return 1
        fi
        if [[ -n ${DOWNLOAD_READY_FILE} && -f ${DOWNLOAD_READY_FILE} ]] \
            && { IFS= read -r candidate <"${DOWNLOAD_READY_FILE}"; } 2>/dev/null \
            && [[ ${candidate} == "${DOWNLOAD_WORKER_PID}" ]]; then
            return 0
        fi
        # shellcheck disable=SC2310 # Predicate failure means the wrapper exited.
        if [[ -n ${DOWNLOAD_WORKER_PID} ]] \
            && ! process_is_running "${DOWNLOAD_WORKER_PID}"; then
            return 1
        fi
        sleep 0.01
    done

    return 1
}

cleanup_download_registration_files() {
    if [[ -n ${DOWNLOAD_PGID_FILE} ]]; then
        rm -f -- \
            "${DOWNLOAD_PGID_FILE}" \
            "${DOWNLOAD_PGID_FILE}.tmp" || true
        DOWNLOAD_PGID_FILE=''
    fi
    if [[ -n ${DOWNLOAD_READY_FILE} ]]; then
        rm -f -- \
            "${DOWNLOAD_READY_FILE}" \
            "${DOWNLOAD_READY_FILE}.tmp" || true
        DOWNLOAD_READY_FILE=''
    fi
}

wait_for_download_exit() {
    local attempts=$1
    local attempt
    local worker_alive=false
    local worker_current=false
    local group_alive=false
    local wait_status=0

    for ((attempt = 0; attempt < attempts; attempt++)); do
        if [[ ${DOWNLOAD_FORCE_STOP} == true ]]; then
            # A consumer may fork between enumeration and signal delivery.
            # Keep escalation active without resetting its original deadline.
            signal_download_worker KILL
        fi
        worker_alive=false
        worker_current=false
        group_alive=false

        if [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
            # Never explicitly reap an observable leader while its authenticated
            # group still has live members. The standalone sentinel normally
            # remains alive itself until every descendant is quiescent.
            # shellcheck disable=SC2310 # Failure revokes direct-PID authority.
            if download_worker_is_current true; then
                worker_current=true
            fi
            # shellcheck disable=SC2310 # Predicate success means it is still alive.
            if [[ ${worker_current} == true ]] \
                && process_is_running "${DOWNLOAD_WORKER_PID}"; then
                worker_alive=true
            fi
        fi

        if [[ ${worker_alive} != true && -z ${DOWNLOAD_WORKER_PGID} &&
            -n ${DOWNLOAD_WORKER_PID} && ${REUSE_CURRENT_SESSION} != true ]]; then
            # In standalone no-fork topology, $! is the future session leader.
            # It may die after forking but before readiness adoption. Keep its
            # number only as a liveness veto, with no start-time authority.
            DOWNLOAD_WORKER_PGID=${DOWNLOAD_WORKER_PID}
            DOWNLOAD_WORKER_PGID_START_TIME=''
        fi

        if [[ ${worker_alive} != true && -n ${DOWNLOAD_SESSION_ID} ]]; then
            # The supervisor itself is excluded by the observation predicate.
            # shellcheck disable=SC2310 # Presence alone vetoes resource cleanup.
            if download_group_has_live_member; then
                group_alive=true
            else
                DOWNLOAD_SESSION_ID=''
            fi
        fi

        if [[ ${worker_alive} != true && -n ${DOWNLOAD_WORKER_PGID} ]]; then
            # Liveness can veto cleanup without authorizing a group signal.
            # A missing/recycled leader must never hide a surviving descendant.
            # shellcheck disable=SC2310 # Failed absence proof preserves tracking.
            if download_group_has_live_member; then
                group_alive=true
            elif ! download_group_is_current && ! download_group_is_absent; then
                group_alive=true
            else
                DOWNLOAD_WORKER_PGID=''
                DOWNLOAD_WORKER_PGID_START_TIME=''
            fi
        fi

        if [[ ${worker_alive} != true && ${group_alive} != true &&
            -n ${DOWNLOAD_WORKER_PID} ]]; then
            # `wait` can reap only this shell's registered child. Even if /proc
            # disappeared before the identity probe, it cannot target a reused
            # unrelated process.
            wait_status=0
            wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || wait_status=$?
            if [[ -z ${DOWNLOAD_WAITED_STATUS} ]]; then
                DOWNLOAD_WAITED_STATUS=${wait_status}
            fi
            DOWNLOAD_WORKER_PID=''
            DOWNLOAD_WORKER_START_TIME=''
        fi

        if [[ ${worker_alive} == false && ${group_alive} == false ]]; then
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
    # shellcheck disable=SC2310 # Failure must preserve the tracked resources.
    if wait_for_download_exit 20; then
        return 0
    fi
    # shellcheck disable=SC2310 # Lost authority is diagnostic, never a kill target.
    if [[ -n ${DOWNLOAD_WORKER_PGID} ]] && ! download_group_is_current; then
        printf '%s\n' \
            'Warning: command group leader identity was lost; shutdown is unconfirmed and group signaling is forbidden.' >&2
    fi
    return 1
}

run_supervised_command() {
    local registration_ready=false
    local worker_status=0
    local -a worker_command=("$@")

    DOWNLOAD_STATUS=125
    if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]]; then
        error 'previous command shutdown is unconfirmed; refusing to replace its process tracking.'
        return 0
    fi
    DOWNLOAD_WORKER_PID=''
    DOWNLOAD_WORKER_START_TIME=''
    DOWNLOAD_WORKER_PGID=''
    DOWNLOAD_WORKER_PGID_START_TIME=''
    DOWNLOAD_PGID_FILE=''
    DOWNLOAD_READY_FILE=''
    DOWNLOAD_WAITED_STATUS=''
    DOWNLOAD_FORCE_STOP=false

    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
        local engine_start_time=''
        # shellcheck disable=SC2310 # Only our actual dedicated session grants this scope.
        if ! process_is_session_group_leader "${BASHPID}" '' engine_start_time false; then
            error 'supervised-session engine is not its session leader.'
            return 0
        fi
        [[ -n ${engine_start_time} ]] || return 0
        DOWNLOAD_SESSION_ID=${BASHPID}
        if ! DOWNLOAD_READY_FILE=$(mktemp \
            --tmpdir="${OUTPUT_LOCK_ROOT}" \
            '.worker-ready.XXXXXXXX'); then
            error 'unable to create the command-readiness file.'
            return 0
        fi
        rm -f -- "${DOWNLOAD_READY_FILE}"

        # The GUI has already placed this engine and every descendant in one
        # dedicated session. Do not create a nested session that the GUI could
        # lose after an emergency SIGKILL of this wrapper.
        begin_signal_registration
        # shellcheck disable=SC2016 # Expanded by the intentionally nested shell.
        LC_ALL=C env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            bash -c '
            set -euo pipefail
            ready_file=$1
            shift
            ready_temporary="${ready_file}.tmp"
            trap "exit 129" HUP
            trap "exit 130" INT
            trap "exit 143" TERM
            printf "%s\n" "$$" >"${ready_temporary}" || exit 125
            mv -Tf -- "${ready_temporary}" "${ready_file}" || exit 125
            trap - HUP INT TERM
            exec "$@"
        ' bash "${DOWNLOAD_READY_FILE}" "${worker_command[@]}" &
        DOWNLOAD_WORKER_PID=$!
        # shellcheck disable=SC2310 # A fast failure is handled after registration.
        process_is_direct_child_of \
            "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
            DOWNLOAD_WORKER_START_TIME true || DOWNLOAD_WORKER_START_TIME=''
        # Keep signals deferred until env has restored their default disposition
        # and the post-env wrapper has atomically published its readiness.
        # shellcheck disable=SC2310
        if wait_for_download_ready; then
            registration_ready=true
            cleanup_download_registration_files
        fi
        finish_signal_registration
    else
        if ! DOWNLOAD_PGID_FILE=$(mktemp \
            --tmpdir="${OUTPUT_LOCK_ROOT}" \
            '.worker-pgid.XXXXXXXX'); then
            error 'unable to create the command process-group file.'
            return 0
        fi

        # Standalone CLI mode needs its own session so signals sent only to the
        # wrapper PID can be relayed to the complete command tree. The outer env
        # keeps the registration process immune to foreground-group signals.
        # With monitor mode disabled above, setsid does not need to fork: $!
        # remains the future session leader throughout the critical section.
        begin_signal_registration
        # shellcheck disable=SC2016 # Expanded by the intentionally nested shell.
        LC_ALL=C env \
            --ignore-signal=HUP \
            --ignore-signal=INT \
            --ignore-signal=TERM \
            setsid --wait env \
            --default-signal=HUP \
            --default-signal=INT \
            --default-signal=TERM \
            bash -c '
            set -euo pipefail
            pgid_file=$1
            shift
            # The sentinel must survive the first graceful group signal so it
            # remains an authenticated PGID anchor for bounded KILL escalation.
            trap "" HUP INT TERM
            env \
                --default-signal=HUP \
                --default-signal=INT \
                --default-signal=TERM \
                bash -c "
                    set -euo pipefail
                    pgid_file=\$1
                    shift
                    pgid_temporary=\"\${pgid_file}.tmp\"
                    printf \"%s\\n\" \"\${PPID}\" \
                        >\"\${pgid_temporary}\" || exit 125
                    mv -Tf -- \"\${pgid_temporary}\" \
                        \"\${pgid_file}\" || exit 125
                    exec \"\$@\"
                " bash "${pgid_file}" "$@" &
            command_pid=$!
            command_status=0
            wait "${command_pid}" || command_status=$?

            process_threads_are_quiescent() {
                local pid=$1 expected_start=$2 task_path task_stat task_observation
                local tasks="" previous_tasks=""
                local -a fields=()

                for task_observation in 1 2; do
                    tasks=""
                    for task_path in /proc/"${pid}"/task/[0-9]*/stat; do
                        if ! { IFS= read -r task_stat <"${task_path}"; } 2>/dev/null; then
                            return 1
                        fi
                        read -r -a fields <<<"${task_stat##*) }"
                        ((${#fields[@]} > 19)) || return 1
                        [[ ${fields[0]} == Z || ${fields[0]} == X ]] || return 1
                        tasks+="${task_path}:${fields[19]} "
                    done
                    [[ -n ${tasks} ]] || return 1
                    [[ ${task_observation} != 2 || ${tasks} == "${previous_tasks}" ]] || return 1
                    previous_tasks=${tasks}
                done
                if ! { IFS= read -r task_stat <"/proc/${pid}/stat"; } 2>/dev/null; then
                    return 1
                fi
                read -r -a fields <<<"${task_stat##*) }"
                [[ ${fields[19]:-} == "${expected_start}" ]]
            }
            # Stay alive as the authenticated session leader until every
            # same-session descendant has exited. A command may otherwise
            # orphan work after returning and make its numeric PGID unsafe to
            # reuse as signaling authority.
            while true; do
                group_member_alive=false
                previous_members=""
                for observation in 1 2; do
                    members=""
                    inventory_self_seen=false
                    for process_path in /proc/[1-9]*/stat; do
                        process_stat=""
                        if ! { IFS= read -r process_stat <"${process_path}"; } 2>/dev/null; then
                            if [[ -d ${process_path%/stat} ]]; then
                                group_member_alive=true
                                break
                            fi
                            continue
                        fi
                        process_pid=${process_stat%% *}
                        if [[ ${process_pid} == "$$" ]]; then
                            inventory_self_seen=true
                            continue
                        fi
                        process_fields=()
                        read -r -a process_fields <<<"${process_stat##*) }"
                        if ((${#process_fields[@]} <= 19)); then
                            group_member_alive=true
                            break
                        fi
                        [[ ${process_fields[3]} == "$$" ]] || continue
                        if [[ ${process_fields[0]} != Z && ${process_fields[0]} != X ]]; then
                            group_member_alive=true
                            break
                        fi
                        if ! process_threads_are_quiescent "${process_pid}" "${process_fields[19]}"; then
                            group_member_alive=true
                            break
                        fi
                        members+="${process_path}:${process_fields[19]} "
                    done
                    [[ ${inventory_self_seen} == true ]] || group_member_alive=true
                    [[ ${group_member_alive} == false ]] || break
                    if [[ ${observation} == 2 && ${members} != "${previous_members}" ]]; then
                        group_member_alive=true
                        break
                    fi
                    previous_members=${members}
                done
                [[ ${group_member_alive} == true ]] || break
                sleep 0.1
            done
            exit "${command_status}"
        ' bash "${DOWNLOAD_PGID_FILE}" "${worker_command[@]}" &
        DOWNLOAD_WORKER_PID=$!
        # shellcheck disable=SC2310 # A fast failure is handled after registration.
        process_is_direct_child_of \
            "${DOWNLOAD_WORKER_PID}" "${BASHPID}" \
            DOWNLOAD_WORKER_START_TIME true || DOWNLOAD_WORKER_START_TIME=''
        # PGID publication happens only after the inner env restored signal
        # dispositions inside the new session.
        # Holding the registration critical section until then prevents an
        # inherited ignored SIGINT from consuming the first shutdown request.
        # shellcheck disable=SC2310
        if wait_for_download_pgid; then
            registration_ready=true
            cleanup_download_registration_files
        fi
        finish_signal_registration
    fi

    # A command may fail before its readiness marker appears. Preserve the real
    # command status instead of converting a legitimate fast failure into the
    # internal startup status 125.
    if [[ ${registration_ready} != true ]]; then
        worker_status=0
        # shellcheck disable=SC2310
        if ! process_is_running "${DOWNLOAD_WORKER_PID}" \
            && wait_for_download_exit 1; then
            worker_status=${DOWNLOAD_WAITED_STATUS:-125}
            if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
                DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS:-143}
            else
                DOWNLOAD_STATUS=${worker_status}
            fi
            cleanup_download_registration_files
            return 0
        fi

        if [[ ${SHUTDOWN_REQUESTED} != true ]]; then
            if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
                error 'unable to confirm command readiness.'
            else
                error 'unable to determine the command process group.'
            fi
        fi
        # shellcheck disable=SC2310
        stop_download_worker || true
        if [[ -n ${REQUESTED_EXIT_STATUS} ]]; then
            DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS}
        elif [[ ${DOWNLOAD_WAITED_STATUS} =~ ^[0-9]+$ ]]; then
            DOWNLOAD_STATUS=${DOWNLOAD_WAITED_STATUS}
        fi
        if [[ -z ${DOWNLOAD_WORKER_PID} && -z ${DOWNLOAD_WORKER_PGID} ]]; then
            cleanup_download_registration_files
        fi
        return 0
    fi

    if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
        # shellcheck disable=SC2310
        if ! wait_for_download_exit 100; then
            signal_download_worker KILL
            # shellcheck disable=SC2310
            wait_for_download_exit 30 || true
        fi
        DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS:-143}
    else
        # Poll rather than immediately reaping the session leader. A command
        # can exit after leaving a same-session descendant behind; retaining
        # the leader identity is the only safe authority for later group
        # cancellation.
        # shellcheck disable=SC2310 # Bounded predicates keep long jobs responsive.
        while ! wait_for_download_exit 10; do
            [[ ${SHUTDOWN_REQUESTED} == true ]] && break
        done
        if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
            # A signal interrupted wait. Bound shutdown and reap any group
            # member that deliberately ignored the first graceful signal.
            # shellcheck disable=SC2310
            if ! wait_for_download_exit 100; then
                signal_download_worker KILL
                # shellcheck disable=SC2310
                wait_for_download_exit 30 || true
            fi
            DOWNLOAD_STATUS=${REQUESTED_EXIT_STATUS:-143}
        else
            DOWNLOAD_STATUS=${DOWNLOAD_WAITED_STATUS:-125}
        fi
    fi

    if [[ -z ${DOWNLOAD_WORKER_PID} && -z ${DOWNLOAD_WORKER_PGID} ]]; then
        cleanup_download_registration_files
    fi
    return 0
}

# Preserve yt-dlp stdout byte-for-byte for JSON/progress consumers while
# filtering a forbidden external source label from stderr before it can reach
# a terminal or GUI diagnostic log.
run_supervised_ytdlp() {
    (($# > 0)) || return 2

    # The quoted program is intentionally evaluated by the supervised shell.
    # shellcheck disable=SC2016
    run_supervised_command bash -c '
        set -o pipefail
        trap ":" HUP INT TERM
        forbidden_source_name=$(printf "\170\150\141\155\163\164\145\162")
        exec 3>&1
        {
            "$@" 2>&1 1>&3 3>&-
        } | (
            # The complete process group receives cancellation. Keep the
            # redactor alive until the producer closes its pipe so the producer
            # cannot lose its TERM handler to a concurrent SIGPIPE.
            trap "" HUP INT TERM
            LC_ALL=C exec sed -u -E \
                "s/${forbidden_source_name}/[REDACTED_SOURCE]/gI"
        ) >&2
        pipeline_statuses=("${PIPESTATUS[@]}")
        producer_status=${pipeline_statuses[0]:-125}
        redactor_status=${pipeline_statuses[1]:-125}
        exec 3>&-
        # Never turn a broken diagnostic redaction boundary into the
        # producer status. Otherwise preserve the exact yt-dlp result.
        if ((redactor_status != 0)); then
            exit "${redactor_status}"
        fi
        exit "${producer_status}"
    ' bash "$@"
}

remove_recorded_private_aria2_sensitive_file() {
    local sensitive_path=$1
    local recorded_identity=$2
    local current_identity=''

    [[ -n ${sensitive_path} && -n ${recorded_identity} ]] || return 0
    if [[ ! -e ${sensitive_path} && ! -L ${sensitive_path} ]]; then
        return 0
    fi
    # shellcheck disable=SC2310 # Failure preserves the sensitive pathname.
    get_path_identity current_identity "${sensitive_path}" regular-file \
        || return 1
    [[ ${current_identity} == "${recorded_identity}" ]] || return 1
    rm -f -- "${sensitive_path}"
}

remove_active_private_aria2_sensitive_metadata() {
    local current_staging_identity=''
    local removal_status=0
    local -a unrecorded_sensitive_names=()

    [[ -n ${PRIVATE_ARIA2_METADATA_IDENTITY} ]] || return 1
    # shellcheck disable=SC2310 # Failure preserves the complete staging tree.
    get_path_identity \
        current_staging_identity "${PRIVATE_ARIA2_METADATA}" directory \
        || return 1
    [[ ${current_staging_identity} == "${PRIVATE_ARIA2_METADATA_IDENTITY}" ]] \
        || return 1

    [[ -z ${PRIVATE_ARIA2_PLAN_IDENTITY} && -n ${PRIVATE_ARIA2_PLAN} ]] \
        && unrecorded_sensitive_names+=(plan.json)
    [[ -z ${PRIVATE_ARIA2_COOKIE_JAR_IDENTITY} &&
        -n ${PRIVATE_ARIA2_COOKIE_JAR} ]] \
        && unrecorded_sensitive_names+=(cookies.txt)
    [[ -z ${PRIVATE_ARIA2_INPUT_IDENTITY} && -n ${PRIVATE_ARIA2_INPUT} ]] \
        && unrecorded_sensitive_names+=(aria2.input)
    [[ -z ${PRIVATE_ARIA2_MANIFEST_IDENTITY} &&
        -n ${PRIVATE_ARIA2_MANIFEST} ]] \
        && unrecorded_sensitive_names+=(manifest.json)

    # shellcheck disable=SC2310 # Cleanup aggregates every removal failure.
    remove_recorded_private_aria2_sensitive_file \
        "${PRIVATE_ARIA2_PLAN}" "${PRIVATE_ARIA2_PLAN_IDENTITY}" \
        || removal_status=1
    # shellcheck disable=SC2310 # Cleanup aggregates every removal failure.
    remove_recorded_private_aria2_sensitive_file \
        "${PRIVATE_ARIA2_COOKIE_JAR}" "${PRIVATE_ARIA2_COOKIE_JAR_IDENTITY}" \
        || removal_status=1
    # shellcheck disable=SC2310 # Cleanup aggregates every removal failure.
    remove_recorded_private_aria2_sensitive_file \
        "${PRIVATE_ARIA2_INPUT}" "${PRIVATE_ARIA2_INPUT_IDENTITY}" \
        || removal_status=1
    # shellcheck disable=SC2310 # Cleanup aggregates every removal failure.
    remove_recorded_private_aria2_sensitive_file \
        "${PRIVATE_ARIA2_MANIFEST}" "${PRIVATE_ARIA2_MANIFEST_IDENTITY}" \
        || removal_status=1
    # Creation precedes identity recording by a few commands. Remove only the
    # unrecorded names through the ownership marker fallback; an identity-bound
    # file that changed must stay preserved as ambiguous external state.
    # shellcheck disable=SC2310 # Marker cleanup contributes to the aggregate.
    if ((${#unrecorded_sensitive_names[@]} > 0)) \
        && ! remove_marked_private_aria2_sensitive_metadata \
            "${PRIVATE_ARIA2_METADATA}" \
            "${unrecorded_sensitive_names[@]}"; then
        removal_status=1
    fi
    return "${removal_status}"
}

remove_marked_private_aria2_sensitive_metadata() {
    (($# > 1)) || return 2
    local candidate=$1
    shift
    local candidate_name=${candidate##*/}
    local candidate_owner=''
    local candidate_mode=''
    local candidate_parent=''
    local marker_path="${candidate}/${PRIVATE_ARIA2_STAGING_MARKER}"
    local marker_owner=''
    local marker_mode=''
    local marker_size=''
    local marker_value=''
    local sensitive_name=''
    local sensitive_path=''
    local sensitive_owner=''
    local sensitive_mode=''
    local removal_status=0
    local -a sensitive_names=("$@")

    [[ ${candidate} == "${PRIVATE_ARIA2_METADATA}" ]] || return 1
    [[ ${candidate_name} =~ ^[.]yt-dlp-aria2[.][A-Za-z0-9]{8}$ ]] || return 1
    [[ ! -L ${candidate} && -d ${candidate} ]] || return 1
    candidate_owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null) || return 1
    candidate_mode=$(stat -c '%a' -- "${candidate}" 2>/dev/null) || return 1
    [[ ${candidate_owner} == "${EUID}" && ${candidate_mode} == 700 ]] || return 1
    candidate_parent=$(realpath -e -- "${candidate}/.." 2>/dev/null) || return 1
    [[ ${candidate_parent} == "${OUTPUT_LOCK_ROOT}" ]] || return 1

    [[ ! -L ${marker_path} && -f ${marker_path} ]] || return 1
    marker_owner=$(stat -c '%u' -- "${marker_path}" 2>/dev/null) || return 1
    marker_mode=$(stat -c '%a' -- "${marker_path}" 2>/dev/null) || return 1
    marker_size=$(stat -c '%s' -- "${marker_path}" 2>/dev/null) || return 1
    [[ ${marker_owner} == "${EUID}" && ${marker_mode} == 600 ]] || return 1
    [[ ${marker_size} == "$((${#PRIVATE_ARIA2_STAGING_MARKER_VALUE} + 1))" ]] \
        || return 1
    IFS= read -r marker_value <"${marker_path}" || return 1
    [[ ${marker_value} == "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" ]] || return 1

    for sensitive_name in "${sensitive_names[@]}"; do
        case ${sensitive_name} in
            plan.json | cookies.txt | aria2.input | manifest.json) ;;
            *) return 2 ;;
        esac
        sensitive_path="${candidate}/${sensitive_name}"
        if [[ ! -e ${sensitive_path} && ! -L ${sensitive_path} ]]; then
            continue
        fi
        if [[ -L ${sensitive_path} || ! -f ${sensitive_path} ]]; then
            removal_status=1
            continue
        fi
        sensitive_owner=$(stat -c '%u' -- "${sensitive_path}" 2>/dev/null) \
            || {
                removal_status=1
                continue
            }
        sensitive_mode=$(stat -c '%a' -- "${sensitive_path}" 2>/dev/null) \
            || {
                removal_status=1
                continue
            }
        if [[ ${sensitive_owner} != "${EUID}" || ${sensitive_mode} != 600 ]] \
            || ! rm -f -- "${sensitive_path}"; then
            removal_status=1
        fi
    done
    return "${removal_status}"
}

private_aria2_staging_candidate_is_safe() {
    local candidate=$1
    local -n validated_entries=$2
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
    local inventory_pid=''
    local inventory_status=0
    local -a inventory=()

    validated_entries=()

    [[ ${candidate_name} =~ ^[.]yt-dlp-aria2[.][A-Za-z0-9]{8}$ ]] || return 1
    [[ ! -L ${candidate} && -d ${candidate} ]] || return 1

    candidate_owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null) || return 1
    candidate_mode=$(stat -c '%a' -- "${candidate}" 2>/dev/null) || return 1
    [[ ${candidate_owner} == "${EUID}" && ${candidate_mode} == 700 ]] || return 1

    candidate_parent=$(realpath -e -- "${candidate}/.." 2>/dev/null) || return 1
    [[ ${candidate_parent} == "${OUTPUT_DIR}" ]] || return 1

    # A process substitution does not propagate find's status to its consumer.
    # Acquire one complete inventory, wait for its producer, then validate every
    # entry before granting any deletion authority. Never rescan for deletion.
    # shellcheck disable=SC2312 # The producer's $! is explicitly waited below, separately from mapfile.
    mapfile -d '' -t inventory < <(
        find "${candidate}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
    ) || inventory_status=$?
    inventory_pid=$!
    wait "${inventory_pid}" || inventory_status=$?
    ((inventory_status == 0)) || return 1

    for entry in "${inventory[@]}"; do
        entry_name=${entry##*/}
        [[ ! -L ${entry} && -f ${entry} ]] || return 1

        entry_owner=$(stat -c '%u' -- "${entry}" 2>/dev/null) || return 1
        entry_mode=$(stat -c '%a' -- "${entry}" 2>/dev/null) || return 1
        [[ ${entry_owner} == "${EUID}" && ${entry_mode} == 600 ]] || return 1

        case ${entry_name} in
            "${PRIVATE_ARIA2_STAGING_MARKER}")
                [[ ${marker_seen} == false ]] || return 1
                marker_size=$(stat -c '%s' -- "${entry}" 2>/dev/null) || return 1
                [[ ${marker_size} == "$((${#PRIVATE_ARIA2_STAGING_MARKER_VALUE} + 1))" ]] \
                    || return 1
                marker_value=''
                IFS= read -r marker_value <"${entry}" || return 1
                [[ ${marker_value} == "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" ]] \
                    || return 1
                marker_seen=true
                ;;
            plan.json | cookies.txt | aria2.input | manifest.json | \
                item-[0-9][0-9][0-9].download | \
                item-[0-9][0-9][0-9].download.aria2)
                ;;
            *)
                return 1
                ;;
        esac
    done

    [[ ${marker_seen} == true ]] || return 1
    # shellcheck disable=SC2034 # This nameref returns the fully validated inventory to the caller.
    validated_entries=("${inventory[@]}")
}

remove_private_aria2_staging_candidate() {
    local candidate=$1
    local entry=''
    local -a entries=()

    # shellcheck disable=SC2310 # Predicate explicitly handles failures; validation failure stops deletion.
    private_aria2_staging_candidate_is_safe "${candidate}" entries \
        || return 1

    for entry in "${entries[@]}"; do
        [[ ! -L ${entry} && -f ${entry} ]] || return 1
        rm -f -- "${entry}" || return 1
    done

    rmdir -- "${candidate}"
}

report_abandoned_private_aria2_staging() {
    local candidate=''
    # Old sessions have no retained identity or live descriptor in this process.
    # A marker, owner, age or familiar basename cannot authorize deletion.
    # Only active, descriptor-bound temporaries are removed by cleanup.
    for candidate in "${OUTPUT_DIR}"/.yt-dlp-aria2.????????; do
        [[ -e ${candidate} || -L ${candidate} ]] || continue
        printf 'Warning: preserving legacy staging for manual inspection: %s\n' \
            "${candidate##*/}" >&2
    done
}

capture_media_probe() {
    local capture_file="${PRIVATE_ARIA2_METADATA}/probe.json"
    PROBE_OUTPUT_FILE=${capture_file}
    LC_ALL=C run_supervised_command python3 "${PROCESS_SUPERVISOR}" \
        --timeout 15 --grace 2 -- ffprobe "$@" >"${capture_file}" 2>/dev/null
    if [[ -n ${REQUESTED_EXIT_STATUS} ]]; then
        exit "${REQUESTED_EXIT_STATUS}"
    fi
    if ((DOWNLOAD_STATUS != 0)); then
        return "${DOWNLOAD_STATUS}"
    fi
    return 0
}

probe_media_summary() {
    local summary_variable=$1 media_path=$2
    local summary_value='' probe_status=0

    # shellcheck disable=SC2310 # Probe failures become explicit validation results.
    capture_media_probe -v error \
        -show_entries 'format=start_time,duration:stream=codec_type:stream_disposition=attached_pic' \
        -of json \
        "${media_path}" || probe_status=$?
    ((probe_status != 124 && probe_status != 137)) || return 124
    ((probe_status == 0)) || return 1
    summary_value=$(python3 -c '
import json
import sys
from decimal import Decimal, InvalidOperation

try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)

streams = payload.get("streams", [])
if not isinstance(streams, list):
    raise SystemExit(2)

audio_present = False
video_present = False
for stream in streams:
    if not isinstance(stream, dict):
        continue
    codec_type = stream.get("codec_type")
    disposition = stream.get("disposition")
    if not isinstance(disposition, dict):
        disposition = {}
    if codec_type == "audio":
        audio_present = True
    elif (
        codec_type == "video"
        and disposition.get("attached_pic", 0) != 1
    ):
        video_present = True

format_info = payload.get("format") or {}
if not isinstance(format_info, dict):
    format_info = {}

limit = Decimal("9000000000000")
scale = Decimal(1000000)

def parse_microseconds(raw_value, *, require_positive):
    try:
        value = Decimal(str(raw_value))
    except (InvalidOperation, ValueError):
        return "-"
    if not value.is_finite() or abs(value) > limit:
        return "-"
    if require_positive and value <= 0:
        return "-"
    return str(int(value * scale))

start_microseconds = parse_microseconds(
    format_info.get("start_time"),
    require_positive=False,
)
duration_microseconds = parse_microseconds(
    format_info.get("duration"),
    require_positive=True,
)

print(
    "true" if video_present else "false",
    "true" if audio_present else "false",
    start_microseconds,
    duration_microseconds,
)
' <"${PROBE_OUTPUT_FILE}") || return 1
    printf -v "${summary_variable}" '%s' "${summary_value}"
}

probe_duration_microseconds() {
    local probe_duration_output_variable=$1
    local media_path=$2
    local probe_duration=''
    local probe_seconds=''
    local probe_fraction=''
    local probe_duration_microseconds=''
    local seconds_bound_comparison=1

    # shellcheck disable=SC2310 # Missing duration remains an explicit unknown.
    if capture_media_probe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "${media_path}"; then
        probe_duration=$(<"${PROBE_OUTPUT_FILE}")
        probe_duration=${probe_duration%%$'\n'*}
        if [[ ${probe_duration} =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
            probe_seconds=${BASH_REMATCH[1]}
            probe_fraction=${BASH_REMATCH[3]:-0}
            probe_fraction="${probe_fraction}000000"
            probe_fraction=${probe_fraction:0:6}
            normalize_decimal_component probe_seconds "${probe_seconds}"
            compare_decimal_components \
                seconds_bound_comparison "${probe_seconds}" '9000000000000'
            if ((seconds_bound_comparison <= 0)); then
                probe_duration_microseconds=$((\
                    10#${probe_seconds} * 1000000 + 10#${probe_fraction}))
            fi
        fi
    fi

    printf -v "${probe_duration_output_variable}" '%s' \
        "${probe_duration_microseconds}"
    return 0
}

validate_stream_tail_reaches_target() {
    local media_path=$1
    local selector=$2
    local seek_seconds=$3
    local target_seconds=$4
    local probe_status=0 parser_status=0

    # Exit status contract:
    #   0 = the selected stream reaches the acceptance threshold
    #   1 = probe succeeded but the selected stream ends before the threshold
    #   2 = FFprobe/parser failure; fail closed
    # shellcheck disable=SC2310 # Probe failures become explicit validation results.
    capture_media_probe -v error \
        -read_intervals "${seek_seconds}%" \
        -select_streams "${selector}" \
        -show_packets \
        -show_entries packet=pts_time,dts_time,duration_time \
        -of json \
        "${media_path}" || probe_status=$?
    ((probe_status == 0)) || return 2
    python3 -c '
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
' "${target_seconds}" <"${PROBE_OUTPUT_FILE}" || parser_status=$?
    case ${parser_status} in
        0 | 1) return "${parser_status}" ;;
        *) return 2 ;;
    esac
}

validate_media_tail_consistency() {
    local media_path=$1
    local mode=$2
    local start_microseconds=$3
    local duration_microseconds=$4
    local tolerance_microseconds=0
    local target_microseconds=0
    local seek_microseconds=0
    local max_positive_start=0
    local target_seconds=''
    local seek_seconds=''
    local tail_probe_status=0

    MEDIA_TAIL_VALIDATION_REASON=''

    [[ ${start_microseconds} =~ ^-?[0-9]+$ ]] || return 0
    [[ ${duration_microseconds} =~ ^[1-9][0-9]*$ ]] || return 0

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
                *)
                    MEDIA_TAIL_VALIDATION_REASON='probe-tail-error'
                    return 1
                    ;;
            esac

            validate_stream_tail_reaches_target \
                "${media_path}" 'a:0' "${seek_seconds}" "${target_seconds}"
            tail_probe_status=$?
            if ((tail_probe_status != 0)); then
                if ((tail_probe_status == 1)); then
                    MEDIA_TAIL_VALIDATION_REASON='tail-inconsistent'
                else
                    MEDIA_TAIL_VALIDATION_REASON='probe-tail-error'
                fi
                return 1
            fi
            return 0
            ;;
        audio)
            validate_stream_tail_reaches_target \
                "${media_path}" 'a:0' "${seek_seconds}" "${target_seconds}"
            tail_probe_status=$?
            if ((tail_probe_status != 0)); then
                if ((tail_probe_status == 1)); then
                    MEDIA_TAIL_VALIDATION_REASON='tail-inconsistent'
                else
                    MEDIA_TAIL_VALIDATION_REASON='probe-tail-error'
                fi
                return 1
            fi
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
    local media_summary=''
    local video_present=false
    local audio_present=false
    local start_microseconds='-'
    local duration_microseconds='-'
    local unexpected_summary_field=''
    local media_summary_status=0
    local tail_status=0

    FINAL_MEDIA_VALIDATION_REASON='unknown'
    if [[ ! -f ${final_path} || ! -s ${final_path} ]]; then
        FINAL_MEDIA_VALIDATION_REASON='missing-or-empty-file'
        return 1
    fi

    # probe_media_summary supervises the probe before parsing; failure is
    # deliberately converted into a stable validation reason.
    # shellcheck disable=SC2310
    probe_media_summary media_summary "${final_path}" \
        || media_summary_status=$?
    if ((media_summary_status != 0)); then
        if ((media_summary_status == 124)); then
            FINAL_MEDIA_VALIDATION_REASON='probe-timeout'
        else
            FINAL_MEDIA_VALIDATION_REASON='probe-error'
        fi
        return 1
    fi
    read -r \
        video_present audio_present \
        start_microseconds duration_microseconds unexpected_summary_field \
        <<<"${media_summary}"
    if [[ ${video_present} != true && ${video_present} != false ]] \
        || [[ ${audio_present} != true && ${audio_present} != false ]] \
        || [[ -n ${unexpected_summary_field} ]]; then
        FINAL_MEDIA_VALIDATION_REASON='probe-error'
        return 1
    fi

    case ${mode} in
        video)
            if [[ ${video_present} != true ]]; then
                FINAL_MEDIA_VALIDATION_REASON='missing-content-video'
                return 1
            fi
            if [[ ${audio_present} != true ]]; then
                FINAL_MEDIA_VALIDATION_REASON='missing-audio'
                return 1
            fi
            ;;
        audio)
            if [[ ${audio_present} != true ]]; then
                FINAL_MEDIA_VALIDATION_REASON='missing-audio'
                return 1
            fi
            if [[ ${video_present} != false ]]; then
                FINAL_MEDIA_VALIDATION_REASON='unexpected-content-video'
                return 1
            fi
            ;;
        *)
            FINAL_MEDIA_VALIDATION_REASON='invalid-mode'
            return 2
            ;;
    esac

    validate_media_tail_consistency \
        "${final_path}" "${mode}" \
        "${start_microseconds}" "${duration_microseconds}"
    tail_status=$?
    if ((tail_status != 0)); then
        FINAL_MEDIA_VALIDATION_REASON=${MEDIA_TAIL_VALIDATION_REASON:-tail-inconsistent}
        return 1
    fi
    FINAL_MEDIA_VALIDATION_REASON='ok'
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

# Parse only the public CLI surface. Semantic URL/mode validation is kept in
# dedicated phases so main() remains an orchestration function.
parse_arguments() {
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
}

# Resolve the single URL from argv or its private file and classify its host.
resolve_requested_url() {
    local url_control_pattern=$'[\001-\037\177]'
    local url_file_mode=''
    local url_file_owner=''
    local url_line=''
    local url_line_count=0
    local url_authority=''

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
        if ! url_file_mode=$(stat -c '%a' -- "${URL_FILE}" 2>/dev/null) \
            || [[ ! ${url_file_mode} =~ ^[0-7]{3,4}$ ]]; then
            error 'unable to determine the URL file permissions.'
            exit 2
        fi
        if ((8#${url_file_mode} & 077)); then
            error 'the URL file must not be accessible by group or other users.'
            exit 2
        fi
        # Ordinary Bash read silently discards NUL bytes. Detect that delimiter
        # first, in bounded chunks, before decoding the URL as newline text.
        while IFS= read -r -d '' -n 65536 url_line; do
            if ((${#url_line} < 65536)); then
                error 'the URL must not contain control characters.'
                exit 2
            fi
        done <"${URL_FILE}"
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
    if [[ ${URL} =~ ${url_control_pattern} ]]; then
        error 'the URL must not contain control characters.'
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
}

# Validate option combinations after URL classification is available.
validate_mode_selection() {
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
}

# Resolve required commands, adjacent helpers, and managed runtime executables.
initialize_runtime_dependencies() {
    local command_name
    local script_path
    local script_dir
    local runtime_manager
    local runtime_action
    local runtime_attestation=''
    local runtime_status=0

    for command_name in aria2c env ffmpeg ffprobe python3 sed stdbuf tr realpath grep ln mktemp mv rm rmdir chmod flock mkdir sha256sum stat setsid sleep timeout find; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            error "required command \"${command_name}\" was not found."
            exit 127
        fi
    done
    check_env_capabilities
    check_setsid_capabilities

    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
        error 'unable to resolve the engine path.'
        exit 66
    }
    script_dir=${script_path%/*}
    runtime_manager="${script_dir}/runtime-manager.sh"
    PRIVATE_ARIA2_HELPER="${script_dir}/private-aria2-plan.py"

    if [[ -L ${PRIVATE_ARIA2_HELPER} ||
        ! -f ${PRIVATE_ARIA2_HELPER} ||
        ! -r ${PRIVATE_ARIA2_HELPER} ]]; then
        error "private aria2 helper is missing or unsafe: ${PRIVATE_ARIA2_HELPER}"
        exit 66
    fi
    PROCESS_SUPERVISOR="${script_dir}/private-process-supervisor.py"
    if [[ ! -f ${PROCESS_SUPERVISOR} || -L ${PROCESS_SUPERVISOR} || ! -r ${PROCESS_SUPERVISOR} ]]; then
        error 'the timed-command supervisor is missing or unsafe.'
        exit 66
    fi
    readonly PROCESS_SUPERVISOR
    readonly PRIVATE_ARIA2_HELPER
    if ! python3 -I -B "${PROCESS_SUPERVISOR}" --check-capabilities; then
        error 'Linux process supervision is unavailable; refusing to start a download.'
        exit 69
    fi

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
        # shellcheck disable=SC2310 # Failure becomes a bounded setup diagnostic.
        if ! resolve_lock_root || [[ -z ${OUTPUT_LOCK_ROOT} ]]; then
            error 'unable to resolve the runtime-attestation directory.'
            exit 73
        fi
        RUNTIME_ATTESTATION_TMP=$(mktemp \
            --tmpdir="${OUTPUT_LOCK_ROOT}" \
            '.runtime-attestation.XXXXXXXX') || {
            error 'unable to create the private runtime attestation file.'
            exit 70
        }
        if ! chmod 600 -- "${RUNTIME_ATTESTATION_TMP}"; then
            error 'unable to secure the private runtime attestation file.'
            exit 70
        fi
        run_supervised_command \
            "${runtime_manager}" prepare "${runtime_action}" \
            >"${RUNTIME_ATTESTATION_TMP}"
        runtime_status=${DOWNLOAD_STATUS}
        if ((runtime_status != 0)); then
            if [[ ${SHUTDOWN_REQUESTED} == true ]]; then
                exit "${REQUESTED_EXIT_STATUS:-143}"
            fi
            error 'unable to initialize the managed yt-dlp and Deno runtimes.'
            exit 69
        fi
        runtime_attestation=$(<"${RUNTIME_ATTESTATION_TMP}")
        rm -f -- "${RUNTIME_ATTESTATION_TMP}"
        RUNTIME_ATTESTATION_TMP=''
        # shellcheck disable=SC2310 # The parser checks every assignment and reports bounded diagnostics.
        if ! parse_managed_runtime_attestation "${runtime_attestation}"; then
            error 'unable to resolve the attested managed runtimes.'
            exit 69
        fi
    fi
    readonly YTDLP_BIN DENO_BIN MANAGED_RUNTIME_ATTESTED
    readonly MANAGED_YTDLP_VERSION MANAGED_DENO_VERSION

    if [[ ! -x ${YTDLP_BIN} ]]; then
        error 'the selected yt-dlp runtime is not executable.'
        exit 127
    fi

    # Keep this as a simple command: placing it in an if/|| context would disable
    # errexit inside the function body under Bash's documented rules.
    check_runtime_compatibility
    readonly ARIA2_SUPPORTS_NO_NETRC
    readonly ARIA2_HTTPS_DIRECT_SAFE
}

# A canonical directory chain may cross a shared location such as /tmp only
# when sticky-bit ownership rules prevent another user from replacing its
# descendants. This makes later pathname-based private staging safe against a
# different UID without excluding root-owned system parents or user mounts.
private_directory_chain_is_safe() {
    local candidate=$1
    local component=''
    local current_path=/
    local metadata=''
    local mode=''
    local mode_value=0
    local owner=''
    local remainder=${candidate#/}
    local root_owner=''
    local unexpected=''

    [[ ${candidate} == /* && -d ${candidate} ]] || return 1
    root_owner=$(stat -c '%u' -- / 2>/dev/null) || return 1
    [[ ${root_owner} =~ ^[0-9]+$ ]] || return 1

    while true; do
        [[ -d ${current_path} && ! -L ${current_path} ]] || return 1
        metadata=$(stat -c '%u:%a' -- "${current_path}" 2>/dev/null) \
            || return 1
        IFS=: read -r owner mode unexpected <<<"${metadata}"
        [[ -z ${unexpected} && ${owner} =~ ^[0-9]+$ &&
            ${mode} =~ ^[0-7]{3,4}$ ]] || return 1
        [[ ${owner} == 0 || ${owner} == "${root_owner}" ||
            ${owner} == "${EUID}" ]] || return 1
        mode_value=$((8#${mode}))
        if ((mode_value & 0022)) && ! ((mode_value & 01000)); then
            return 1
        fi

        [[ -n ${remainder} ]] || break
        if [[ ${remainder} == */* ]]; then
            component=${remainder%%/*}
            remainder=${remainder#*/}
        else
            component=${remainder}
            remainder=''
        fi
        [[ -n ${component} ]] || return 1
        current_path="${current_path%/}/${component}"
    done

    return 0
}

# Canonicalize and lock the destination before creating any transfer state.
prepare_output_directory() {
    local opened_identity=''
    local literal_dollar='%(id&$|$)s'
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
    FINAL_OUTPUT_DIR=${OUTPUT_DIR}
    readonly FINAL_OUTPUT_DIR
    if [[ ! -w ${OUTPUT_DIR} || ! -x ${OUTPUT_DIR} ]]; then
        error "destination directory is not writable: ${OUTPUT_DIR}"
        exit 13
    fi
    # Record the chosen media directory before selecting any local workspace.
    # shellcheck disable=SC2310 # A changed directory cannot receive a result.
    if ! exec {FINAL_OUTPUT_FD}<"${OUTPUT_DIR}" \
        || ! get_path_identity FINAL_OUTPUT_IDENTITY "${OUTPUT_DIR}" directory \
        || ! opened_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${FINAL_OUTPUT_FD}") \
        || [[ ${opened_identity} != "${FINAL_OUTPUT_IDENTITY}" ]]; then
        error 'unable to authenticate the destination directory.'
        exit 73
    fi
    readonly FINAL_OUTPUT_IDENTITY
    acquire_output_lock "${OUTPUT_DIR}"

    if python3 "${PRIVATE_ARIA2_HELPER}" media-local-safe --output-dir "${OUTPUT_DIR}"; then
        report_abandoned_private_aria2_staging
    else
        local media_root=''
        if ! media_root=$(python3 "${PRIVATE_ARIA2_HELPER}" private-root --disk); then
            error 'this destination requires a private local disk workspace, but none is usable.'
            exit 73
        fi
        begin_signal_registration
        if ! MEDIA_WORKSPACE=$(mktemp -d --tmpdir="${media_root}" '.media-work.XXXXXXXX'); then
            finish_signal_registration
            error 'unable to create a private local media workspace.'
            exit 73
        fi
        # shellcheck disable=SC2310 # Register the new exclusive directory before replaying signals.
        if ! exec {MEDIA_WORKSPACE_FD}<"${MEDIA_WORKSPACE}" \
            || ! get_path_identity MEDIA_WORKSPACE_IDENTITY "${MEDIA_WORKSPACE}" directory \
            || ! opened_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${MEDIA_WORKSPACE_FD}") \
            || [[ ${opened_identity} != "${MEDIA_WORKSPACE_IDENTITY}" ]]; then
            # A pathname observed after open may identify a replacement, not
            # the allocated directory. It must not grant cleanup authority.
            MEDIA_WORKSPACE_IDENTITY=''
            finish_signal_registration
            error 'unable to authenticate the local media workspace.'
            exit 73
        fi
        finish_signal_registration
        OUTPUT_DIR=${MEDIA_WORKSPACE}
        if [[ ${MACHINE_PROGRESS} == true ]]; then
            printf '%s\n' 'YTDLP_STORAGE|local-disk'
        fi
        print_human_line 'The selected destination requires local disk staging. Media will be copied there after validation.'
        print_human_line "Local media workspace: ${MEDIA_WORKSPACE}"
        print_human_line 'Allow space for downloaded streams and merged/remuxed output on this local disk.'
        # Old destination staging has no authenticated identity in this session.
        # Never scan or delete similarly named residues on the shared filesystem.
    fi
    readonly OUTPUT_DIR
    OUTPUT_DIR_TEMPLATE=${OUTPUT_DIR//%/%%}
    # yt-dlp expands environment variables before its metadata templates. Emit
    # dollars during template evaluation, after escaping the literal percents.
    OUTPUT_DIR_TEMPLATE=${OUTPUT_DIR_TEMPLATE//\$/"${literal_dollar}"}
    readonly OUTPUT_DIR_TEMPLATE
}

# Create private path records and aria2/yt-dlp transfer metadata.
prepare_private_work_files() {
    local result_name
    local result_parent
    local staging_marker_path
    local opened_identity=''

    begin_signal_registration
    if ! PRIVATE_ARIA2_METADATA=$(mktemp -d \
        --tmpdir="${OUTPUT_LOCK_ROOT}" '.yt-dlp-aria2.XXXXXXXX'); then
        finish_signal_registration
        error 'unable to create the local private metadata directory.'
        exit 73
    fi
    # shellcheck disable=SC2310 # Identity is registered before signal delivery.
    if ! exec {PRIVATE_ARIA2_METADATA_FD}<"${PRIVATE_ARIA2_METADATA}" \
        || ! get_path_identity PRIVATE_ARIA2_METADATA_IDENTITY \
            "${PRIVATE_ARIA2_METADATA}" directory \
        || ! opened_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${PRIVATE_ARIA2_METADATA_FD}") \
        || [[ ${opened_identity} != "${PRIVATE_ARIA2_METADATA_IDENTITY}" ]]; then
        PRIVATE_ARIA2_METADATA_IDENTITY=''
        finish_signal_registration
        error 'unable to authenticate the local private metadata directory.'
        exit 73
    fi
    finish_signal_registration
    staging_marker_path="${PRIVATE_ARIA2_METADATA}/${PRIVATE_ARIA2_STAGING_MARKER}"
    printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" >"${staging_marker_path}"
    # Firefox extraction makes its own temporary cookie database copies.
    # Override ambient locations only after the shared allocator has validated
    # this local private root; downstream tools inherit the same confinement.
    export TMPDIR="${PRIVATE_ARIA2_METADATA}"
    export TMP="${PRIVATE_ARIA2_METADATA}" TEMP="${PRIVATE_ARIA2_METADATA}"

    if [[ -n ${RESULT_FILE} ]]; then
        if [[ ${RESULT_FILE} == *$'\n'* || ${RESULT_FILE} == *$'\r'* ]]; then
            error 'the result-file path must not contain line breaks.'
            exit 2
        fi

        result_parent=${RESULT_FILE%/*}
        result_name=${RESULT_FILE##*/}
        if [[ ${result_parent} == "${RESULT_FILE}" ]]; then
            result_parent='.'
        elif [[ -z ${result_parent} ]]; then
            result_parent='/'
        fi

        if [[ -z ${result_name} || ${result_name} == . || ${result_name} == .. ]] \
            || ! result_parent=$(realpath -e -- "${result_parent}" 2>/dev/null) \
            || [[ ! -d ${result_parent} || ! -w ${result_parent} || ! -x ${result_parent} ]]; then
            error 'the result-file directory is not writable.'
            exit 13
        fi
        # shellcheck disable=SC2310 # Failure is a fatal result-path trust check.
        if ! private_directory_chain_is_safe "${result_parent}"; then
            error 'the result-file directory or one of its ancestors is unsafe.'
            exit 13
        fi
        RESULT_FILE="${result_parent%/}/${result_name}"
        RESULT_FILE_PARENT=${result_parent}
        # shellcheck disable=SC2310 # Failure rejects an unstable parent.
        if ! get_path_identity \
            RESULT_FILE_PARENT_IDENTITY "${RESULT_FILE_PARENT}" directory; then
            error 'unable to authenticate the result-file directory.'
            exit 13
        fi

        if [[ -e ${RESULT_FILE} || -L ${RESULT_FILE} ]]; then
            error 'the result-file already exists; refusing to overwrite it.'
            exit 13
        fi

        # Defer signals until cleanup can identify the newly created inode.
        begin_signal_registration
        if ! RESULT_FILE_TMP=$(mktemp \
            --tmpdir="${result_parent}" \
            '.yt-dlp-result.XXXXXXXX'); then
            finish_signal_registration
            error 'unable to create the temporary result file.'
            exit 13
        fi
    fi

    if [[ -z ${RESULT_FILE_TMP} ]]; then
        # Always retain the final yt-dlp path internally for FFprobe validation.
        begin_signal_registration
        if ! INTERNAL_PATH_FILE_TMP=$(mktemp \
            --tmpdir="${PRIVATE_ARIA2_METADATA}" \
            '.yt-dlp-path.XXXXXXXX'); then
            finish_signal_registration
            error 'unable to create the internal result-path file.'
            exit 13
        fi
    fi

    PATH_RECORD_TMP=${RESULT_FILE_TMP:-${INTERNAL_PATH_FILE_TMP}}
    # shellcheck disable=SC2310 # Failure is a fatal private-record trust check.
    if ! open_private_path_record "${PATH_RECORD_TMP}"; then
        finish_signal_registration
        error 'unable to authenticate the private result-path file.'
        exit 13
    fi
    finish_signal_registration

    if ! YTDLP_BATCH_FILE_TMP=$(mktemp \
        --tmpdir="${PRIVATE_ARIA2_METADATA}" \
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

    # Replay catchable signals only after cleanup can authenticate both the
    # allocated staging directory and its complete ownership marker.
    begin_signal_registration
    if ! PRIVATE_ARIA2_STAGING=$(mktemp -d \
        --tmpdir="${OUTPUT_DIR}" \
        '.yt-dlp-aria2.XXXXXXXX'); then
        finish_signal_registration
        error 'unable to create the private aria2 staging directory.'
        exit 13
    fi
    if ! chmod 700 -- "${PRIVATE_ARIA2_STAGING}"; then
        finish_signal_registration
        error 'unable to secure the private aria2 staging directory.'
        exit 13
    fi
    # shellcheck disable=SC2310 # Failure rejects the newly created directory.
    if ! exec {PRIVATE_ARIA2_STAGING_FD}<"${PRIVATE_ARIA2_STAGING}" \
        || ! get_path_identity \
            PRIVATE_ARIA2_STAGING_IDENTITY \
            "${PRIVATE_ARIA2_STAGING}" directory \
        || ! opened_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${PRIVATE_ARIA2_STAGING_FD}") \
        || [[ ${opened_identity} != "${PRIVATE_ARIA2_STAGING_IDENTITY}" ]]; then
        PRIVATE_ARIA2_STAGING_IDENTITY=''
        finish_signal_registration
        error 'unable to identify the private aria2 staging directory.'
        exit 13
    fi

    staging_marker_path="${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
    if ! printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
        >"${staging_marker_path}" \
        || ! chmod 600 -- "${staging_marker_path}"; then
        finish_signal_registration
        error 'unable to initialize private aria2 staging ownership metadata.'
        exit 13
    fi
    finish_signal_registration

    PRIVATE_ARIA2_PLAN="${PRIVATE_ARIA2_METADATA}/plan.json"
    PRIVATE_ARIA2_COOKIE_JAR="${PRIVATE_ARIA2_METADATA}/cookies.txt"
    PRIVATE_ARIA2_INPUT="${PRIVATE_ARIA2_METADATA}/aria2.input"
    PRIVATE_ARIA2_MANIFEST="${PRIVATE_ARIA2_METADATA}/manifest.json"

    # shellcheck disable=SC2310 # Failure rejects partially initialized state.
    if ! : >"${PRIVATE_ARIA2_PLAN}" \
        || ! chmod 600 -- "${PRIVATE_ARIA2_PLAN}" \
        || ! get_path_identity \
            PRIVATE_ARIA2_PLAN_IDENTITY \
            "${PRIVATE_ARIA2_PLAN}" regular-file; then
        error 'unable to initialize the private transfer plan.'
        exit 13
    fi
    # shellcheck disable=SC2310 # Failure rejects partially initialized state.
    if ! printf '%s\n' '# Netscape HTTP Cookie File' \
        >"${PRIVATE_ARIA2_COOKIE_JAR}" \
        || ! chmod 600 -- "${PRIVATE_ARIA2_COOKIE_JAR}" \
        || ! get_path_identity \
            PRIVATE_ARIA2_COOKIE_JAR_IDENTITY \
            "${PRIVATE_ARIA2_COOKIE_JAR}" regular-file; then
        error 'unable to initialize the private transfer cookie jar.'
        exit 13
    fi
}

# Build immutable aria2 arguments and the mutable yt-dlp execution option set.
configure_download_options() {
    local video_format

    print_human_line "${SCRIPT_NAME} version ${VERSION}"
    print_human_line "Download directory: ${FINAL_OUTPUT_DIR}"
    print_human_line "Mode: ${MODE}"
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        print_human_line 'YouTube access: Firefox cookies with web_safari HLS'
    fi

    ARIA2_DIRECT_OPTIONS=(
        -x 8 -s 8 -k 1M
        --file-allocation=none
        --no-conf=true
    )
    if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then
        ARIA2_DIRECT_OPTIONS+=(--no-netrc=true)
    fi
    ARIA2_DIRECT_OPTIONS+=(
        --allow-overwrite=false
        --auto-file-renaming=false
        --max-concurrent-downloads=1
        --console-log-level=warn
        --enable-color=false
        --truncate-console-readout=false
    )
    if [[ ${MACHINE_PROGRESS} == true ]]; then
        # aria2c's periodic readout must remain on stdout to reach the GUI log
        # during a successful transfer.
        ARIA2_DIRECT_OPTIONS+=(
            --summary-interval=1
            --show-console-readout=true
            --stderr=false
        )
    else
        ARIA2_DIRECT_OPTIONS+=(--summary-interval=0)
    fi
    readonly -a ARIA2_DIRECT_OPTIONS

    YT_DLP_OPTIONS=(
        --ignore-config
        --no-plugin-dirs
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
        --downloader 'dash,m3u8:native'
        --concurrent-fragments 1
    )

    if [[ ${JS_RUNTIME_AVAILABLE} == true ]]; then
        YT_DLP_OPTIONS+=(--js-runtimes "deno:${DENO_BIN}")
    fi

    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        YT_DLP_OPTIONS+=(
            --cookies-from-browser firefox
            --extractor-args 'youtube:player_client=web_safari'
            --fixup force
        )
    fi

    if [[ ${MODE} == video ]]; then
        if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
            video_format='(bv*+ba/b)[protocol^=m3u8]'
        else
            video_format='bv*+ba/b'
        fi
        YT_DLP_OPTIONS+=(--format "${video_format}")
        if [[ ${YOUTUBE_HLS_FIREFOX} != true ]]; then
            YT_DLP_OPTIONS+=(
                --merge-output-format mkv
                --remux-video mkv
            )
        fi
    else
        YT_DLP_OPTIONS+=(
            --format 'ba/b'
            --extract-audio
            --audio-format best
            --audio-quality 0
        )
    fi
}

# Run the metadata-only PLAN pass and validate the transport classifier output.
plan_selected_transport() {
    local plan_status
    local classification_output=''
    local classification_line
    local -a classifier_security_options=()
    local -a plan_options=(
        "${YT_DLP_OPTIONS[@]}"
        --skip-download
        --no-clean-info-json
        --dump-single-json
    )

    run_supervised_ytdlp \
        "${YTDLP_BIN}" \
        "${plan_options[@]}" \
        --batch-file "${YTDLP_BATCH_FILE_TMP}" \
        >"${PRIVATE_ARIA2_PLAN}"

    plan_status=${DOWNLOAD_STATUS}
    if ((plan_status != 0)); then
        printf '\nDownload failed during format planning with exit code %d.\n' \
            "${plan_status}" >&2
        exit "${plan_status}"
    fi

    if [[ ${ARIA2_HTTPS_DIRECT_SAFE} == true ]]; then
        classifier_security_options+=(--allow-https-direct)
    fi
    if ! classification_output=$(python3 \
        "${PRIVATE_ARIA2_HELPER}" classify \
        "${classifier_security_options[@]}" \
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
    readonly PRIVATE_TRANSPORT PRIVATE_TRANSFER_COUNT
}

# Add progress and final-path reporting only after the PLAN option set is fixed.
configure_download_reporting() {
    local path_record_template

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

    if [[ -n ${PATH_RECORD_FD_PATH} ]]; then
        # The FILE argument is itself an output template.
        path_record_template=${PATH_RECORD_FD_PATH//%/%%}
        YT_DLP_OPTIONS+=(
            --print-to-file 'after_move:%(filepath)s' "${path_record_template}"
        )
    fi
}

# Execute either the private aria2 direct path or yt-dlp's native transport.
execute_selected_transport() {
    local aria2_status
    local build_status=0
    local commit_status
    local native_preflight_status=0
    local native_output_template=''
    local native_audio_extension=''
    local -a builder_security_options=()
    local -a native_output_options=()

    if [[ ${PRIVATE_TRANSPORT} == direct ]]; then
        if [[ ${MACHINE_PROGRESS} == true ]]; then
            printf 'ARIA2_PLAN|%s\n' "${PRIVATE_TRANSFER_COUNT}"
        fi
        if [[ ${ARIA2_HTTPS_DIRECT_SAFE} == true ]]; then
            builder_security_options+=(--allow-https-direct)
        fi
        if [[ ${MODE} == video && ${YOUTUBE_HLS_FIREFOX} != true ]]; then
            # Ordinary video always remuxes to MKV. Check the actual final
            # directory before transferring its components, including when the
            # plan itself points into a private local workspace.
            builder_security_options+=(
                --final-output-dir "${FINAL_OUTPUT_DIR}"
                --final-output-identity "${FINAL_OUTPUT_IDENTITY}"
                --final-extension mkv
            )
        fi
        python3 "${PRIVATE_ARIA2_HELPER}" build \
            "${builder_security_options[@]}" \
            --plan "${PRIVATE_ARIA2_PLAN}" \
            --output-dir "${OUTPUT_DIR}" \
            --staging-dir "${PRIVATE_ARIA2_STAGING}" \
            --private-dir "${PRIVATE_ARIA2_METADATA}" \
            --aria2-input "${PRIVATE_ARIA2_INPUT}" \
            --manifest "${PRIVATE_ARIA2_MANIFEST}" \
            >/dev/null || build_status=$?
        if ((build_status != 0)); then
            if ((build_status == 1)); then
                error 'final media destination already exists; refusing to overwrite it.'
                exit "${build_status}"
            fi
            error 'unable to build the private aria2 transfer plan.'
            exit 65
        fi
        # shellcheck disable=SC2310 # Failure rejects an unbound sensitive file.
        if ! chmod 600 -- "${PRIVATE_ARIA2_INPUT}" \
            || ! get_path_identity \
                PRIVATE_ARIA2_INPUT_IDENTITY \
                "${PRIVATE_ARIA2_INPUT}" regular-file; then
            error 'unable to secure the private aria2 input file.'
            exit 13
        fi
        # shellcheck disable=SC2310 # Failure rejects an unbound sensitive file.
        if ! chmod 600 -- "${PRIVATE_ARIA2_MANIFEST}" \
            || ! get_path_identity \
                PRIVATE_ARIA2_MANIFEST_IDENTITY \
                "${PRIVATE_ARIA2_MANIFEST}" regular-file; then
            error 'unable to secure the private aria2 transfer manifest.'
            exit 13
        fi

        # Redact every HTTP(S) token from aria2 diagnostics.
        # shellcheck disable=SC2016 # Expanded by the intentionally nested shell.
        run_supervised_command bash -c '
            set -o pipefail
            trap ":" HUP INT TERM
            # Keep both filters alive during cooperative cancellation so the
            # producer can finish its signal handler without a broken pipe.
            # Bytewise matching also redacts malformed diagnostic URL tokens.
            "$@" 2>&1 |
                (
                    trap "" HUP INT TERM
                    LC_ALL=C exec stdbuf -o0 tr "\r" "\n"
                ) | (
                    trap "" HUP INT TERM
                LC_ALL=C exec sed -u -E "s#https?://[^[:space:]]+#[REDACTED_URL]#gI"
                )
            pipeline_statuses=("${PIPESTATUS[@]}")
            producer_status=${pipeline_statuses[0]:-125}
            normalizer_status=${pipeline_statuses[1]:-125}
            redactor_status=${pipeline_statuses[2]:-125}
            # Diagnostic normalization/redaction failures remain fatal;
            # otherwise preserve the exact aria2c result.
            if ((redactor_status != 0)); then
                exit "${redactor_status}"
            fi
            if ((normalizer_status != 0)); then
                exit "${normalizer_status}"
            fi
            exit "${producer_status}"
        ' bash \
            aria2c \
            --input-file="${PRIVATE_ARIA2_INPUT}" \
            --dir="${PRIVATE_ARIA2_STAGING}" \
            --load-cookies="${PRIVATE_ARIA2_COOKIE_JAR}" \
            "${ARIA2_DIRECT_OPTIONS[@]}"

        aria2_status=${DOWNLOAD_STATUS}

        if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]]; then
            # An unconfirmed shutdown still owns the private input and cookies.
            # Finalization propagates the failure; cleanup preserves everything.
            return 0
        fi

        # shellcheck disable=SC2310 # A changed inode is a hard preservation path.
        if ! remove_recorded_private_aria2_sensitive_file \
            "${PRIVATE_ARIA2_INPUT}" "${PRIVATE_ARIA2_INPUT_IDENTITY}"; then
            error 'unable to remove the private aria2 input file.'
            exit 13
        fi
        PRIVATE_ARIA2_INPUT=''
        PRIVATE_ARIA2_INPUT_IDENTITY=''

        if ((aria2_status == 0)); then
            commit_status=0
            python3 "${PRIVATE_ARIA2_HELPER}" commit \
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

            # shellcheck disable=SC2310 # A changed inode is a hard preservation path.
            if ! remove_recorded_private_aria2_sensitive_file \
                "${PRIVATE_ARIA2_MANIFEST}" \
                "${PRIVATE_ARIA2_MANIFEST_IDENTITY}"; then
                error 'unable to remove the private aria2 transfer manifest.'
                exit 13
            fi
            PRIVATE_ARIA2_MANIFEST=''
            PRIVATE_ARIA2_MANIFEST_IDENTITY=''

            run_supervised_ytdlp "${YTDLP_BIN}" \
                "${YT_DLP_OPTIONS[@]}" \
                --load-info-json "${PRIVATE_ARIA2_METADATA}/transfer-plan.json"
        else
            DOWNLOAD_STATUS=${aria2_status}
        fi
    else
        if [[ ${YOUTUBE_HLS_FIREFOX} != true ]]; then
            # No-overwrites does not prevent yt-dlp's metadata postprocessor
            # from rewriting an existing MKV or native audio input. Bind every
            # native extraction/retry to the preflighted basename before transfer.
            native_output_template=$(python3 "${PRIVATE_ARIA2_HELPER}" check-native-final \
                --plan "${PRIVATE_ARIA2_PLAN}" --output-dir "${OUTPUT_DIR}" \
                --final-output-dir "${FINAL_OUTPUT_DIR}" \
                --final-output-identity "${FINAL_OUTPUT_IDENTITY}" --mode "${MODE}" \
                --ownership "${RESOURCE_STATE_FILE}") \
                || native_preflight_status=$?
            if ((native_preflight_status == 1)); then
                error 'final media destination already exists; refusing to overwrite it.'
                exit 1
            elif ((native_preflight_status != 0)) \
                || [[ -z ${native_output_template} || ${native_output_template} == *$'\n'* ]]; then
                error 'unable to validate the native media destination.'
                exit 65
            fi
            native_output_options=(--output "${native_output_template}")
            if [[ ${MODE} == audio ]]; then
                native_audio_extension=${native_output_template##*.}
                if [[ ! ${native_audio_extension} =~ ^[A-Za-z0-9]+$ ]]; then
                    error 'unable to validate the native audio extension.'
                    exit 65
                fi
                # A metadata refresh may change the available audio container.
                # Keep selection and its checked input name paired; fail before
                # transfer rather than reuse a different existing audio file.
                native_output_options+=(--format "(ba/b)[ext=${native_audio_extension}]")
            fi
        fi
        if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
            native_output_template=$(python3 "${PRIVATE_ARIA2_HELPER}" check-native-final \
                --plan "${PRIVATE_ARIA2_PLAN}" --output-dir "${OUTPUT_DIR}" \
                --final-output-dir "${FINAL_OUTPUT_DIR}" \
                --final-output-identity "${FINAL_OUTPUT_IDENTITY}" --mode "${MODE}" \
                --ownership "${RESOURCE_STATE_FILE}") || exit $?
            native_output_options=(--output "${native_output_template}")
        fi
        run_supervised_ytdlp \
            "${YTDLP_BIN}" \
            "${YT_DLP_OPTIONS[@]}" \
            "${native_output_options[@]}" \
            --load-info-json "${PRIVATE_ARIA2_METADATA}/transfer-plan.json"
    fi

    if [[ -n ${DOWNLOAD_WORKER_PID} || -n ${DOWNLOAD_WORKER_PGID} ]]; then
        # Native download or direct replay may still consume this private URL.
        return 0
    fi
    if ! rm -f -- "${YTDLP_BATCH_FILE_TMP}"; then
        error 'unable to remove the private yt-dlp URL batch file.'
        exit 13
    fi
    YTDLP_BATCH_FILE_TMP=''
}

# Normalize yt-dlp's last reported result and enforce destination containment.
normalize_successful_path_record() {
    local path_record_status

    [[ -n ${PATH_RECORD_FD_PATH} ]] || return 0

    set +e
    normalize_path_record "${PATH_RECORD_FD_PATH}" "${OUTPUT_DIR}"
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
}

# Reject a remux whose verified duration loses more than the bounded tolerance.
validate_hls_duration_parity() {
    local source_duration_us=$1
    local final_duration_us=$2
    local source_path=$3
    local hls_duration_tolerance_us
    local hls_duration_loss_us

    ((final_duration_us < source_duration_us)) || return 0

    # Permit 2% timestamp loss, with a 0.5 s floor and 5 s ceiling.
    hls_duration_tolerance_us=$((source_duration_us / 50))
    if ((hls_duration_tolerance_us < 500000)); then
        hls_duration_tolerance_us=500000
    elif ((hls_duration_tolerance_us > 5000000)); then
        hls_duration_tolerance_us=5000000
    fi
    hls_duration_loss_us=$((source_duration_us - final_duration_us))
    if ((hls_duration_loss_us <= hls_duration_tolerance_us)); then
        return 0
    fi

    emit_machine_postprocess error FFmpegVideoRemuxer
    error 'the remuxed MKV is substantially shorter than the repaired HLS source.'
    printf 'Source duration: %s us; remuxed duration: %s us; allowed loss: %s us.\n' \
        "${source_duration_us}" \
        "${final_duration_us}" \
        "${hls_duration_tolerance_us}" >&2
    printf 'The repaired HLS intermediate was retained at: %s\n' \
        "${source_path}" >&2
    exit 65
}

hls_remux_temp_identity_matches() {
    local current_remux_identity=''
    local opened_remux_identity=''

    [[ -n ${HLS_REMUX_TMP} && -n ${HLS_REMUX_TMP_IDENTITY} &&
        -n ${HLS_REMUX_FD} && -n ${HLS_REMUX_FD_PATH} ]] || return 1
    # shellcheck disable=SC2310 # Failure is the false identity predicate.
    get_path_identity \
        current_remux_identity "${HLS_REMUX_TMP}" regular-file || return 1
    opened_remux_identity=$(stat -Lc '%d:%i' -- \
        "${HLS_REMUX_FD_PATH}" 2>/dev/null) || return 1
    [[ ${opened_remux_identity} =~ ^[0-9]+:[0-9]+$ &&
        ${current_remux_identity} == "${HLS_REMUX_TMP_IDENTITY}" &&
        ${opened_remux_identity} == "${HLS_REMUX_TMP_IDENTITY}" ]]
}

close_hls_remux_fd() {
    if [[ -n ${HLS_REMUX_FD} ]]; then
        if ! { exec {HLS_REMUX_FD}>&-; } 2>/dev/null; then
            printf 'Warning: unable to close the authenticated HLS remux descriptor.\n' >&2
        fi
    fi
    HLS_REMUX_FD=''
    HLS_REMUX_FD_PATH=''
    return 0
}

remove_owned_hls_remux_temp() {
    [[ -n ${HLS_REMUX_TMP} ]] || return 0
    if [[ ! -e ${HLS_REMUX_TMP} && ! -L ${HLS_REMUX_TMP} ]]; then
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        close_hls_remux_fd
        return 0
    fi
    # shellcheck disable=SC2310 # Failure preserves an identity-changed path.
    if ! hls_remux_temp_identity_matches; then
        printf 'Warning: preserving a changed temporary HLS remux: %s\n' \
            "${HLS_REMUX_TMP}" >&2
        MEDIA_WORKSPACE_CLEANUP_SAFE=false
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        close_hls_remux_fd
        return 1
    fi
    if ! rm -f -- "${HLS_REMUX_TMP}"; then
        MEDIA_WORKSPACE_CLEANUP_SAFE=false
        return 1
    fi
    HLS_REMUX_TMP=''
    HLS_REMUX_TMP_IDENTITY=''
    close_hls_remux_fd
}

# Retain a verified remux for diagnosis when final publication cannot complete.
# This does not publish the final media or update the private result record.
preserve_verified_hls_remux() {
    local retained_remux_path=${HLS_REMUX_TMP}
    local retained_remux_dir=''
    local retained_remux_name=''
    local retained_remux_candidate=''
    local current_retained_identity=''
    local retained_remux_identity=''

    [[ -n ${retained_remux_path} ]] || return 0
    # shellcheck disable=SC2310 # A replacement must not be moved or removed.
    if ! hls_remux_temp_identity_matches; then
        printf 'Warning: preserving a changed temporary HLS remux in place: %s\n' \
            "${retained_remux_path}" >&2
        MEDIA_WORKSPACE_CLEANUP_SAFE=false
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        close_hls_remux_fd
        return 0
    fi

    retained_remux_identity=${HLS_REMUX_TMP_IDENTITY}
    if [[ ! -L ${retained_remux_path} && -f ${retained_remux_path} ]]; then
        retained_remux_dir=${retained_remux_path%/*}
        retained_remux_name=${retained_remux_path##*/}
        if [[ ${retained_remux_name} == .yt-dlp-remux.*.mkv ]]; then
            retained_remux_name=${retained_remux_name/#.yt-dlp-remux./.yt-dlp-retained-remux.}
            retained_remux_candidate="${retained_remux_dir}/${retained_remux_name}"
            if mv -nT -- \
                "${retained_remux_path}" "${retained_remux_candidate}" \
                && [[ ! -e ${retained_remux_path} &&
                    ! -L ${retained_remux_path} ]]; then
                retained_remux_path=${retained_remux_candidate}
            fi
        fi
        # The moved inode must still be the remux that was verified. If the
        # pathname changed again, leave it untouched and report only that the
        # ambiguous path was preserved.
        current_retained_identity=''
        # shellcheck disable=SC2310 # Failure leaves the ambiguous path untouched.
        if ! get_path_identity \
            current_retained_identity "${retained_remux_path}" regular-file \
            || [[ ${current_retained_identity} != "${retained_remux_identity}" ]]; then
            printf 'Warning: preserving an identity-changed retained HLS remux: %s\n' \
                "${retained_remux_path}" >&2
            MEDIA_WORKSPACE_CLEANUP_SAFE=false
            HLS_REMUX_TMP=''
            HLS_REMUX_TMP_IDENTITY=''
            close_hls_remux_fd
            return 0
        fi
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        close_hls_remux_fd
        if [[ -n ${MEDIA_WORKSPACE} ]]; then
            MEDIA_RETAINED_PATHS+=("${retained_remux_path}")
            MEDIA_RETAINED_IDENTITIES+=("${retained_remux_identity}")
        fi
        printf 'The verified remuxed MKV was retained at: %s\n' \
            "${retained_remux_path}" >&2
    fi
    return 0
}

publish_hls_remux_result() {
    local source_path=$1
    local final_path=$2
    local source_identity=$3
    local current_remux_identity=''
    local current_source_identity=''
    local opened_remux_identity=''

    # shellcheck disable=SC2310 # Failure preserves the repaired source.
    if ! get_path_identity \
        current_source_identity "${source_path}" regular-file \
        || [[ ${current_source_identity} != "${source_identity}" ]]; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'the repaired HLS source changed during remux; refusing publication.'
        preserve_verified_hls_remux
        exit 13
    fi
    # shellcheck disable=SC2310 # A changed temporary inode forbids publication.
    if ! hls_remux_temp_identity_matches; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'the temporary HLS remux changed before publication.'
        preserve_verified_hls_remux
        exit 13
    fi
    if [[ ! -f ${HLS_REMUX_FD_PATH} ]] \
        || ! opened_remux_identity=$(stat -Lc '%d:%i' -- "${HLS_REMUX_FD_PATH}" 2>/dev/null) \
        || [[ ! ${opened_remux_identity} =~ ^[0-9]+:[0-9]+$ ]] \
        || [[ ${opened_remux_identity} != "${HLS_REMUX_TMP_IDENTITY}" ]]; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'the temporary HLS remux changed while it was opened for publication.'
        preserve_verified_hls_remux
        exit 13
    fi
    # Hard-link from the authenticated descriptor so a pathname replacement
    # after the last check cannot become the published media inode. Filesystems
    # without hard links retain the compatible no-clobber rename path only
    # after the safe directory chain and source identity are revalidated.
    if ! ln -LT -- "${HLS_REMUX_FD_PATH}" "${final_path}"; then
        if [[ -e ${final_path} || -L ${final_path} ]]; then
            emit_machine_postprocess error FFmpegVideoRemuxer
            error "the final MKV appeared during publication; refusing to overwrite it: ${final_path}"
            preserve_verified_hls_remux
            exit 13
        fi
        # shellcheck disable=SC2310 # A changed pathname forbids the fallback move.
        if ! hls_remux_temp_identity_matches; then
            emit_machine_postprocess error FFmpegVideoRemuxer
            error 'the temporary HLS remux changed during publication.'
            preserve_verified_hls_remux
            exit 13
        fi
        if ! mv -nT -- "${HLS_REMUX_TMP}" "${final_path}" \
            || [[ -e ${HLS_REMUX_TMP} || -L ${HLS_REMUX_TMP} ]]; then
            emit_machine_postprocess error FFmpegVideoRemuxer
            error 'unable to publish the final MKV without overwriting an existing path.'
            preserve_verified_hls_remux
            exit 13
        fi
    fi
    # shellcheck disable=SC2310 # Failure rejects the publication identity.
    if ! get_path_identity \
        current_remux_identity "${final_path}" regular-file \
        || [[ ${current_remux_identity} != "${opened_remux_identity}" ]]; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'the final MKV identity changed during publication.'
        preserve_verified_hls_remux
        exit 13
    fi
    # The final name now anchors the verified inode. Remove only an unchanged
    # temporary name; an injected replacement remains external state.
    # shellcheck disable=SC2310 # A changed path is deliberately preserved.
    if ! remove_owned_hls_remux_temp && [[ -n ${HLS_REMUX_TMP} ]]; then
        printf 'Warning: unable to remove the published HLS remux temporary name: %s\n' \
            "${HLS_REMUX_TMP}" >&2
    fi
    if ! printf '%s\n' "${final_path}" >"${PATH_RECORD_FD_PATH}"; then
        error 'unable to record the final MKV path.'
        printf 'The repaired HLS intermediate was retained at: %s\n' \
            "${source_path}" >&2
        exit 13
    fi
    emit_machine_postprocess finished FFmpegVideoRemuxer
    HLS_SOURCE_TO_CLEAN=${source_path}
    HLS_SOURCE_TO_CLEAN_IDENTITY=${source_identity}
}

remove_repaired_hls_source() {
    local current_source_identity=''

    [[ -n ${HLS_SOURCE_TO_CLEAN} ]] || return 0
    # shellcheck disable=SC2310 # Failure preserves a changed source.
    if ! get_path_identity \
        current_source_identity "${HLS_SOURCE_TO_CLEAN}" regular-file \
        || [[ ${current_source_identity} != "${HLS_SOURCE_TO_CLEAN_IDENTITY}" ]]; then
        printf 'Warning: preserving a changed repaired HLS source: %s\n' \
            "${HLS_SOURCE_TO_CLEAN}" >&2
        MEDIA_WORKSPACE_CLEANUP_SAFE=false
    elif ! rm -f -- "${HLS_SOURCE_TO_CLEAN}"; then
        printf 'Warning: unable to remove the repaired HLS intermediate: %s\n' \
            "${HLS_SOURCE_TO_CLEAN}" >&2
        MEDIA_WORKSPACE_CLEANUP_SAFE=false
    fi
    HLS_SOURCE_TO_CLEAN=''
    HLS_SOURCE_TO_CLEAN_IDENTITY=''
}

# Remux the authenticated YouTube HLS intermediate and verify duration parity.
remux_hls_result() {
    local hls_source_path
    local hls_source_dir
    local hls_source_name
    local hls_source_stem
    local hls_final_path
    local hls_source_identity=''
    local hls_source_duration_us=''
    local hls_final_duration_us=''
    local ffmpeg_status

    hls_source_path=$(<"${PATH_RECORD_FD_PATH}") || {
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
    if [[ ${hls_final_path} == "${hls_source_path}" ]]; then
        # A conditional inode replacement is not available through mv. Publish
        # under a distinct no-clobber name and remove the source only after the
        # remuxed result has passed global validation.
        hls_final_path="${hls_source_dir}/${hls_source_stem}.remuxed.mkv"
    fi

    # shellcheck disable=SC2310 # Failure rejects an unsafe repaired source.
    if ! get_path_identity \
        hls_source_identity "${hls_source_path}" regular-file; then
        error 'the repaired HLS source is missing or unsafe.'
        exit 13
    fi
    if [[ -n ${MEDIA_WORKSPACE} ]]; then
        MEDIA_RETAINED_PATHS+=("${hls_source_path}")
        MEDIA_RETAINED_IDENTITIES+=("${hls_source_identity}")
    fi
    if [[ -e ${hls_final_path} || -L ${hls_final_path} ]]; then
        error "the final MKV already exists; refusing to overwrite it: ${hls_final_path}"
        exit 13
    fi

    emit_machine_postprocess started FFmpegVideoRemuxer
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
    # Keep the temporary pathname, identity and open descriptor one registered
    # resource before a deferred signal can invoke cleanup.
    begin_signal_registration
    if ! HLS_REMUX_TMP=$(mktemp \
        --tmpdir="${hls_source_dir}" \
        --suffix='.mkv' \
        '.yt-dlp-remux.XXXXXXXX'); then
        finish_signal_registration
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to create the temporary MKV file.'
        exit 13
    fi
    # shellcheck disable=SC2310 # Failure rejects an unbound temporary inode.
    if ! chmod 600 -- "${HLS_REMUX_TMP}" \
        || ! get_path_identity \
            HLS_REMUX_TMP_IDENTITY "${HLS_REMUX_TMP}" regular-file; then
        finish_signal_registration
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to secure the temporary MKV file.'
        exit 13
    fi
    if ! exec {HLS_REMUX_FD}<>"${HLS_REMUX_TMP}"; then
        finish_signal_registration
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to open the temporary MKV file for authenticated remuxing.'
        exit 13
    fi
    HLS_REMUX_FD_PATH="/proc/${BASHPID}/fd/${HLS_REMUX_FD}"
    # shellcheck disable=SC2310 # Failure rejects an unauthenticated remux descriptor.
    if ! hls_remux_temp_identity_matches; then
        finish_signal_registration
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to authenticate the temporary MKV descriptor.'
        exit 13
    fi
    finish_signal_registration

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
    # shellcheck disable=SC2310 # A replacement must never reach FFprobe or mv.
    if ! hls_remux_temp_identity_matches; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'the temporary HLS remux changed while FFmpeg was running.'
        preserve_verified_hls_remux
        exit 13
    fi

    probe_duration_microseconds \
        hls_final_duration_us "${HLS_REMUX_TMP}" 2>/dev/null
    if [[ ! ${hls_final_duration_us} =~ ^[1-9][0-9]*$ ]]; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to determine the remuxed MKV duration; refusing to publish an unverifiable result.'
        printf 'The repaired HLS intermediate was retained at: %s\n' \
            "${hls_source_path}" >&2
        exit 65
    fi
    validate_hls_duration_parity \
        "${hls_source_duration_us}" \
        "${hls_final_duration_us}" \
        "${hls_source_path}"
    publish_hls_remux_result \
        "${hls_source_path}" "${hls_final_path}" "${hls_source_identity}"
}

# Validate the final media and atomically publish or discard its path record.
validate_and_publish_result() {
    local current_parent_identity=''
    local final_media_path=''
    local opened_record_identity=''
    local published_record_identity=''
    local current_source_identity=''
    local validation_status

    if ! { IFS= read -r final_media_path <"${PATH_RECORD_FD_PATH}"; } 2>/dev/null \
        || [[ -z ${final_media_path} ]]; then
        error 'unable to read the final media path for validation.'
        exit 13
    fi

    if [[ -n ${MEDIA_WORKSPACE} ]]; then
        MEDIA_RETAINED_PATH=${final_media_path}
        # shellcheck disable=SC2310 # Retain only the validated path's original inode.
        if ! get_path_identity MEDIA_RETAINED_IDENTITY "${final_media_path}" regular-file; then
            error 'the final local media identity is unavailable.'
            exit 73
        fi
    fi
    emit_machine_postprocess started MediaValidation

    # Do not invoke validation in a conditional context: Bash would disable
    # errexit throughout the complete validation function.
    set +e
    validate_final_media_file "${final_media_path}" "${MODE}"
    validation_status=$?
    set -e

    if ((validation_status != 0)); then
        emit_machine_postprocess error MediaValidation
        error "the final media file failed FFprobe validation: ${final_media_path}"
        printf 'Media validation reason: %s\n' \
            "${FINAL_MEDIA_VALIDATION_REASON:-unknown}" >&2
        printf '%s\n' \
            'The media file was retained for diagnosis and was not published as a successful result.' >&2
        if [[ -n ${HLS_SOURCE_TO_CLEAN} ]]; then
            printf 'The repaired HLS intermediate was retained at: %s\n' \
                "${HLS_SOURCE_TO_CLEAN}" >&2
        fi
        exit 65
    fi
    emit_machine_postprocess finished MediaValidation

    if [[ -n ${MEDIA_WORKSPACE} ]]; then
        local publication_record="${PRIVATE_ARIA2_METADATA}/published-path"
        # Preserve the validated local source on failed/ambiguous network publication.
        MEDIA_RETAINED_PATH=${final_media_path}
        # shellcheck disable=SC2310 # A swapped source cannot be published or deleted.
        if ! get_path_identity current_source_identity "${final_media_path}" regular-file \
            || [[ ${current_source_identity} != "${MEDIA_RETAINED_IDENTITY}" ]]; then
            error 'the validated local media changed before publication.'
            exit 73
        fi
        emit_machine_postprocess started MediaPublication
        run_supervised_command python3 "${PRIVATE_ARIA2_HELPER}" publish-media \
            --source "${final_media_path}" --source-identity "${MEDIA_RETAINED_IDENTITY}" \
            --output-dir "${FINAL_OUTPUT_DIR}" \
            --output-identity "${FINAL_OUTPUT_IDENTITY}" >"${publication_record}"
        if ((DOWNLOAD_STATUS != 0)); then
            emit_machine_postprocess error MediaPublication
            error "unable to publish the final media safely (status ${DOWNLOAD_STATUS})."
            print_human_line "Validated local media retained at: ${MEDIA_RETAINED_PATH}" >&2
            exit "${DOWNLOAD_STATUS}"
        fi
        if ! IFS= read -r final_media_path <"${publication_record}" \
            || [[ -z ${final_media_path} ]] \
            || ! printf '%s\n' "${final_media_path}" >"${PATH_RECORD_FD_PATH}"; then
            error 'unable to record the published media destination.'
            exit 73
        fi
        normalize_path_record "${PATH_RECORD_FD_PATH}" "${FINAL_OUTPUT_DIR}"
        MEDIA_RETAINED_PATH=''
        MEDIA_RETAINED_IDENTITY=''
        MEDIA_RETAINED_PATHS=()
        MEDIA_RETAINED_IDENTITIES=()
        emit_machine_postprocess finished MediaPublication
    fi

    RESOURCE_COMPLETED_PATH=${final_media_path}
    if [[ -n ${RESULT_FILE} ]]; then
        # Reauthenticate both endpoints immediately before publication. The
        # hard link is sourced from the open descriptor so a pathname swap
        # after validation cannot select a different result-record inode.
        # shellcheck disable=SC2310 # Failure rejects an unstable parent.
        if ! get_path_identity \
            current_parent_identity "${RESULT_FILE_PARENT}" directory \
            || [[ ${current_parent_identity} != "${RESULT_FILE_PARENT_IDENTITY}" ]]; then
            error 'the result-file directory changed before publication.'
            exit 13
        fi
        opened_record_identity=$(stat -Lc '%d:%i' -- \
            "${PATH_RECORD_FD_PATH}" 2>/dev/null) || {
            error 'unable to reauthenticate the private result-path file.'
            exit 13
        }
        if [[ ${opened_record_identity} != "${PATH_RECORD_IDENTITY}" ]]; then
            error 'the private result-path identity changed before publication.'
            exit 13
        fi
        if ! ln -LT -- "${PATH_RECORD_FD_PATH}" "${RESULT_FILE}"; then
            if [[ -e ${RESULT_FILE} || -L ${RESULT_FILE} ]]; then
                error 'the result file appeared during publication; refusing to overwrite it.'
                exit 13
            fi
            # shellcheck disable=SC2310 # A changed pathname forbids fallback publication.
            if ! path_record_temp_identity_matches "${PATH_RECORD_TMP}"; then
                error 'the private result-path pathname changed during publication.'
                exit 13
            fi
            if ! mv -nT -- "${PATH_RECORD_TMP}" "${RESULT_FILE}" \
                || [[ -e ${PATH_RECORD_TMP} || -L ${PATH_RECORD_TMP} ]]; then
                error 'unable to publish the result file without overwriting an existing path.'
                exit 13
            fi
        fi
        # shellcheck disable=SC2310 # Failure rejects a changed publication.
        if ! get_path_identity \
            published_record_identity "${RESULT_FILE}" regular-file \
            || [[ ${published_record_identity} != "${opened_record_identity}" ]]; then
            error 'the published result-file identity changed during publication.'
            exit 13
        fi
    fi

    # The authenticated descriptor, rather than this mutable pathname, owns
    # the record. Never remove an injected replacement at the temporary name.
    # shellcheck disable=SC2310 # A changed pathname is deliberately preserved.
    if ! remove_owned_path_record_temp "${PATH_RECORD_TMP}"; then
        if [[ -n ${PRIVATE_ARIA2_METADATA} &&
            ${PATH_RECORD_TMP%/*} == "${PRIVATE_ARIA2_METADATA}" ]]; then
            PRIVATE_ARIA2_METADATA_CLEANUP_SAFE=false
        fi
        printf 'Warning: preserving a changed temporary path record: %s\n' \
            "${PATH_RECORD_TMP}" >&2
    fi
    RESULT_FILE_TMP=''
    INTERNAL_PATH_FILE_TMP=''
    PATH_RECORD_TMP=''
    if ! exec {PATH_RECORD_FD}>&-; then
        printf 'Warning: unable to close the private result-path descriptor.\n' >&2
    fi
    PATH_RECORD_FD=''
    PATH_RECORD_FD_PATH=''
    PATH_RECORD_IDENTITY=''

    if [[ -n ${HLS_SOURCE_TO_CLEAN} ]]; then
        remove_repaired_hls_source
    fi
}

# Convert transport status into the final validated success/failure contract.
finalize_download() {
    local status

    if ((DOWNLOAD_STATUS != 0)); then
        status=${DOWNLOAD_STATUS}
        printf '\nDownload failed with exit code %d.\n' "${status}" >&2
        exit "${status}"
    fi

    normalize_successful_path_record
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        remux_hls_result
    fi
    validate_and_publish_result
    print_human_line ''
    print_human_line 'Download completed successfully.'
}

main() {
    trap cleanup EXIT
    trap 'request_shutdown HUP 129' HUP
    trap 'request_shutdown INT 130' INT
    trap 'request_shutdown TERM 143' TERM
    trap 'if [[ ${SHUTDOWN_REQUESTED} == true && ${DOWNLOAD_FORCE_STOP} != true ]]; then signal_download_worker KILL; fi' CONT

    parse_arguments "$@"
    resolve_requested_url
    validate_mode_selection
    initialize_runtime_dependencies

    prepare_output_directory

    prepare_private_work_files

    configure_download_options
    plan_selected_transport
    acquire_resource_reservations
    if [[ -n ${MEDIA_WORKSPACE} ]]; then
        if ! python3 "${PRIVATE_ARIA2_HELPER}" check-space \
            --plan "${PRIVATE_ARIA2_PLAN}" --output-dir "${OUTPUT_DIR}"; then
            error 'the private local media disk cannot accommodate this download.'
            exit 73
        fi
    fi
    configure_download_reporting
    execute_selected_transport
    finalize_download

}

main "$@"

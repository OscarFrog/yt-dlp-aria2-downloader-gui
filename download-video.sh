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

readonly VERSION="2.3.8"
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
HLS_SOURCE_TO_CLEAN=''
HLS_SOURCE_TO_CLEAN_IDENTITY=''
YTDLP_BATCH_FILE_TMP=''
PRIVATE_ARIA2_STAGING=''
PRIVATE_ARIA2_STAGING_IDENTITY=''
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
DOWNLOAD_WORKER_PID=''
DOWNLOAD_WORKER_START_TIME=''
DOWNLOAD_WORKER_PGID=''
DOWNLOAD_WORKER_PGID_START_TIME=''
DOWNLOAD_PGID_FILE=''
DOWNLOAD_READY_FILE=''
DOWNLOAD_STATUS=125
DOWNLOAD_WAITED_STATUS=''
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
                printf 'Warning: preserving a changed temporary path record: %s\n' \
                    "${PATH_RECORD_TMP}" >&2
            fi
        else
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
            remove_owned_hls_remux_temp || true
        else
            printf 'Warning: preserving an unverified temporary HLS remux: %s\n' \
                "${HLS_REMUX_TMP}" >&2
        fi
    fi
    if [[ -n ${YTDLP_BATCH_FILE_TMP} ]]; then
        rm -f -- "${YTDLP_BATCH_FILE_TMP}" || true
    fi
    if [[ -n ${PRIVATE_ARIA2_STAGING} &&
        (-e ${PRIVATE_ARIA2_STAGING} || -L ${PRIVATE_ARIA2_STAGING}) ]]; then
        if declare -F remove_active_private_aria2_sensitive_metadata \
            >/dev/null 2>&1; then
            # shellcheck disable=SC2310 # A changed identity is the preserve path.
            if ! remove_active_private_aria2_sensitive_metadata; then
                active_staging_metadata_safe=false
                printf 'Warning: preserving ambiguous private aria2 authentication metadata: %s\n' \
                    "${PRIVATE_ARIA2_STAGING##*/}" >&2
            fi
        fi
        # A sensitive pathname whose recorded inode changed is external state,
        # even when its replacement reused an otherwise allowlisted basename.
        # Preserve the directory instead of letting structural cleanup erase it.
        # shellcheck disable=SC2310 # Cleanup preserves staging that no longer validates.
        if [[ ${active_staging_metadata_safe} != true ]] \
            || ! remove_private_aria2_staging_candidate \
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
    local candidate=''
    local canonical_candidate=''
    local canonical_runtime_dir=''
    local owner=''
    local mode=''

    if [[ -n ${XDG_RUNTIME_DIR:-} && ${XDG_RUNTIME_DIR} == /* &&
        -d ${XDG_RUNTIME_DIR} && ! -L ${XDG_RUNTIME_DIR} ]] \
        && canonical_runtime_dir=$(realpath -e -- \
            "${XDG_RUNTIME_DIR}" 2>/dev/null); then
        if owner=$(stat -c '%u' -- \
            "${canonical_runtime_dir}" 2>/dev/null) \
            && mode=$(stat -c '%a' -- \
                "${canonical_runtime_dir}" 2>/dev/null); then
            # shellcheck disable=SC2310 # An unsafe runtime chain selects the private /tmp fallback.
            if [[ ${owner} == "${EUID}" && ${mode} == 700 ]] \
                && private_directory_chain_is_safe "${canonical_runtime_dir}"; then
                candidate="${canonical_runtime_dir}/yt-dlp-aria2-downloader"
            fi
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

    if ! owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null); then
        error 'unable to determine the download-lock directory owner.'
        return 73
    fi
    if [[ ${owner} != "${EUID}" ]]; then
        error 'the download-lock directory is not owned by the current user.'
        return 73
    fi
    if ! chmod 700 -- "${candidate}"; then
        error 'unable to secure the download-lock directory.'
        return 73
    fi

    canonical_candidate=$(realpath -e -- "${candidate}" 2>/dev/null) || {
        error 'unable to resolve the download-lock directory.'
        return 73
    }
    if [[ ${canonical_candidate} != "${candidate}" ]]; then
        error 'the download-lock directory changed during validation.'
        return 73
    fi
    if ! mode=$(stat -c '%a' -- "${canonical_candidate}" 2>/dev/null); then
        error 'unable to determine the download-lock directory permissions.'
        return 73
    fi
    # shellcheck disable=SC2310 # Final validation precedes all private work-file creation.
    if [[ ${mode} != 700 ]] \
        || ! private_directory_chain_is_safe "${canonical_candidate}"; then
        error 'the download-lock directory has an unsafe ownership or shared-write chain.'
        return 73
    fi

    OUTPUT_LOCK_ROOT=${canonical_candidate}
    return 0
}

acquire_output_lock() {
    local output_dir=$1
    local lock_key

    # shellcheck disable=SC2310 # Failure is converted to a lock setup status.
    if ! resolve_lock_root || [[ -z ${OUTPUT_LOCK_ROOT} ]]; then
        error 'unable to resolve the download-lock directory.'
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

download_group_has_live_member() {
    local process_path=''
    local process_stat=''
    local process_state=''
    local process_group=''
    local process_session=''
    local -a process_fields=()

    [[ -n ${DOWNLOAD_WORKER_PGID} ]] || return 1
    for process_path in /proc/[1-9]*/stat; do
        [[ -r ${process_path} ]] || continue
        process_stat=''
        if ! { IFS= read -r process_stat <"${process_path}"; } 2>/dev/null; then
            continue
        fi
        process_fields=()
        read -r -a process_fields <<<"${process_stat##*) }"
        ((${#process_fields[@]} > 3)) || continue
        process_state=${process_fields[0]}
        process_group=${process_fields[2]}
        process_session=${process_fields[3]}
        if [[ ${process_state} != Z && ${process_state} != X &&
            ${process_group} == "${DOWNLOAD_WORKER_PGID}" &&
            ${process_session} == "${DOWNLOAD_WORKER_PGID}" ]]; then
            return 0
        fi
    done
    return 1
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

signal_download_worker() {
    local signal_name=$1
    local candidate_start_time=''
    local group_signaled=false

    # When the GUI already created the session, the entire outer process group
    # receives its signal directly. Avoid signaling our own group recursively;
    # target the direct child only as a best-effort fallback.
    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
        # shellcheck disable=SC2310 # A failed identity check forbids signaling.
        if download_worker_is_current false; then
            kill "-${signal_name}" -- "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
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
        if download_group_is_current \
            && download_group_has_live_member \
            && kill "-${signal_name}" -- "-${DOWNLOAD_WORKER_PGID}" 2>/dev/null; then
            group_signaled=true
        else
            DOWNLOAD_WORKER_PGID=''
            DOWNLOAD_WORKER_PGID_START_TIME=''
        fi
    fi

    if [[ ${signal_name} == KILL || ${group_signaled} == false ]] \
        && [[ -n ${DOWNLOAD_WORKER_PID} ]]; then
        # shellcheck disable=SC2310 # Direct fallback requires the original child.
        if ! download_worker_is_current false; then
            return 0
        fi
        kill "-${signal_name}" -- "${DOWNLOAD_WORKER_PID}" 2>/dev/null || true
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

        if [[ ${worker_alive} != true && -n ${DOWNLOAD_WORKER_PGID} ]]; then
            # shellcheck disable=SC2310 # Failed authentication ends group tracking.
            if download_group_is_current \
                && download_group_has_live_member; then
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
    wait_for_download_exit 20
}

run_supervised_command() {
    local registration_ready=false
    local worker_status=0
    local -a worker_command=("$@")

    DOWNLOAD_STATUS=125
    DOWNLOAD_WORKER_PID=''
    DOWNLOAD_WORKER_START_TIME=''
    DOWNLOAD_WORKER_PGID=''
    DOWNLOAD_WORKER_PGID_START_TIME=''
    DOWNLOAD_PGID_FILE=''
    DOWNLOAD_READY_FILE=''
    DOWNLOAD_WAITED_STATUS=''

    if [[ ${REUSE_CURRENT_SESSION} == true ]]; then
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

            # Stay alive as the authenticated session leader until every
            # same-session descendant has exited. A command may otherwise
            # orphan work after returning and make its numeric PGID unsafe to
            # reuse as signaling authority.
            while true; do
                group_member_alive=false
                for process_path in /proc/[1-9]*/stat; do
                    [[ -r ${process_path} ]] || continue
                    process_stat=""
                    if ! IFS= read -r process_stat <"${process_path}" 2>/dev/null; then
                        continue
                    fi
                    process_pid=${process_stat%% *}
                    [[ ${process_pid} != "$$" ]] || continue
                    process_fields=()
                    read -r -a process_fields <<<"${process_stat##*) }"
                    ((${#process_fields[@]} > 3)) || continue
                    if [[ ${process_fields[0]} != Z &&
                        ${process_fields[0]} != X &&
                        ${process_fields[2]} == "$$" &&
                        ${process_fields[3]} == "$$" ]]; then
                        group_member_alive=true
                        break
                    fi
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
        if ! process_is_running "${DOWNLOAD_WORKER_PID}"; then
            wait "${DOWNLOAD_WORKER_PID}" 2>/dev/null || worker_status=$?
            DOWNLOAD_WAITED_STATUS=${worker_status}
            DOWNLOAD_WORKER_PID=''
            DOWNLOAD_WORKER_START_TIME=''
            DOWNLOAD_WORKER_PGID=''
            DOWNLOAD_WORKER_PGID_START_TIME=''
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
        cleanup_download_registration_files
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

    cleanup_download_registration_files
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
        forbidden_source_name=$(printf "\170\150\141\155\163\164\145\162")
        exec 3>&1
        {
            "$@" 2>&1 1>&3 3>&-
        } | (
            # The complete process group receives cancellation. Keep the
            # redactor alive until the producer closes its pipe so the producer
            # cannot lose its TERM handler to a concurrent SIGPIPE.
            trap "" HUP INT TERM
            exec sed -u -E \
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

    [[ -n ${PRIVATE_ARIA2_STAGING_IDENTITY} ]] || return 1
    # shellcheck disable=SC2310 # Failure preserves the complete staging tree.
    get_path_identity \
        current_staging_identity "${PRIVATE_ARIA2_STAGING}" directory \
        || return 1
    [[ ${current_staging_identity} == "${PRIVATE_ARIA2_STAGING_IDENTITY}" ]] \
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
            "${PRIVATE_ARIA2_STAGING}" \
            "${unrecorded_sensitive_names[@]}"; then
        removal_status=1
    fi
    return "${removal_status}"
}

remove_marked_private_aria2_sensitive_metadata() {
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

    if ((${#sensitive_names[@]} == 0)); then
        sensitive_names=(plan.json cookies.txt aria2.input manifest.json)
    fi

    [[ ${candidate_name} =~ ^[.]yt-dlp-aria2[.][A-Za-z0-9]{8}$ ]] || return 1
    [[ ! -L ${candidate} && -d ${candidate} ]] || return 1
    candidate_owner=$(stat -c '%u' -- "${candidate}" 2>/dev/null) || return 1
    candidate_mode=$(stat -c '%a' -- "${candidate}" 2>/dev/null) || return 1
    [[ ${candidate_owner} == "${EUID}" && ${candidate_mode} == 700 ]] || return 1
    candidate_parent=$(realpath -e -- "${candidate}/.." 2>/dev/null) || return 1
    [[ ${candidate_parent} == "${OUTPUT_DIR}" ]] || return 1

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
            if [[ ${require_marker} == true ]]; then
                # Even when an unknown transfer artifact forces preservation,
                # remove authenticated URLs and cookies from a directory whose
                # ownership marker and private metadata still validate.
                # shellcheck disable=SC2310
                if ! remove_marked_private_aria2_sensitive_metadata \
                    "${candidate}"; then
                    printf 'Warning: unable to remove ambiguous private aria2 authentication metadata: %s\n' \
                        "${candidate##*/}" >&2
                fi
            fi
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

probe_media_summary() {
    local media_path=$1
    local -a probe_statuses=()

    LC_ALL=C timeout --signal=TERM --kill-after=2s 15s \
        ffprobe -v error \
        -show_entries 'format=start_time,duration:stream=codec_type:stream_disposition=attached_pic' \
        -of json \
        "${media_path}" 2>/dev/null \
        | python3 -c '
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
'

    probe_statuses=("${PIPESTATUS[@]}")
    ((${#probe_statuses[@]} == 2)) || return 1
    if ((probe_statuses[0] == 124 || probe_statuses[0] == 137)); then
        return 124
    fi
    if ((probe_statuses[0] != 0)); then
        return 1
    fi
    return "${probe_statuses[1]}"
}

probe_duration_microseconds() {
    local probe_duration_output_variable=$1
    local media_path=$2
    local probe_duration=''
    local probe_seconds=''
    local probe_fraction=''
    local probe_duration_microseconds=''
    local seconds_bound_comparison=1

    if probe_duration=$(
        timeout --signal=TERM --kill-after=2s 15s \
            ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "${media_path}" 2>/dev/null
    ); then
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

    # probe_media_summary is a status-returning pipeline whose failure is
    # deliberately converted into a stable validation reason.
    # shellcheck disable=SC2310
    media_summary=$(probe_media_summary "${final_path}") \
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
    readonly PRIVATE_ARIA2_HELPER

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

    # shellcheck disable=SC2310 # Failure is a fatal destination trust check.
    if ! private_directory_chain_is_safe "${OUTPUT_DIR}"; then
        error "destination directory or one of its ancestors is owned by another user or is shared without sticky-bit protection: ${OUTPUT_DIR}"
        exit 13
    fi

    # --output is an yt-dlp output template. Escape literal percent signs from
    # the real destination path.
    OUTPUT_DIR_TEMPLATE=${OUTPUT_DIR//%/%%}
    readonly OUTPUT_DIR_TEMPLATE

    if [[ ! -w ${OUTPUT_DIR} || ! -x ${OUTPUT_DIR} ]]; then
        error "destination directory is not writable: ${OUTPUT_DIR}"
        exit 13
    fi

    # Keep one same-user writer per canonical destination directory.
    acquire_output_lock "${OUTPUT_DIR}"
    recover_abandoned_private_aria2_staging
    cleanup_stale_temporary_files
}

# Create private path records and aria2/yt-dlp transfer metadata.
prepare_private_work_files() {
    local result_name
    local result_parent
    local staging_marker_path

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

        if ! RESULT_FILE_TMP=$(mktemp \
            --tmpdir="${result_parent}" \
            '.yt-dlp-result.XXXXXXXX'); then
            error 'unable to create the temporary result file.'
            exit 13
        fi
    fi

    if [[ -z ${RESULT_FILE_TMP} ]]; then
        # Always retain the final yt-dlp path internally for FFprobe validation.
        if ! INTERNAL_PATH_FILE_TMP=$(mktemp \
            --tmpdir="${OUTPUT_DIR}" \
            '.yt-dlp-path.XXXXXXXX'); then
            error 'unable to create the internal result-path file.'
            exit 13
        fi
    fi

    PATH_RECORD_TMP=${RESULT_FILE_TMP:-${INTERNAL_PATH_FILE_TMP}}
    # shellcheck disable=SC2310 # Failure is a fatal private-record trust check.
    if ! open_private_path_record "${PATH_RECORD_TMP}"; then
        error 'unable to authenticate the private result-path file.'
        exit 13
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
    # shellcheck disable=SC2310 # Failure rejects the newly created directory.
    if ! get_path_identity \
        PRIVATE_ARIA2_STAGING_IDENTITY \
        "${PRIVATE_ARIA2_STAGING}" directory; then
        error 'unable to identify the private aria2 staging directory.'
        exit 13
    fi

    staging_marker_path="${PRIVATE_ARIA2_STAGING}/${PRIVATE_ARIA2_STAGING_MARKER}"
    if ! printf '%s\n' "${PRIVATE_ARIA2_STAGING_MARKER_VALUE}" \
        >"${staging_marker_path}" \
        || ! chmod 600 -- "${staging_marker_path}"; then
        error 'unable to initialize private aria2 staging ownership metadata.'
        exit 13
    fi

    PRIVATE_ARIA2_PLAN="${PRIVATE_ARIA2_STAGING}/plan.json"
    PRIVATE_ARIA2_COOKIE_JAR="${PRIVATE_ARIA2_STAGING}/cookies.txt"
    PRIVATE_ARIA2_INPUT="${PRIVATE_ARIA2_STAGING}/aria2.input"
    PRIVATE_ARIA2_MANIFEST="${PRIVATE_ARIA2_STAGING}/manifest.json"

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
    local aria2_arguments
    local video_format

    print_human_line "${SCRIPT_NAME} version ${VERSION}"
    print_human_line "Download directory: ${OUTPUT_DIR}"
    print_human_line "Mode: ${MODE}"
    if [[ ${YOUTUBE_HLS_FIREFOX} == true ]]; then
        print_human_line 'YouTube access: Firefox cookies with web_safari HLS'
    fi

    aria2_arguments='-x 8 -s 8 -k 1M --file-allocation=none --no-conf=true'
    if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then
        aria2_arguments+=' --no-netrc=true'
    fi
    aria2_arguments+=' --allow-overwrite=false --auto-file-renaming=false --max-concurrent-downloads=1'
    aria2_arguments+=' --console-log-level=warn --enable-color=false --truncate-console-readout=false'
    if [[ ${MACHINE_PROGRESS} == true ]]; then
        # aria2c's periodic readout must remain on stdout to reach the GUI log
        # during a successful transfer.
        aria2_arguments+=' --summary-interval=1 --show-console-readout=true --stderr=false'
    else
        aria2_arguments+=' --summary-interval=0'
    fi
    read -r -a ARIA2_DIRECT_OPTIONS <<<"${aria2_arguments}"
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
    local commit_status
    local -a builder_security_options=()

    if [[ ${PRIVATE_TRANSPORT} == direct ]]; then
        if [[ ${MACHINE_PROGRESS} == true ]]; then
            printf 'ARIA2_PLAN|%s\n' "${PRIVATE_TRANSFER_COUNT}"
        fi
        if [[ ${ARIA2_HTTPS_DIRECT_SAFE} == true ]]; then
            builder_security_options+=(--allow-https-direct)
        fi
        if ! python3 "${PRIVATE_ARIA2_HELPER}" build \
            "${builder_security_options[@]}" \
            --plan "${PRIVATE_ARIA2_PLAN}" \
            --output-dir "${OUTPUT_DIR}" \
            --staging-dir "${PRIVATE_ARIA2_STAGING}" \
            --aria2-input "${PRIVATE_ARIA2_INPUT}" \
            --manifest "${PRIVATE_ARIA2_MANIFEST}" \
            >/dev/null; then
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
            "$@" 2>&1 |
                stdbuf -o0 tr "\r" "\n" | sed -u -E "s#https?://[^[:space:]]+#[REDACTED_URL]#g"
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
                --load-info-json "${PRIVATE_ARIA2_PLAN}"
        else
            DOWNLOAD_STATUS=${aria2_status}
        fi
    else
        run_supervised_ytdlp \
            "${YTDLP_BIN}" \
            "${YT_DLP_OPTIONS[@]}" \
            --batch-file "${YTDLP_BATCH_FILE_TMP}"
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

    [[ -n ${HLS_REMUX_TMP} && -n ${HLS_REMUX_TMP_IDENTITY} ]] || return 1
    # shellcheck disable=SC2310 # Failure is the false identity predicate.
    get_path_identity \
        current_remux_identity "${HLS_REMUX_TMP}" regular-file || return 1
    [[ ${current_remux_identity} == "${HLS_REMUX_TMP_IDENTITY}" ]]
}

remove_owned_hls_remux_temp() {
    [[ -n ${HLS_REMUX_TMP} ]] || return 0
    if [[ ! -e ${HLS_REMUX_TMP} && ! -L ${HLS_REMUX_TMP} ]]; then
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        return 0
    fi
    # shellcheck disable=SC2310 # Failure preserves an identity-changed path.
    if ! hls_remux_temp_identity_matches; then
        printf 'Warning: preserving a changed temporary HLS remux: %s\n' \
            "${HLS_REMUX_TMP}" >&2
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
        return 1
    fi
    if ! rm -f -- "${HLS_REMUX_TMP}"; then
        return 1
    fi
    HLS_REMUX_TMP=''
    HLS_REMUX_TMP_IDENTITY=''
    return 0
}

# Atomically publish a verified HLS remux and update the private path record.
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
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
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
            HLS_REMUX_TMP=''
            HLS_REMUX_TMP_IDENTITY=''
            return 0
        fi
        HLS_REMUX_TMP=''
        HLS_REMUX_TMP_IDENTITY=''
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
    local remux_fd=''
    local remux_fd_path=''

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
    if ! exec {remux_fd}<"${HLS_REMUX_TMP}"; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to open the verified HLS remux for publication.'
        preserve_verified_hls_remux
        exit 13
    fi
    remux_fd_path="/proc/${BASHPID}/fd/${remux_fd}"
    if [[ ! -f ${remux_fd_path} ]] \
        || ! opened_remux_identity=$(stat -Lc '%d:%i' -- "${remux_fd_path}" 2>/dev/null) \
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
    if ! ln -LT -- "${remux_fd_path}" "${final_path}"; then
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
    if ! exec {remux_fd}>&-; then
        printf 'Warning: unable to close the verified HLS remux descriptor after publication.\n' >&2
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
    elif ! rm -f -- "${HLS_SOURCE_TO_CLEAN}"; then
        printf 'Warning: unable to remove the repaired HLS intermediate: %s\n' \
            "${HLS_SOURCE_TO_CLEAN}" >&2
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
    if ! HLS_REMUX_TMP=$(mktemp \
        --tmpdir="${hls_source_dir}" \
        --suffix='.mkv' \
        '.yt-dlp-remux.XXXXXXXX'); then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to create the temporary MKV file.'
        exit 13
    fi
    # shellcheck disable=SC2310 # Failure rejects an unbound temporary inode.
    if ! chmod 600 -- "${HLS_REMUX_TMP}" \
        || ! get_path_identity \
            HLS_REMUX_TMP_IDENTITY "${HLS_REMUX_TMP}" regular-file; then
        emit_machine_postprocess error FFmpegVideoRemuxer
        error 'unable to secure the temporary MKV file.'
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
    local validation_status

    if ! { IFS= read -r final_media_path <"${PATH_RECORD_FD_PATH}"; } 2>/dev/null \
        || [[ -z ${final_media_path} ]]; then
        error 'unable to read the final media path for validation.'
        exit 13
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

    parse_arguments "$@"
    resolve_requested_url
    validate_mode_selection
    initialize_runtime_dependencies

    prepare_output_directory

    prepare_private_work_files

    configure_download_options
    plan_selected_transport
    configure_download_reporting
    execute_selected_transport
    finalize_download

}

main "$@"

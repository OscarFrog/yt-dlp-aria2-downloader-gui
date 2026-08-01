#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
# shellcheck disable=SC1090
source "${script_dir}/tests/lib/assert.sh"
# shellcheck disable=SC1090
source "${script_dir}/tests/lib/project-files.sh"

if ((${#ALL_SHELL_FILES[@]} == 0)); then
    printf 'Error: ALL_SHELL_FILES is empty.\n' >&2
    exit 65
fi
for file in "${ALL_SHELL_FILES[@]}"; do
    bash -n -- "${script_dir}/${file}"
done

assert_status 0 'download engine help' \
    "${script_dir}/download-video.sh" --help
assert_status 0 'download engine version' \
    "${script_dir}/download-video.sh" --version

assert_status_split 0 'help stream separation' \
    "${script_dir}/download-video.sh" --help
assert_text_contains "${ASSERT_STDOUT}" 'Usage:' 'help is written to stdout'
assert_equals '' "${ASSERT_STDERR}" 'help leaves stderr empty'

assert_status_split 2 'error stream separation' \
    "${script_dir}/download-video.sh"
assert_equals '' "${ASSERT_STDOUT}" 'missing URL leaves stdout empty'
assert_text_contains "${ASSERT_STDERR}" 'a video URL is required.' \
    'missing URL is written to stderr'

assert_status 2 'invalid mode is rejected' \
    "${script_dir}/download-video.sh" --mode invalid \
    'https://example.com/video'
assert_text_contains "${ASSERT_OUTPUT}" '--mode must be video or audio.' \
    'invalid mode diagnostic'

assert_status 2 'removed audio-format option is rejected' \
    "${script_dir}/download-video.sh" --audio-format mp3 \
    'https://example.com/video'
assert_text_contains "${ASSERT_OUTPUT}" 'unknown option: --audio-format' \
    'audio-format rejection reason'

assert_status 2 'removed audio-quality option is rejected' \
    "${script_dir}/download-video.sh" --audio-quality 0 \
    'https://example.com/video'
assert_text_contains "${ASSERT_OUTPUT}" 'unknown option: --audio-quality' \
    'audio-quality rejection reason'

assert_status 2 'URL line breaks are rejected' \
    "${script_dir}/download-video.sh" $'https://example.com/a\nb'
assert_text_contains "${ASSERT_OUTPUT}" 'must not contain line breaks' \
    'URL line-break diagnostic'

assert_status 2 'two positional URLs are rejected' \
    "${script_dir}/download-video.sh" \
    'https://example.com/a' 'https://example.com/b'
assert_text_contains "${ASSERT_OUTPUT}" 'exactly one video URL is required.' \
    'multiple URL diagnostic'

assert_status 2 'a second URL after -- is rejected' \
    "${script_dir}/download-video.sh" \
    'https://example.com/a' -- 'https://example.com/b'
assert_text_contains "${ASSERT_OUTPUT}" 'exactly one video URL is required.' \
    'multiple URL after separator diagnostic'

assert_status 2 'installer requires one command' \
    "${script_dir}/install-gui.sh"

assert_file_contains \
    "${script_dir}/download-video-gui.sh" \
    'LC_ALL=C setsid --fork --wait bash -c' \
    'GUI worker locale stabilization'

engine_locale_probes=(
    'LC_ALL=C yt-dlp --version'
    'LC_ALL=C yt-dlp --help'
    'LC_ALL=C deno --version'
    'LC_ALL=C aria2c --version'
    'LC_ALL=C aria2c --help=#all'
)

for required_probe in "${engine_locale_probes[@]}"; do
    assert_file_contains \
        "${script_dir}/download-video.sh" \
        "${required_probe}" \
        "locale-stabilized probe ${required_probe}"
done

assert_file_contains \
    "${script_dir}/download-video-gui.sh" \
    'LC_ALL=C setsid --help' \
    'setsid capability probe locale stabilization'

assert_file_contains \
    "${script_dir}/download-video-gui.sh" \
    "pgid_temporary=\"\${pgid_file}.tmp\"" \
    'atomic PGID staging file'
assert_file_contains \
    "${script_dir}/download-video-gui.sh" \
    "mv -f -- \"\${pgid_temporary}\" \"\${pgid_file}\"" \
    'atomic PGID publication'
assert_file_contains \
    "${script_dir}/download-video-gui.sh" \
    "trap '' HUP INT TERM" \
    'cleanup signal protection'
assert_file_contains \
    "${script_dir}/progress-monitor.sh" \
    '^\[#([[:xdigit:]]+)[[:space:]]' \
    'aria2 progress without mandatory percentage'
assert_file_contains \
    "${script_dir}/install-gui.sh" \
    "readonly LAUNCHER_LINK=\"\${LAUNCHER_DIR}/launch\"" \
    'stable desktop launcher link'
assert_file_contains \
    "${script_dir}/install-gui.sh" \
    "desktop-file-validate \\" \
    'desktop launcher validation'
# shellcheck disable=SC2016
# These assertions deliberately search for literal shell source code.
assert_file_contains "${script_dir}/tests/mock-integration.sh" \
    'readonly TEST_OWNER_BASHPID=${BASHPID}' \
    'mock-suite cleanup owner identity'
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/tests/mock-integration.sh" \
    '[[ ${BASHPID} != "${TEST_OWNER_BASHPID}" ]]' \
    'non-owner test cleanup protection'
readonly EXPECTED_VERSION='2.1.14'
assert_file_contains "${script_dir}/download-video.sh" \
    "readonly VERSION=\"${EXPECTED_VERSION}\"" \
    'engine version constant'
for versioned_script in \
    download-video.sh download-video-gui.sh progress-monitor.sh install-gui.sh; do
    assert_file_contains "${script_dir}/${versioned_script}" \
        "# Version     : ${EXPECTED_VERSION}" \
        "${versioned_script} version header"
done
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'readonly LOG_RETENTION_DAYS=15' \
    'GUI retained-log lifetime'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    '--width=620' \
    'profile dialog width'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    '--height=305' \
    'profile dialog height'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'readonly PROGRESS_DIALOG_WIDTH=700' \
    'progress dialog width'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'process_is_running() {' \
    'zombie-aware worker liveness check'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    "bash \"\${PROGRESS_MONITOR}\"" \
    'GUI delegates progress parsing to the unified monitor'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'IFS= read -r -N 65536 chunk <&3' \
    'progress log is consumed incrementally without an asynchronous reader pipeline'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    "pending_data+=\${chunk}" \
    'partial progress records are retained across reads'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    "emit_progress 100 'Download complete.'" \
    '100 percent is emitted only by final result verification'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    "trap 'exit 0' PIPE" \
    'closed Zenity pipe ends the monitor normally'
assert_file_contains "${script_dir}/download-video.sh" \
    'normalize_path_record() {' \
    'final result path record normalization'
# shellcheck disable=SC2016
# The assertion searches for literal shell source code.
assert_file_contains "${script_dir}/download-video.sh" \
    'normalize_path_record "${PATH_RECORD_TMP}" "${OUTPUT_DIR}"' \
    'final result path confinement to the destination directory'
# shellcheck disable=SC2016
# The assertion searches for literal shell source code.
assert_file_contains "${script_dir}/download-video.sh" \
    'mv -n -- "${RESULT_FILE_TMP}" "${RESULT_FILE}"' \
    'result-file no-clobber publication'
# shellcheck disable=SC2016
# The assertion searches for literal shell source code.
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'RESOLVED_KEY="native:$((seen_items + 1))"' \
    'progress uses opaque internal item keys'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'MAX_PENDING_CHARS=1048576' \
    'progress pending-record memory bound'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source code.
assert_file_contains "${script_dir}/download-video.sh" \
    'acquire_output_lock "${OUTPUT_DIR}"' \
    'engine destination-directory lock'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source code.
assert_file_contains "${script_dir}/download-video.sh" \
    'flock --exclusive --nonblock "${OUTPUT_LOCK_FD}"' \
    'nonblocking destination lock acquisition'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source code.
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'kill -0 -- "-${WORKER_PGID}"' \
    'worker group remains tracked after supervisor exit'
assert_file_contains "${script_dir}/download-video.sh" \
    'the result-file already exists; refusing to overwrite it.' \
    'existing result files are protected'
assert_file_contains "${script_dir}/download-video.sh" \
    'the final MKV already exists; refusing to overwrite it:' \
    'existing HLS MKV files are protected'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    "monitor_status=\${pipeline_status[0]:-1}" \
    'technical progress-monitor status is checked'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'final media file could not be confirmed inside the selected destination folder' \
    'GUI result path is constrained to the selected destination'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    'strict semantic release tag validation'
assert_file_contains "${script_dir}/.github/workflows/shell.yml" \
    'cancel-in-progress: true' \
    'outdated validation runs are cancelled'

assert_file_contains "${script_dir}/README.md"     "is **${EXPECTED_VERSION}**." 'English README version'
assert_file_contains "${script_dir}/README.fr.md"     "version actuelle est la **${EXPECTED_VERSION}**." 'French README version'
assert_file_contains "${script_dir}/CHANGELOG.md"     "## ${EXPECTED_VERSION} - " 'changelog version'

assert_file_contains "${script_dir}/.github/workflows/shell.yml" \
    '    branches:' \
    'push validation branch filter'
assert_file_contains "${script_dir}/.github/workflows/shell.yml" \
    '      - main' \
    'push validation main branch'
# shellcheck disable=SC2016
# The assertion deliberately searches for literal workflow shell source.
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'git merge-base --is-ancestor "${tag_commit}" origin/main' \
    'release tag ancestry validation'

printf '%s\n' 'Static tests passed.'

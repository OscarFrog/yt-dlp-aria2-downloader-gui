#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
# shellcheck disable=SC1090
source "${script_dir}/tests/lib/assert.sh"
# shellcheck disable=SC1090
source "${script_dir}/tests/lib/project-files.sh"

for file in "${ALL_SHELL_FILES[@]}"; do
    bash -n "${script_dir}/${file}"
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

assert_status 2 'missing URL is rejected' \
    "${script_dir}/download-video.sh"
assert_text_contains "${ASSERT_OUTPUT}" 'a video URL is required.' \
    'missing URL diagnostic'

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
    "${script_dir}/download-video-gui.sh" \
    '\[#[[:xdigit:]]+[[:space:]]' \
    'aria2 progress without mandatory percentage'
assert_file_contains \
    "${script_dir}/install-gui.sh" \
    "readonly LAUNCHER_LINK=\"\${LAUNCHER_DIR}/launch\"" \
    'stable desktop launcher link'
assert_file_contains \
    "${script_dir}/install-gui.sh" \
    "desktop-file-validate \\" \
    'desktop launcher validation'
readonly EXPECTED_VERSION='2.1.10'
assert_file_contains "${script_dir}/download-video.sh" \
    "readonly VERSION=\"${EXPECTED_VERSION}\"" \
    'engine version constant'
for versioned_script in download-video.sh download-video-gui.sh install-gui.sh; do
    assert_file_contains "${script_dir}/${versioned_script}" \
        "# Version     : ${EXPECTED_VERSION}" \
        "${versioned_script} version header"
done
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'readonly LOG_RETENTION_DAYS=15' \
    'GUI retained-log lifetime'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'process_is_running() {' \
    'zombie-aware worker liveness check'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'When a child group was signaled, keep the setsid --wait supervisor alive' \
    'setsid supervisor reaping policy'

assert_file_contains "${script_dir}/README.md"     "is **${EXPECTED_VERSION}**." 'English README version'
assert_file_contains "${script_dir}/README.fr.md"     "version actuelle est la **${EXPECTED_VERSION}**." 'French README version'
assert_file_contains "${script_dir}/CHANGELOG.md"     "## ${EXPECTED_VERSION} - " 'changelog version'

printf 'Static tests passed.
'

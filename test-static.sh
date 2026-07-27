#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
# shellcheck disable=SC1090
source "${script_dir}/tests/lib/assert.sh"

for file in \
    download-video.sh \
    download-video-gui.sh \
    install-gui.sh \
    test-static.sh \
    tests/run-all.sh \
    tests/lib/assert.sh \
    tests/mock-integration.sh \
    tests/installer-integration.sh; do
    bash -n "${script_dir}/${file}"
done

assert_status 0 'download engine help' \
    "${script_dir}/download-video.sh" --help
assert_status 0 'download engine version' \
    "${script_dir}/download-video.sh" --version

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

printf 'Static tests passed.\n'

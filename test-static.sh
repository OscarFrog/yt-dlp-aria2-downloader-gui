#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir

assert_status_2() {
    local status

    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    if ((status != 2)); then
        printf 'Expected status 2, got %d for: %s\n' "${status}" "$*" >&2
        exit 1
    fi
}

for file in \
    download-video.sh \
    download-video-gui.sh \
    install-gui.sh \
    test-static.sh \
    tests/mock-integration.sh \
    tests/installer-integration.sh; do
    bash -n "${script_dir}/${file}"
done

"${script_dir}/download-video.sh" --help >/dev/null
"${script_dir}/download-video.sh" --version >/dev/null
assert_status_2 "${script_dir}/download-video.sh"
assert_status_2 "${script_dir}/download-video.sh" --mode invalid \
    'https://example.com/video'
assert_status_2 "${script_dir}/download-video.sh" --audio-format mp3 \
    'https://example.com/video'
assert_status_2 "${script_dir}/download-video.sh" --audio-quality 0 \
    'https://example.com/video'
assert_status_2 "${script_dir}/download-video.sh" $'https://example.com/a\nb'
assert_status_2 "${script_dir}/install-gui.sh"

grep -Fq -- \
    'LC_ALL=C setsid --fork --wait bash -c' \
    "${script_dir}/download-video-gui.sh" || {
    printf '%s\n' \
        'GUI worker must be launched with LC_ALL=C.' >&2
    exit 1
}


engine_locale_probes=(
    'LC_ALL=C yt-dlp --version'
    'LC_ALL=C yt-dlp --help'
    'LC_ALL=C deno --version'
    'LC_ALL=C aria2c --version'
    'LC_ALL=C aria2c --help=#all'
)

for required_probe in "${engine_locale_probes[@]}"; do
    grep -Fq -- \
        "${required_probe}" \
        "${script_dir}/download-video.sh" || {
        printf 'Missing locale-stabilized probe: %s\n' \
            "${required_probe}" >&2
        exit 1
    }
done

grep -Fq -- \
    'LC_ALL=C setsid --help' \
    "${script_dir}/download-video-gui.sh" || {
    printf '%s\n' \
        'The setsid capability probe must use LC_ALL=C.' >&2
    exit 1
}

printf 'Static tests passed.\n'

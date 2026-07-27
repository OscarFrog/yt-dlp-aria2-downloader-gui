#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_dir
project_dir=$(cd -- "${script_dir}/.." && pwd -P)
readonly project_dir

cd -- "${project_dir}"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'Error: shellcheck is required to run the complete validation suite.\n' >&2
    exit 127
fi

shellcheck --version
./test-static.sh

shellcheck -o all \
    download-video.sh \
    download-video-gui.sh \
    install-gui.sh

# Test scripts intentionally capture non-zero statuses. They use the standard
# ShellCheck rules while production scripts also enable every optional rule.
shellcheck -x -o all \
    test-static.sh \
    tests/run-all.sh \
    tests/lib/assert.sh \
    tests/mock-integration.sh \
    tests/installer-integration.sh

./tests/mock-integration.sh
./tests/installer-integration.sh

printf 'All validation suites passed.\n'

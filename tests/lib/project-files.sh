#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Canonical project shell-file lists shared by syntax and ShellCheck validation.
# Paths are relative to the repository root. Callers must resolve them against
# that root or change to it before passing the lists to external tools.
# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
PRODUCTION_SHELL_FILES=(
    download-video.sh
    download-video-gui.sh
    install-gui.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
TEST_SHELL_FILES=(
    test-static.sh
    tests/run-all.sh
    tests/lib/assert.sh
    tests/lib/project-files.sh
    tests/mock-integration.sh
    tests/installer-integration.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
ALL_SHELL_FILES=(
    "${PRODUCTION_SHELL_FILES[@]}"
    "${TEST_SHELL_FILES[@]}"
)

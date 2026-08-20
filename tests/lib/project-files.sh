#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Canonical project shell-file lists shared by syntax and ShellCheck validation.
# Paths are relative to the repository root. Callers must resolve them against
# that root or change to it before passing the lists to external tools.
# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
PRODUCTION_SHELL_FILES=(
    download-video.sh
    download-video-gui.sh
    progress-monitor.sh
    runtime-manager.sh
    install-gui.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
PACKAGING_SHELL_FILES=(
    install-fedora.sh
    packaging/install-tree.sh
    packaging/deb/build-deb.sh
    packaging/deb/test-package-lifecycle.sh
    packaging/rpm/build-rpm.sh
    packaging/rpm/test-package-lifecycle.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
TEST_SHELL_FILES=(
    test-static.sh
    tests/run-all.sh
    tests/lib/assert.sh
    tests/lib/project-files.sh
    tests/mock-integration.sh
    tests/runtime-manager-integration.sh
    tests/progress-monitor-integration.sh
    tests/installer-integration.sh
    tests/packaging-integration.sh
    tests/ffmpeg-progress-integration.sh
    tests/real-tools-integration.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
ALL_SHELL_FILES=(
    "${PRODUCTION_SHELL_FILES[@]}"
    "${PACKAGING_SHELL_FILES[@]}"
    "${TEST_SHELL_FILES[@]}"
)

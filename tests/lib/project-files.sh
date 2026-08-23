#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/project-files.sh
# Purpose     : Define the canonical shell-file lists used by validation.
# ==============================================================================

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
    scripts/release-preflight.sh
    packaging/install-tree.sh
    packaging/package-user-cleanup.sh
    packaging/deb/build-deb.sh
    packaging/deb/postinst
    packaging/deb/prerm
    packaging/deb/postrm
    packaging/deb/test-package-lifecycle.sh
    packaging/deb/test-package-upgrade.sh
    packaging/rpm/build-rpm.sh
    packaging/rpm/test-package-lifecycle.sh
    packaging/rpm/test-package-upgrade.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
TEST_SHELL_FILES=(
    test-static.sh
    tests/run-all.sh
    tests/lib/assert.sh
    tests/lib/project-files.sh
    tests/mock-integration.sh
    tests/runtime-manager-integration.sh
    tests/runtime-manager-hardening-integration.sh
    tests/progress-monitor-integration.sh
    tests/installer-integration.sh
    tests/packaging-integration.sh
    tests/package-user-cleanup-integration.sh
    tests/rpm6-multisig-integration.sh
    tests/ffmpeg-progress-integration.sh
    tests/ffmpeg-real-progress-integration.sh
    tests/hls-remux-duration-integration.sh
    tests/real-tools-integration.sh
    tests/aria2-real-behavior-integration.sh
)

# Development shell tools are part of the canonical validation surface.
# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
DEVELOPMENT_SHELL_FILES=(
    scripts/dev-tools/ensure-shfmt.sh
    scripts/check-shell-format.sh
    scripts/format-shell.sh
)

# Shell files intentionally exempt from the explicit main() entry-point rule:
# POSIX maintainer hooks, sourced libraries, and tiny linear Bash executables.
# shellcheck disable=SC2034 # Array is read by test-static.sh.
MAIN_EXEMPT_SHELL_FILES=(
    packaging/install-tree.sh
    packaging/deb/postinst
    packaging/deb/prerm
    packaging/deb/postrm
    tests/run-all.sh
    tests/lib/assert.sh
    tests/lib/project-files.sh
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
ALL_SHELL_FILES=(
    "${PRODUCTION_SHELL_FILES[@]}"
    "${PACKAGING_SHELL_FILES[@]}"
    "${TEST_SHELL_FILES[@]}"
    "${DEVELOPMENT_SHELL_FILES[@]}"
)

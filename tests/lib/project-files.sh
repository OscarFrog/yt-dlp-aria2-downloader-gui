#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/project-files.sh
# Purpose     : Define the canonical source-file lists used by validation.
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
    tests/run-all-signal-integration.sh
    tests/repeat-qualification.sh
    tests/test-runner-integration.sh
    tests/lib/assert.sh
    tests/lib/package-lifecycle.sh
    tests/lib/package-runtime-preservation.sh
    tests/lib/project-files.sh
    tests/lib/test-runner.sh
    tests/mock-integration.sh
    tests/private-aria2-plan-integration.sh
    tests/aria2-auth-headers-integration.sh
    tests/runtime-manager-integration.sh
    tests/runtime-manager-hardening-integration.sh
    tests/progress-monitor-integration.sh
    tests/installer-integration.sh
    tests/install-fedora-authentication-integration.sh
    tests/packaging-integration.sh
    tests/package-user-cleanup-integration.sh
    tests/rpm6-multisig-integration.sh
    tests/ffmpeg-progress-integration.sh
    tests/ffmpeg-real-progress-integration.sh
    tests/ffmpeg-generation-compatibility.sh
    tests/ffmpeg-generation-qualification.sh
    tests/hls-remux-duration-integration.sh
    tests/real-tools-integration.sh
    tests/aria2-real-behavior-integration.sh
    tests/zenity-real-session-qualification.sh
)

# Development shell tools are part of the canonical validation surface.
# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
DEVELOPMENT_SHELL_FILES=(
    scripts/dev-tools/ensure-shfmt.sh
    scripts/check-shell-format.sh
    scripts/format-shell.sh
    scripts/git-inspect.sh
    scripts/release-evidence-qualification.sh
)

# Shell files sourced by other scripts. These libraries must not change their
# caller's shell-option state and are exempt from the executable main() rule.
# shellcheck disable=SC2034 # Array is read by test-static.sh.
SOURCED_SHELL_FILES=(
    tests/lib/assert.sh
    tests/lib/package-lifecycle.sh
    tests/lib/package-runtime-preservation.sh
    tests/lib/project-files.sh
    tests/lib/test-runner.sh
)

# Executables that intentionally handle every fallible operation explicitly
# instead of relying on errexit. Each file carries its durable local rationale.
# shellcheck disable=SC2034 # Array is read by test-static.sh.
NO_ERREXIT_SHELL_FILES=(
    runtime-manager.sh
    packaging/package-user-cleanup.sh
)

# Shell files intentionally exempt from the explicit main() entry-point rule.
# shellcheck disable=SC2034 # Array is read by test-static.sh.
MAIN_EXEMPT_SHELL_FILES=(
    "${SOURCED_SHELL_FILES[@]}"
)

# shellcheck disable=SC2034 # Arrays are read by scripts that source this file.
ALL_SHELL_FILES=(
    "${PRODUCTION_SHELL_FILES[@]}"
    "${PACKAGING_SHELL_FILES[@]}"
    "${TEST_SHELL_FILES[@]}"
    "${DEVELOPMENT_SHELL_FILES[@]}"
)

# Python modules use the project-wide identity contract in AGENTS.md rather
# than the Bash-only header contract in SHELL_STYLE.md.
# shellcheck disable=SC2034 # Array is read by test-static.sh.
PYTHON_FILES=(
    private-aria2-plan.py
    private-launcher-manager.py
    scripts/update-published-version.py
)

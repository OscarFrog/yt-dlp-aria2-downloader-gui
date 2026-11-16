#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/packaging-integration.sh
# Purpose     : Validate the staged package install tree.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly PROJECT_DIR
# Resolve the assertion library relative to this test script.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# Exercise the same helper contract in staging and installed RPM/DEB lifecycles.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/package-lifecycle.sh
source "${SCRIPT_DIR}/lib/package-lifecycle.sh"

for command_name in desktop-file-validate readlink stat; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 127
    }
done

version_output=$("${PROJECT_DIR}/download-video.sh" --version)
version=${version_output##* }
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Invalid project version: ${version}"

root=$(mktemp -d)

cleanup() {
    rm -rf -- "${root}"
}

test_package_apt_routing() {
    python3 -I -B - "${PROJECT_DIR}" <<'PY_PACKAGE_APT'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
bash = shutil.which("bash")
assert bash is not None
available = subprocess.run(["locale", "-a"], check=True, capture_output=True,
                           text=True, encoding="utf-8").stdout.splitlines()
locales = ["C"]
locales.extend(value for value in available if value.lower().replace("-", "") == "fr_fr.utf8")
checks = 0
with tempfile.TemporaryDirectory(prefix="package-apt-routing-") as temporary:
    root = Path(temporary)
    binary = root / "bin"
    binary.mkdir()
    log = root / "calls"
    for command in ("apt-get", "python3"):
        fake = binary / command
        fake.write_text(f"#!{bash}\n" + '''printf '%s\\0' "${0##*/}" "${DEBIAN_FRONTEND:-}" "$@" >"$CHECK_APT_CALL"
exit "$CHECK_APT_STATUS"
''', encoding="utf-8")
        fake.chmod(0o755)
    for language in locales:
        for selection in (None, "", "1", "0", "hostile"):
            for status in (0, 23, 100):
                log.unlink(missing_ok=True)
                env = dict(os.environ, LC_ALL=language, PATH=str(binary) + os.pathsep + os.defpath,
                           LIBRARY=str(project / "tests/lib/package-lifecycle.sh"),
                           PROJECT_DIR=str(project), CHECK_APT_CALL=str(log),
                           CHECK_APT_STATUS=str(status))
                env.pop("YT_DLP_CI_APT", None)
                if selection is not None:
                    env["YT_DLP_CI_APT"] = selection
                result = subprocess.run(
                    [bash, "-euc", 'source "$LIBRARY"; DEBIAN_FRONTEND=noninteractive '
                     'package_test_apt install --yes "/tmp/paquet été 日本.deb"'],
                    env=env, capture_output=True, timeout=5)
                valid = selection in (None, "", "1")
                assert result.returncode == (status if valid else 65), (selection, status, result)
                assert not result.stdout
                if valid:
                    expected = [b"python3" if selection == "1" else b"apt-get", b"noninteractive"]
                    if selection == "1":
                        expected.extend([b"-I", b"-B", os.fsencode(project / "scripts/ci-ubuntu-mirrors.py"),
                                         b"--apt"])
                    expected.extend([b"install", b"--yes", "/tmp/paquet été 日本.deb".encode("utf-8")])
                    assert log.read_bytes().split(b"\0")[:-1] == expected
                    assert not result.stderr
                else:
                    assert not log.exists()
                    assert result.stderr == b"Error: invalid CI APT selection.\n"
                checks += 1
        for directory in (None, "relative-project"):
            log.unlink(missing_ok=True)
            env = dict(os.environ, LC_ALL=language, PATH=str(binary) + os.pathsep + os.defpath,
                       LIBRARY=str(project / "tests/lib/package-lifecycle.sh"), YT_DLP_CI_APT="1",
                       CHECK_APT_CALL=str(log), CHECK_APT_STATUS="0")
            env.pop("PROJECT_DIR", None)
            if directory is not None:
                env["PROJECT_DIR"] = directory
            result = subprocess.run([bash, "-euc", 'source "$LIBRARY"; package_test_apt update'],
                                    env=env, capture_output=True, timeout=5)
            assert result.returncode == 65
            assert not log.exists()
            assert result.stderr == b"Error: CI APT requires an absolute project directory.\n"
            checks += 1

# Both DEB jobs must carry the selection across sudo for all package transitions.
for workflow in ("packages.yml", "release.yml"):
    text = (project / ".github/workflows" / workflow).read_text(encoding="utf-8")
    for kind in ("lifecycle", "upgrade"):
        script = f"packaging/deb/test-package-{kind}.sh"
        assert text.count(f"sudo env YT_DLP_CI_APT=1 bash {script}") == 1
        assert f"sudo bash {script}" not in text
for kind, expected_calls in (("lifecycle", 5), ("upgrade", 4)):
    text = (project / f"packaging/deb/test-package-{kind}.sh").read_text(encoding="utf-8")
    assert text.count("package_test_apt ") == expected_calls
    for command in ("install", "remove", "purge"):
        assert f"apt-get {command}" not in text
print(f"Package APT routing: {checks} cases passed; locales: {', '.join(locales)}")
PY_PACKAGE_APT
}

test_rejected_private_directories() {
    local invalid_private_dir=''
    local invalid_root=''

    for invalid_private_dir in \
        '/usr/' \
        '/usr/.' \
        '/usr/..' \
        '/usr//lib/yt-dlp-aria2-downloader' \
        '/usr/lib/yt-dlp-aria2-downloader/' \
        '/usr/lib/../lib/yt-dlp-aria2-downloader' \
        '/opt/yt-dlp-aria2-downloader' \
        'usr/lib/yt-dlp-aria2-downloader'; do
        invalid_root="${root}/invalid-${RANDOM}-${RANDOM}"
        if bash "${PROJECT_DIR}/packaging/install-tree.sh" \
            "${invalid_root}" "${version}" "${invalid_private_dir}" \
            >/dev/null 2>&1; then
            fail "install-tree accepted unsafe PRIVATE_DIR: ${invalid_private_dir}"
        fi
        [[ ! -e ${invalid_root} ]] \
            || fail "Rejected PRIVATE_DIR created a staging tree: ${invalid_private_dir}"
    done
}

test_alternate_private_directory() {
    local alternate_root="${root}/libexec-case"

    bash "${PROJECT_DIR}/packaging/install-tree.sh" \
        "${alternate_root}" "${version}" \
        '/usr/libexec/yt-dlp-aria2-downloader' >/dev/null
    assert_link_target \
        "${alternate_root}/usr/bin/yt-dlp-aria2-downloader" \
        '../libexec/yt-dlp-aria2-downloader/download-video.sh' \
        'packaged CLI libexec symlink target'
    assert_packaged_executables \
        "${alternate_root}/usr/libexec/yt-dlp-aria2-downloader"
    assert_package_helper_behavior \
        "${alternate_root}/usr/bin/yt-dlp-aria2-downloader"
}

assert_packaged_executables() {
    local private_dir=$1
    local executable

    for executable in \
        download-video.sh \
        download-video-gui.sh \
        progress-monitor.sh \
        runtime-manager.sh \
        package-user-cleanup.sh; do
        [[ -x ${private_dir}/${executable} && ! -L ${private_dir}/${executable} ]] \
            || fail "Missing packaged executable: ${executable}"
        assert_path_mode "${private_dir}/${executable}" 755 \
            "${executable} permissions"
    done

    local private_aria2_helper="${private_dir}/private-aria2-plan.py"
    local track_helper
    local -a expected_track_helpers=(private-art-tracks.py private-art-media.py private-art-subtitle.py)
    local -a installed_track_helpers=("${private_dir}"/private-art*.py)
    # This prefix also matches the obsolete spellings. Equal cardinality plus
    # every exact current filename excludes old modules and compatibility aliases.
    ((${#installed_track_helpers[@]} == ${#expected_track_helpers[@]})) \
        || fail 'Package must contain exactly the three current track helper modules.'
    for track_helper in "${expected_track_helpers[@]}"; do
        [[ -f ${private_dir}/${track_helper} && ! -L ${private_dir}/${track_helper} ]] \
            || fail 'Missing or unsafe packaged track helper.'
        assert_path_mode "${private_dir}/${track_helper}" 644 "${track_helper} permissions"
        python3 -I -B "${private_dir}/${track_helper}" --help >/dev/null \
            || fail 'Installed track helper cannot run independently.'
    done
    [[ -f ${private_dir}/private-process-supervisor.py &&
        ! -L ${private_dir}/private-process-supervisor.py ]] \
        || fail 'Missing or unsafe packaged process supervisor.'
    assert_path_mode "${private_dir}/private-process-supervisor.py" 644 \
        'private-process-supervisor.py permissions'
    local private_launcher_helper="${private_dir}/private-launcher-manager.py"
    [[ -f ${private_aria2_helper} &&
        ! -L ${private_aria2_helper} &&
        ! -x ${private_aria2_helper} ]] \
        || fail 'Missing or unsafe packaged private aria2 helper.'
    assert_path_mode "${private_aria2_helper}" 644 \
        'private-aria2-plan.py permissions'

    [[ ! -e ${private_launcher_helper} && ! -L ${private_launcher_helper} ]] \
        || fail 'System package contains the portable-only launcher helper.'
}

assert_packaged_entrypoints() {
    local packaged_version

    packaged_version=$(
        "${root}/usr/bin/yt-dlp-aria2-downloader" --version
    )
    assert_link_target \
        "${root}/usr/bin/yt-dlp-aria2-downloader" \
        '../lib/yt-dlp-aria2-downloader/download-video.sh' \
        'packaged CLI symlink target'
    assert_link_target \
        "${root}/usr/bin/yt-dlp-aria2-downloader-gui" \
        '../lib/yt-dlp-aria2-downloader/download-video-gui.sh' \
        'packaged GUI symlink target'
    assert_equals "yt-dlp-aria2-downloader version ${version}" \
        "${packaged_version}" 'packaged CLI version'
}

assert_packaged_desktop_entry() {
    local desktop_file="${root}/usr/share/applications/yt-dlp-aria2-downloader.desktop"

    desktop-file-validate --no-hints "${desktop_file}"
    assert_file_contains "${desktop_file}" \
        'Exec=/usr/bin/yt-dlp-aria2-downloader-gui' 'system desktop Exec'
    assert_file_contains "${desktop_file}" \
        'TryExec=/usr/bin/yt-dlp-aria2-downloader-gui' 'system desktop TryExec'
    assert_file_contains "${desktop_file}" \
        'Icon=yt-dlp-aria2-downloader' 'dedicated packaged icon name'
}

assert_packaged_assets() {
    local private_dir=$1
    local icon_file="${root}/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg"
    local document document_path key_file

    [[ -f ${icon_file} && ! -L ${icon_file} ]] \
        || fail 'Missing packaged application icon.'
    assert_path_mode "${icon_file}" 644 'packaged icon permissions'

    for document in README.md README.fr.md CHANGELOG.md; do
        document_path="${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/${document}"
        [[ -f ${document_path} && ! -L ${document_path} ]] \
            || fail "Missing packaged document: ${document}"
        assert_path_mode "${document_path}" 644 "${document} permissions"
    done

    for document in README.md README.fr.md; do
        document_path="${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/${document}"
        assert_file_not_contains "${document_path}" '](TESTING.md)' \
            "${document} has no broken installed TESTING link"
        assert_file_not_contains "${document_path}" '](LICENSE)' \
            "${document} has no broken installed LICENSE link"
    done
    assert_file_contains \
        "${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/README.md" \
        'For a launcher installed from a portable ZIP or Git checkout' \
        'English source-tree uninstall command is explicitly qualified'
    assert_file_contains \
        "${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/README.fr.md" \
        'Pour un lanceur installé depuis une archive ZIP portable ou un checkout Git' \
        'French source-tree uninstall command is explicitly qualified'

    [[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/tests ]] \
        || fail 'Package tree contains the test suite.'
    [[ ! -e ${root}/usr/share/doc/yt-dlp-aria2-downloader-gui/docs ]] \
        || fail 'Package tree contains obsolete screenshots.'
    [[ ! -e ${private_dir}/install-gui.sh ]] \
        || fail 'System package contains the source-tree launcher installer.'
    key_file="${private_dir}/keys/yt-dlp-public.key"
    [[ -f ${key_file} && ! -L ${key_file} ]] \
        || fail 'Package tree is missing the yt-dlp signing key.'
    assert_path_mode "${key_file}" 644 \
        'packaged yt-dlp signing-key permissions'
}

test_packaged_install_tree() {
    local private_dir="${root}/usr/lib/yt-dlp-aria2-downloader"

    bash "${PROJECT_DIR}/packaging/install-tree.sh" \
        "${root}" "${version}" '/usr/lib/yt-dlp-aria2-downloader'
    assert_packaged_executables "${private_dir}"
    assert_packaged_entrypoints
    assert_packaged_desktop_entry
    assert_packaged_assets "${private_dir}"
    assert_package_helper_behavior "${root}/usr/bin/yt-dlp-aria2-downloader"
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    test_package_apt_routing
    test_rejected_private_directories
    test_alternate_private_directory
    test_packaged_install_tree
    printf 'Packaging integration tests passed.\n'
}

main "$@"

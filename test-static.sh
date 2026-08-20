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

# shellcheck disable=SC2016
# These probes deliberately search for literal variable references in source.
engine_locale_probes=(
    'LC_ALL=C "${YTDLP_BIN}" --version'
    'LC_ALL=C "${YTDLP_BIN}" --help'
    'LC_ALL=C "${DENO_BIN}" --version'
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
    "mv -Tf -- \"\${pgid_temporary}\" \"\${pgid_file}\"" \
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
    "${script_dir}/progress-monitor.sh" \
    'parse_aria_size() {' \
    'aria2 human-readable byte counters are parsed for weighted progress'
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
readonly EXPECTED_VERSION='2.1.23'
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
    'mv -nT -- "${RESULT_FILE_TMP}" "${RESULT_FILE}"' \
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

assert_file_contains \
    "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    '%dir %{_docdir}/%{name}' \
    'RPM owns its application documentation directory'

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

assert_file_contains "${script_dir}/download-video.sh" \
    'umask 077' \
    'engine restrictive umask'
assert_file_contains "${script_dir}/download-video.sh" \
    'readonly YTDLP_NO_PLUGINS=1' \
    'yt-dlp plugins disabled by default'
assert_file_contains "${script_dir}/download-video.sh" \
    '--no-overwrites' \
    'yt-dlp final-file overwrite protection'
assert_file_contains "${script_dir}/download-video.sh" \
    '--no-post-overwrites' \
    'yt-dlp post-processing overwrite protection'
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    'LC_ALL=C setsid --fork --wait bash -c' \
    'CLI worker isolated for signal forwarding'
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    'signal_download_worker "${signal_name}"' \
    'CLI signals relayed to worker group'
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    'candidate="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"' \
    'XDG runtime lock location'
assert_file_contains "${script_dir}/download-video.sh" \
    '%(title).160B [%(id).64B].%(ext)s' \
    'byte-bounded output filename'


assert_file_contains "${script_dir}/download-video.sh" \
    'run_supervised_command() {' \
    'generic long-running command supervisor'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/download-video.sh" \
    'run_supervised_command "${YTDLP_BIN}"' \
    'yt-dlp uses the generic supervisor'
assert_file_contains "${script_dir}/download-video.sh" \
    'ARIA2_SUPPORTS_NO_NETRC=false' \
    'aria2 netrc support is detected as an optional capability'
# This assertion deliberately searches for literal shell source.
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    'if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then' \
    'aria2 receives no-netrc only when the build advertises it'
assert_file_contains "${script_dir}/download-video.sh" \
    'validate_final_media_file() {' \
    'final media FFprobe validation'
# This assertion deliberately searches for literal shell source.
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    '-select_streams "${stream_selector}"' \
    'mode-specific FFprobe stream validation'
# This assertion deliberately searches for literal shell source.
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/download-video.sh" \
    'mv -nT -- "${HLS_REMUX_TMP}" "${hls_final_path}"' \
    'HLS publication never treats the target as a directory'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'YTDLP_ARIA2_SUPERVISED_SESSION=true' \
    'GUI requests reuse of its single process session without a public option'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'PROFILE OUTPUT_DIR' \
    'progress monitor receives the canonical destination'
README_EN_TEXT=$(<"${script_dir}/README.md")
README_FR_TEXT=$(<"${script_dir}/README.fr.md")
readonly README_EN_TEXT README_FR_TEXT

assert_text_not_contains "${README_EN_TEXT}" \
    'docs/images/' 'English README has no embedded screenshots'
assert_text_not_contains "${README_FR_TEXT}" \
    'docs/images/' 'French README has no embedded screenshots'


assert_file_not_contains "${script_dir}/.github/workflows/packages.yml" \
    'name: Debian package' 'unsupported DEB validation is disabled'
assert_file_contains "${script_dir}/.github/workflows/packages.yml" \
    'name: Fedora 44 RPM' 'RPM package validation job'
assert_file_not_contains "${script_dir}/.github/workflows/release.yml" \
    'dist/*.deb' 'release does not publish an unsupported DEB payload'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'dist/*.rpm' 'release publishes an RPM payload'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'dist/*.zip' 'release preserves the portable ZIP payload'
assert_file_contains "${script_dir}/packaging/yt-dlp-aria2-downloader.desktop" \
    'TryExec=/usr/bin/yt-dlp-aria2-downloader-gui' \
    'packaged desktop launcher command'
assert_file_contains "${script_dir}/packaging/deb/build-deb.sh" \
    'dpkg-deb --root-owner-group --build' 'native DEB construction'
assert_file_contains "${script_dir}/packaging/rpm/build-rpm.sh" \
    'rpmbuild -bb' 'native RPM construction'
[[ ! -e ${script_dir}/docs/images ]] || \
    fail 'Obsolete screenshot directory remains in the project.'

# These assertions deliberately search for literal workflow source.
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/.github/workflows/packages.yml" \
    'git config --global --add safe.directory "${GITHUB_WORKSPACE}"' \
    'Fedora package-validation container trusts only its checked-out workspace'
# shellcheck disable=SC2016
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'git config --global --add safe.directory "${GITHUB_WORKSPACE}"' \
    'Fedora release container trusts only its checked-out workspace'

assert_file_contains "${script_dir}/README.md" \
    '## Recommended installation' 'prominent English package installation'
assert_file_contains "${script_dir}/README.fr.md" \
    '## Installation recommandée' 'prominent French package installation'
assert_file_contains "${script_dir}/README.md" \
    'are installed automatically in the desktop application menu.' \
    'English automatic package launcher installation'
assert_file_contains "${script_dir}/README.md" \
    "\`install-gui.sh\` after installing a package." \
    'English package installer exclusion'
assert_file_contains "${script_dir}/README.fr.md" \
    'installés automatiquement dans le menu des applications.' \
    'French automatic package launcher installation'
assert_file_contains "${script_dir}/README.fr.md" \
    "\`install-gui.sh\` après l’installation d’un paquet." \
    'French package installer exclusion'
assert_file_contains "${script_dir}/packaging/yt-dlp-aria2-downloader.desktop" \
    'Icon=yt-dlp-aria2-downloader' 'dedicated desktop icon name'
[[ -f ${script_dir}/packaging/icons/yt-dlp-aria2-downloader.svg ]] || \
    fail 'Dedicated application icon is absent.'
assert_file_contains "${script_dir}/packaging/install-tree.sh" \
    'usr/share/icons/hicolor/scalable/apps' \
    'Freedesktop hicolor icon installation'
assert_file_not_contains "${script_dir}/.github/workflows/packages.yml" \
    'packaging/deb/test-package-lifecycle.sh' \
    'unsupported DEB lifecycle is not run in package CI'
assert_file_contains "${script_dir}/.github/workflows/packages.yml" \
    'packaging/rpm/test-package-lifecycle.sh' \
    'RPM installation and removal validation'
assert_file_not_contains "${script_dir}/.github/workflows/release.yml" \
    'packaging/deb/test-package-lifecycle.sh' \
    'unsupported DEB lifecycle is not run during release'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'packaging/rpm/test-package-lifecycle.sh' \
    'release RPM installation and removal validation'
assert_file_not_contains "${script_dir}/packaging/deb/build-deb.sh" \
    'install-gui.sh' 'DEB does not run the per-user launcher installer'
assert_file_not_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    'install-gui.sh' 'RPM does not run the per-user launcher installer'



# Version 2.1.23 runtime-update, Fedora bootstrap, playlist, HLS, packaging, and supply-chain contracts.
assert_file_contains "${script_dir}/download-video.sh" \
    '--url-file FILE' 'private URL-file input'
assert_file_contains "${script_dir}/download-video.sh" \
    "--batch-file \"\${YTDLP_BATCH_FILE_TMP}\"" 'private yt-dlp batch file'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    "--url-file \"\${URL_FILE}\"" 'GUI private URL transfer'
assert_file_not_contains "${script_dir}/download-video-gui.sh" \
    "COMMAND+=(-- \"\${URL}\")" 'GUI URL is absent from process arguments'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'LOG_MAX_BYTES=8388608' 'retained diagnostic log size bound'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    '[REDACTED_URL]' 'retained diagnostic URL redaction'
assert_file_contains "${script_dir}/download-video-gui.sh" \
    'live-download-log.' 'live log remains in the private runtime directory'
assert_file_contains "${script_dir}/download-video.sh" \
    "probe_stream stream_present \"\${final_path}\" 'v:0'" 'complete-video video stream validation'
assert_file_contains "${script_dir}/download-video.sh" \
    "probe_stream stream_present \"\${final_path}\" 'a:0'" 'complete-video audio stream validation'
assert_file_contains "${script_dir}/download-video.sh" \
    '-nostdin' 'FFmpeg standard-input isolation'
assert_file_contains "${script_dir}/download-video.sh" \
    '-progress pipe:1' 'FFmpeg machine progress output'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'FFMPEG_PROGRESS_DURATION' 'measured FFmpeg progress parsing'
assert_file_contains "${script_dir}/progress-monitor.sh" \
    'MAX_SAFE_COUNTER=9000000000000000' 'bounded progress arithmetic'
assert_file_contains "${script_dir}/packaging/deb/build-deb.sh" \
    'aria2 (>= 1.37.0), ffmpeg, yt-dlp (>= 2026.06.09), zenity' \
    'DEB versioned runtime dependencies'
assert_file_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    'Requires:       aria2 >= 1.37.0' 'RPM minimum aria2 dependency'
assert_file_contains "${script_dir}/install-gui.sh" \
    'readonly ICON_FILE=' 'per-user dedicated icon installation'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'actions/attest@59d89421af93a897026c735860bf21b6eb4f7b26' \
    'release provenance attestation action'
assert_file_contains "${script_dir}/.github/workflows/real-tools.yml" \
    'tests/real-tools-integration.sh' 'hermetic real-tool CI validation'
assert_file_contains "${script_dir}/.github/workflows/release.yml" \
    'tests/real-tools-integration.sh' 'release is gated by hermetic real-tool validation'
assert_file_not_contains "${script_dir}/.github/workflows/packages.yml" \
    'container: debian:13-slim' 'unsupported Debian package job is absent'
assert_file_not_contains "${script_dir}/.github/workflows/packages.yml" \
    'trixie-backports' 'package CI does not rely on insufficient Debian backports'
assert_file_contains "${script_dir}/tests/run-all.sh" \
    'tests/ffmpeg-progress-integration.sh' 'measured FFmpeg progress regression suite'

assert_status 2 'URL user information is rejected' \
    "${script_dir}/download-video.sh" \
    'https://user:password@example.com/video'
assert_text_contains "${ASSERT_OUTPUT}" 'user information' \
    'URL user-information rejection reason'
assert_file_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    '%dir %{_licensedir}/%{name}' \
    'RPM owns its private license directory'

assert_file_contains "${script_dir}/download-video.sh" \
    "--break-match-filters '!playlist_index'" \
    'collection entries are rejected before download'
assert_file_contains "${script_dir}/download-video.sh" \
    '--concurrent-fragments 1' \
    'native HLS/DASH fragment downloads are serialized for reliability'
assert_file_contains "${script_dir}/download-video.sh" \
    '--no-update' \
    'yt-dlp cannot self-update in the middle of a download'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/download-video.sh" \
    '--js-runtimes "deno:${DENO_BIN}"' \
    'managed Deno path is passed explicitly to yt-dlp'
assert_file_contains "${script_dir}/runtime-manager.sh" \
    'yt-dlp/yt-dlp-nightly-builds/releases/latest' \
    'managed yt-dlp checks the nightly release channel'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/runtime-manager.sh" \
    'upgrade --dry-run "${DENO_CHANNEL}"' \
    'managed Deno checks the stable channel on launch'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/runtime-manager.sh" \
    'parse_deno_version "${candidate}" version' \
    'managed Deno strips --version metadata before version-directory naming'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/runtime-manager.sh" \
    '--verify "${work}/SHA2-256SUMS.sig"' \
    'yt-dlp checksum signature is passed to GPG'
# shellcheck disable=SC2016
# This assertion deliberately searches for literal shell source.
assert_file_contains "${script_dir}/runtime-manager.sh" \
    '"${work}/SHA2-256SUMS" >/dev/null 2>&1' \
    'yt-dlp signed SHA-256 manifest is verified'
assert_file_contains "${script_dir}/install-fedora.sh" \
    'dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg' \
    'Fedora bootstrap replaces ffmpeg-free'
assert_file_contains "${script_dir}/install-fedora.sh" \
    "ffmpeg_vendor" \
    'Fedora bootstrap validates the FFmpeg vendor'
assert_file_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    'Requires:       gnupg2' \
    'RPM installs signature-verification tooling'
assert_file_not_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    'Requires:       yt-dlp' \
    'RPM does not mix a system yt-dlp with the managed runtime'
assert_file_not_contains "${script_dir}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
    'Recommends:     deno' \
    'Deno is managed explicitly instead of weakly recommended'


# shellcheck disable=SC2016
# This assertion deliberately searches for a literal shell variable reference.
assert_file_contains "${script_dir}/install-fedora.sh" \
    '"${runtime_manager}" update' \
    'Fedora installer delegates managed-runtime validation to runtime manager'
assert_file_not_contains "${script_dir}/install-fedora.sh" \
    '--list-impersonate-targets' \
    'Fedora installer does not duplicate yt-dlp impersonation parsing'
assert_file_contains "${script_dir}/runtime-manager.sh" \
    '--list-impersonate-targets' \
    'runtime manager owns yt-dlp impersonation validation'

printf '%s\n' 'Static tests passed.'

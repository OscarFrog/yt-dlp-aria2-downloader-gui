%{!?project_version:%global project_version 0}
Name:           yt-dlp-aria2-downloader-gui
Version:        %{project_version}
Release:        1%{?dist}
Summary:        Zenity interface and Bash engine for yt-dlp and aria2
License:        MIT
URL:            https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  desktop-file-utils
Requires:       bash >= 4.4
Requires:       coreutils
Requires:       findutils
Requires:       grep
Requires:       sed
Requires:       util-linux
Requires:       aria2 >= 1.37.0
Requires:       python3 >= 3.10
Requires:       ffmpeg
Requires:       curl
Requires:       gnupg2
Requires:       unzip
Requires:       zenity
Requires:       hicolor-icon-theme
Requires(preun): bash
Requires(preun): coreutils
Requires(preun): util-linux
Suggests:       firefox

%description
A Zenity graphical interface and Bash engine that downloads one complete MKV
video or the best native audio track using yt-dlp, aria2c, FFmpeg, and Zenity.

%prep
%autosetup
%build
%install
bash packaging/install-tree.sh "%{buildroot}" "%{version}" "%{_libexecdir}/yt-dlp-aria2-downloader"
install -D -m 0644 LICENSE "%{buildroot}%{_licensedir}/%{name}/LICENSE"
%check
desktop-file-validate --no-hints "%{buildroot}%{_datadir}/applications/yt-dlp-aria2-downloader.desktop"
test "$("%{buildroot}%{_bindir}/yt-dlp-aria2-downloader" --version)" = "yt-dlp-aria2-downloader version %{version}"

%preun
if [ "$1" -eq 0 ]; then
    helper="%{_libexecdir}/yt-dlp-aria2-downloader/package-user-cleanup.sh"
    if [ -x "${helper}" ]; then
        "${helper}" --all-users || :
    fi
fi
:

%files
%{_bindir}/yt-dlp-aria2-downloader
%{_bindir}/yt-dlp-aria2-downloader-gui
%dir %{_libexecdir}/yt-dlp-aria2-downloader
%{_libexecdir}/yt-dlp-aria2-downloader/download-video.sh
%{_libexecdir}/yt-dlp-aria2-downloader/download-video-gui.sh
%{_libexecdir}/yt-dlp-aria2-downloader/progress-monitor.sh
%{_libexecdir}/yt-dlp-aria2-downloader/private-aria2-plan.py
%{_libexecdir}/yt-dlp-aria2-downloader/runtime-manager.sh
%{_libexecdir}/yt-dlp-aria2-downloader/package-user-cleanup.sh
%dir %{_libexecdir}/yt-dlp-aria2-downloader/keys
%{_libexecdir}/yt-dlp-aria2-downloader/keys/yt-dlp-public.key
%{_datadir}/applications/yt-dlp-aria2-downloader.desktop
%{_datadir}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg
%{_mandir}/man1/yt-dlp-aria2-downloader.1*
%{_mandir}/man1/yt-dlp-aria2-downloader-gui.1*
%dir %{_docdir}/%{name}
%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/README.fr.md
%doc %{_docdir}/%{name}/CHANGELOG.md
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/LICENSE
%changelog
* Sun Aug 30 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.8-1
- Preserve supervised command status and authenticate process-group signaling.
- Harden private transfer cleanup and HLS no-overwrite publication.
- Harden managed-runtime paths, locks, probes, updates, and recovery.

* Sun Aug 30 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.7-1
- Improve GUI profile continuity and one-click diagnostic access.
- Add final retained-log identity with fail-closed atomic publication.
- Add fixed unattended read-only Git inspection actions.

* Sun Aug 30 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.6-1
- Improve two-stream Zenity progress weighting while preserving exact byte progress.
- Align release installation documentation and add guarded post-release updates.

* Sun Aug 30 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.5-1
- Harden runtime, GUI, launcher, cancellation, privacy, and trust boundaries.
- Reduce managed-runtime and validation latency while preserving exact checks.
- Add architecture, agent guidance, and a mechanically enforced file inventory.

* Fri Aug 28 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.4-1
- Make startup-signal qualification deterministic under parallel load.

* Fri Aug 28 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.3-1
- Repair release version validation and select the latest published upgrade baseline.

* Fri Aug 28 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.2-1
- Remove superseded audit and qualification documents from the source tree.

* Fri Aug 28 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.1-1
- Authenticate RPM Fusion bootstrap and harden release-tag authorization.
- Close test-runner startup races and improve media validation diagnostics.

* Fri Aug 28 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.3.0-1
- Unify shell architecture, runtime checks, packaging, and release validation.
- Parallelize profiled validation while retaining dedicated stress coverage.

* Thu Aug 27 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.6-1
- Harden shell/workflow consistency checks and runtime-manager diagnostics.
- Harden RPM per-user cleanup metadata and privilege boundaries.

* Thu Aug 27 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.5-1
- Add package manual pages shared with the Debian package.
- Deduplicate package runtime-preservation qualification helpers.

* Thu Aug 27 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.4-1
- Preserve replacement or ambiguous private aria2 staging during active cleanup.
- Add deterministic pathname-replacement regression coverage.

* Thu Aug 27 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.3-1
- Harden direct URL replay safety and overflow-safe numeric validation.
- Strengthen private aria2 rollback, final-media tail validation, and progress recovery.
- Align current documentation and qualification with the implemented behavior.

* Wed Aug 26 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.2-1
- Prevent unsafe HTTP-header replay across aria2 redirects.
- Require real content video during final-media validation.
- Terminate complete run-all process groups on interruption.
- Harden runtime timeout bounds against Bash arithmetic overflow.

* Tue Aug 25 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.2.1-1
- Recover abandoned private aria2 staging conservatively, qualify private HTTP headers, and fix GUI progress.

* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.28-1
- Add OpenPGP signing for the exact Fedora release RPM and fail-closed verification.

* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.27-1
- Clean managed per-user runtime and exact legacy GUI XDG data on final package erase.

* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.26-1
- Qualify exact previous immutable packages, preserve user runtimes, and harden release verification.

* Thu Aug 20 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.25-1
- Close 2.1.24 audit findings: runtime transactions, exact artifacts, upgrades, and immutable releases.

* Thu Aug 20 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.24-1
- Fix managed Deno discovery, bound runtime updates, add rollback, and requalify DEB packaging.

* Sun Aug 02 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.20-1
- Harden privacy, media validation, progress, dependencies, and release tests.

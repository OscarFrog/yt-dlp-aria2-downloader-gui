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
%{_libexecdir}/yt-dlp-aria2-downloader/runtime-manager.sh
%{_libexecdir}/yt-dlp-aria2-downloader/package-user-cleanup.sh
%dir %{_libexecdir}/yt-dlp-aria2-downloader/keys
%{_libexecdir}/yt-dlp-aria2-downloader/keys/yt-dlp-public.key
%{_datadir}/applications/yt-dlp-aria2-downloader.desktop
%{_datadir}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg
%dir %{_docdir}/%{name}
%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/README.fr.md
%doc %{_docdir}/%{name}/CHANGELOG.md
%dir %{_licensedir}/%{name}
%license %{_licensedir}/%{name}/LICENSE
%changelog
* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.28-1
- Add OpenPGP signing for the exact Fedora release RPM and fail-closed verification.

* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.27-1
- Clean managed per-user runtime and exact legacy GUI XDG data on final package erase.

* Fri Aug 21 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - 2.1.26-1
- Qualify exact previous immutable packages, preserve user runtimes, and harden release verification.

* Thu Aug 20 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - %{version}-1
- Close 2.1.24 audit findings: runtime transactions, exact artifacts, upgrades, and immutable releases.

* Thu Aug 20 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - %{version}-1
- Fix managed Deno discovery, bound runtime updates, add rollback, and requalify DEB packaging.

* Sun Aug 02 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - %{version}-1
- Harden privacy, media validation, progress, dependencies, and release tests.

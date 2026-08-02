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
Requires:       aria2
Requires:       yt-dlp
Requires:       ffmpeg
Requires:       zenity
Requires:       hicolor-icon-theme
Recommends:     deno >= 2.3.0
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
%files
%{_bindir}/yt-dlp-aria2-downloader
%{_bindir}/yt-dlp-aria2-downloader-gui
%dir %{_libexecdir}/yt-dlp-aria2-downloader
%{_libexecdir}/yt-dlp-aria2-downloader/download-video.sh
%{_libexecdir}/yt-dlp-aria2-downloader/download-video-gui.sh
%{_libexecdir}/yt-dlp-aria2-downloader/progress-monitor.sh
%{_datadir}/applications/yt-dlp-aria2-downloader.desktop
%{_datadir}/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg
%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/README.fr.md
%doc %{_docdir}/%{name}/CHANGELOG.md
%license %{_licensedir}/%{name}/LICENSE
%changelog
* Sun Aug 02 2026 OscarFrog <151366285+OscarFrog@users.noreply.github.com> - %{version}-1
- Harden privacy, media validation, progress, dependencies, and release tests.

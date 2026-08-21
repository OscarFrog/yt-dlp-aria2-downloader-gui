#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly APP_VERSION='2.1.27'
readonly PRIVATE_DIR='/usr/libexec/yt-dlp-aria2-downloader'

error() {
    printf 'Error: %s\n' "$*" >&2
}

if (($# != 1)); then
    printf 'Usage: %s PACKAGE.rpm\n' "${0##*/}" >&2
    exit 2
fi

for command_name in dnf rpm realpath; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        error "required installer command is absent: ${command_name}"
        exit 127
    }
done

rpm_path=$(realpath -e -- "$1") || {
    error "RPM not found: $1"
    exit 66
}
[[ ${rpm_path} == *.rpm ]] || {
    error "not an RPM file: ${rpm_path}"
    exit 64
}

rpm_identity_output=''
if ! rpm_identity_output=$(rpm -qp --qf '%{NAME}\n%{VERSION}\n%{ARCH}\n' -- "${rpm_path}"); then
    error 'unable to inspect the RPM metadata.'
    exit 65
fi
mapfile -t rpm_identity <<<"${rpm_identity_output}"
if ((${#rpm_identity[@]} != 3)) ||
    [[ ${rpm_identity[0]} != "${PACKAGE_NAME}" ||
       ${rpm_identity[1]} != "${APP_VERSION}" ||
       ${rpm_identity[2]} != 'noarch' ]]; then
    error "unexpected RPM identity: name=${rpm_identity[0]:-unknown} version=${rpm_identity[1]:-unknown} arch=${rpm_identity[2]:-unknown}"
    exit 65
fi

fedora_version=$(rpm -E %fedora)
[[ ${fedora_version} =~ ^[0-9]+$ ]] || {
    error 'unable to determine the Fedora release.'
    exit 69
}
if ((fedora_version < 44)); then
    error "Fedora 44 or newer is required; found Fedora ${fedora_version}."
    exit 69
fi

run_root() {
    if ((EUID == 0)); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || {
            error 'sudo is required for system package installation.'
            return 127
        }
        sudo "$@"
    fi
}

if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    printf 'Enabling RPM Fusion Free...\n'
    run_root dnf install --assumeyes \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm"
fi

if rpm -q ffmpeg-free >/dev/null 2>&1; then
    printf 'Replacing Fedora ffmpeg-free with RPM Fusion ffmpeg...\n'
    run_root dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg
else
    printf 'Installing RPM Fusion ffmpeg and required system dependencies...\n'
    run_root dnf install --assumeyes --allowerasing \
        ffmpeg aria2 zenity curl gnupg2 unzip
fi

printf 'Installing %s...\n' "${PACKAGE_NAME}"
run_root dnf install --assumeyes --allowerasing "${rpm_path}"

rpm -q "${PACKAGE_NAME}" >/dev/null
rpm -q ffmpeg >/dev/null
if rpm -q ffmpeg-free >/dev/null 2>&1; then
    error 'ffmpeg-free is still installed.'
    exit 65
fi

ffmpeg_vendor=$(rpm -q --qf '%{VENDOR}\n' ffmpeg)
if [[ ${ffmpeg_vendor} != *'RPM Fusion'* ]]; then
    error "ffmpeg is not provided by RPM Fusion: vendor=${ffmpeg_vendor}"
    exit 65
fi

for command_name in ffmpeg ffprobe aria2c zenity; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        error "required command is absent after installation: ${command_name}"
        exit 65
    }
done

runtime_manager="${PRIVATE_DIR}/runtime-manager.sh"
[[ -x ${runtime_manager} ]] || {
    error "runtime manager is missing: ${runtime_manager}"
    exit 65
}

printf 'Installing/updating verified yt-dlp stable and Deno stable runtimes for the current user...\n'
"${runtime_manager}" update

ytdlp_bin=$("${runtime_manager}" path yt-dlp)
deno_bin=$("${runtime_manager}" path deno)

"${ytdlp_bin}" --version
"${deno_bin}" --version | head -n 1

# runtime-manager.sh is the single source of truth for managed-runtime
# integrity and functional validation. The successful "update" call above has
# already validated yt-dlp, including at least one usable curl_cffi
# impersonation target. Do not duplicate parsing of yt-dlp human-readable
# output here; duplicated parsers can drift independently.
application_version=$(/usr/bin/yt-dlp-aria2-downloader --version) || {
    error 'unable to read the installed application version.'
    exit 65
}
ffmpeg_version=$(ffmpeg -version) || {
    error 'unable to read the installed FFmpeg version.'
    exit 65
}
ffmpeg_version=${ffmpeg_version%%$'\n'*}
aria2_version=$(aria2c --version) || {
    error 'unable to read the installed aria2 version.'
    exit 65
}
aria2_version=${aria2_version%%$'\n'*}
ytdlp_version=$("${ytdlp_bin}" --version) || {
    error 'unable to read the managed yt-dlp version.'
    exit 65
}
ytdlp_version=${ytdlp_version%%$'\n'*}
deno_version=$("${deno_bin}" --version) || {
    error 'unable to read the managed Deno version.'
    exit 65
}
deno_version=${deno_version%%$'\n'*}

printf '\nInstallation completed successfully.\n'
printf 'Application : %s\n' "${application_version}"
printf 'FFmpeg      : %s\n' "${ffmpeg_version}"
printf 'FFmpeg vendor: %s\n' "${ffmpeg_vendor}"
printf 'aria2       : %s\n' "${aria2_version}"
printf 'yt-dlp      : %s\n' "${ytdlp_version}"
printf 'Deno        : %s\n' "${deno_version}"

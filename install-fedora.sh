#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly PACKAGE_NAME='yt-dlp-aria2-downloader-gui'
readonly APP_VERSION='2.1.28'
readonly PRIVATE_DIR='/usr/libexec/yt-dlp-aria2-downloader'
readonly RPM_SIGNING_KEY_NAME='RPM-GPG-KEY-OscarFrog'
readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'

error() {
    printf 'Error: %s\n' "$*" >&2
}

usage() {
    cat >&2 <<EOF
Usage:
  ${0##*/} PACKAGE.rpm
  ${0##*/} --allow-unsigned-dev PACKAGE.rpm

Release RPMs must carry an OpenPGP signature made by the pinned OscarFrog RPM
signing certificate. --allow-unsigned-dev is only for local/CI development RPMs.
EOF
}

allow_unsigned_dev=false
if (($# == 2)) && [[ $1 == '--allow-unsigned-dev' ]]; then
    allow_unsigned_dev=true
    shift
fi
if (($# != 1)); then
    usage
    exit 2
fi

for command_name in awk dnf mktemp rpm rpmkeys realpath; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        error "required installer command is absent: ${command_name}"
        exit 127
    }
done

script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || {
    error 'unable to resolve Fedora installer path.'
    exit 66
}
readonly SCRIPT_DIR=${script_path%/*}

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

signature_state=$(LC_ALL=C rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' -- "${rpm_path}") || {
    error 'unable to inspect RPM OpenPGP signature metadata.'
    exit 65
}
case ${signature_state} in
signed)
    ;;
unsigned)
    if [[ ${allow_unsigned_dev} != true ]]; then
        error 'RPM has no OpenPGP signature; refusing release-style installation.'
        error 'Use only an official signed release RPM, or pass --allow-unsigned-dev explicitly for a local development build.'
        exit 65
    fi
    printf '%s\n'         'Warning: installing an explicitly allowed unsigned development RPM; OpenPGP verification is disabled for this transaction.'         >&2
    ;;
*)
    error "unexpected RPM signature state: ${signature_state}"
    exit 65
    ;;
esac

key_path=''
if [[ ${signature_state} == signed ]]; then
    if [[ -f ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} && ! -L ${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME} ]]; then
        key_path="${SCRIPT_DIR}/${RPM_SIGNING_KEY_NAME}"
    elif [[ -f ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} &&
            ! -L ${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME} ]]; then
        key_path="${SCRIPT_DIR}/packaging/keys/${RPM_SIGNING_KEY_NAME}"
    else
        error "RPM signing public key is missing: ${RPM_SIGNING_KEY_NAME}"
        exit 66
    fi
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
    run_root dnf install --assumeyes         "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm"
fi

if rpm -q ffmpeg-free >/dev/null 2>&1; then
    printf 'Replacing Fedora ffmpeg-free with RPM Fusion ffmpeg...\n'
    run_root dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg
else
    printf 'Installing RPM Fusion ffmpeg and required system dependencies...\n'
    run_root dnf install --assumeyes --allowerasing         ffmpeg aria2 zenity curl gnupg2 unzip
fi

if [[ ${signature_state} == signed ]]; then
    command -v gpg >/dev/null 2>&1 || {
        error 'GnuPG is required to validate the pinned RPM signing key.'
        exit 127
    }

    gpg_home=$(mktemp -d) || {
        error 'unable to create a temporary GnuPG home.'
        exit 70
    }
    chmod 700 "${gpg_home}"

    gpg_output=$(mktemp) || {
        rm -rf -- "${gpg_home}"
        error 'unable to create a temporary GnuPG output file.'
        exit 70
    }

    if ! LC_ALL=C gpg \
        --homedir "${gpg_home}" \
        --batch \
        --no-options \
        --with-colons \
        --show-keys \
        --fingerprint \
        "${key_path}" >"${gpg_output}"
    then
        rm -rf -- "${gpg_home}"
        rm -f -- "${gpg_output}"
        error 'unable to inspect the RPM signing public key.'
        exit 65
    fi

    key_fingerprint=$(
        awk -F: \
            '$1 == "fpr" && !found { value=toupper($10); found=1 } END { if (found) print value }' \
            "${gpg_output}"
    )

    rm -rf -- "${gpg_home}"
    rm -f -- "${gpg_output}"

    if [[ ${key_fingerprint} != "${RPM_SIGNING_FINGERPRINT}" ]]; then
        error "unexpected RPM signing key fingerprint: ${key_fingerprint:-missing}"
        exit 65
    fi

    printf 'Importing pinned OscarFrog RPM signing key: %s\n'         "${RPM_SIGNING_FINGERPRINT}"
    run_root rpmkeys --import "${key_path}"

    # shellcheck disable=SC2310
    # run_root is deliberately a status-propagating privilege wrapper. It does
    # not rely on errexit internally, so using its status in this conditional is
    # intentional and preserves the explicit verification diagnostic.
    if ! run_root rpmkeys --checksig "${rpm_path}"; then
        error 'RPM OpenPGP signature verification failed.'
        exit 65
    fi
fi

printf 'Installing %s...\n' "${PACKAGE_NAME}"
if [[ ${signature_state} == signed ]]; then
    run_root dnf install --assumeyes --allowerasing         --setopt=localpkg_gpgcheck=True         "${rpm_path}"
else
    run_root dnf install --assumeyes --allowerasing         --setopt=localpkg_gpgcheck=False         "${rpm_path}"
fi

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

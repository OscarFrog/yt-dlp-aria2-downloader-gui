#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/package-user-cleanup.sh
# Purpose     : Safely remove RPM-managed per-user data during final package erase.
# ==============================================================================

# Security invariants:
# - root only enumerates users;
# - non-root home cleanup is executed under the target UID/GID;
# - no recursive search of /home or the filesystem;
# - only an explicit path allowlist is removed;
# - marker contents are data, never sourced/eval'ed;
# - symlinked parent components below an authorized XDG root are never crossed;
# - cleanup failure must not break RPM package removal.

set -u -o pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly LEGACY_GUI_ID='yt-dlp-aria2-downloader-gui'
readonly MARKER_NAME='.package-runtime-data-home-v1'
readonly RUNTIME_OWNER_SENTINEL='.package-runtime-owner-v1'
readonly MAX_METADATA_BYTES=4096

SELF=$(realpath -e -- "${BASH_SOURCE[0]}") || {
    printf 'Warning: unable to resolve package cleanup helper path.\n' >&2
    exit 66
}
readonly SELF

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

safe_absolute_path() {
    local path=$1
    local rest=''
    local component=''

    [[ ${path} == /* &&
        ${path} != / &&
        ${path} != *[[:cntrl:]]* ]] || return 1

    rest=${path#/}
    while [[ -n ${rest} ]]; do
        if [[ ${rest} == */* ]]; then
            component=${rest%%/*}
            rest=${rest#*/}
        else
            component=${rest}
            rest=''
        fi

        [[ -n ${component} &&
            ${component} != . &&
            ${component} != .. ]] || return 1
    done

    return 0
}

safe_home() {
    local home=$1
    safe_absolute_path "${home}" \
        && [[ ${home} != /nonexistent &&
            ${home} != /var/empty ]]
}

safe_xdg_base() {
    safe_absolute_path "$1"
}

metadata_file_is_bounded() {
    local path=$1
    local size=''

    [[ -f ${path} && ! -L ${path} ]] || return 1
    size=$(stat -c '%s' -- "${path}" 2>/dev/null) || return 1
    [[ ${size} =~ ^[0-9]{1,4}$ ]] || return 1
    ((10#${size} <= MAX_METADATA_BYTES))
}

home_owned_by_effective_user() {
    local home=$1
    local owner=''

    [[ -d ${home} ]] || return 1
    owner=$(stat -Lc '%u' -- "${home}" 2>/dev/null) || return 1
    [[ ${owner} == "${EUID}" ]]
}

path_has_symlink_parent_below_base() {
    local base=$1
    local path=$2
    local relative=''
    local component=''
    local current=''

    safe_xdg_base "${base}" || return 0
    safe_absolute_path "${path}" || return 0
    [[ ${path} == "${base}/"* ]] || return 0

    relative=${path#"${base}/"}
    current=${base}

    # The leaf itself is intentionally excluded: rm(1) removes a terminal
    # symlink rather than traversing it. Only directory components that must be
    # traversed to reach the leaf are forbidden from being symlinks.
    while [[ ${relative} == */* ]]; do
        component=${relative%%/*}
        relative=${relative#*/}
        [[ -n ${component} ]] || return 0

        current="${current}/${component}"
        [[ ! -L ${current} ]] || return 0
    done

    return 1
}

remove_exact() {
    local base=$1
    local path=$2

    if ! safe_xdg_base "${base}" \
        || ! safe_absolute_path "${path}" \
        || [[ ${path} != "${base}/"* ]]; then
        warn "refusing unsafe cleanup path: ${path}"
        return 64
    fi

    if path_has_symlink_parent_below_base "${base}" "${path}"; then
        warn "refusing cleanup through a symlinked parent: ${path}"
        return 64
    fi

    if [[ -e ${path} || -L ${path} ]]; then
        if ! rm -rf --one-file-system --preserve-root=all -- "${path}"; then
            warn "unable to remove: ${path}"
            return 73
        fi
        printf 'Removed: %s\n' "${path}"
    fi

    return 0
}

rmdir_exact_if_empty() {
    local base=$1
    local path=$2

    safe_xdg_base "${base}" || return 1
    safe_absolute_path "${path}" || return 1
    [[ ${path} == "${base}/"* ]] || return 1
    path_has_symlink_parent_below_base "${base}" "${path}" && return 1

    if [[ -d ${path} && ! -L ${path} ]]; then
        rmdir -- "${path}" 2>/dev/null || true
    fi
    return 0
}

remove_legacy_icons() {
    local data_home=$1
    local path
    local nullglob_was_set=false
    local -a icons=()

    shopt -q nullglob && nullglob_was_set=true
    shopt -s nullglob
    icons=(
        "${data_home}/icons/hicolor/"*/apps/"${LEGACY_GUI_ID}.png"
        "${data_home}/icons/hicolor/"*/apps/"${LEGACY_GUI_ID}.svg"
    )
    if [[ ${nullglob_was_set} == false ]]; then
        shopt -u nullglob
    fi

    for path in "${icons[@]}"; do
        remove_exact "${data_home}" "${path}" || true
    done
}

custom_runtime_root_is_owned() {
    local base=$1
    local home=$2
    local sentinel="${base}/${APP_ID}/${RUNTIME_OWNER_SENTINEL}"
    local owner=''
    local mode=''
    local -a lines=()

    safe_xdg_base "${base}" || return 1
    if path_has_symlink_parent_below_base "${base}" "${sentinel}"; then
        return 1
    fi
    metadata_file_is_bounded "${sentinel}" || return 1

    owner=$(stat -c '%u' -- "${sentinel}" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "${sentinel}" 2>/dev/null) || return 1
    [[ ${owner} == "${EUID}" && ${mode} == 600 ]] || return 1

    mapfile -t -n 5 lines <"${sentinel}" || return 1
    ((${#lines[@]} == 4)) || return 1
    [[ ${lines[0]} == "app=${APP_ID}" ]] || return 1
    [[ ${lines[1]} == "uid=${EUID}" ]] || return 1
    [[ ${lines[2]} == "home=${home}" ]] || return 1
    [[ ${lines[3]} == "data=${base}" ]] || return 1

    return 0
}

cleanup_one_home() {
    local home=$1
    local default_data
    local data_home
    local config_home
    local state_home
    local cache_home
    local marker
    local candidate=''
    local marker_parent_safe=true
    local -a data_homes=()
    local -a marker_lines=()

    safe_home "${home}" || {
        warn "refusing invalid HOME: ${home}"
        return 64
    }

    if [[ ! -d ${home} ]]; then
        warn "HOME is unavailable or not mounted; skipping: ${home}"
        return 0
    fi

    default_data="${home}/.local/share"
    config_home="${home}/.config"
    state_home="${home}/.local/state"
    cache_home="${home}/.cache"
    data_homes=("${default_data}")

    marker="${default_data}/${APP_ID}/${MARKER_NAME}"

    if path_has_symlink_parent_below_base "${default_data}" "${marker}"; then
        marker_parent_safe=false
        warn "ignoring runtime location marker behind a symlinked parent: ${marker}"
    fi

    if [[ ${marker_parent_safe} == true &&
        -f ${marker} && ! -L ${marker} ]]; then
        if metadata_file_is_bounded "${marker}" \
            && mapfile -t -n 2 marker_lines <"${marker}" \
            && ((${#marker_lines[@]} == 1)); then
            candidate=${marker_lines[0]}
        else
            candidate=''
        fi

        if ! safe_xdg_base "${candidate}"; then
            warn "ignoring invalid or multi-line runtime location marker: ${marker}"
        elif [[ ${candidate} != "${default_data}" ]]; then
            if custom_runtime_root_is_owned "${candidate}" "${home}"; then
                data_homes+=("${candidate}")
            else
                warn "custom runtime marker lacks a matching ownership sentinel; preserving: ${candidate}"
            fi
        fi
    fi

    for data_home in "${data_homes[@]}"; do
        safe_xdg_base "${data_home}" || continue
        remove_exact "${data_home}" "${data_home}/${APP_ID}/runtime" || true
        remove_exact "${data_home}" "${data_home}/${LEGACY_GUI_ID}" || true
        remove_exact \
            "${data_home}" \
            "${data_home}/applications/${LEGACY_GUI_ID}.desktop" || true
        remove_exact \
            "${data_home}" \
            "${data_home}/metainfo/${LEGACY_GUI_ID}.metainfo.xml" || true
        remove_exact \
            "${data_home}" \
            "${data_home}/appdata/${LEGACY_GUI_ID}.appdata.xml" || true
        remove_legacy_icons "${data_home}"
        remove_exact \
            "${data_home}" \
            "${data_home}/${APP_ID}/${RUNTIME_OWNER_SENTINEL}" || true
        rmdir_exact_if_empty "${data_home}" "${data_home}/${APP_ID}" || true
    done

    remove_exact "${config_home}" "${config_home}/${LEGACY_GUI_ID}" || true
    remove_exact \
        "${config_home}" \
        "${config_home}/autostart/${LEGACY_GUI_ID}.desktop" || true
    remove_exact "${state_home}" "${state_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${cache_home}" "${cache_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${default_data}" "${marker}" || true

    # Preserve a possible portable ZIP/Git launcher in the parent.
    rmdir_exact_if_empty "${default_data}" "${default_data}/${APP_ID}" || true

    return 0
}

run_as_user() {
    local uid=$1
    local gid=$2
    local home=$3

    safe_home "${home}" || {
        warn "refusing invalid HOME for uid=${uid}: ${home}"
        return 0
    }

    if [[ ! -d ${home} ]]; then
        warn "user home unavailable, skipping uid=${uid}: ${home}"
        return 0
    fi

    if ((uid == 0)); then
        timeout 30s \
            env -i \
            HOME="${home}" \
            USER=root \
            LOGNAME=root \
            PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
            "${SELF}" --user-home "${home}" || {
            warn "cleanup failed or timed out for uid=0 home=${home}; continuing"
            return 0
        }
        return 0
    fi

    if ! command -v setpriv >/dev/null 2>&1; then
        warn "setpriv unavailable; refusing root deletion for uid=${uid}"
        return 0
    fi

    timeout 30s \
        setpriv \
        --reuid="${uid}" \
        --regid="${gid}" \
        --clear-groups \
        --inh-caps=-all \
        env -i \
        HOME="${home}" \
        USER="${uid}" \
        LOGNAME="${uid}" \
        PATH='/usr/sbin:/usr/bin:/sbin:/bin' \
        "${SELF}" --user-home "${home}" || {
        warn \
            "cleanup failed or timed out for uid=${uid} home=${home}; continuing"
        return 0
    }

    return 0
}

enumerate_users() {
    local line
    local getent_output=''
    local _name _passwd uid gid _gecos home _shell key
    local passwd_source_usable=false
    local getent_source_usable=false
    local -a records=()
    local -A seen=()

    if [[ -r /etc/passwd ]]; then
        passwd_source_usable=true
        while IFS= read -r line || [[ -n ${line} ]]; do
            records+=("${line}")
        done </etc/passwd
    fi

    if command -v getent >/dev/null 2>&1; then
        if getent_output=$(timeout 8s getent passwd 2>/dev/null); then
            getent_source_usable=true
            if [[ -n ${getent_output} ]]; then
                while IFS= read -r line || [[ -n ${line} ]]; do
                    records+=("${line}")
                done <<<"${getent_output}"
            fi
        fi
    fi

    if [[ ${passwd_source_usable} == false &&
        ${getent_source_usable} == false ]]; then
        warn 'unable to enumerate users from /etc/passwd or getent; skipping all-user cleanup'
        return 0
    fi

    for line in "${records[@]}"; do
        IFS=: read -r \
            _name _passwd uid gid _gecos home _shell <<<"${line}"

        [[ ${uid:-} =~ ^[0-9]+$ ]] || continue
        [[ ${gid:-} =~ ^[0-9]+$ ]] || continue
        safe_home "${home:-}" || continue
        while [[ ${home} == */ && ${home} != / ]]; do
            home=${home%/}
        done

        key="${uid}:${home}"
        [[ -z ${seen["${key}"]+x} ]] || continue
        seen["${key}"]=1

        run_as_user "${uid}" "${gid}" "${home}"
    done

    return 0
}

usage() {
    cat >&2 <<EOF
Usage:
  ${0##*/} --all-users
  ${0##*/} --user-home ABSOLUTE_HOME
  ${0##*/} --numeric-home UID GID ABSOLUTE_HOME
EOF
}

main() {
    case ${1:-} in
        --all-users)
            ((EUID == 0)) || {
                warn '--all-users must run as root'
                exit 77
            }
            (($# == 1)) || {
                usage
                exit 2
            }
            enumerate_users
            ;;

        --user-home)
            (($# == 2)) || {
                usage
                exit 2
            }
            safe_home "$2" || {
                warn "refusing invalid HOME: $2"
                exit 64
            }
            if [[ -d $2 ]] && ! home_owned_by_effective_user "$2"; then
                warn "refusing --user-home for a HOME not owned by effective uid ${EUID}: $2"
                exit 77
            fi
            cleanup_one_home "$2"
            ;;

        --numeric-home)
            (($# == 4)) || {
                usage
                exit 2
            }
            ((EUID == 0)) || {
                warn '--numeric-home must run as root'
                exit 77
            }
            [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || {
                usage
                exit 2
            }
            safe_home "$4" || {
                warn "refusing invalid HOME: $4"
                exit 64
            }
            run_as_user "$2" "$3" "$4"
            ;;

        *)
            usage
            exit 2
            ;;
    esac

}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Best-effort package final-removal cleanup for managed per-user runtime data
# and exact legacy yt-dlp-aria2-downloader-gui XDG artifacts.
#
# Security model:
# - root only enumerates users;
# - non-root home cleanup is executed under the target UID/GID;
# - no recursive search of /home or the filesystem;
# - only an explicit path allowlist is removed;
# - marker contents are data, never sourced/eval'ed;
# - symlinked parent components below an authorized XDG root are never crossed;
# - cleanup failure must not break dpkg/rpm removal.

set -u -o pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly LEGACY_GUI_ID='yt-dlp-aria2-downloader-gui'
readonly MARKER_NAME='.package-runtime-data-home-v1'
readonly RUNTIME_OWNER_SENTINEL='.package-runtime-owner-v1'

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
       ${path} != *$'\n'* &&
       ${path} != *$'\r'* ]] || return 1

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
    safe_absolute_path "${home}" &&
        [[ ${home} != /nonexistent &&
           ${home} != /var/empty ]]
}

safe_xdg_base() {
    safe_absolute_path "$1"
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

    if ! safe_xdg_base "${base}" ||
        ! safe_absolute_path "${path}" ||
        [[ ${path} != "${base}/"* ]]; then
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

remove_legacy_icons() {
    local data_home=$1
    local path
    local -a icons=()

    shopt -s nullglob
    icons=(
        "${data_home}/icons/hicolor/"*/apps/"${LEGACY_GUI_ID}.png"
        "${data_home}/icons/hicolor/"*/apps/"${LEGACY_GUI_ID}.svg"
    )
    shopt -u nullglob

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
    [[ -f ${sentinel} && ! -L ${sentinel} ]] || return 1

    owner=$(stat -c '%u' -- "${sentinel}" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "${sentinel}" 2>/dev/null) || return 1
    [[ ${owner} == "${EUID}" && ${mode} == 600 ]] || return 1

    mapfile -t lines <"${sentinel}" || return 1
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
        if mapfile -t marker_lines <"${marker}" &&
            ((${#marker_lines[@]} == 1)); then
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
        rmdir -- "${data_home}/${APP_ID}" 2>/dev/null || true
    done

    remove_exact "${config_home}" "${config_home}/${LEGACY_GUI_ID}" || true
    remove_exact \
        "${config_home}" \
        "${config_home}/autostart/${LEGACY_GUI_ID}.desktop" || true
    remove_exact "${state_home}" "${state_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${cache_home}" "${cache_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${default_data}" "${marker}" || true

    # Preserve a possible portable ZIP/Git launcher in the parent.
    rmdir -- "${default_data}/${APP_ID}" 2>/dev/null || true

    return 0
}

run_as_user() {
    local uid=$1
    local gid=$2
    local home=$3

    safe_home "${home}" || return 0

    if [[ ! -d ${home} ]]; then
        warn "user home unavailable, skipping uid=${uid}: ${home}"
        return 0
    fi

    if ((uid == 0)); then
        HOME="${home}" USER=root LOGNAME=root \
            "${SELF}" --user-home "${home}" || true
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
    local _name _passwd uid gid _gecos home _shell key seen_key
    local already_seen=false
    local -a records=()
    local -a seen=()

    if [[ -r /etc/passwd ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            records+=("${line}")
        done </etc/passwd
    fi

    if command -v getent >/dev/null 2>&1; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            records+=("${line}")
        done < <(
            timeout 8s getent passwd 2>/dev/null || true
        )
    fi

    for line in "${records[@]}"; do
        IFS=: read -r \
            _name _passwd uid gid _gecos home _shell <<<"${line}"

        [[ ${uid:-} =~ ^[0-9]+$ ]] || continue
        [[ ${gid:-} =~ ^[0-9]+$ ]] || continue
        safe_home "${home:-}" || continue

        key="${uid}:${home}"
        already_seen=false
        for seen_key in "${seen[@]}"; do
            if [[ ${seen_key} == "${key}" ]]; then
                already_seen=true
                break
            fi
        done
        [[ ${already_seen} == false ]] || continue
        seen+=("${key}")

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
    run_as_user "$2" "$3" "$4"
    ;;

*)
    usage
    exit 2
    ;;
esac

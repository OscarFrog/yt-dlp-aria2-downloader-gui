#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : packaging/package-user-cleanup.sh
# Purpose     : Safely migrate launchers and remove per-user data for the RPM.
# ==============================================================================

# Security invariants:
# - root only enumerates users;
# - non-root home operations are executed under the target UID/GID;
# - no recursive search of /home or the filesystem;
# - only an explicit path allowlist is removed;
# - marker contents are data, never sourced/eval'ed;
# - symlinked parent components below an authorized XDG root are never crossed;
# - launcher migration accepts only an exact legacy regular file observed under
#   the target UID, unlinks only its fixed desktop leaf, and never recurses;
# - helper failure must not break RPM package installation or removal.

# Do not use errexit here: every failure is handled explicitly so this
# best-effort helper cannot abort its package lifecycle scriptlet.
set -u -o pipefail
umask 077

readonly APP_ID='yt-dlp-aria2-downloader'
readonly LEGACY_GUI_ID='yt-dlp-aria2-downloader-gui'
readonly LEGACY_PORTABLE_ICON='video-x-generic'
readonly MARKER_NAME='.package-runtime-data-home-v1'
readonly RUNTIME_OWNER_SENTINEL='.package-runtime-owner-v1'
readonly MAX_METADATA_BYTES=4096
readonly MAX_LINUX_ID=4294967294

SELF=''

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

initialize_cleanup_helper_path() {
    if ! SELF=$(realpath -e -- "${BASH_SOURCE[0]}"); then
        warn 'unable to resolve package cleanup helper path.'
        exit 66
    fi
    readonly SELF
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

normalize_linux_id() {
    local output_variable=$1
    local value=$2
    local normalized_value=''
    local LC_ALL=C

    [[ ${value} =~ ^[0-9]+$ ]] || return 1
    normalized_value=${value#"${value%%[!0]*}"}
    [[ -n ${normalized_value} ]] || normalized_value=0

    # Bound the decimal text before arithmetic. Bash integers are signed and
    # fixed-width, so an attacker-controlled NSS field must never wrap to UID 0.
    # shellcheck disable=SC2071 # Equal-length decimal strings are compared lexically.
    if ((${#normalized_value} > ${#MAX_LINUX_ID})) \
        || { ((${#normalized_value} == ${#MAX_LINUX_ID})) \
            && [[ ${normalized_value} > ${MAX_LINUX_ID} ]]; }; then
        return 1
    fi

    printf -v "${output_variable}" '%s' "${normalized_value}" || return 1
    return 0
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

remove_exact_nondirectory() {
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
        # The launcher migration must never recurse if the leaf changes type
        # after validation. A terminal symbolic link is unlinked, not followed.
        if ! rm -f -- "${path}"; then
            warn "unable to remove: ${path}"
            return 73
        fi
        printf 'Removed obsolete launcher override: %s\n' "${path}"
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

serialize_stable_desktop_exec() {
    local output_variable=$1
    local value=$2

    # Stable-link launchers use the two escaping layers required by the
    # desktop-entry string and Exec parsers.
    value=${value//\\/\\\\\\\\}
    value=${value//\"/\\\\\"}
    value=${value//\`/\\\\\`}
    value=${value//\$/\\\\\$}
    printf -v "${output_variable}" '"%s"' "${value}"
}

legacy_desktop_matches_template() {
    local desktop_path=$1
    local desktop_exec=$2
    local comment_schema=$3

    case ${comment_schema} in
        french | english | bilingual) ;;
        *) return 2 ;;
    esac

    LC_ALL=C cmp -s -- "${desktop_path}" <(
        printf '%s\n' \
            '[Desktop Entry]' \
            'Type=Application' \
            'Version=1.0' \
            'Name=yt-dlp aria2 downloader'
        case ${comment_schema} in
            french)
                printf '%s\n' \
                    'Comment=Télécharger une vidéo ou extraire une piste audio'
                ;;
            english)
                printf '%s\n' \
                    'Comment=Download a video or extract an audio track'
                ;;
            bilingual)
                printf '%s\n' \
                    'Comment=Download a video or extract an audio track' \
                    'Comment[fr]=Télécharger une vidéo ou extraire une piste audio'
                ;;
            *) ;;
        esac
        printf '%s\n' \
            "Exec=${desktop_exec}" \
            "Icon=${LEGACY_PORTABLE_ICON}" \
            'Terminal=false' \
            'Categories=AudioVideo;' \
            'StartupNotify=true'
    )
}

safe_direct_desktop_exec() {
    local output_variable=$1
    local home=$2
    local exec_line=$3
    local direct_path=''

    [[ ${exec_line} == 'Exec="'*'"' ]] || return 1
    direct_path=${exec_line#'Exec="'}
    direct_path=${direct_path%'"'}

    # Historical direct launchers escaped several desktop metacharacters.
    # Conservatively migrate only a plain canonical absolute path that can be
    # validated without interpreting or unescaping user-controlled text.
    [[ -n ${direct_path} &&
        ${direct_path} != *\\* &&
        ${direct_path} != *'"'* &&
        ${direct_path} != *'`'* &&
        ${direct_path} != *'$'* &&
        ${direct_path} != *'%'* ]] || return 1
    safe_absolute_path "${direct_path}" || return 1
    [[ ${direct_path} == "${home}/"* &&
        ${direct_path} == */download-video-gui.sh ]] || return 1

    printf -v "${output_variable}" '"%s"' "${direct_path}"
}

legacy_portable_desktop_is_exact() {
    local home=$1
    local data_home=$2
    local desktop_path=$3
    local launcher_path="${data_home}/${APP_ID}/launch"
    local initial_identity=''
    local final_identity=''
    local stable_desktop_exec=''
    local direct_desktop_exec=''
    local matched=false
    local -a desktop_lines=()

    [[ -f ${desktop_path} && ! -L ${desktop_path} ]] || return 1
    path_has_symlink_parent_below_base "${home}" "${desktop_path}" && return 1
    metadata_file_is_bounded "${desktop_path}" || return 1

    initial_identity=$(stat -c '%d:%i:%u:%a' -- "${desktop_path}" 2>/dev/null) \
        || return 1
    [[ ${initial_identity} == *":${EUID}:644" ]] || return 1

    # Later generic-icon releases used one deterministic stable-link schema.
    # Earlier releases used one of three fixed comment schemas with a direct
    # GUI path. Every other field and the final newline remain exact.
    if [[ ${launcher_path} != *'%'* && ${launcher_path} != *'='* ]]; then
        serialize_stable_desktop_exec stable_desktop_exec "${launcher_path}"
        if legacy_desktop_matches_template \
            "${desktop_path}" "${stable_desktop_exec}" bilingual; then
            matched=true
        fi
    fi

    if [[ ${matched} == false ]]; then
        mapfile -t -n 13 desktop_lines <"${desktop_path}" || return 1
        case ${#desktop_lines[@]} in
            10)
                if safe_direct_desktop_exec \
                    direct_desktop_exec "${home}" "${desktop_lines[5]}" \
                    && { legacy_desktop_matches_template \
                        "${desktop_path}" "${direct_desktop_exec}" french \
                        || legacy_desktop_matches_template \
                            "${desktop_path}" "${direct_desktop_exec}" english; }; then
                    matched=true
                fi
                ;;
            11)
                if safe_direct_desktop_exec \
                    direct_desktop_exec "${home}" "${desktop_lines[6]}" \
                    && legacy_desktop_matches_template \
                        "${desktop_path}" "${direct_desktop_exec}" bilingual; then
                    matched=true
                fi
                ;;
            *) ;;
        esac
    fi

    [[ ${matched} == true ]] || return 1
    final_identity=$(stat -c '%d:%i:%u:%a' -- "${desktop_path}" 2>/dev/null) \
        || return 1
    [[ ${final_identity} == "${initial_identity}" ]]
}

migrate_legacy_portable_launcher() {
    local home=$1
    local data_home="${home}/.local/share"
    local desktop_path="${data_home}/applications/${APP_ID}.desktop"

    # Only the standard path is reconstructable from the account database.
    # A custom XDG_DATA_HOME remains untouched unless its owner removes the
    # portable launcher explicitly with install-gui.sh.
    legacy_portable_desktop_is_exact \
        "${home}" "${data_home}" "${desktop_path}" || return 0
    remove_exact_nondirectory "${home}" "${desktop_path}" || true
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

discover_cleanup_data_homes() {
    local home=$1
    local default_data=$2
    local -n discovered_data_homes=$3
    local marker="${default_data}/${APP_ID}/${MARKER_NAME}"
    local candidate=''
    local marker_parent_safe=true
    local -a marker_lines=()

    discovered_data_homes=("${default_data}")

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
                discovered_data_homes+=("${candidate}")
            else
                warn "custom runtime marker lacks a matching ownership sentinel; preserving: ${candidate}"
            fi
        fi
    fi
}

cleanup_registered_data_home() {
    local data_home=$1

    safe_xdg_base "${data_home}" || return 0
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
}

cleanup_standard_user_paths() {
    local home=$1
    local default_data=$2
    local config_home="${home}/.config"
    local state_home="${home}/.local/state"
    local cache_home="${home}/.cache"
    local marker="${default_data}/${APP_ID}/${MARKER_NAME}"

    remove_exact "${config_home}" "${config_home}/${LEGACY_GUI_ID}" || true
    remove_exact \
        "${config_home}" \
        "${config_home}/autostart/${LEGACY_GUI_ID}.desktop" || true
    remove_exact "${state_home}" "${state_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${cache_home}" "${cache_home}/${LEGACY_GUI_ID}" || true
    remove_exact "${default_data}" "${marker}" || true

    # Preserve a possible portable ZIP/Git launcher in the parent.
    rmdir_exact_if_empty "${default_data}" "${default_data}/${APP_ID}" || true
}

cleanup_one_home() {
    local home=$1
    local default_data="${home}/.local/share"
    local data_home=''
    local -a data_homes=()

    safe_home "${home}" || {
        warn "refusing invalid HOME: ${home}"
        return 64
    }

    if [[ ! -d ${home} ]]; then
        warn "HOME is unavailable or not mounted; skipping: ${home}"
        return 0
    fi

    discover_cleanup_data_homes "${home}" "${default_data}" data_homes

    for data_home in "${data_homes[@]}"; do
        cleanup_registered_data_home "${data_home}"
    done

    cleanup_standard_user_paths "${home}" "${default_data}"
    return 0
}

migrate_launcher_one_home() {
    local home=$1

    safe_home "${home}" || {
        warn "refusing invalid HOME: ${home}"
        return 64
    }

    if [[ ! -d ${home} ]]; then
        warn "HOME is unavailable or not mounted; skipping: ${home}"
        return 0
    fi
    if [[ -L ${home} ]]; then
        warn "refusing launcher migration through a symbolic-link HOME: ${home}"
        return 0
    fi

    migrate_legacy_portable_launcher "${home}"
    return 0
}

run_as_user() {
    local uid=$1
    local gid=$2
    local home=$3
    local helper_mode=${4:---user-home}
    local normalized_uid=''
    local normalized_gid=''

    case ${helper_mode} in
        --user-home | --user-home-migrate-launcher) ;;
        *) return 2 ;;
    esac

    if ! normalize_linux_id normalized_uid "${uid}" \
        || ! normalize_linux_id normalized_gid "${gid}"; then
        warn "refusing invalid numeric uid/gid: uid=${uid} gid=${gid}"
        return 0
    fi
    uid=${normalized_uid}
    gid=${normalized_gid}

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
            "${SELF}" "${helper_mode}" "${home}" || {
            warn "per-user operation failed or timed out for uid=0 home=${home}; continuing"
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
        "${SELF}" "${helper_mode}" "${home}" || {
        warn \
            "per-user operation failed or timed out for uid=${uid} home=${home}; continuing"
        return 0
    }

    return 0
}

enumerate_users() {
    local helper_mode=${1:---user-home}
    local line
    local getent_output=''
    local _name _passwd uid gid _gecos home _shell key
    local normalized_uid normalized_gid
    local passwd_source_usable=false
    local getent_source_usable=false
    local -a records=()
    local -A seen=()

    case ${helper_mode} in
        --user-home | --user-home-migrate-launcher) ;;
        *) return 2 ;;
    esac

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
        normalize_linux_id normalized_uid "${uid}" || continue
        normalize_linux_id normalized_gid "${gid}" || continue
        uid=${normalized_uid}
        gid=${normalized_gid}
        safe_home "${home:-}" || continue
        while [[ ${home} == */ && ${home} != / ]]; do
            home=${home%/}
        done

        key="${uid}:${home}"
        [[ -z ${seen["${key}"]+x} ]] || continue
        seen["${key}"]=1

        run_as_user "${uid}" "${gid}" "${home}" "${helper_mode}"
    done

    return 0
}

usage() {
    cat >&2 <<EOF
Usage:
  ${0##*/} --all-users
  ${0##*/} --all-users-migrate-launcher
  ${0##*/} --user-home ABSOLUTE_HOME
  ${0##*/} --user-home-migrate-launcher ABSOLUTE_HOME
  ${0##*/} --numeric-home UID GID ABSOLUTE_HOME
EOF
}

run_all_users_mode() {
    ((EUID == 0)) || {
        warn '--all-users must run as root'
        exit 77
    }
    (($# == 1)) || {
        usage
        exit 2
    }
    enumerate_users
}

run_all_users_migrate_launcher_mode() {
    ((EUID == 0)) || {
        warn '--all-users-migrate-launcher must run as root'
        exit 77
    }
    (($# == 1)) || {
        usage
        exit 2
    }
    enumerate_users --user-home-migrate-launcher
}

run_user_home_mode() {
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
}

run_user_home_migrate_launcher_mode() {
    (($# == 2)) || {
        usage
        exit 2
    }
    safe_home "$2" || {
        warn "refusing invalid HOME: $2"
        exit 64
    }
    if [[ -d $2 ]] && ! home_owned_by_effective_user "$2"; then
        warn "refusing --user-home-migrate-launcher for a HOME not owned by effective uid ${EUID}: $2"
        exit 77
    fi
    migrate_launcher_one_home "$2"
}

run_numeric_home_mode() {
    local normalized_uid=''
    local normalized_gid=''

    (($# == 4)) || {
        usage
        exit 2
    }
    ((EUID == 0)) || {
        warn '--numeric-home must run as root'
        exit 77
    }
    if ! normalize_linux_id normalized_uid "$2" \
        || ! normalize_linux_id normalized_gid "$3"; then
        usage
        exit 2
    fi
    safe_home "$4" || {
        warn "refusing invalid HOME: $4"
        exit 64
    }
    run_as_user "${normalized_uid}" "${normalized_gid}" "$4"
}

main() {
    initialize_cleanup_helper_path

    case ${1:-} in
        --all-users) run_all_users_mode "$@" ;;
        --all-users-migrate-launcher) run_all_users_migrate_launcher_mode "$@" ;;
        --user-home) run_user_home_mode "$@" ;;
        --user-home-migrate-launcher) run_user_home_migrate_launcher_mode "$@" ;;
        --numeric-home) run_numeric_home_mode "$@" ;;
        *)
            usage
            exit 2
            ;;
    esac

}

main "$@"

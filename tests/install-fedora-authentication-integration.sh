#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/install-fedora-authentication-integration.sh
# Purpose     : Verify fail-closed Fedora RPM authentication and root staging.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

TEST_ROOT=''

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${TEST_ROOT} ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
}

prepare_fixture() {
    local library_copy=$1
    local mock_bin=$2

    # install-fedora.sh is an executable, not a sourced library. Remove only
    # its final main invocation in the private test copy so the real functions
    # and constants can be exercised without a privileged transaction.
    sed '$d' "${PROJECT_DIR}/install-fedora.sh" >"${library_copy}"
    chmod 0600 -- "${library_copy}"

    mkdir -p -- "${mock_bin}"

    cat >"${mock_bin}/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ ${MOCK_CURL_FAIL:-0} != 1 ]] || exit 22
output=''
previous=''
for argument in "$@"; do
    if [[ ${previous} == --output ]]; then
        output=${argument}
        previous=''
        continue
    fi
    [[ ${argument} == --output ]] && previous=--output
done
[[ -n ${output} ]] || exit 64
printf '%s\n' fixture >"${output}"
EOF_CURL

    cat >"${mock_bin}/gpg" <<'EOF_GPG'
#!/usr/bin/env bash
set -euo pipefail
[[ ${MOCK_GPG_FAIL:-0} != 1 ]] || exit 2
if [[ ${MOCK_APPLICATION_STAGE:-0} == 1 ]]; then
    key_path=${*: -1}
    key_content=$(<"${key_path}")
    if [[ ${key_content} == verified-key ]]; then
        primary_fingerprint=7B54065FE061E78ED2C96252E3BE996196ABEA7F
        signing_fingerprint=1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    else
        primary_fingerprint=0000000000000000000000000000000000000000
        signing_fingerprint=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    fi
    printf '%s\n' \
        'pub:-:4096:1:0000000000000000:0:0:::::c:' \
        "fpr:::::::::${primary_fingerprint}:" \
        'sub:-:4096:1:1111111111111111:0:0:::::s:' \
        "fpr:::::::::${signing_fingerprint}:"
    exit 0
fi
if [[ ${MOCK_RPMFUSION_STAGE_MUTATION:-0} == 1 ]]; then
    key_path=${*: -1}
    key_content=$(<"${key_path}")
    printf 'rpmfusion-gpg-path=%s\nrpmfusion-gpg-content=%s\n' \
        "${key_path}" "${key_content}" >>"${MOCK_STAGE_LOG}"
    [[ ${key_content} == fixture ]] || exit 2
fi
validity=${MOCK_GPG_VALIDITY:--}
fingerprint=${MOCK_GPG_FINGERPRINT:-E9A491A3DE247814E7E067EAE06F8ECDD651FF2E}
printf 'pub:%s:4096:1:0000000000000000:0:0:::::scESC:\n' "${validity}"
printf 'fpr:::::::::%s:\n' "${fingerprint}"
EOF_GPG

    cat >"${mock_bin}/rpm" <<'EOF_RPM'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -q ]]; then
    if [[ ${MOCK_RPM_FUSION_INSTALLED:-0} == 1 ]]; then
        printf '%s\n' \
            "${MOCK_INSTALLED_RPM_FUSION_NEVRA:-rpmfusion-free-release-44-3.noarch}"
        exit 0
    fi
    exit 1
fi
if [[ ${1:-} == -qp ]]; then
    query_format=''
    previous=''
    for argument in "$@"; do
        if [[ ${previous} == --qf ]]; then
            query_format=${argument}
            previous=''
            continue
        fi
        [[ ${argument} == --qf ]] && previous=--qf
    done
    if [[ ${query_format} == *OPENPGP* ]]; then
        printf '%s\n' signed
        exit 0
    fi
    if [[ ${query_format} == *'%{NAME}'* &&
        ${query_format} == *'%{VERSION}'* &&
        ${query_format} == *'%{ARCH}'* &&
        ${query_format} != *'%{RELEASE}'* ]]; then
        rpm_path=${*: -1}
        [[ $(<"${rpm_path}") == verified-rpm ]] || exit 1
        printf '%s\n' yt-dlp-aria2-downloader-gui 2.3.7 noarch
        exit 0
    fi
    printf '%s\n' \
        "${MOCK_RPM_FUSION_NEVRA:-rpmfusion-free-release-44-3.noarch}"
    exit 0
fi
exit 64
EOF_RPM

    cat >"${mock_bin}/rpmkeys" <<'EOF_RPMKEYS'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' --checksig '* && ${MOCK_RPMKEYS_CHECK_FAIL:-0} == 1 ]]; then
    exit 1
fi
if [[ ${MOCK_APPLICATION_STAGE:-0} == 1 ]]; then
    operand=${*: -1}
    if [[ " $* " == *' --checksig '* ]]; then
        [[ $(<"${operand}") == verified-rpm ]] || exit 1
        printf 'isolated-check-path=%s\nisolated-check-content=%s\n' \
            "${operand}" "$(<"${operand}")" >>"${MOCK_STAGE_LOG}"
    elif [[ " $* " == *' --import '* && " $* " != *' --define '* ]]; then
        printf 'system-import-path=%s\nsystem-import-content=%s\n' \
            "${operand}" "$(<"${operand}")" >>"${MOCK_STAGE_LOG}"
    fi
fi
if [[ ${MOCK_RPMFUSION_STAGE_MUTATION:-0} == 1 ]]; then
    operand=${*: -1}
    if [[ " $* " == *' --checksig '* ]]; then
        [[ $(<"${operand}") == fixture ]] || exit 1
        printf 'rpmfusion-isolated-check-path=%s\nrpmfusion-isolated-check-content=%s\n' \
            "${operand}" "$(<"${operand}")" >>"${MOCK_STAGE_LOG}"
    elif [[ " $* " == *' --import '* && " $* " != *' --define '* ]]; then
        printf 'rpmfusion-system-import-path=%s\nrpmfusion-system-import-content=%s\n' \
            "${operand}" "$(<"${operand}")" >>"${MOCK_STAGE_LOG}"
    fi
fi
exit 0
EOF_RPMKEYS

    cat >"${mock_bin}/dnf" <<'EOF_DNF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_DNF_LOG:?}"
printf '%q ' "$@" >>"${MOCK_DNF_LOG}"
printf '\n' >>"${MOCK_DNF_LOG}"
if [[ ${MOCK_APPLICATION_STAGE:-0} == 1 && ${*: -1} == */application.rpm ]]; then
    application_rpm=${*: -1}
    printf 'dnf-application-path=%s\ndnf-application-content=%s\n' \
        "${application_rpm}" "$(<"${application_rpm}")" >>"${MOCK_STAGE_LOG}"
fi
if [[ ${MOCK_RPMFUSION_STAGE_MUTATION:-0} == 1 && ${*: -1} == */rpmfusion-release.rpm ]]; then
    rpmfusion_rpm=${*: -1}
    printf 'rpmfusion-dnf-path=%s\nrpmfusion-dnf-content=%s\n' \
        "${rpmfusion_rpm}" "$(<"${rpmfusion_rpm}")" >>"${MOCK_STAGE_LOG}"
fi
EOF_DNF

    cat >"${mock_bin}/install" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
source_path=${*: -2:1}
destination_path=${*: -1}
/usr/bin/install "$@"
if [[ ${MOCK_APPLICATION_STAGE:-0} == 1 ]]; then
    case ${source_path} in
        "${MOCK_ORIGINAL_RPM}")
            printf '%s\n' attacker-rpm >"${source_path}"
            ;;
        "${MOCK_ORIGINAL_KEY}")
            printf '%s\n' attacker-key >"${source_path}"
            ;;
    esac
    printf 'stage-copy-source=%s\nstage-copy-destination=%s\n' \
        "${source_path}" "${destination_path}" >>"${MOCK_STAGE_LOG}"
fi
if [[ ${MOCK_RPMFUSION_STAGE_MUTATION:-0} == 1 ]]; then
    case ${destination_path} in
        */rpmfusion-key.asc)
            printf '%s\n' attacker-rpmfusion-key >"${source_path}"
            ;;
        */rpmfusion-release.rpm)
            printf '%s\n' attacker-rpmfusion-rpm >"${source_path}"
            ;;
    esac
    printf 'rpmfusion-stage-copy-source=%s\nrpmfusion-stage-copy-destination=%s\n' \
        "${source_path}" "${destination_path}" >>"${MOCK_STAGE_LOG}"
fi
EOF_INSTALL

    cat >"${mock_bin}/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_ROOT_COMMAND_LOG:-} ]]; then
    printf '%q ' "$@" >>"${MOCK_ROOT_COMMAND_LOG}"
    printf '\n' >>"${MOCK_ROOT_COMMAND_LOG}"
fi
exec "$@"
EOF_SUDO

    cat >"${mock_bin}/mktemp" <<'EOF_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_ROOT_MKTEMP_LOG:-} ]]; then
    printf 'mktemp ' >>"${MOCK_ROOT_MKTEMP_LOG}"
    printf '%q ' "$@" >>"${MOCK_ROOT_MKTEMP_LOG}"
    printf '\n' >>"${MOCK_ROOT_MKTEMP_LOG}"
fi
exec /usr/bin/mktemp "$@"
EOF_MKTEMP

    chmod 0755 -- "${mock_bin}"/*
}

run_enable_rpm_fusion() {
    local library_copy=$1
    local mock_bin=$2
    shift 2

    # shellcheck disable=SC2016 # Positional parameters belong to bash -c.
    env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        MOCK_DNF_LOG="${TEST_ROOT}/dnf.log" \
        MOCK_ROOT_COMMAND_LOG="${TEST_ROOT}/root-commands.log" \
        MOCK_STAGE_LOG="${TEST_ROOT}/stage.log" \
        "$@" \
        bash -c 'source "$1"; enable_rpm_fusion "$2"' \
        bash "${library_copy}" 44
}

write_project_key_listing() {
    local path=$1
    local primary_validity=$2
    local primary_capabilities=$3
    local primary_fingerprint=$4
    local subkey_validity=$5
    local subkey_capabilities=$6
    local subkey_fingerprint=$7
    local extra_signing_subkey=${8:-false}

    {
        printf 'pub:%s:4096:1:0000000000000000:0:0:::::%s:\n' \
            "${primary_validity}" "${primary_capabilities}"
        printf 'fpr:::::::::%s:\n' "${primary_fingerprint}"
        printf 'sub:%s:4096:1:1111111111111111:0:0:::::%s:\n' \
            "${subkey_validity}" "${subkey_capabilities}"
        printf 'fpr:::::::::%s:\n' "${subkey_fingerprint}"
        if [[ ${extra_signing_subkey} == true ]]; then
            printf 'sub:-:4096:1:2222222222222222:0:0:::::s:\n'
            printf 'fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n'
        fi
    } >"${path}"
}

run_project_key_validation() {
    local library_copy=$1
    local listing=$2

    bash -c 'source "$1"; listing=$(<"$2"); validate_rpm_signing_certificate "$listing"' \
        bash "${library_copy}" "${listing}"
}

run_application_stage_mutation() {
    local library_copy=$1
    local mock_bin=$2
    local source_rpm=$3
    local source_key=$4

    env \
        PATH="${mock_bin}:/usr/bin:/bin" \
        MOCK_APPLICATION_STAGE=1 \
        MOCK_DNF_LOG="${TEST_ROOT}/dnf.log" \
        MOCK_ORIGINAL_RPM="${source_rpm}" \
        MOCK_ORIGINAL_KEY="${source_key}" \
        MOCK_ROOT_COMMAND_LOG="${TEST_ROOT}/root-commands.log" \
        MOCK_ROOT_MKTEMP_LOG="${TEST_ROOT}/root-mktemp.log" \
        MOCK_STAGE_LOG="${TEST_ROOT}/stage.log" \
        bash -s -- "${library_copy}" "${source_rpm}" "${source_key}" <<'EOF_APPLICATION_STAGE'
source "$1"
trap cleanup EXIT
prepare_application_rpm "$2" "$3" signed false
install_application_rpm "${STAGED_APPLICATION_RPM}" signed
release_application_stage
EOF_APPLICATION_STAGE
}

main() {
    local library_copy=''
    local mock_bin=''
    local project_key_listing=''
    local source_rpm=''
    local source_key=''
    local staged_rpm_path=''
    local staged_key_path=''
    local staged_rpmfusion_path=''

    for command_name in bash chmod mktemp rm sed; do
        require_test_command "${command_name}"
    done

    TEST_ROOT=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    library_copy="${TEST_ROOT}/install-fedora-library.sh"
    mock_bin="${TEST_ROOT}/bin"
    : >"${TEST_ROOT}/dnf.log"
    prepare_fixture "${library_copy}" "${mock_bin}"

    assert_status 0 'authenticated RPM Fusion bootstrap' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}"
    assert_file_contains "${TEST_ROOT}/dnf.log" \
        '--setopt=localpkg_gpgcheck=True' \
        'RPM Fusion local package verification remains enabled'
    : >"${TEST_ROOT}/stage.log"
    assert_status 0 'RPM Fusion root staging survives source replacement' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_RPMFUSION_STAGE_MUTATION=1
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'rpmfusion-system-import-content=fixture' \
        'RPM Fusion system import consumes the staged verified certificate'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'rpmfusion-gpg-content=fixture' \
        'RPM Fusion fingerprint inspection consumes the staged certificate'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'rpmfusion-isolated-check-content=fixture' \
        'RPM Fusion isolated verification consumes the staged package'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'rpmfusion-dnf-content=fixture' \
        'RPM Fusion DNF consumes the staged verified package'
    staged_rpmfusion_path=$(sed -n 's/^rpmfusion-dnf-path=//p' \
        "${TEST_ROOT}/stage.log")
    [[ ${staged_rpmfusion_path} == /tmp/yt-dlp-aria2-downloader-rpmfusion.*/rpmfusion-release.rpm ]] \
        || fail 'RPM Fusion DNF did not use root staging.'
    [[ ! -e ${staged_rpmfusion_path%/*} ]] \
        || fail 'root-owned RPM Fusion staging survived successful installation.'
    assert_status 0 'qualified installed RPM Fusion release is accepted' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_RPM_FUSION_INSTALLED=1
    assert_status 65 'unqualified installed RPM Fusion release is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_RPM_FUSION_INSTALLED=1 \
        MOCK_INSTALLED_RPM_FUSION_NEVRA=rpmfusion-free-release-44-99.noarch

    assert_status 65 'wrong RPM Fusion fingerprint is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_GPG_FINGERPRINT=0000000000000000000000000000000000000000
    assert_status 65 'revoked RPM Fusion certificate is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_GPG_VALIDITY=r
    assert_status 65 'wrong RPM Fusion NEVRA is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_RPM_FUSION_NEVRA=rpmfusion-free-release-44-99.noarch
    assert_status 65 'unsigned RPM Fusion package is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_RPMKEYS_CHECK_FAIL=1
    assert_status 69 'RPM Fusion network failure is bounded' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_CURL_FAIL=1
    assert_status 65 'unreadable RPM Fusion certificate is rejected' \
        run_enable_rpm_fusion "${library_copy}" "${mock_bin}" \
        MOCK_GPG_FAIL=1
    # shellcheck disable=SC2016 # Positional parameters belong to bash -c.
    assert_status 69 'unqualified Fedora release is rejected' \
        env PATH="${mock_bin}:/usr/bin:/bin" \
        MOCK_DNF_LOG="${TEST_ROOT}/dnf.log" \
        bash -c 'source "$1"; enable_rpm_fusion 45' \
        bash "${library_copy}"

    project_key_listing="${TEST_ROOT}/project-key.colons"
    write_project_key_listing "${project_key_listing}" - c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 0 'project RPM certificate policy accepts the pinned key' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"

    write_project_key_listing "${project_key_listing}" - c \
        0000000000000000000000000000000000000000 \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects a wrong primary' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" e c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects an expired primary' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" r c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects a revoked primary' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" - cs \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects primary signing' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" - c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        e s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects an expired signing subkey' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" - c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        r s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245
    assert_status 65 'project RPM certificate rejects a revoked signing subkey' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"
    write_project_key_listing "${project_key_listing}" - c \
        7B54065FE061E78ED2C96252E3BE996196ABEA7F \
        - s 1F5B769CE48A08AAC0A7D9DDECC9894B41830245 true
    assert_status 65 'project RPM certificate rejects an extra signing subkey' \
        run_project_key_validation "${library_copy}" "${project_key_listing}"

    source_rpm="${TEST_ROOT}/application.rpm"
    source_key="${TEST_ROOT}/project-signing-key.asc"
    printf '%s\n' verified-rpm >"${source_rpm}"
    printf '%s\n' verified-key >"${source_key}"
    : >"${TEST_ROOT}/root-commands.log"
    : >"${TEST_ROOT}/root-mktemp.log"
    : >"${TEST_ROOT}/stage.log"
    assert_status 0 'root staging remains bound to verified bytes after source mutation' \
        run_application_stage_mutation \
        "${library_copy}" "${mock_bin}" "${source_rpm}" "${source_key}"
    assert_file_contains "${source_rpm}" attacker-rpm \
        'source RPM was replaced after its root-owned copy'
    assert_file_contains "${source_key}" attacker-key \
        'source key was replaced after its root-owned copy'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'system-import-content=verified-key' \
        'system key import consumes the staged verified certificate'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'isolated-check-content=verified-rpm' \
        'isolated RPM verification consumes the staged verified package'
    assert_file_contains "${TEST_ROOT}/stage.log" \
        'dnf-application-content=verified-rpm' \
        'DNF consumes the staged verified package'
    assert_file_not_contains "${TEST_ROOT}/dnf.log" "${source_rpm}" \
        'DNF never reopens the mutable source RPM path'
    assert_file_not_contains "${TEST_ROOT}/root-commands.log" \
        "rpmkeys --import ${source_key}" \
        'system key import never reopens the mutable source key path'
    staged_key_path=$(sed -n 's/^system-import-path=//p' \
        "${TEST_ROOT}/stage.log")
    staged_rpm_path=$(sed -n 's/^dnf-application-path=//p' \
        "${TEST_ROOT}/stage.log")
    [[ ${staged_key_path} == /tmp/yt-dlp-aria2-downloader-application.*/signing-key.asc ]] \
        || fail 'system key import did not use root staging.'
    [[ ${staged_rpm_path} == /tmp/yt-dlp-aria2-downloader-application.*/application.rpm ]] \
        || fail 'DNF did not use root staging.'
    [[ ! -e ${staged_rpm_path%/*} ]] \
        || fail 'root-owned application staging survived successful installation.'
    assert_file_contains "${TEST_ROOT}/root-mktemp.log" \
        'mktemp -d --tmpdir=/tmp yt-dlp-aria2-downloader-application.XXXXXXXX' \
        'application staging directory is created through the privileged boundary'

    printf '%s\n' 'Fedora bootstrap authentication integration passed.'
}

main "$@"

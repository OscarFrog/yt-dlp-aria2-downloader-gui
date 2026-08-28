#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/install-fedora-authentication-integration.sh
# Purpose     : Verify fail-closed RPM Fusion bootstrap authentication.
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
exit 0
EOF_RPMKEYS

    cat >"${mock_bin}/dnf" <<'EOF_DNF'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_DNF_LOG:?}"
printf '%q ' "$@" >>"${MOCK_DNF_LOG}"
printf '\n' >>"${MOCK_DNF_LOG}"
EOF_DNF

    cat >"${mock_bin}/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF_SUDO

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

    bash -c 'source "$1"; validate_rpm_signing_certificate "$2"' \
        bash "${library_copy}" "${listing}"
}

main() {
    local library_copy=''
    local mock_bin=''
    local project_key_listing=''

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

    printf '%s\n' 'Fedora bootstrap authentication integration passed.'
}

main "$@"

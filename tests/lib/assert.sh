#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/assert.sh
# Purpose     : Provide shared assertion helpers for shell integration tests.
# ==============================================================================

# This file is sourced by the test scripts. It intentionally does not change
# the caller's shell options. Command substitutions remove trailing newlines;
# ASSERT_OUTPUT, ASSERT_STDOUT, and ASSERT_STDERR therefore represent textual
# output, not byte-exact output.
# Assertion helpers must be invoked as simple commands, not from a pipeline or
# command substitution where exit would terminate only a subshell.

# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_OUTPUT=''
# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_STDOUT=''
# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_STDERR=''

# Abort the current test with an assertion-failure message.
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Abort the current test for invalid harness usage or setup.
test_error() {
    printf 'TEST ERROR: %s\n' "$*" >&2
    exit 2
}

# Require one command name to resolve through PATH.
require_test_command() {
    (($# == 1)) || test_error "require_test_command requires 1 argument; got $#."
    local command_name=$1

    if ! command -v -- "${command_name}" >/dev/null 2>&1; then
        printf 'TEST ERROR: required command was not found: %s\n' \
            "${command_name}" >&2
        exit 127
    fi
}

# Require a path to be a readable regular file.
assert_readable_file() {
    (($# == 2)) || test_error "assert_readable_file requires 2 arguments; got $#."
    local file=$1
    local label=$2

    [[ -f ${file} ]] || fail "${label}: not a regular file: ${file}"
    [[ -r ${file} ]] || fail "${label}: file is not readable: ${file}"
}

# Require a symbolic link to resolve to the expected textual target.
assert_link_target() {
    (($# == 3)) || test_error "assert_link_target requires 3 arguments; got $#."
    local link_path=$1
    local expected_target=$2
    local label=$3
    local actual_target=''

    if ! actual_target=$(readlink -- "${link_path}"); then
        fail "${label}: unable to read link ${link_path}"
    fi
    [[ ${actual_target} == "${expected_target}" ]] \
        || fail "${label}: expected ${expected_target}, found ${actual_target}"
}

# Require a path to expose the expected numeric permission mode.
assert_path_mode() {
    (($# == 3)) || test_error "assert_path_mode requires 3 arguments; got $#."
    local path=$1
    local expected_mode=$2
    local label=$3
    local actual_mode=''

    if ! actual_mode=$(stat -c '%a' -- "${path}"); then
        fail "${label}: unable to read permissions for ${path}"
    fi
    [[ ${actual_mode} == "${expected_mode}" ]] \
        || fail "${label}: expected mode ${expected_mode}, found ${actual_mode}"
}

# Require a command name or explicit path to be invocable.
assert_invocable_command() {
    (($# == 2)) || test_error "assert_invocable_command requires 2 arguments; got $#."
    local command_name=$1
    local label=$2

    if [[ ${command_name} == */* ]]; then
        [[ -f ${command_name} && -x ${command_name} ]] \
            || test_error "${label}: command is absent or not executable: ${command_name}"
    elif ! command -v -- "${command_name}" >/dev/null 2>&1; then
        test_error "${label}: command cannot be resolved: ${command_name}"
    fi
}

# Normalize an expected exit status into 0..255 and assign it by name.
validate_expected_status() {
    (($# == 3)) || test_error "validate_expected_status requires 3 arguments; got $#."
    local raw=$1
    local label=$2
    local output_name=$3
    local normalized=''

    [[ ${raw} =~ ^[0-9]+$ ]] \
        || test_error "${label}: expected status is not an integer: ${raw}"
    [[ ${raw} =~ ^0*([0-9]{1,3})$ ]] \
        || test_error "${label}: expected status is outside 0-255: ${raw}"

    normalized=${BASH_REMATCH[1]}
    [[ -n ${normalized} ]] || normalized=0
    ((10#${normalized} <= 255)) \
        || test_error "${label}: expected status is outside 0-255: ${raw}"

    printf -v "${output_name}" '%d' "$((10#${normalized}))"
}

# Run a command, require its status, and expose combined output in ASSERT_OUTPUT.
assert_status() {
    (($# >= 3)) || test_error \
        'assert_status requires an expected status, a label, and a command.'
    local expected=$1
    local label=$2
    shift 2
    local actual=0
    local output=''

    validate_expected_status "${expected}" "${label}" expected
    assert_invocable_command "$1" "${label}"

    ASSERT_OUTPUT=''
    output=$("$@" 2>&1) || actual=$?

    if ((actual != expected)); then
        printf 'FAIL: %s\n' "${label}" >&2
        printf 'Expected status: %d\n' "${expected}" >&2
        printf 'Actual status:   %d\n' "${actual}" >&2
        printf 'Command:' >&2
        printf ' %q' "$@" >&2
        printf '\nOutput:\n%s\n' "${output}" >&2
        exit 1
    fi

    ASSERT_OUTPUT=${output}
}

# Run a command and expose validated stdout/stderr separately.
assert_status_split() {
    (($# >= 3)) || test_error \
        'assert_status_split requires an expected status, a label, and a command.'
    local expected=$1
    local label=$2
    shift 2
    local actual=0
    local temporary_dir
    local stdout_file
    local stderr_file

    validate_expected_status "${expected}" "${label}" expected
    assert_invocable_command "$1" "${label}"

    temporary_dir=$(mktemp -d) \
        || test_error "${label}: unable to create output-capture directory"
    stdout_file="${temporary_dir}/stdout"
    stderr_file="${temporary_dir}/stderr"

    ASSERT_STDOUT=''
    ASSERT_STDERR=''
    ("$@") >"${stdout_file}" 2>"${stderr_file}" || actual=$?
    ASSERT_STDOUT=$(<"${stdout_file}")
    ASSERT_STDERR=$(<"${stderr_file}")
    if ! rm -rf -- "${temporary_dir}"; then
        test_error "${label}: unable to remove output-capture directory: ${temporary_dir}"
    fi

    if ((actual != expected)); then
        printf 'FAIL: %s\n' "${label}" >&2
        printf 'Expected status: %d\n' "${expected}" >&2
        printf 'Actual status:   %d\n' "${actual}" >&2
        printf 'Command:' >&2
        printf ' %q' "$@" >&2
        printf '\nStdout:\n%s\nStderr:\n%s\n' \
            "${ASSERT_STDOUT}" "${ASSERT_STDERR}" >&2
        exit 1
    fi
}

# Require exact string equality.
assert_equals() {
    (($# == 3)) || test_error "assert_equals requires 3 arguments; got $#."
    local expected=$1
    local actual=$2
    local label=$3

    if [[ ${actual} != "${expected}" ]]; then
        printf 'FAIL: %s\nExpected: %s\nActual:   %s\n' \
            "${label}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

# Require a string to contain a non-empty literal fragment.
assert_text_contains() {
    (($# == 3)) || test_error "assert_text_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    [[ -n ${needle} ]] \
        || test_error "${label}: assert_text_contains requires a non-empty needle."

    if [[ ${text} != *"${needle}"* ]]; then
        printf 'FAIL: %s\nMissing text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

# Require a string not to contain a non-empty literal fragment.
assert_text_not_contains() {
    (($# == 3)) || test_error "assert_text_not_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    [[ -n ${needle} ]] \
        || test_error "${label}: assert_text_not_contains requires a non-empty needle."

    if [[ ${text} == *"${needle}"* ]]; then
        printf 'FAIL: %s\nUnexpected text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

# Require a readable file to contain a literal fragment.
assert_file_contains() {
    (($# == 3)) || test_error "assert_file_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3
    local status=0

    [[ -n ${needle} ]] \
        || test_error "${label}: assert_file_contains requires a non-empty needle."

    assert_readable_file "${file}" "${label}"
    grep -Fq -- "${needle}" "${file}" || status=$?
    case ${status} in
        0) ;;
        1)
            printf 'FAIL: %s\nMissing text: %s\nFile: %s\n' \
                "${label}" "${needle}" "${file}" >&2
            exit 1
            ;;
        *) test_error "${label}: grep failed with status ${status}: ${file}" ;;
    esac
}

# Require a readable file not to contain a literal fragment.
assert_file_not_contains() {
    (($# == 3)) || test_error "assert_file_not_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3
    local status=0

    [[ -n ${needle} ]] \
        || test_error "${label}: assert_file_not_contains requires a non-empty needle."

    assert_readable_file "${file}" "${label}"
    grep -Fq -- "${needle}" "${file}" || status=$?
    case ${status} in
        0)
            printf 'FAIL: %s\nUnexpected text: %s\nFile: %s\n' \
                "${label}" "${needle}" "${file}" >&2
            exit 1
            ;;
        1) ;;
        *) test_error "${label}: grep failed with status ${status}: ${file}" ;;
    esac
}

# Require a readable file to contain one exact complete line.
assert_file_has_line() {
    (($# == 3)) || test_error "assert_file_has_line requires 3 arguments; got $#."
    local file=$1
    local expected=$2
    local label=$3
    local status=0

    assert_readable_file "${file}" "${label}"
    grep -Fxq -- "${expected}" "${file}" || status=$?
    case ${status} in
        0) ;;
        1)
            printf 'FAIL: %s\nExpected complete line: %s\nFile: %s\n' \
                "${label}" "${expected}" "${file}" >&2
            exit 1
            ;;
        *) test_error "${label}: grep failed with status ${status}: ${file}" ;;
    esac
}

# Require a readable file not to contain one exact complete line.
assert_file_has_no_line() {
    (($# == 3)) || test_error "assert_file_has_no_line requires 3 arguments; got $#."
    local file=$1
    local unexpected=$2
    local label=$3
    local status=0

    assert_readable_file "${file}" "${label}"
    grep -Fxq -- "${unexpected}" "${file}" || status=$?
    case ${status} in
        0)
            printf 'FAIL: %s\nUnexpected complete line: %s\nFile: %s\n' \
                "${label}" "${unexpected}" "${file}" >&2
            exit 1
            ;;
        1) ;;
        *) test_error "${label}: grep failed with status ${status}: ${file}" ;;
    esac
}

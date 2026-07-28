#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This file is sourced by the test scripts. It intentionally does not change
# the caller's shell options. Command substitutions remove trailing newlines;
# ASSERT_OUTPUT therefore represents textual output, not byte-exact output.
# Assertion helpers must be invoked as simple commands, not from a pipeline or
# command substitution where exit would terminate only a subshell.

# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_OUTPUT=''
# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_STDOUT=''
# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_STDERR=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_error() {
    printf 'TEST ERROR: %s\n' "$*" >&2
    exit 2
}

require_test_command() {
    (($# == 1)) || test_error "require_test_command requires 1 argument; got $#."
    local command_name=$1

    if ! command -v -- "${command_name}" >/dev/null 2>&1; then
        printf 'TEST ERROR: required command was not found: %s\n' \
            "${command_name}" >&2
        exit 127
    fi
}

assert_readable_file() {
    (($# == 2)) || test_error "assert_readable_file requires 2 arguments; got $#."
    local file=$1
    local label=$2

    [[ -f ${file} ]] || fail "${label}: not a regular file: ${file}"
    [[ -r ${file} ]] || fail "${label}: file is not readable: ${file}"
}

assert_invocable_command() {
    (($# == 2)) || test_error "assert_invocable_command requires 2 arguments; got $#."
    local command_name=$1
    local label=$2

    if [[ ${command_name} == */* ]]; then
        [[ -f ${command_name} && -x ${command_name} ]] ||
            test_error "${label}: command is absent or not executable: ${command_name}"
    elif ! command -v -- "${command_name}" >/dev/null 2>&1; then
        test_error "${label}: command cannot be resolved: ${command_name}"
    fi
}

assert_status() {
    (($# >= 3)) || test_error \
        'assert_status requires an expected status, a label, and a command.'
    local expected=$1
    local label=$2
    shift 2
    local actual=0
    local output=''

    [[ ${expected} =~ ^[0-9]+$ ]] ||
        test_error "${label}: expected status is not an integer: ${expected}"
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

    [[ ${expected} =~ ^[0-9]+$ ]] ||
        test_error "${label}: expected status is not an integer: ${expected}"
    assert_invocable_command "$1" "${label}"

    temporary_dir=$(mktemp -d) ||
        test_error "${label}: unable to create output-capture directory"
    stdout_file="${temporary_dir}/stdout"
    stderr_file="${temporary_dir}/stderr"

    ASSERT_STDOUT=''
    ASSERT_STDERR=''
    "$@" >"${stdout_file}" 2>"${stderr_file}" || actual=$?
    ASSERT_STDOUT=$(<"${stdout_file}")
    ASSERT_STDERR=$(<"${stderr_file}")
    rm -rf -- "${temporary_dir}"

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

assert_text_contains() {
    (($# == 3)) || test_error "assert_text_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    if [[ ${text} != *"${needle}"* ]]; then
        printf 'FAIL: %s\nMissing text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

assert_text_not_contains() {
    (($# == 3)) || test_error "assert_text_not_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    if [[ ${text} == *"${needle}"* ]]; then
        printf 'FAIL: %s\nUnexpected text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

assert_file_contains() {
    (($# == 3)) || test_error "assert_file_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3
    local status=0

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

assert_file_not_contains() {
    (($# == 3)) || test_error "assert_file_not_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3
    local status=0

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

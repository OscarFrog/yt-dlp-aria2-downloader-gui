#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/aria2-auth-headers-integration.sh
# Purpose     : Qualify private aria2 HTTP header fidelity and confidentiality.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${PROJECT_DIR}/tests/lib/assert.sh"

readonly HELPER="${PROJECT_DIR}/private-aria2-plan.py"
RUNS=${ARIA2_AUTH_HEADER_RUNS:-3}

for command_name in aria2c bash cat chmod grep mkdir mktemp python3 rm sleep stat; do
    require_test_command "${command_name}"
done

case ${RUNS} in
    '' | *[!0-9]*)
        printf 'Error: ARIA2_AUTH_HEADER_RUNS must be a positive integer.\n' >&2
        exit 64
        ;;
    *)
        ;;
esac
[[ ${RUNS} =~ ^[0-9]{1,6}$ ]] || {
    printf 'Error: ARIA2_AUTH_HEADER_RUNS is unreasonably large: %s\n' "${RUNS}" >&2
    exit 64
}
RUNS=$((10#${RUNS}))
((RUNS > 0)) || {
    printf 'Error: ARIA2_AUTH_HEADER_RUNS must be greater than zero.\n' >&2
    exit 64
}
readonly RUNS

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
SERVER_PID=''
PORT=''
CASE_STATUS=0

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${SERVER_PID} ]]; then
        kill -TERM -- "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}

write_plan() {
    local case_name=$1
    local plan_file=$2
    local output_dir=$3
    local url=$4

    python3 - "${case_name}" "${plan_file}" "${output_dir}" "${url}" <<'PY_PLAN'
import json
import os
import sys
from pathlib import Path

case_name, plan_name, output_name, url = sys.argv[1:]
plan_file = Path(plan_name)
output_dir = Path(output_name)

AUTH = "Bearer qualification-auth-7a91"
COOKIE = "session=qualification-cookie-3d42"
REFERER = "https://origin.invalid/qualification"
REDIRECT = "qualification-redirect-9c15"

headers = {
    "no-auth": {},
    "referer": {"Referer": REFERER},
    "cookie": {"Cookie": COOKIE},
    "authorization": {"Authorization": AUTH},
    "multiheaders": {
        "Authorization": AUTH,
        "Cookie": COOKIE,
        "Referer": REFERER,
        "X-Qualification": "multi-header-proof",
    },
    "redirect": {"X-Redirect-Proof": REDIRECT},
}[case_name]

payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / f"{case_name}.bin"),
            "url": url,
            "protocol": "http",
            "http_headers": headers,
        }
    ]
}
plan_file.write_text(json.dumps(payload) + "\n", encoding="utf-8")
os.chmod(plan_file, 0o600)
PY_PLAN
}

run_case() {
    local case_name=$1
    local iteration=$2
    local helper=${3:-${HELPER}}
    local case_root="${TEST_ROOT}/${case_name}-${iteration}-${helper##*/}"
    local output_dir="${case_root}/output"
    local staging_dir="${output_dir}/.yt-dlp-aria2-test"
    local home_dir="${case_root}/home"
    local plan_file="${case_root}/plan.json"
    local input_file="${staging_dir}/aria2.input"
    local manifest_file="${staging_dir}/manifest.json"
    local aria_log="${case_root}/aria2.log"
    local target_path="/case/${case_name}"
    local secret=''
    local input_mode=''
    local staging_mode=''
    local -a aria_args=()

    if [[ ${case_name} == redirect ]]; then
        target_path='/redirect/start'
    fi

    mkdir -p -- "${staging_dir}" "${home_dir}"
    chmod 700 -- "${staging_dir}" "${home_dir}"

    write_plan \
        "${case_name}" \
        "${plan_file}" \
        "${output_dir}" \
        "http://127.0.0.1:${PORT}${target_path}"

    python3 "${helper}" build \
        --plan "${plan_file}" \
        --output-dir "${output_dir}" \
        --staging-dir "${staging_dir}" \
        --aria2-input "${input_file}" \
        --manifest "${manifest_file}" \
        >/dev/null

    input_mode=$(stat -c '%a' -- "${input_file}")
    staging_mode=$(stat -c '%a' -- "${staging_dir}")
    assert_equals '600' "${input_mode}" "${case_name} private aria2 input mode"
    assert_equals '700' "${staging_mode}" "${case_name} private staging mode"

    aria_args=(
        --input-file="${input_file}"
        --dir="${staging_dir}"
        --file-allocation=none
        --no-conf=true
        --allow-overwrite=false
        --auto-file-renaming=false
        --summary-interval=0
        --console-log-level=warn
        --max-tries=1
        --retry-wait=0
        --connect-timeout=5
        --timeout=5
    )

    # Harness invariant: aria_args contains only paths and transport controls.
    # Production argv confidentiality is covered by tests that invoke the real
    # download engine; this test focuses on private input-file fidelity.
    CASE_STATUS=0
    set +e
    HOME="${home_dir}" \
        HTTP_PROXY='' HTTPS_PROXY='' ALL_PROXY='' \
        http_proxy='' https_proxy='' all_proxy='' \
        NO_PROXY='127.0.0.1,localhost' no_proxy='127.0.0.1,localhost' \
        aria2c "${aria_args[@]}" >"${aria_log}" 2>&1
    CASE_STATUS=$?
    set -e

    if ((CASE_STATUS == 0)); then
        [[ -s ${staging_dir}/item-000.download ]] \
            || fail "${case_name}: aria2 succeeded without the expected payload"
    fi

    for secret in \
        'Bearer qualification-auth-7a91' \
        'session=qualification-cookie-3d42' \
        'https://origin.invalid/qualification' \
        'qualification-redirect-9c15'; do
        if grep -Fq -- "${secret}" "${aria_log}"; then
            fail "${case_name}: sensitive header value leaked into aria2 output"
        fi
    done
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    cat >"${TEST_ROOT}/server.py" <<'PY_SERVER'
import http.server
import pathlib
import socketserver
import sys
import urllib.parse

port_file = pathlib.Path(sys.argv[1])

AUTH = "Bearer qualification-auth-7a91"
COOKIE = "session=qualification-cookie-3d42"
REFERER = "https://origin.invalid/qualification"
REDIRECT = "qualification-redirect-9c15"
BODY = b"header-fidelity-ok\n"

EXPECTED = {
    "no-auth": {},
    "referer": {"Referer": REFERER},
    "cookie": {"Cookie": COOKIE},
    "authorization": {"Authorization": AUTH},
    "multiheaders": {
        "Authorization": AUTH,
        "Cookie": COOKIE,
        "Referer": REFERER,
        "X-Qualification": "multi-header-proof",
    },
    "redirect": {"X-Redirect-Proof": REDIRECT},
}

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *args):
        return

    def _send_body(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _check_case(self, case_name):
        expected = EXPECTED[case_name]
        for name, value in expected.items():
            if self.headers.get(name) != value:
                self._send_body(403)
                return

        if case_name == "no-auth":
            for name in ("Authorization", "Cookie", "Referer"):
                if self.headers.get(name) is not None:
                    self._send_body(403)
                    return

        self._send_body(200, BODY)

    def _dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/redirect/start":
            self.send_response(302)
            self.send_header("Location", "/case/redirect")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        if parsed.path.startswith("/case/"):
            case_name = parsed.path.removeprefix("/case/")
            if case_name not in EXPECTED:
                self._send_body(404)
                return
            self._check_case(case_name)
            return

        self._send_body(404)

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

with Server(("127.0.0.1", 0), Handler) as server:
    port_file.write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()
PY_SERVER

    python3 "${TEST_ROOT}/server.py" "${TEST_ROOT}/port" &
    SERVER_PID=$!
    for _ in {1..100}; do
        [[ -s ${TEST_ROOT}/port ]] && break
        sleep 0.05
    done
    [[ -s ${TEST_ROOT}/port ]] \
        || fail 'Header-fidelity HTTP server did not publish its port.'
    PORT=$(<"${TEST_ROOT}/port")
    readonly PORT

    for ((iteration = 1; iteration <= RUNS; iteration++)); do
        for case_name in \
            no-auth \
            referer \
            cookie \
            authorization \
            multiheaders \
            redirect; do
            printf 'Private aria2 header scenario: %s %d/%d\n' \
                "${case_name}" "${iteration}" "${RUNS}"
            run_case "${case_name}" "${iteration}"
            assert_equals '0' "${CASE_STATUS}" \
                "${case_name} exact header fidelity through real aria2"
        done
    done

    mutant="${TEST_ROOT}/private-aria2-plan-drop-authorization.py"
    python3 - "${HELPER}" "${mutant}" <<'PY_MUTANT'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
needle = "for header_name in sorted(headers):"
replacement = (
    'for header_name in sorted('
    'name for name in headers if name.lower() != "authorization"):'
)
if needle not in source:
    raise SystemExit("mutation anchor is absent")
Path(sys.argv[2]).write_text(
    source.replace(needle, replacement, 1),
    encoding="utf-8",
)
PY_MUTANT
    chmod 600 -- "${mutant}"

    printf '%s\n' 'Private aria2 header mutation: dropped Authorization'
    run_case authorization mutation "${mutant}"
    if ((CASE_STATUS == 0)); then
        fail 'Authorization-dropping helper mutation was not detected.'
    fi

    printf '%s\n' 'Private aria2 authentication/header integration tests passed.'
}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/aria2-auth-headers-integration.sh
# Purpose     : Qualify safe aria2 headers and cross-origin secret isolation.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${PROJECT_DIR}/tests/lib/assert.sh"

readonly HELPER="${PROJECT_DIR}/private-aria2-plan.py"
TEST_ROOT=''
SERVER_PID=''
ORIGIN_PORT=''

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${SERVER_PID} ]]; then
        kill -TERM -- "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    if [[ -n ${TEST_ROOT} ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
}

write_plan() {
    local plan_file=$1
    local output_dir=$2
    local url=$3
    local mode=$4

    python3 - "${plan_file}" "${output_dir}" "${url}" "${mode}" <<'PY_PLAN'
import json
import os
import sys
from pathlib import Path

plan_file = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
url = sys.argv[3]
mode = sys.argv[4]

AUTH = "Bearer qualification-auth-7a91"
COOKIE = "session=qualification-cookie-3d42"
REFERER = "https://origin.invalid/qualification"

headers = {
    "safe": {
        "User-Agent": "qualification-agent",
        "Accept": "application/octet-stream",
        "Accept-Language": "en",
        "Sec-Fetch-Mode": "navigate",
    },
    "authorization": {"Authorization": AUTH},
    "cookie": {"Cookie": COOKIE},
    "referer": {"Referer": REFERER},
    "custom": {"X-Qualification": "custom-secret-like-header"},
    "proxy-authorization": {"Proxy-Authorization": "Basic c2VjcmV0"},
    "cross-origin": {
        "Authorization": AUTH,
        "Cookie": COOKIE,
    },
}[mode]

payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / f"{mode}.bin"),
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

classify_plan() {
    local plan_file=$1
    python3 "${HELPER}" classify --plan "${plan_file}"
}

build_plan() {
    local helper=$1
    local plan_file=$2
    local output_dir=$3
    local staging_dir=$4

    python3 "${helper}" build \
        --plan "${plan_file}" \
        --output-dir "${output_dir}" \
        --staging-dir "${staging_dir}" \
        --aria2-input "${staging_dir}/aria2.input" \
        --manifest "${staging_dir}/manifest.json"
}

run_aria2() {
    local staging_dir=$1
    local log_file=$2

    HOME="${TEST_ROOT}/home" \
        HTTP_PROXY='' HTTPS_PROXY='' ALL_PROXY='' \
        http_proxy='' https_proxy='' all_proxy='' \
        NO_PROXY='127.0.0.1,localhost' no_proxy='127.0.0.1,localhost' \
        aria2c \
        --input-file="${staging_dir}/aria2.input" \
        --dir="${staging_dir}" \
        --file-allocation=none \
        --no-conf=true \
        --allow-overwrite=false \
        --auto-file-renaming=false \
        --summary-interval=0 \
        --console-log-level=warn \
        --max-tries=1 \
        --retry-wait=0 \
        --connect-timeout=5 \
        --timeout=5 >"${log_file}" 2>&1
}

main() {
    local plan_file
    local output_dir
    local staging_dir
    local classification
    local unsafe_mode
    local mutant
    local leak_file

    for command_name in aria2c chmod grep mkdir mktemp python3 rm sleep stat; do
        require_test_command "${command_name}"
    done

    TEST_ROOT=$(mktemp -d)
    leak_file="${TEST_ROOT}/cross-origin-leak.txt"
    trap cleanup EXIT
    trap 'return 129' HUP
    trap 'return 130' INT
    trap 'return 143' TERM
    mkdir -p -- "${TEST_ROOT}/home"

    cat >"${TEST_ROOT}/server.py" <<'PY_SERVER'
import http.server
import pathlib
import socketserver
import sys
import threading

ports_file = pathlib.Path(sys.argv[1])
leak_file = pathlib.Path(sys.argv[2])

AUTH = "Bearer qualification-auth-7a91"
COOKIE = "session=qualification-cookie-3d42"
BODY = b"header-policy-ok\n"


class QuietHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *args):
        return

    def send_body(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)


class SinkHandler(QuietHandler):
    def dispatch(self):
        auth = self.headers.get("Authorization")
        cookie = self.headers.get("Cookie")
        if auth is not None or cookie is not None:
            leak_file.write_text(
                f"Authorization={auth!r}\nCookie={cookie!r}\n",
                encoding="utf-8",
            )
        self.send_body(200, BODY)

    do_GET = dispatch
    do_HEAD = dispatch


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


sink = Server(("127.0.0.1", 0), SinkHandler)
sink_port = sink.server_address[1]


class OriginHandler(QuietHandler):
    def dispatch(self):
        if self.path == "/safe":
            expected = {
                "User-Agent": "qualification-agent",
                "Accept": "application/octet-stream",
                "Accept-Language": "en",
                "Sec-Fetch-Mode": "navigate",
            }
            if any(self.headers.get(k) != v for k, v in expected.items()):
                self.send_body(403)
                return
            self.send_body(200, BODY)
            return

        if self.path == "/redirect-safe":
            self.send_response(302)
            self.send_header("Location", "/safe")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if self.path == "/cross-origin":
            if (
                self.headers.get("Authorization") != AUTH
                or self.headers.get("Cookie") != COOKIE
            ):
                self.send_body(403)
                return
            self.send_response(302)
            self.send_header(
                "Location", f"http://127.0.0.1:{sink_port}/sink"
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_body(404)

    do_GET = dispatch
    do_HEAD = dispatch


origin = Server(("127.0.0.1", 0), OriginHandler)
ports_file.write_text(
    f"{origin.server_address[1]} {sink_port}\n",
    encoding="ascii",
)
threading.Thread(target=sink.serve_forever, daemon=True).start()
origin.serve_forever()
PY_SERVER

    python3 "${TEST_ROOT}/server.py" \
        "${TEST_ROOT}/ports" "${leak_file}" &
    SERVER_PID=$!
    for _ in {1..100}; do
        [[ -s ${TEST_ROOT}/ports ]] && break
        sleep 0.05
    done
    [[ -s ${TEST_ROOT}/ports ]] \
        || fail 'header-policy HTTP servers did not publish their ports'
    read -r ORIGIN_PORT _ <"${TEST_ROOT}/ports"
    readonly ORIGIN_PORT

    for path in safe redirect-safe; do
        output_dir="${TEST_ROOT}/${path}/output"
        staging_dir="${output_dir}/.yt-dlp-aria2-test"
        plan_file="${TEST_ROOT}/${path}/plan.json"
        mkdir -p -- "${staging_dir}"
        chmod 700 -- "${staging_dir}"
        write_plan "${plan_file}" "${output_dir}" \
            "http://127.0.0.1:${ORIGIN_PORT}/${path}" safe

        classification=$(classify_plan "${plan_file}")
        assert_text_contains "${classification}" 'transport=direct' \
            "${path} remains direct"
        assert_status 0 "${path} private aria2 plan build" \
            build_plan "${HELPER}" "${plan_file}" "${output_dir}" "${staging_dir}"
        assert_status 0 "${path} real aria2 transfer" \
            run_aria2 "${staging_dir}" "${TEST_ROOT}/${path}.aria2.log"
    done

    for unsafe_mode in \
        authorization cookie referer custom proxy-authorization; do
        output_dir="${TEST_ROOT}/${unsafe_mode}/output"
        staging_dir="${output_dir}/.yt-dlp-aria2-test"
        plan_file="${TEST_ROOT}/${unsafe_mode}/plan.json"
        mkdir -p -- "${staging_dir}"
        chmod 700 -- "${staging_dir}"
        write_plan "${plan_file}" "${output_dir}" \
            "http://127.0.0.1:${ORIGIN_PORT}/safe" "${unsafe_mode}"

        classification=$(classify_plan "${plan_file}")
        assert_text_contains "${classification}" 'transport=native' \
            "${unsafe_mode} forces native transport"
        assert_status 65 "${unsafe_mode} direct build is fail-closed" \
            build_plan "${HELPER}" "${plan_file}" "${output_dir}" "${staging_dir}"
        [[ ! -e ${staging_dir}/aria2.input ]] \
            || fail "${unsafe_mode}: unsafe aria2 input was created"
    done

    output_dir="${TEST_ROOT}/cross-origin/output"
    staging_dir="${output_dir}/.yt-dlp-aria2-test"
    plan_file="${TEST_ROOT}/cross-origin/plan.json"
    mkdir -p -- "${staging_dir}"
    chmod 700 -- "${staging_dir}"
    write_plan "${plan_file}" "${output_dir}" \
        "http://127.0.0.1:${ORIGIN_PORT}/cross-origin" cross-origin

    classification=$(classify_plan "${plan_file}")
    assert_text_contains "${classification}" 'transport=native' \
        'cross-origin secret plan forces native transport'
    assert_status 65 'cross-origin secret direct build is rejected' \
        build_plan "${HELPER}" "${plan_file}" "${output_dir}" "${staging_dir}"
    [[ ! -e ${leak_file} ]] \
        || fail 'cross-origin sink received a secret on the safe path'

    mutant="${TEST_ROOT}/private-aria2-plan-unsafe-mutant.py"
    python3 - "${HELPER}" "${mutant}" <<'PY_MUTANT'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
needle = "if not direct_headers_are_replay_safe(headers):"
if source.count(needle) != 2:
    raise SystemExit("expected two replay-safety guards")
source = source.replace(needle, "if False:", 2)
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY_MUTANT
    chmod 600 -- "${mutant}"

    assert_status 0 'unsafe mutant can build the vulnerable aria2 plan' \
        build_plan "${mutant}" "${plan_file}" "${output_dir}" "${staging_dir}"
    assert_status 0 'unsafe mutant demonstrates real aria2 cross-origin replay' \
        run_aria2 "${staging_dir}" "${TEST_ROOT}/cross-origin-mutant.log"
    assert_file_contains "${leak_file}" \
        'Bearer qualification-auth-7a91' \
        'cross-origin Authorization replay fixture'
    assert_file_contains "${leak_file}" \
        'session=qualification-cookie-3d42' \
        'cross-origin Cookie replay fixture'

    printf '%s\n' 'Private aria2 authentication/header integration tests passed.'
}

main "$@"

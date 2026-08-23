#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/aria2-real-behavior-integration.sh
# Purpose     : Exercise real aria2 direct-transfer, quiescence and resume behavior.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=${PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
readonly PROJECT_DIR
readonly BASIC_RUNS=${ARIA2_BEHAVIOR_BASIC_RUNS:-3}
readonly RESUME_RUNS=${ARIA2_BEHAVIOR_RESUME_RUNS:-10}
readonly QUIESCENCE_RUNS=${ARIA2_BEHAVIOR_QUIESCENCE_RUNS:-10}
readonly MIN_COMPLETED_RANGE_BYTES=262144

for command_name in aria2c awk bash ffmpeg ffprobe find grep mktemp python3 realpath sed sleep stat tail wc; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'Error: required command is absent: %s\n' "${command_name}" >&2
        exit 77
    }
done
command -v yt-dlp >/dev/null 2>&1 || {
    printf 'Error: required command is absent: yt-dlp\n' >&2
    exit 77
}

case ${BASIC_RUNS} in
    '' | *[!0-9]*)
        printf 'Error: ARIA2_BEHAVIOR_BASIC_RUNS must be a positive integer.\n' >&2
        exit 64
        ;;
    *) ;;
esac
case ${RESUME_RUNS} in
    '' | *[!0-9]*)
        printf 'Error: ARIA2_BEHAVIOR_RESUME_RUNS must be a positive integer.\n' >&2
        exit 64
        ;;
    *) ;;
esac
case ${QUIESCENCE_RUNS} in
    '' | *[!0-9]*)
        printf 'Error: ARIA2_BEHAVIOR_QUIESCENCE_RUNS must be a positive integer.\n' >&2
        exit 64
        ;;
    *) ;;
esac
((BASIC_RUNS > 0 && RESUME_RUNS > 0 && QUIESCENCE_RUNS > 0)) || {
    printf 'Error: aria2 behavior repetition counts must be greater than zero.\n' >&2
    exit 64
}

TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
SERVER_PID=''
REAL_ARIA2=$(command -v aria2c)
readonly REAL_ARIA2

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${SERVER_PID} ]]; then
        kill -TERM -- "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_ROOT}" || true
}

assert_av_media() {
    local media_path=$1
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=index -of csv=p=0 "${media_path}" \
        | grep -Eq '^[0-9]+$'
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=index -of csv=p=0 "${media_path}" \
        | grep -Eq '^[0-9]+$'
}

run_engine() {
    local scenario=$1
    local url=$2
    local scenario_dir="${TEST_ROOT}/output/${scenario}"
    local result_file="${TEST_ROOT}/${scenario}.result"
    local stdout_file="${TEST_ROOT}/${scenario}.stdout"

    RUN_FINAL_FILE=''
    RUN_STATUS=0
    rm -rf -- "${scenario_dir}"
    mkdir -p -- "${scenario_dir}"
    rm -f -- "${result_file}" "${stdout_file}"
    set +e
    bash "${PROJECT_DIR}/download-video.sh" \
        --mode video \
        --output-dir "${scenario_dir}" \
        --result-file "${result_file}" \
        "${url}" >"${stdout_file}" 2>&1
    RUN_STATUS=$?
    set -e
    if ((RUN_STATUS == 0)); then
        [[ -s ${result_file} ]] || {
            printf 'FAIL: %s succeeded without publishing a result-file.\n' "${scenario}" >&2
            return 65
        }
        IFS= read -r RUN_FINAL_FILE <"${result_file}" || return 65
        [[ -n ${RUN_FINAL_FILE} ]] || return 65
    fi
}

assert_aria2_used() {
    [[ -s ${ARIA2_INVOCATION_LOG} ]] || {
        printf 'FAIL: scenario did not cross the real aria2c boundary.\n' >&2
        return 65
    }
}

wait_for_completed_partial_range() {
    local start_line=$1
    local deadline=200
    local count=0
    while ((count < deadline)); do
        if awk -F'|' \
            -v first="${start_line}" \
            -v minimum="${MIN_COMPLETED_RANGE_BYTES}" \
            -v media_size="${MEDIA_SIZE}" \
            'NR >= first && $1 == "END" && $2 == "/range/media.mp4" &&
             $3 ~ /^bytes=/ && $4 == 206 && $5 >= minimum &&
             $5 < media_size && $6 == 1 { found=1 }
             END { exit !found }' "${SERVER_LOG}"; then
            return 0
        fi
        sleep 0.05
        ((count += 1))
    done
    return 1
}

server_is_active() {
    local activity=''

    if ! { IFS= read -r activity <"${SERVER_STATE}"; } 2>/dev/null; then
        return 1
    fi
    [[ ${activity} =~ ^[1-9][0-9]*$ ]]
}

wait_for_server_quiescence() {
    local activity=''
    local count=0

    while ((count < 200)); do
        activity=''
        if { IFS= read -r activity <"${SERVER_STATE}"; } 2>/dev/null \
            && [[ ${activity} =~ ^[0-9]+$ ]] \
            && ((activity == 0)); then
            return 0
        fi
        sleep 0.05
        ((count += 1))
    done
    return 1
}

run_engine_with_monitor() {
    local scenario=$1
    local url=$2
    local cancel_after_partial_range=${3:-false}
    local scenario_dir="${TEST_ROOT}/output/${scenario}"
    local result_file="${TEST_ROOT}/${scenario}.result"
    local log_file="${TEST_ROOT}/${scenario}.engine.log"
    local progress_file="${TEST_ROOT}/${scenario}.progress"
    local engine_pid
    local monitor_pid
    local engine_status=0
    local monitor_status=0
    local server_start_line
    local wait_status=0

    rm -rf -- "${scenario_dir}"
    mkdir -p -- "${scenario_dir}"
    rm -f -- "${result_file}" "${log_file}" "${progress_file}"
    : >"${log_file}"
    server_start_line=$(($(wc -l <"${SERVER_LOG}") + 1))

    bash "${PROJECT_DIR}/download-video.sh" \
        --mode video \
        --machine-progress \
        --output-dir "${scenario_dir}" \
        --result-file "${result_file}" \
        "${url}" >"${log_file}" 2>&1 &
    engine_pid=$!

    bash "${PROJECT_DIR}/progress-monitor.sh" \
        "${log_file}" "${engine_pid}" "${result_file}" video "${scenario_dir}" \
        >"${progress_file}" &
    monitor_pid=$!

    if [[ ${cancel_after_partial_range} == true ]]; then
        set +e
        wait_for_completed_partial_range "${server_start_line}"
        wait_status=$?
        set -e
        if ((wait_status != 0)); then
            printf 'FAIL: resume setup never completed an observable partial Range response.\n' >&2
            kill -TERM -- "${engine_pid}" 2>/dev/null || true
            wait "${engine_pid}" 2>/dev/null || true
            wait "${monitor_pid}" 2>/dev/null || true
            return 65
        fi
        [[ ! -e ${result_file} ]] || {
            printf 'FAIL: resume setup published a result-file before cancellation.\n' >&2
            kill -TERM -- "${engine_pid}" 2>/dev/null || true
            wait "${engine_pid}" 2>/dev/null || true
            wait "${monitor_pid}" 2>/dev/null || true
            return 65
        }
        kill -TERM -- "${engine_pid}"
    fi

    set +e
    wait "${engine_pid}"
    engine_status=$?
    wait "${monitor_pid}"
    monitor_status=$?
    set -e

    RUN_STATUS=${engine_status}
    if grep -Fqx '100' "${progress_file}" && [[ ! -s ${result_file} ]]; then
        printf 'FAIL: %s emitted global 100 without a published result-file.\n' "${scenario}" >&2
        return 65
    fi
    if ((monitor_status != 0)); then
        printf 'FAIL: progress monitor returned %d for %s.\n' \
            "${monitor_status}" "${scenario}" >&2
        return 65
    fi
    return 0
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mkdir -p -- \
        "${TEST_ROOT}/web" \
        "${TEST_ROOT}/output" \
        "${TEST_ROOT}/runtime" \
        "${TEST_ROOT}/shim"
    chmod 700 -- "${TEST_ROOT}/runtime"

    # A moderately sized deterministic A/V fixture keeps the resume window observable
    # without making the repeated test expensive.
    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'testsrc2=size=320x180:rate=24' \
        -f lavfi -i 'sine=frequency=700:sample_rate=48000' \
        -t 30 -shortest \
        -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
        -g 48 -keyint_min 48 -sc_threshold 0 \
        -c:a aac -b:a 128k -movflags +faststart \
        "${TEST_ROOT}/web/media.mp4"
    MEDIA_SIZE=$(stat -c '%s' -- "${TEST_ROOT}/web/media.mp4")
    readonly MEDIA_SIZE
    ((MEDIA_SIZE > 1048576)) || {
        printf 'FAIL: resume fixture is unexpectedly small: %d bytes.\n' "${MEDIA_SIZE}" >&2
        exit 65
    }

    SERVER_LOG="${TEST_ROOT}/server.log"
    readonly SERVER_LOG
    SERVER_STATE="${TEST_ROOT}/server.state"
    readonly SERVER_STATE
    : >"${SERVER_LOG}"

    cat >"${TEST_ROOT}/server.py" <<'PY_SERVER'
import http.server
import os
import pathlib
import re
import socketserver
import sys
import threading
import time
import urllib.parse

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])
log_file = pathlib.Path(sys.argv[3])
state_file = pathlib.Path(sys.argv[4])
media_path = root / "media.mp4"
media_size = media_path.stat().st_size
log_lock = threading.Lock()
activity_lock = threading.Lock()
active_requests = 0
range_re = re.compile(r"^bytes=(\d+)-(\d*)$")

def write_log(*fields):
    line = "|".join(str(field).replace("\n", " ") for field in fields) + "\n"
    with log_lock:
        with log_file.open("a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()

def set_activity(delta):
    global active_requests
    with activity_lock:
        next_value = active_requests + delta
        if next_value < 0:
            raise RuntimeError("active request counter became negative")
        active_requests = next_value
        temporary = pathlib.Path(f"{state_file}.tmp")
        temporary.write_text(f"{active_requests}\n", encoding="ascii")
        os.replace(temporary, state_file)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *args):
        return

    def _source_page(self, media_url):
        body = (
            "<!doctype html><html><head><title>aria2 behavior fixture</title>"
            f'<meta property="og:video" content="{media_url}">'
            "</head><body>"
            f'<video controls src="{media_url}"></video>'
            "</body></html>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _media_response(self, mode, parsed):
        range_header = self.headers.get("Range", "-")
        start = 0
        end = media_size - 1
        status = 200

        if mode == "error":
            write_log("REQ", parsed.path, range_header, "404")
            self.send_error(404, "deterministic test error")
            return

        if mode == "redirect":
            write_log("REQ", parsed.path, range_header, "302")
            location = "/range/media.mp4?redirected=1"
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        if mode == "range" and range_header != "-":
            match = range_re.match(range_header)
            if not match:
                write_log("REQ", parsed.path, range_header, "416")
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{media_size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start = int(match.group(1))
            if start >= media_size:
                write_log("REQ", parsed.path, range_header, "416")
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{media_size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if match.group(2):
                end = min(int(match.group(2)), media_size - 1)
            if end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{media_size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206

        # The no-range endpoint deliberately ignores a Range request and returns
        # the complete object with HTTP 200.
        if mode == "no-range":
            start = 0
            end = media_size - 1
            status = 200

        write_log("REQ", parsed.path, range_header, status)
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Cache-Control", "no-store")
        if mode == "range":
            self.send_header("Accept-Ranges", "bytes")
        else:
            self.send_header("Accept-Ranges", "none")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{media_size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if self.command == "HEAD":
            write_log("END", parsed.path, range_header, status, 0, 1)
            return

        sent = 0
        complete = 0
        throttle = parsed.query == "resume=1"
        try:
            with media_path.open("rb") as handle:
                handle.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = handle.read(min(32768, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent += len(chunk)
                    remaining -= len(chunk)
                    if throttle:
                        # Allow the first range to complete ahead of the other
                        # split connections so cancellation occurs after at
                        # least one persisted aria2 piece, not at an arbitrary
                        # wall-clock instant.
                        time.sleep(0.01 if start == 0 else 0.08)
            complete = int(sent == end - start + 1)
        except (BrokenPipeError, ConnectionResetError):
            complete = 0
        finally:
            write_log("END", parsed.path, range_header, status, sent, complete)

    def _dispatch(self):
        set_activity(+1)
        try:
            self._dispatch_inner()
        finally:
            set_activity(-1)

    def _dispatch_inner(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path.startswith("/source/") and parsed.path.endswith(".html"):
            name = pathlib.PurePosixPath(parsed.path).stem
            mapping = {
                "range": "/range/media.mp4",
                "no-range": "/no-range/media.mp4",
                "redirect": "/redirect/media.mp4",
                "error": "/error/media.mp4",
                "resume": "/range/media.mp4?resume=1",
            }
            media_url = mapping.get(name)
            if media_url is None:
                self.send_error(404)
                return
            self._source_page(media_url)
            return
        if parsed.path == "/range/media.mp4":
            self._media_response("range", parsed)
            return
        if parsed.path == "/no-range/media.mp4":
            self._media_response("no-range", parsed)
            return
        if parsed.path == "/redirect/media.mp4":
            self._media_response("redirect", parsed)
            return
        if parsed.path == "/error/media.mp4":
            self._media_response("error", parsed)
            return
        if parsed.path == "/control/silent-active":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            # Deliberately stay active without touching SERVER_LOG. The former
            # log-size heuristic would falsely declare quiescence in this gap.
            time.sleep(0.50)
            if self.command != "HEAD":
                try:
                    self.wfile.write(body)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
        self.send_error(404)

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

with Server(("127.0.0.1", 0), Handler) as server:
    set_activity(0)
    port_file.write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()
PY_SERVER

    python3 "${TEST_ROOT}/server.py" \
        "${TEST_ROOT}/web" "${TEST_ROOT}/port" "${SERVER_LOG}" "${SERVER_STATE}" &
    SERVER_PID=$!
    for _ in {1..100}; do
        [[ -s ${TEST_ROOT}/port && -s ${SERVER_STATE} ]] && break
        sleep 0.05
    done
    [[ -s ${TEST_ROOT}/port && -s ${SERVER_STATE} ]] || {
        printf 'FAIL: local HTTP server did not publish its port/activity state.\n' >&2
        exit 65
    }
    PORT=$(<"${TEST_ROOT}/port")
    readonly PORT

    ARIA2_INVOCATION_LOG="${TEST_ROOT}/aria2-invocations.log"
    readonly ARIA2_INVOCATION_LOG
    export ARIA2_INVOCATION_LOG REAL_ARIA2
    : >"${ARIA2_INVOCATION_LOG}"

    cat >"${TEST_ROOT}/shim/aria2c" <<'EOF_ARIA2_SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
--version | --help=#all)
    exec "${REAL_ARIA2:?}" "$@"
    ;;
esac
{
    printf 'aria2c'
    printf ' %q' "$@"
    printf '\n'
} >>"${ARIA2_INVOCATION_LOG:?}"
exec "${REAL_ARIA2:?}" "$@"
EOF_ARIA2_SHIM
    chmod 700 -- "${TEST_ROOT}/shim/aria2c"
    export PATH="${TEST_ROOT}/shim:${PATH}"
    export XDG_RUNTIME_DIR="${TEST_ROOT}/runtime"
    export YTDLP_ARIA2_SKIP_RUNTIME_UPDATE=1
    YTDLP_ARIA2_YTDLP_BIN=$(command -v yt-dlp)
    export YTDLP_ARIA2_YTDLP_BIN
    export YTDLP_DISABLE_REMOTE_EJS=1

    RUN_FINAL_FILE=''
    RUN_STATUS=0

    # Negative control for quiescence: keep a response active while SERVER_LOG
    # remains byte-for-byte unchanged. The historical log-size stability heuristic
    # would return after roughly 150 ms; explicit activity state must wait for the
    # response to finish.
    for ((iteration = 1; iteration <= QUIESCENCE_RUNS; iteration += 1)); do
        printf '=== server quiescence negative control %d/%d ===\n' \
            "${iteration}" "${QUIESCENCE_RUNS}"
        log_size_before=$(stat -c '%s' -- "${SERVER_LOG}")
        python3 - "${PORT}" <<'PY_QUIESCENCE_CLIENT' >/dev/null 2>&1 &
import sys
import urllib.request

with urllib.request.urlopen(
    f"http://127.0.0.1:{sys.argv[1]}/control/silent-active",
    timeout=5,
) as response:
    response.read()
PY_QUIESCENCE_CLIENT
        control_pid=$!

        activity_seen=false
        for _ in {1..200}; do
            set +e
            server_is_active
            activity_status=$?
            set -e
            if ((activity_status == 0)); then
                activity_seen=true
                break
            fi
            sleep 0.01
        done
        if [[ ${activity_seen} != true ]]; then
            printf 'FAIL: silent-active control never became observable.\n' >&2
            kill -TERM -- "${control_pid}" 2>/dev/null || true
            wait "${control_pid}" 2>/dev/null || true
            exit 65
        fi

        set +e
        wait_for_server_quiescence
        quiescence_status=$?
        set -e
        if ((quiescence_status != 0)); then
            printf 'FAIL: explicit quiescence control timed out.\n' >&2
            kill -TERM -- "${control_pid}" 2>/dev/null || true
            wait "${control_pid}" 2>/dev/null || true
            exit 65
        fi
        set +e
        server_is_active
        activity_status=$?
        set -e
        if ((activity_status == 0)); then
            printf 'FAIL: quiescence returned while the silent response was still active.\n' >&2
            kill -TERM -- "${control_pid}" 2>/dev/null || true
            wait "${control_pid}" 2>/dev/null || true
            exit 65
        fi

        control_status=0
        wait "${control_pid}" || control_status=$?
        if ((control_status != 0)); then
            printf 'FAIL: silent-active control client returned %d.\n' \
                "${control_status}" >&2
            exit 65
        fi
        log_size_after=$(stat -c '%s' -- "${SERVER_LOG}")
        if [[ ${log_size_after} != "${log_size_before}" ]]; then
            printf 'FAIL: silent-active control unexpectedly changed the server log.\n' >&2
            exit 65
        fi
    done

    # Scenario group: Range, no-Range, redirection, and error behavior repeat independently.
    for ((iteration = 1; iteration <= BASIC_RUNS; iteration += 1)); do
        printf '=== aria2 direct behavior iteration %d/%d ===\n' \
            "${iteration}" "${BASIC_RUNS}"

        : >"${ARIA2_INVOCATION_LOG}"
        start_line=$(($(wc -l <"${SERVER_LOG}") + 1))
        run_engine "range-${iteration}" \
            "http://127.0.0.1:${PORT}/source/range.html"
        ((RUN_STATUS == 0)) || {
            printf 'FAIL: Range scenario returned %d.\n' "${RUN_STATUS}" >&2
            exit 65
        }
        [[ -f ${RUN_FINAL_FILE} ]] || {
            printf 'FAIL: Range result is absent.\n' >&2
            exit 65
        }
        assert_av_media "${RUN_FINAL_FILE}"
        assert_aria2_used
        grep -Fq '/range/media.mp4' "${ARIA2_INVOCATION_LOG}" || {
            printf 'FAIL: Range URL did not reach real aria2c.\n' >&2
            exit 65
        }
        tail -n +"${start_line}" "${SERVER_LOG}" \
            | awk -F'|' '$1 == "REQ" && $2 == "/range/media.mp4" && $3 ~ /^bytes=/ { found=1 } END { exit !found }' || {
            printf 'FAIL: Range endpoint did not observe a Range request.\n' >&2
            exit 65
        }

        : >"${ARIA2_INVOCATION_LOG}"
        start_line=$(($(wc -l <"${SERVER_LOG}") + 1))
        run_engine "no-range-${iteration}" \
            "http://127.0.0.1:${PORT}/source/no-range.html"
        ((RUN_STATUS == 0)) || {
            printf 'FAIL: no-Range scenario returned %d.\n' "${RUN_STATUS}" >&2
            exit 65
        }
        [[ -f ${RUN_FINAL_FILE} ]] || {
            printf 'FAIL: no-Range result is absent.\n' >&2
            exit 65
        }
        assert_av_media "${RUN_FINAL_FILE}"
        assert_aria2_used
        grep -Fq '/no-range/media.mp4' "${ARIA2_INVOCATION_LOG}" || {
            printf 'FAIL: no-Range URL did not reach real aria2c.\n' >&2
            exit 65
        }
        tail -n +"${start_line}" "${SERVER_LOG}" \
            | awk -F'|' '$1 == "REQ" && $2 == "/no-range/media.mp4" && $4 == 200 { found=1 } END { exit !found }' || {
            printf 'FAIL: no-Range endpoint was not transferred successfully with HTTP 200.\n' >&2
            exit 65
        }

        : >"${ARIA2_INVOCATION_LOG}"
        start_line=$(($(wc -l <"${SERVER_LOG}") + 1))
        run_engine "redirect-${iteration}" \
            "http://127.0.0.1:${PORT}/source/redirect.html"
        ((RUN_STATUS == 0)) || {
            printf 'FAIL: redirect scenario returned %d.\n' "${RUN_STATUS}" >&2
            exit 65
        }
        [[ -f ${RUN_FINAL_FILE} ]] || {
            printf 'FAIL: redirect result is absent.\n' >&2
            exit 65
        }
        assert_av_media "${RUN_FINAL_FILE}"
        assert_aria2_used
        grep -Fq '/redirect/media.mp4' "${ARIA2_INVOCATION_LOG}" || {
            printf 'FAIL: redirect URL did not reach real aria2c.\n' >&2
            exit 65
        }
        tail -n +"${start_line}" "${SERVER_LOG}" \
            | awk -F'|' '
                $1 == "REQ" && $2 == "/redirect/media.mp4" && $4 == 302 { redirect=1 }
                $1 == "REQ" && $2 == "/range/media.mp4" { target=1 }
                END { exit !(redirect && target) }
            ' || {
            printf 'FAIL: controlled redirect was not followed to the Range endpoint.\n' >&2
            exit 65
        }

        : >"${ARIA2_INVOCATION_LOG}"
        start_line=$(($(wc -l <"${SERVER_LOG}") + 1))
        run_engine_with_monitor "error-${iteration}" \
            "http://127.0.0.1:${PORT}/source/error.html" false
        ((RUN_STATUS != 0)) || {
            printf 'FAIL: HTTP error scenario unexpectedly succeeded.\n' >&2
            exit 65
        }
        [[ ! -e ${TEST_ROOT}/error-${iteration}.result ]] || {
            printf 'FAIL: HTTP error scenario published a result-file.\n' >&2
            exit 65
        }
        assert_aria2_used
        grep -Fq '/error/media.mp4' "${ARIA2_INVOCATION_LOG}" || {
            printf 'FAIL: HTTP error URL did not reach real aria2c.\n' >&2
            exit 65
        }
        tail -n +"${start_line}" "${SERVER_LOG}" \
            | grep -Fq 'REQ|/error/media.mp4|' || {
            printf 'FAIL: deterministic HTTP error endpoint was never reached.\n' >&2
            exit 65
        }
    done

    # Scenario: resume only after a substantial partial 206 response, retain aria2's
    # partial state, then prove the second run fetches fewer media bytes than a full
    # redownload while still producing a valid file. Do not assume a split starts at
    # byte zero; aria2 is free to schedule ranges.
    for ((iteration = 1; iteration <= RESUME_RUNS; iteration += 1)); do
        printf '=== aria2 resume iteration %d/%d ===\n' \
            "${iteration}" "${RESUME_RUNS}"
        scenario="resume-${iteration}"
        scenario_dir="${TEST_ROOT}/output/${scenario}"
        result_file="${TEST_ROOT}/${scenario}.result"
        quiescence_status=0

        : >"${ARIA2_INVOCATION_LOG}"
        run_engine_with_monitor "${scenario}" \
            "http://127.0.0.1:${PORT}/source/resume.html" true
        ((RUN_STATUS != 0)) || {
            printf 'FAIL: canceled resume setup unexpectedly returned success.\n' >&2
            exit 65
        }
        [[ ! -e ${result_file} ]] || {
            printf 'FAIL: canceled resume setup published a result-file.\n' >&2
            exit 65
        }
        assert_aria2_used
        find "${scenario_dir}" -maxdepth 1 -type f \
            \( -name '*.part' -o -name '*.aria2' \) -print -quit \
            | grep -q . || {
            printf 'FAIL: cancellation did not retain an aria2/yt-dlp partial.\n' >&2
            exit 65
        }

        set +e
        wait_for_server_quiescence
        quiescence_status=$?
        set -e
        if ((quiescence_status != 0)); then
            printf 'FAIL: local server did not quiesce after cancellation.\n' >&2
            exit 65
        fi
        marker="MARK|resume|${iteration}"
        printf '%s\n' "${marker}" >>"${SERVER_LOG}"

        : >"${ARIA2_INVOCATION_LOG}"
        RUN_FINAL_FILE=''
        RUN_STATUS=0
        set +e
        bash "${PROJECT_DIR}/download-video.sh" \
            --mode video \
            --output-dir "${scenario_dir}" \
            --result-file "${result_file}" \
            "http://127.0.0.1:${PORT}/source/resume.html" \
            >"${TEST_ROOT}/${scenario}.resume.stdout" 2>&1
        RUN_STATUS=$?
        set -e
        ((RUN_STATUS == 0)) || {
            printf 'FAIL: resumed transfer returned %d.\n' "${RUN_STATUS}" >&2
            exit 65
        }
        [[ -s ${result_file} ]] || {
            printf 'FAIL: resumed transfer did not publish a result-file.\n' >&2
            exit 65
        }
        IFS= read -r RUN_FINAL_FILE <"${result_file}"
        [[ -f ${RUN_FINAL_FILE} ]] || {
            printf 'FAIL: resumed final media is absent.\n' >&2
            exit 65
        }
        assert_av_media "${RUN_FINAL_FILE}"
        assert_aria2_used

        set +e
        wait_for_server_quiescence
        quiescence_status=$?
        set -e
        if ((quiescence_status != 0)); then
            printf 'FAIL: local server did not quiesce before resume accounting.\n' >&2
            exit 65
        fi

        post_resume_bytes=$(
            awk -F'|' -v marker="${marker}" '
                $0 == marker { seen=1; next }
                seen && $1 == "END" && $2 == "/range/media.mp4" &&
                    ($4 == 200 || $4 == 206) {
                    total += $5
                }
                END { print total + 0 }
            ' "${SERVER_LOG}"
        )
        if ((post_resume_bytes <= 0 || post_resume_bytes >= MEDIA_SIZE)); then
            printf 'FAIL: resume proof served %d of %d total media bytes after restart; expected a strict partial remainder.\n' \
                "${post_resume_bytes}" "${MEDIA_SIZE}" >&2
            exit 65
        fi
        awk -F'|' -v marker="${marker}" '
            $0 == marker { seen=1; next }
            seen && $1 == "REQ" && $2 == "/range/media.mp4" && $3 ~ /^bytes=/ {
                found=1
            }
            END { exit !found }
        ' "${SERVER_LOG}" || {
            printf 'FAIL: resumed transfer did not expose a post-restart Range request.\n' >&2
            exit 65
        }
    done

    printf 'Real aria2 Range/no-Range/redirect/error/resume integration passed.\n'

}

main "$@"

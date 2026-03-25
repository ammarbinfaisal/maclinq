#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PATH="${ROOT_DIR}/scripts/fixtures/e2e.fixture"
MAC_BUILD_SCRATCH="${MAC_BUILD_SCRATCH:-/tmp/maclinq-mac-scratch-e2e}"
REMOTE_HOST="${MACLINQ_E2E_REMOTE_HOST:-}"
REMOTE_USER="${MACLINQ_E2E_REMOTE_USER:-ammar}"
REMOTE_PASS="${MACLINQ_E2E_REMOTE_PASS:-}"
REMOTE_PORT="${MACLINQ_E2E_PORT:-}"
LOCAL_HTTP_PORT="${MACLINQ_E2E_HTTP_PORT:-38471}"
REMOTE_BASE="/tmp/maclinq-e2e"
REMOTE_EVENTS="${REMOTE_BASE}/events.log"
REMOTE_STDOUT="${REMOTE_BASE}/receiver.stdout.log"
REMOTE_STDERR="${REMOTE_BASE}/receiver.stderr.log"
REMOTE_PID_FILE="${REMOTE_BASE}/receiver.pid"
LOCAL_BUNDLE_DIR=""
LOCAL_HTTP_PID=""

die() {
  printf 'maclinq-e2e: %s\n' "$*" >&2
  exit 1
}

run_ssh() {
  sshpass -p "${REMOTE_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

run_local() {
  printf 'maclinq-e2e: %s\n' "$*"
  "$@"
}

fetch_remote_file() {
  local remote_path="$1"
  local local_path="$2"
  sshpass -p "${REMOTE_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${REMOTE_USER}@${REMOTE_HOST}" \
    "printf '%s\n' '${REMOTE_PASS}' | sudo -S -p '' cat '${remote_path}'" >"${local_path}"
}

detect_local_ip() {
  local iface
  local ip

  iface="$(route -n get "${REMOTE_HOST}" 2>/dev/null | awk '/interface:/{print $2; exit}')"
  [[ -n "${iface}" ]] || die "could not determine the outbound interface for ${REMOTE_HOST}"

  ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
  [[ -n "${ip}" ]] || die "could not determine the local IP address for interface ${iface}"

  printf '%s\n' "${ip}"
}

start_local_http_server() {
  local directory="$1"
  local bind_ip="$2"

  python3 -m http.server "${LOCAL_HTTP_PORT}" --bind "${bind_ip}" --directory "${directory}" \
    >/tmp/maclinq-e2e-http.log 2>&1 &
  LOCAL_HTTP_PID="$!"
}

cleanup_remote() {
  if [[ -n "${LOCAL_HTTP_PID}" ]]; then
    kill "${LOCAL_HTTP_PID}" >/dev/null 2>&1 || true
    wait "${LOCAL_HTTP_PID}" 2>/dev/null || true
  fi
  if [[ -n "${LOCAL_BUNDLE_DIR}" ]]; then
    rm -rf "${LOCAL_BUNDLE_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REMOTE_HOST}" && -n "${REMOTE_PASS}" ]]; then
    run_ssh "if [[ -f '${REMOTE_PID_FILE}' ]]; then printf '%s\n' '${REMOTE_PASS}' | sudo -S -p '' kill \$(cat '${REMOTE_PID_FILE}') >/dev/null 2>&1 || true; fi; rm -rf '${REMOTE_BASE}'" >/dev/null 2>&1 || true
  fi
}

trap cleanup_remote EXIT

command -v sshpass >/dev/null 2>&1 || die "sshpass is required"
command -v swift >/dev/null 2>&1 || die "swift is required"
command -v grep >/dev/null 2>&1 || die "grep is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

[[ -n "${REMOTE_HOST}" ]] || die "set MACLINQ_E2E_REMOTE_HOST"
[[ -n "${REMOTE_PASS}" ]] || die "set MACLINQ_E2E_REMOTE_PASS"
[[ -n "${REMOTE_PORT}" ]] || die "set MACLINQ_E2E_PORT"
[[ -f "${FIXTURE_PATH}" ]] || die "fixture not found at ${FIXTURE_PATH}"

run_local mkdir -p "${MAC_BUILD_SCRATCH}"
run_local swift test --scratch-path "${MAC_BUILD_SCRATCH}" --package-path "${ROOT_DIR}/maclinq-mac"

LOCAL_BUNDLE_DIR="$(mktemp -d /tmp/maclinq-e2e-bundle.XXXXXX)"
LOCAL_IP="$(detect_local_ip)"
run_local env COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -C "${ROOT_DIR}" -cf "${LOCAL_BUNDLE_DIR}/maclinq-linux.tar" maclinq-linux
start_local_http_server "${LOCAL_BUNDLE_DIR}" "${LOCAL_IP}"

run_ssh "rm -rf '${REMOTE_BASE}' && mkdir -p '${REMOTE_BASE}' && curl -fsS 'http://${LOCAL_IP}:${LOCAL_HTTP_PORT}/maclinq-linux.tar' -o '${REMOTE_BASE}/maclinq-linux.tar' && tar -C '${REMOTE_BASE}' -xf '${REMOTE_BASE}/maclinq-linux.tar' && rm -f '${REMOTE_BASE}/maclinq-linux.tar'"

run_ssh "cd '${REMOTE_BASE}/maclinq-linux' && make clean && make test && make"

run_ssh "mkdir -p '${REMOTE_BASE}' && cd '${REMOTE_BASE}/maclinq-linux' && printf '%s\n' '${REMOTE_PASS}' | sudo -S -p '' ./maclinq-receiver --once --event-log '${REMOTE_EVENTS}' -p ${REMOTE_PORT} >'${REMOTE_STDOUT}' 2>'${REMOTE_STDERR}' & echo \$! >'${REMOTE_PID_FILE}'"

run_local swift run --scratch-path "${MAC_BUILD_SCRATCH}" --package-path "${ROOT_DIR}/maclinq-mac" maclinq-mac --fixture "${FIXTURE_PATH}" "${REMOTE_HOST}" "${REMOTE_PORT}"

run_ssh "for _ in \$(seq 1 20); do [[ -f '${REMOTE_EVENTS}' ]] && exit 0; sleep 1; done; exit 1" || die "remote event log was not produced"

EVENT_LOG_LOCAL="$(mktemp -t maclinq-e2e-events)"
STDOUT_LOG_LOCAL="$(mktemp -t maclinq-e2e-stdout)"
STDERR_LOG_LOCAL="$(mktemp -t maclinq-e2e-stderr)"

fetch_remote_file "${REMOTE_EVENTS}" "${EVENT_LOG_LOCAL}"
fetch_remote_file "${REMOTE_STDOUT}" "${STDOUT_LOG_LOCAL}"
fetch_remote_file "${REMOTE_STDERR}" "${STDERR_LOG_LOCAL}"

grep -q "SESSION connected" "${EVENT_LOG_LOCAL}" || die "missing session start in remote event log"
grep -q "KEY down code=46" "${EVENT_LOG_LOCAL}" || die "missing key-down event for KEY_C in remote event log"
grep -q "KEY up code=46" "${EVENT_LOG_LOCAL}" || die "missing key-up event for KEY_C in remote event log"
grep -q "MOUSE down button=left" "${EVENT_LOG_LOCAL}" || die "missing left-button down event in remote event log"
grep -q "MOUSE move dx=12 dy=-8" "${EVENT_LOG_LOCAL}" || die "missing mouse move event in remote event log"
grep -q "MOUSE up button=left" "${EVENT_LOG_LOCAL}" || die "missing left-button up event in remote event log"
grep -q "SCROLL dx=0 dy=-1" "${EVENT_LOG_LOCAL}" || die "missing scroll event in remote event log"
grep -q "CONTROL disconnect" "${EVENT_LOG_LOCAL}" || die "missing disconnect control packet in remote event log"
grep -q "handshake completed successfully" "${STDOUT_LOG_LOCAL}" || die "missing successful handshake in receiver stdout"

printf 'maclinq-e2e: success\n'

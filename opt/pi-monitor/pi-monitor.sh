#!/usr/bin/env bash

BASE_DIR="/opt/pi-monitor"
ENV_FILE="$BASE_DIR/pi-monitor.env"
STATE_FILE="$BASE_DIR/state.env"
STATE_LOCK_FILE="$BASE_DIR/state.lock"
FAIL_LOG="$BASE_DIR/failures.log"
RUN_LOCK_FILE="/var/lock/pi-monitor.lock"

mkdir -p "$BASE_DIR"
touch "$STATE_FILE" "$FAIL_LOG" "$STATE_LOCK_FILE"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${ALERT_EMAIL:?ALERT_EMAIL missing in env}"

RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-300}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
TCP_CONNECT_TIMEOUT="${TCP_CONNECT_TIMEOUT:-10}"

PROBE_DETAIL=""

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_event() {
  printf '%s %s\n' "$(ts)" "$1" >> "$FAIL_LOG"
}

send_mail() {
  local subject="$1" body="$2"
  if ! printf 'To: %s\nSubject: %s\n\n%b\n' "$ALERT_EMAIL" "$subject" "$body" | /usr/sbin/sendmail -t -oi; then
    log_event "MAIL_FAIL subject=\"$subject\""
  fi
}

state_get() {
  grep -m1 -E "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-
}

# Locks the read-modify-write so concurrent writes cannot overwrite each other.
state_set() {
  local key="$1" status="$2" since="$3"
  {
    flock 9
    grep -v -E "^(${key}_STATUS=|${key}_SINCE=)" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
    printf '%s_STATUS=%s\n%s_SINCE=%s\n' "$key" "$status" "$key" "$since" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  } 9>"$STATE_LOCK_FILE"
}

probe_tcp() {
  local target="$1" host="${1%:*}" port="${1##*:}"
  if timeout "$TCP_CONNECT_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1; then
    PROBE_DETAIL="TCP connect OK"
    return 0
  fi
  PROBE_DETAIL="TCP connect failed"
  return 1
}

probe_http() {
  local url="$1" code rc
  code="$(curl -sS -L -A "CodewordMonitor/1.0" -H "Accept: text/html,application/xhtml+xml" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    PROBE_DETAIL="curl_exit=$rc"
    return 1
  fi
  PROBE_DETAIL="HTTP $code"
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

probe() {
  case "$1" in
    tcp) probe_tcp "$2" ;;
    http) probe_http "$2" ;;
    *) PROBE_DETAIL="unknown_type=$1"; log_event "CONFIG_BAD unknown_type=$1 target=$2"; return 1 ;;
  esac
}

# Detached background job so this retry's delay doesn't block other runs.
retry_worker() {
  local mode="$1" key="$2" type="$3" target="$4" label="$5"

  sleep "$RETRY_DELAY_SECONDS"

  local status
  status="$(state_get "${key}_STATUS")"

  if probe "$type" "$target"; then
    if [[ "$status" == "DOWN" ]]; then
      send_mail "RECOVERY: $label" "$label is reachable again.\nMode: $mode\nTarget: $target\nResult: $PROBE_DETAIL"
      log_event "RECOVERY mode=$mode key=$key label=\"$label\" target=\"$target\" detail=\"$PROBE_DETAIL\""
    else
      # Blipped and self-resolved before the alert threshold; no email sent.
      log_event "RECOVERED_BEFORE_DOWN mode=$mode key=$key label=\"$label\" target=\"$target\" detail=\"$PROBE_DETAIL\""
    fi
    state_set "$key" "UP" ""
    return 0
  fi

  if [[ "$status" != "DOWN" ]]; then
    send_mail "DOWN: $label" "$label is still not responding after the ${RETRY_DELAY_SECONDS}s retry.\nMode: $mode\nTarget: $target\nResult: $PROBE_DETAIL"
    log_event "DOWN mode=$mode key=$key label=\"$label\" target=\"$target\" detail=\"$PROBE_DETAIL\""
    state_set "$key" "DOWN" "$(date +%s)"
  fi
}

handle_check() {
  local mode="$1" key="$2" type="$3" target="$4" label="$5"
  local status
  status="$(state_get "${key}_STATUS")"
  [[ -z "$status" ]] && status="UP"

  if probe "$type" "$target"; then
    if [[ "$status" == "DOWN" ]]; then
      send_mail "RECOVERY: $label" "$label is reachable again.\nMode: $mode\nTarget: $target\nResult: $PROBE_DETAIL"
      log_event "RECOVERY mode=$mode key=$key label=\"$label\" target=\"$target\" detail=\"$PROBE_DETAIL\""
      state_set "$key" "UP" ""
    fi
    return 0
  fi

  # Fresh failure: start a retry. Already PENDING/DOWN: nothing to do, it's already being tracked.
  if [[ "$status" == "UP" ]]; then
    log_event "FAIL1 mode=$mode key=$key label=\"$label\" target=\"$target\" detail=\"$PROBE_DETAIL\""
    state_set "$key" "PENDING" "$(date +%s)"
    retry_worker "$mode" "$key" "$type" "$target" "$label" &
    disown
  fi
}

run_monitor_group() {
  local mode="$1"
  local -n checks_ref="$2"
  local entry key type target label

  exec 200>"$RUN_LOCK_FILE"
  flock -n 200 || return 0

  for entry in "${checks_ref[@]}"; do
    [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r key type target label <<<"$entry"
    if [[ -z "$key" || -z "$type" || -z "$target" || -z "$label" ]]; then
      log_event "CONFIG_BAD mode=$mode entry=\"$entry\""
      continue
    fi
    handle_check "$mode" "$key" "$type" "$target" "$label"
  done

  flock -u 200
}

run_test_mode() {
  local scope="${1:-all}"
  local -a tests=()
  local entry key type target label result
  local pass=0 fail=0 total=0
  local body subject

  case "$scope" in
    critical) tests=("${CRITICAL_CHECKS[@]}") ;;
    hourly) tests=("${HOURLY_CHECKS[@]}") ;;
    *) tests=("${CRITICAL_CHECKS[@]}" "${HOURLY_CHECKS[@]}") ;;
  esac

  body="Pi monitor test report\nTime: $(ts)\nScope: $scope\n\n"

  for entry in "${tests[@]}"; do
    [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r key type target label <<<"$entry"
    total=$((total + 1))
    if [[ -z "$key" || -z "$type" || -z "$target" || -z "$label" ]]; then
      body+="CONFIG BAD: $entry\n"
      fail=$((fail + 1))
      continue
    fi
    if probe "$type" "$target"; then
      result="PASS"; pass=$((pass + 1))
    else
      result="FAIL"; fail=$((fail + 1))
    fi
    body+="$result - $label [$target] ($PROBE_DETAIL)\n"
  done

  body+="\nSummary: $pass passed, $fail failed, $total total.\n"
  subject="TEST RESULTS: $([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"

  send_mail "$subject" "$body"
  log_event "TEST scope=$scope pass=$pass fail=$fail total=$total"
  (( fail == 0 ))
}

usage() {
  echo "Usage: $0 critical|hourly" >&2
  echo "       $0 test [all|critical|hourly]" >&2
}

case "${1:-}" in
  critical) run_monitor_group "critical" CRITICAL_CHECKS ;;
  hourly) run_monitor_group "hourly" HOURLY_CHECKS ;;
  test) run_test_mode "${2:-all}" ;;
  *) usage; exit 1 ;;
esac

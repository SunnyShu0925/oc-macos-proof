#!/usr/bin/env bash
# Shipped-contrast probe for PR 183033 (launchd stop deadlines).
#
# Runs the real `openclaw daemon stop --force` against a real LaunchAgent that
# runs the real Gateway. A sibling process takes the Gateway TCP port the moment
# the job releases it, so the shipped port-release wait runs against a real busy
# port. A real forward wall-clock jump is injected into the shipped CLI process.
#
# Usage: probe-launchd-stop.sh <fixed|prefix> <openclaw-dir>
#   SKIP_BASELINE=1  -> skip the no-lock/no-jump plumbing case
set -uo pipefail

MODE="${1:?mode: fixed|prefix}"
OPENCLAW_DIR="${2:?openclaw dir}"
LABEL="ai.openclaw.gateway"
PORT="${PROBE_PORT:-19990}"
UIDNUM="$(id -u)"
DOMAIN="gui/$UIDNUM"
SERVICE_TARGET="$DOMAIN/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUN_DIR="$OPENCLAW_DIR/proof-run"
RESULTS="$RUN_DIR/$MODE-results.txt"
HOLDER_PID=""

mkdir -p "$RUN_DIR"
log() { echo "$*" | tee -a "$RESULTS"; }

cleanup_job() {
  if [ -n "$HOLDER_PID" ]; then
    kill "$HOLDER_PID" >/dev/null 2>&1 || true
    HOLDER_PID=""
  fi
  launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  pkill -f "openclaw.mjs gateway" >/dev/null 2>&1 || true
  pkill -f "hold-port.mjs" >/dev/null 2>&1 || true
}
trap cleanup_job EXIT

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(command -v node)</string>
    <string>$OPENCLAW_DIR/openclaw.mjs</string>
    <string>gateway</string>
    <string>--dev</string>
    <string>--allow-unconfigured</string>
    <string>--port</string>
    <string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$RUN_DIR/$MODE-agent-out.log</string>
  <key>StandardErrorPath</key><string>$RUN_DIR/$MODE-agent-err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>OPENCLAW_LOG_LEVEL</key><string>debug</string>
  </dict>
</dict>
</plist>
PLIST
}

start_agent() {
  cleanup_job
  sleep 1
  write_plist
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1 | tee -a "$RESULTS"
  local rc=${PIPESTATUS[0]}
  log "bootstrap exit=$rc"
  for _ in $(seq 1 240); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      log "gateway listening on 127.0.0.1:$PORT"
      return 0
    fi
    sleep 0.5
  done
  log "GATEWAY LISTEN TIMEOUT"
  tail -n 30 "$RUN_DIR/$MODE-agent-err.log" 2>/dev/null || true
  return 1
}

start_holder() {
  node "$OPENCLAW_DIR/proofs/183033/hold-port.mjs" "$PORT" 420000 >> "$RUN_DIR/$MODE-holder.log" 2>&1 &
  HOLDER_PID=$!
}

# run_stop <label> <jump-ms> <jump-at-ms>
run_stop() {
  local label="$1" jump_ms="$2" jump_at="$3"
  local started
  started=$(date +%s)
  PROOF_JUMP_MS="$jump_ms" PROOF_JUMP_AT_MS="$jump_at" \
    node --import "$OPENCLAW_DIR/proofs/183033/clock-inject.mjs" \
    "$OPENCLAW_DIR/openclaw.mjs" daemon stop --force 2>&1 | tee -a "$RESULTS"
  local rc=${PIPESTATUS[0]}
  local elapsed=$(( $(date +%s) - started ))
  log "CASE $label jump=${jump_ms}@${jump_at}ms => exit=$rc elapsed=${elapsed}s"
}

log "=== LAUNCHD STOP CONTRAST PROBE mode=$MODE ==="
log "node=$(node --version) platform=$(sw_vers -productVersion 2>/dev/null || uname -a)"
log "label=$LABEL port=$PORT"

if [ "${SKIP_BASELINE:-0}" != "1" ]; then
  if start_agent; then
    run_stop "baseline-no-port-holder" 0 0
  fi
fi

if start_agent; then
  start_holder
  sleep 1
  run_stop "caseA-port-held-no-jump" 0 0
fi

cleanup_job
if start_agent; then
  start_holder
  sleep 1
  run_stop "caseB-port-held-jump" "${PROOF_JUMP_MS:-400000}" "${PROOF_JUMP_AT_MS:-30000}"
fi

cleanup_job
log "=== PROBE DONE mode=$MODE ==="
exit 0

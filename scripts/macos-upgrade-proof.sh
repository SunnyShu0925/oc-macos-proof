#!/usr/bin/env bash
# Published-driver (npm 2026.10.9) -> reviewed-candidate managed upgrade proof on macOS.
# Real launchd LaunchAgent, real `openclaw gateway call update.run`, real handoff helper,
# real npm install of a candidate packed from the reviewed head by the canonical packager.
set -uo pipefail

DRIVER_VERSION="${DRIVER_VERSION:-2026.10.9}"
CANDIDATE="${CANDIDATE_VERSION:-2026.10.10}"
PORT_GATEWAY="${PORT_GATEWAY:-19031}"
PORT_REGISTRY="${PORT_REGISTRY:-48741}"
SUMMARY=/tmp/macos-proof-summary.txt
: >"$SUMMARY"

say() { echo; echo "=== $* ==="; }
note() { echo "$*" | tee -a "$SUMMARY"; }

launchd_label() {
  local uid plist
  uid="$(id -u)"
  for plist in "$HOME"/Library/LaunchAgents/ai.openclaw.gateway*.plist; do
    [ -f "$plist" ] || continue
    basename "$plist" .plist
    return 0
  done
  echo "ai.openclaw.gateway"
}

say "environment"
{
  sw_vers
  uname -a
  echo "uid=$(id -u) user=$(id -un)"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 && echo "gui_domain=available" || echo "gui_domain=unavailable"
  git -C "$GITHUB_WORKSPACE/openclaw" rev-parse HEAD
  git -C "$GITHUB_WORKSPACE/openclaw" log -1 --format='%H %s'
} 2>&1 | tee -a "$SUMMARY"

say "pack reviewed candidate $CANDIDATE (canonical packer, version pinned before build)"
TARBALL="$GITHUB_WORKSPACE/artifacts/pkg/openclaw-candidate.tgz"
if [ "${SKIP_PACK:-0}" = "1" ]; then
  note "candidate_tarball=$TARBALL reused_from_run=${REUSE_RUN_ID:-unknown}"
else
cd "$GITHUB_WORKSPACE/openclaw"
mkdir -p "$GITHUB_WORKSPACE/artifacts/pkg"
node scripts/package-openclaw-for-docker.mjs --skip-build --allow-unreleased-changelog \
  --output-dir "$GITHUB_WORKSPACE/artifacts/pkg" --output-name openclaw-head.tgz 2>&1 | tail -4
rm -rf /tmp/relabel && mkdir -p /tmp/relabel
tar -xzf "$GITHUB_WORKSPACE/artifacts/pkg/openclaw-head.tgz" -C /tmp/relabel
node -e '
const fs = require("node:fs");
const p = "/tmp/relabel/package/package.json";
const doc = JSON.parse(fs.readFileSync(p, "utf8"));
doc.version = process.env.CANDIDATE_VERSION;
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
'
TARBALL="$GITHUB_WORKSPACE/artifacts/pkg/openclaw-candidate.tgz"
tar -czf "$TARBALL" -C /tmp/relabel package
cp /tmp/relabel/package/package.json "$GITHUB_WORKSPACE/artifacts/pkg/manifest-candidate.json"
note "candidate_tarball=$TARBALL bytes=$(stat -f%z "$TARBALL") version=$CANDIDATE"
say "candidate carries this PR's monotonic budget"
grep -rho 'createMonotonicBudget(params.recoveryTimeoutMs)\|Date.now() < deadline' /tmp/relabel/package/dist 2>/dev/null |
  sort | uniq -c | tee -a "$SUMMARY"
fi

say "install published driver $DRIVER_VERSION"
npm install -g "openclaw@$DRIVER_VERSION" --no-audit --no-fund 2>&1 | tail -3
NPM_PREFIX="$(npm prefix -g)"
DRIVER_BIN="$NPM_PREFIX/bin/openclaw"
DRIVER_PKG="$NPM_PREFIX/lib/node_modules/openclaw"
export DRIVER_BIN DRIVER_PKG
note "driver_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"
note "driver_wallclock_budget_files=$(grep -rl 'deadline - Date.now()' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"
note "driver_monotonic_budget_files=$(grep -rl 'createMonotonicBudget' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"

say "start loopback registry serving the candidate"
rm -f /tmp/registry.log
PROOF_REGISTRY_PORT="$PORT_REGISTRY" \
PROOF_TARBALL="$TARBALL" \
PROOF_CANDIDATE_VERSION="$CANDIDATE" \
PROOF_BASE_VERSION="$DRIVER_VERSION" \
PROOF_CANDIDATE_MANIFEST="$GITHUB_WORKSPACE/artifacts/pkg/manifest-candidate.json" \
PROOF_REGISTRY_LOG=/tmp/registry.log \
  nohup node "$GITHUB_WORKSPACE/harness/registry-proxy.mjs" >/tmp/registry.stdout 2>&1 &
for _ in $(seq 1 30); do grep -q 'listening on' /tmp/registry.log 2>/dev/null && break; sleep 1; done
head -1 /tmp/registry.log
printf 'registry=http://127.0.0.1:%s/\n' "$PORT_REGISTRY" >"$HOME/.npmrc"

say "install and start the managed launchd Gateway service"
"$DRIVER_BIN" config set gateway.mode local
"$DRIVER_BIN" config set gateway.port "$PORT_GATEWAY"
"$DRIVER_BIN" gateway install --force --port "$PORT_GATEWAY" 2>&1 | tail -6
LABEL="$(launchd_label)"
TARGET="gui/$(id -u)/$LABEL"
note "launchd_target=$TARGET"
for _ in $(seq 1 90); do
  CODE=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT_GATEWAY/health" || true)
  [ "$CODE" = "200" ] && break
  sleep 2
done
PRE_PID="$(launchctl print "$TARGET" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
note "pre_health=$CODE pre_pid=$PRE_PID pre_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"

say "seed operator settings and data"
mkdir -p "$HOME/.openclaw/workspace" "$HOME/.openclaw/proof"
echo "MARKER-macos-186831" >"$HOME/.openclaw/proof-marker"
echo "workspace-macos-186831" >"$HOME/.openclaw/workspace/note.txt"
printf '{"keep":"me","record":42}\n' >"$HOME/.openclaw/proof/data.json"
CONFIG_SHA_BEFORE="$(shasum -a 256 "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
note "config_sha_before=$CONFIG_SHA_BEFORE"
say "state dir before update"
ls -la "$HOME/.openclaw" 2>/dev/null | tail -n +2 | awk '{print $5, $9}' | tee -a "$SUMMARY"

say "run the shipped update entry (published driver -> candidate) on launchd"
rm -rf /tmp/openclaw-update-run-handoff-* "${TMPDIR:-/tmp}/openclaw-update-run-handoff-"* 2>/dev/null
find "$HOME/.openclaw/tmp" -maxdepth 2 -name '*handoff*' -exec rm -rf {} + 2>/dev/null
START=$(date +%s)
set +e
npm_config_registry="http://127.0.0.1:$PORT_REGISTRY/" \
OPENCLAW_UPDATE_PACKAGE_SPEC=openclaw \
  "$DRIVER_BIN" gateway call update.run --params '{"timeoutMs":900000}' --timeout 900000 --json \
    >/tmp/update.json 2>/tmp/update.err
UPDATE_RPC_EXIT=$?
set -e
note "rpc_exit=$UPDATE_RPC_EXIT rpc_duration_s=$(( $(date +%s) - START ))"
tail -20 /tmp/update.err
node -e '
const fs = require("node:fs");
let body;
try { body = JSON.parse(fs.readFileSync("/tmp/update.json", "utf8")); } catch (e) { console.log("update_json_unparseable=" + e.message); process.exit(0); }
console.log("handoff=" + JSON.stringify(body.handoff));
const res = body.result || {};
console.log("result_status=" + res.status + " reason=" + (res.reason ?? ""));
for (const step of res.steps || []) console.log("  step: " + (step.name ?? step.step) + " dur=" + step.durationMs + " exit=" + step.exitCode);
' | tee -a "$SUMMARY"

say "settle the managed handoff"
SETTLE_START=$(date +%s)
for i in $(seq 1 260); do
  HELPERS="$(pgrep -f 'update-managed-service-handoff|openclaw update' 2>/dev/null | tr '\n' ' ' || true)"
  AFTER_CODE=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT_GATEWAY/health" || true)
  AFTER_VERSION="$("$DRIVER_BIN" --version 2>&1 | tail -1)"
  if [ -z "$HELPERS" ] && [ "$AFTER_CODE" = "200" ] && echo "$AFTER_VERSION" | grep -q "$CANDIDATE"; then break; fi
  if [ $((i % 20)) -eq 0 ]; then
    note "settle_wait round=$i elapsed_s=$(( $(date +%s) - SETTLE_START )) version='$AFTER_VERSION' health=$AFTER_CODE helpers='$HELPERS'"
  fi
  sleep 5
done
note "settle_elapsed_s=$(( $(date +%s) - SETTLE_START ))"
AFTER_PID="$(launchctl print "$TARGET" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
note "after_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"
note "after_health=$AFTER_CODE after_pid=$AFTER_PID pre_pid=$PRE_PID"
note "after_marker=$(cat "$HOME/.openclaw/proof-marker" 2>/dev/null)"
note "after_workspace=$(cat "$HOME/.openclaw/workspace/note.txt" 2>/dev/null)"
note "after_data=$(cat "$HOME/.openclaw/proof/data.json" 2>/dev/null | tr -d '\n')"
CONFIG_SHA_AFTER="$(shasum -a 256 "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
note "config_sha_after=$CONFIG_SHA_AFTER"
say "state dir after update"
ls -la "$HOME/.openclaw" 2>/dev/null | tail -n +2 | awk '{print $5, $9}' | tee -a "$SUMMARY"
note "installed_monotonic_budget_files=$(grep -rl 'createMonotonicBudget' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"
note "installed_wallclock_budget_files=$(grep -rl 'deadline - Date.now()' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"

say "production handoff trace"
HANDOFF_ROOTS=("$HOME/.openclaw/tmp" "${TMPDIR:-/tmp}" /tmp "$HOME/.openclaw")
for root in "${HANDOFF_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r log; do
    d="$(dirname "$log")"
    echo "## $log"
    ls -la "$d" | tail -n +2 | awk '{print $5, $9}'
    tail -60 "$log" 2>/dev/null
    cp -a "$d" "$GITHUB_WORKSPACE/handoff-dir-$(basename "$d")" 2>/dev/null
  done < <(find "$root" -maxdepth 3 -name 'handoff.log' 2>/dev/null | head -6)
done
say "update reports"
ls -la "$HOME/.openclaw/update-reports" 2>/dev/null | tail -n +2 | awk '{print $5, $9}'
for f in "$HOME"/.openclaw/update-reports/*; do
  [ -f "$f" ] || continue
  echo "## $f"
  tail -40 "$f"
done
say "gateway service log tail"
for f in "$HOME"/.openclaw/logs/*; do
  [ -f "$f" ] || continue
  echo "## $f"
  tail -30 "$f"
done
echo "=== registry requests ==="
wc -l /tmp/registry.log 2>/dev/null
tail -10 /tmp/registry.log 2>/dev/null

say "verdict"
VERSION_OK=no
"$DRIVER_BIN" --version 2>&1 | tail -1 | grep -q "$CANDIDATE" && VERSION_OK=yes
DATA_OK=no
[ "$(cat "$HOME/.openclaw/proof-marker" 2>/dev/null)" = "MARKER-macos-186831" ] &&
  [ "$(cat "$HOME/.openclaw/workspace/note.txt" 2>/dev/null)" = "workspace-macos-186831" ] &&
  [ "$(cat "$HOME/.openclaw/proof/data.json" 2>/dev/null | tr -d '\n')" = '{"keep":"me","record":42}' ] && DATA_OK=yes
[ "$CONFIG_SHA_AFTER" = "$CONFIG_SHA_BEFORE" ] && CONFIG_OK=yes || CONFIG_OK=no
VERDICT=FAIL
if [ "$UPDATE_RPC_EXIT" -eq 0 ] && [ "$VERSION_OK" = yes ] && [ "$DATA_OK" = yes ] &&
   [ "$CONFIG_OK" = yes ] && [ "$AFTER_CODE" = "200" ] && [ -n "$AFTER_PID" ]; then VERDICT=PASS; fi
note "VERDICT=$VERDICT rpcExit=$UPDATE_RPC_EXIT versionAdvanced=$VERSION_OK dataIntact=$DATA_OK configIntact=$CONFIG_OK health=$AFTER_CODE"
[ "$VERDICT" = PASS ] || exit 1

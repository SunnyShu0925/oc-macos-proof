#!/usr/bin/env bash
# Published-driver (npm 2026.10.9) -> reviewed-candidate managed upgrade proof on macOS.
# Real launchd LaunchAgent, real `openclaw gateway call update.run`, real handoff helper,
# real npm install of a candidate packed from the reviewed head by the canonical packager.
set -uo pipefail

DRIVER_VERSION="${DRIVER_VERSION:-2026.10.9}"
CANDIDATE="${CANDIDATE_VERSION:-2026.10.10}"
# packed = serve the reviewed head build from a loopback registry
# npm      = upgrade to the published successor release from registry.npmjs.org
CANDIDATE_SOURCE="${CANDIDATE_SOURCE:-packed}"
TARGET_SPEC="${TARGET_SPEC:-openclaw@beta}"
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

if [ "$CANDIDATE_SOURCE" = "packed" ]; then
say "pack reviewed candidate $CANDIDATE (canonical packer, version pinned before build)"
PKG_DIR="$GITHUB_WORKSPACE/artifacts/pkg"
TARBALL="$PKG_DIR/openclaw-candidate.tgz"
MANIFEST="$PKG_DIR/manifest-candidate.json"
if [ "${SKIP_PACK:-0}" = "1" ]; then
  # download-artifact may nest the tree depending on how it was uploaded
  if [ ! -f "$TARBALL" ]; then
    found="$(find "$GITHUB_WORKSPACE/artifacts" -type f \( -name 'openclaw-candidate.tgz' -o -name 'openclaw-candidate-*.tgz' \) 2>/dev/null | head -1)"
    [ -n "$found" ] && TARBALL="$found"
  fi
  if [ ! -f "$MANIFEST" ]; then
    found="$(find "$GITHUB_WORKSPACE/artifacts" -type f -name 'manifest-candidate.json' 2>/dev/null | head -1)"
    [ -n "$found" ] && MANIFEST="$found"
  fi
  note "candidate_tarball=$TARBALL bytes=$(stat -f%z "$TARBALL" 2>/dev/null) manifest=$MANIFEST reused_from_run=${REUSE_RUN_ID:-unknown}"
  rm -rf /tmp/relabel && mkdir -p /tmp/relabel
  tar -xzf "$TARBALL" -C /tmp/relabel
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
TARBALL="$PKG_DIR/openclaw-candidate.tgz"
note "candidate_tarball=$TARBALL bytes=$(stat -f%z "$TARBALL") version=$CANDIDATE"
fi

say "rewrite the candidate manifest the way a published release ships it"
# A packed head tree still carries "workspace:*" specs, which npm cannot resolve
# from the registry; published manifests carry the sibling version instead.
CANDIDATE_VERSION="$CANDIDATE" SIBLING_VERSION="$DRIVER_VERSION" node -e '
const fs = require("node:fs");
const p = "/tmp/relabel/package/package.json";
const doc = JSON.parse(fs.readFileSync(p, "utf8"));
doc.version = process.env.CANDIDATE_VERSION;
const rewritten = [];
for (const field of ["dependencies", "optionalDependencies", "peerDependencies"]) {
  const map = doc[field];
  if (!map) continue;
  for (const [name, spec] of Object.entries(map)) {
    if (String(spec).startsWith("workspace:")) {
      map[name] = process.env.SIBLING_VERSION;
      rewritten.push(`${name}@${process.env.SIBLING_VERSION}`);
    }
  }
}
fs.writeFileSync(p, JSON.stringify(doc, null, 2));
console.log("manifest_workspace_specs_rewritten=" + (rewritten.join(",") || "none"));
console.log("candidate_manifest_version=" + doc.version + " typebox=" + (doc.dependencies || {}).typebox);
' | tee -a "$SUMMARY"
STAGED_TARBALL="/tmp/openclaw-candidate-$CANDIDATE.tgz"
tar -czf "$STAGED_TARBALL" -C /tmp/relabel package
cp /tmp/relabel/package/package.json "$MANIFEST"
TARBALL="$STAGED_TARBALL"
note "served_candidate_tarball=$TARBALL bytes=$(stat -f%z "$TARBALL") manifest=$MANIFEST"
note "candidate_package_version=$(node -e 'console.log(require("/tmp/relabel/package/package.json").version)' 2>&1 | tail -1)"
say "candidate carries this PR's monotonic budget"
grep -rho 'createMonotonicBudget(params.recoveryTimeoutMs)\|Date.now() < deadline' /tmp/relabel/package/dist 2>/dev/null |
  sort | uniq -c | tee -a "$SUMMARY"
NPM_REGISTRY_URL="http://127.0.0.1:$PORT_REGISTRY/"
TARGET_SPEC=openclaw
else
say "resolve the published successor release as the upgrade target"
CANDIDATE="$(npm view "$TARGET_SPEC" version 2>/dev/null | tail -1)"
[ -n "$CANDIDATE" ] || { echo "candidate_resolution_failed spec=$TARGET_SPEC"; exit 1; }
note "target_spec=$TARGET_SPEC resolved_candidate=$CANDIDATE registry=public"
NPM_REGISTRY_URL="https://registry.npmjs.org/"
fi

say "install published driver $DRIVER_VERSION"
# GitHub macOS images block npm install scripts unless allowlisted; the update's
# candidate admission needs openclaw's postinstall-generated bundled plugin runtime.
# The updater fences update-owned native commands against its own install root; the
# setup-node tool cache root is refused, so use a plain user prefix like the Linux cell.
NPM_PREFIX="$HOME/.npm-global"
mkdir -p "$NPM_PREFIX"
npm config set prefix "$NPM_PREFIX" --location=user
npm config set allow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw --location=user
export PATH="$NPM_PREFIX/bin:$PATH"
npm install -g --allow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw \
  "openclaw@$DRIVER_VERSION" --no-audit --no-fund 2>&1 | tail -3
DRIVER_BIN="$NPM_PREFIX/bin/openclaw"
DRIVER_PKG="$NPM_PREFIX/lib/node_modules/openclaw"
export DRIVER_BIN DRIVER_PKG NPM_PREFIX
note "driver_prefix=$NPM_PREFIX"
note "driver_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"
note "driver_wallclock_budget_files=$(grep -rl 'deadline - Date.now()' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"
note "driver_monotonic_budget_files=$(grep -rl 'createMonotonicBudget' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"

if [ "$CANDIDATE_SOURCE" = "packed" ]; then
say "start loopback registry serving the candidate"
rm -f /tmp/registry.log
PROOF_REGISTRY_PORT="$PORT_REGISTRY" \
PROOF_TARBALL="$TARBALL" \
PROOF_CANDIDATE_VERSION="$CANDIDATE" \
PROOF_BASE_VERSION="$DRIVER_VERSION" \
PROOF_CANDIDATE_MANIFEST="$MANIFEST" \
PROOF_REGISTRY_LOG=/tmp/registry.log \
  nohup node "$GITHUB_WORKSPACE/harness/registry-proxy.mjs" >/tmp/registry.stdout 2>&1 &
for _ in $(seq 1 30); do grep -q 'listening on' /tmp/registry.log 2>/dev/null && break; sleep 1; done
head -1 /tmp/registry.log
fi
printf 'registry=%s\nprefix=%s\nallow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw\n' "$NPM_REGISTRY_URL" "$NPM_PREFIX" >"$HOME/.npmrc"
note "npmrc=$(cat "$HOME/.npmrc" | tr '\n' ';')"

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

say "probe the staged executor fence exactly as the updater does"
rm -rf /tmp/stageprobe && mkdir -p /tmp/stageprobe
npm install --prefix /tmp/stageprobe --no-audit --no-fund "openclaw@$CANDIDATE" >/tmp/stageprobe.npm 2>&1
note "stageprobe_npm_exit=$? tail=$(tail -3 /tmp/stageprobe.npm | tr '\n' ';')"
PROBE_ENTRY=/tmp/stageprobe/node_modules/openclaw/dist/entry.js
ls -l "$PROBE_ENTRY" 2>&1 | tail -2
set +e
OPENCLAW_NO_RESPAWN=1 node "$PROBE_ENTRY" gateway install --update-executor check --json \
  >/tmp/stageprobe.json 2>/tmp/stageprobe.err
note "stageprobe_exit=$?"
set +e
echo "--- stageprobe stdout ---"; head -c 1500 /tmp/stageprobe.json; echo
echo "--- stageprobe stderr ---"; head -c 1500 /tmp/stageprobe.err; echo
node -e '
const fs = require("node:fs");
let doc;
try { doc = JSON.parse(fs.readFileSync("/tmp/stageprobe.json", "utf8")); } catch (e) { console.log("stageprobe_stdout_not_json=" + e.message); process.exit(0); }
console.log("stageprobe_updateExecutor=" + doc.updateExecutor);
for (const [k, v] of Object.entries(doc)) if (typeof v === "boolean" || k.endsWith("Binding")) console.log("  capability " + k + "=" + v);
'

say "run the shipped update entry (published driver -> candidate) on launchd"
rm -rf /tmp/openclaw-update-run-handoff-* "${TMPDIR:-/tmp}/openclaw-update-run-handoff-"* 2>/dev/null
find "$HOME/.openclaw/tmp" -maxdepth 2 -name '*handoff*' -exec rm -rf {} + 2>/dev/null
START=$(date +%s)
set +e
npm_config_registry="$NPM_REGISTRY_URL" \
npm_config_allow_scripts=@google/genai,esbuild,koffi,protobufjs,openclaw \
npm_config_ignore_scripts=false \
OPENCLAW_UPDATE_PACKAGE_SPEC="$TARGET_SPEC" \
  "$DRIVER_BIN" gateway call update.run --params '{"timeoutMs":900000}' --timeout 900000 --json \
    >/tmp/update.json 2>/tmp/update.err
UPDATE_RPC_EXIT=$?
set +e
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

say "settle the managed handoff (phase A: managed service is active)"
SETTLE_START=$(date +%s)
for i in $(seq 1 60); do
  HELPERS="$(pgrep -f 'update-managed-service-handoff|openclaw update' 2>/dev/null | tr '\n' ' ' || true)"
  AFTER_CODE=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT_GATEWAY/health" || true)
  AFTER_VERSION="$("$DRIVER_BIN" --version 2>&1 | tail -1)"
  if [ -z "$HELPERS" ] && [ "$AFTER_CODE" = "200" ] && echo "$AFTER_VERSION" | grep -q "$CANDIDATE"; then break; fi
  if [ $((i % 15)) -eq 0 ]; then
    note "settle_wait round=$i elapsed_s=$(( $(date +%s) - SETTLE_START )) version='$AFTER_VERSION' health=$AFTER_CODE helpers='$HELPERS'"
  fi
  sleep 4
done
note "settle_elapsed_s=$(( $(date +%s) - SETTLE_START ))"
note "phaseA_after_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"
note "phaseA_service_pid=$(launchctl print "$TARGET" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}') pre_pid=$PRE_PID"
note "phaseA_health=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT_GATEWAY/health" || true)"
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
while IFS= read -r f; do
  echo "## $f"
  tail -30 "$f"
done < <(find "$HOME/.openclaw/logs" -maxdepth 3 -type f 2>/dev/null | head -20)
say "update failure diagnostics"
while IFS= read -r f; do
  echo "## $f"
  head -c 4000 "$f"
  echo
done < <(find "$HOME/.openclaw/logs/support" -maxdepth 1 -name 'openclaw-update-failure-*.json' 2>/dev/null | head -4)
echo "=== registry requests ==="
wc -l /tmp/registry.log 2>/dev/null
tail -10 /tmp/registry.log 2>/dev/null

say "phase B: shipped openclaw update entry with the launchd job parked"
launchctl bootout "$TARGET" 2>&1 | tail -2
sleep 3
note "phaseB_job_parked=$(launchctl print "$TARGET" >/dev/null 2>&1 && echo no || echo yes)"
B_START=$(date +%s)
set +e
npm_config_registry="$NPM_REGISTRY_URL" \
npm_config_allow_scripts=@google/genai,esbuild,koffi,protobufjs,openclaw \
npm_config_ignore_scripts=false \
OPENCLAW_UPDATE_PACKAGE_SPEC="$TARGET_SPEC" \
  "$DRIVER_BIN" update --yes --json --timeout 1200 >/tmp/update-b.json 2>/tmp/update-b.err
UPDATE_B_EXIT=$?
set +e
note "phaseB_update_exit=$UPDATE_B_EXIT phaseB_duration_s=$(( $(date +%s) - B_START ))"
tail -25 /tmp/update-b.err
node -e '
const fs = require("node:fs");
let body;
try { body = JSON.parse(fs.readFileSync("/tmp/update-b.json", "utf8")); } catch (e) { console.log("phaseB_json_unparseable=" + e.message); process.exit(0); }
const res = body.run ?? body;
console.log("phaseB_status=" + (res.status ?? body.status) + " reason=" + (res.reason ?? body.reason ?? ""));
console.log("phaseB_from=" + (res.currentVersion ?? body.currentVersion ?? "") + " to=" + (res.targetVersion ?? body.targetVersion ?? ""));
for (const step of res.steps ?? body.steps ?? []) console.log("  phaseB step: " + (step.step ?? step.name) + ":" + step.status + " dur=" + step.durationMs + " exit=" + (step.exitCode ?? ""));
' | tee -a "$SUMMARY"
for i in $(seq 1 60); do
  B_VERSION="$("$DRIVER_BIN" --version 2>&1 | tail -1)"
  echo "$B_VERSION" | grep -q "$CANDIDATE" && break
  sleep 5
done
note "phaseB_after_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"

collect_service_evidence() {
  local arm="$1"
  "$DRIVER_BIN" gateway install --force --port "$PORT_GATEWAY" 2>&1 | tail -4
  local code="" pid="" svc=""
  for _ in $(seq 1 60); do
    code=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT_GATEWAY/health" || true)
    [ "$code" = "200" ] && break
    sleep 3
  done
  pid="$(launchctl print "$TARGET" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
  svc=$("$DRIVER_BIN" gateway status --json 2>/dev/null | node -e '
let raw = "";
process.stdin.on("data", (c) => (raw += c)).on("end", () => {
  try { const d = JSON.parse(raw); console.log(d?.service?.runtime?.version ?? d?.runtime?.version ?? "n/a"); } catch { console.log("unreadable"); }
});')
  note "${arm}_health=$code ${arm}_service_pid=$pid pre_update_pid=$PRE_PID ${arm}_service_version=$svc"
  note "${arm}_marker=$(cat "$HOME/.openclaw/proof-marker" 2>/dev/null) ${arm}_workspace=$(cat "$HOME/.openclaw/workspace/note.txt" 2>/dev/null) ${arm}_data=$(cat "$HOME/.openclaw/proof/data.json" 2>/dev/null | tr -d '\n')"
  note "${arm}_installed_monotonic_budget_files=$(grep -rl 'createMonotonicBudget' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"
  note "${arm}_installed_wallclock_budget_files=$(grep -rl 'Date.now() < deadline' "$DRIVER_PKG/dist" 2>/dev/null | wc -l | tr -d ' ')"
  CONFIG_SHA_FINAL="$(shasum -a 256 "$HOME/.openclaw/openclaw.json" | cut -d' ' -f1)"
  note "${arm}_config_sha_after=$CONFIG_SHA_FINAL (before=$CONFIG_SHA_BEFORE)"
  ARM_HEALTH="$code"
  ARM_PID="$pid"
}

say "phase B: bring the managed launchd service back on the candidate"
collect_service_evidence phaseB
say "phase B update report"
for f in $(ls -1t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1); do
  echo "## $f"
  head -30 "$f"
done

say "phase C: shipped update entry with the managed service uninstalled"
"$DRIVER_BIN" gateway uninstall --json 2>&1 | tail -3
launchctl bootout "$TARGET" 2>&1 | tail -2
note "phaseC_job_present=$(launchctl print "$TARGET" >/dev/null 2>&1 && echo yes || echo no)"
note "phaseC_launchagents=$(ls "$HOME"/Library/LaunchAgents 2>/dev/null | tr '\n' ' ')"
C_START=$(date +%s)
npm_config_registry="$NPM_REGISTRY_URL" \
npm_config_allow_scripts=@google/genai,esbuild,koffi,protobufjs,openclaw \
npm_config_ignore_scripts=false \
OPENCLAW_UPDATE_PACKAGE_SPEC="$TARGET_SPEC" \
  "$DRIVER_BIN" update --yes --json --timeout 1200 >/tmp/update-c.json 2>/tmp/update-c.err
UPDATE_C_EXIT=$?
note "phaseC_update_exit=$UPDATE_C_EXIT phaseC_duration_s=$(( $(date +%s) - C_START ))"
tail -25 /tmp/update-c.err
node -e '
const fs = require("node:fs");
let body;
try { body = JSON.parse(fs.readFileSync("/tmp/update-c.json", "utf8")); } catch (e) { console.log("phaseC_json_unparseable=" + e.message); process.exit(0); }
const res = body.run ?? body;
console.log("phaseC_status=" + (res.status ?? body.status) + " reason=" + (res.reason ?? body.reason ?? ""));
console.log("phaseC_from=" + (res.currentVersion ?? body.currentVersion ?? "") + " to=" + (res.targetVersion ?? body.targetVersion ?? ""));
for (const step of res.steps ?? body.steps ?? []) console.log("  phaseC step: " + (step.step ?? step.name) + ":" + step.status + " dur=" + step.durationMs + " exit=" + (step.exitCode ?? ""));
' | tee -a "$SUMMARY"
for i in $(seq 1 60); do
  C_VERSION="$("$DRIVER_BIN" --version 2>&1 | tail -1)"
  echo "$C_VERSION" | grep -q "$CANDIDATE" && break
  sleep 5
done
note "phaseC_after_version=$("$DRIVER_BIN" --version 2>&1 | tail -1)"
say "phase C: bring the managed launchd service back on the candidate"
collect_service_evidence phaseC
say "phase C update report"
for f in $(ls -1t "$HOME"/.openclaw/update-reports/*.md 2>/dev/null | head -1); do
  echo "## $f"
  head -30 "$f"
done

say "fence postmortem: executor check straight from each staged install root"
for stage in "$NPM_PREFIX"/lib/node_modules/.openclaw.update-stage-*/lib/node_modules/openclaw; do
  [ -d "$stage" ] || continue
  echo "## stage=$stage"
  ( cd "$stage" && OPENCLAW_NO_RESPAWN=1 npm_config_registry="$NPM_REGISTRY_URL" \
      node dist/entry.js gateway install --update-executor check --json ) \
    >/tmp/stagecheck.json 2>/tmp/stagecheck.err
  note "stagecheck_exit=$? stagecheck_stdout=$(head -c 600 /tmp/stagecheck.json)"
  note "stagecheck_stderr=$(head -c 600 /tmp/stagecheck.err | tr '\n' ';')"
done
ls -1d "$NPM_PREFIX"/lib/node_modules/.openclaw.update-stage-* "$NPM_PREFIX"/lib/openclaw-update-runtime-* 2>/dev/null | tee -a "$SUMMARY"

[ "$CANDIDATE_SOURCE" = "packed" ] || note "phaseD_skipped source=$CANDIDATE_SOURCE"
if [ "$CANDIDATE_SOURCE" = "packed" ]; then
say "phase D: reproduce the updater's staged candidate install and inspect its tree"
STAGE="$NPM_PREFIX/lib/node_modules/.openclaw.update-stage-manual"
rm -rf "$STAGE" && mkdir -p "$STAGE"
npm_config_registry="$NPM_REGISTRY_URL" \
  npm i -g --allow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw --prefix "$STAGE" "openclaw@$CANDIDATE" \
  --no-fund --no-audit --loglevel=error --min-release-age=0 >/tmp/stage-d.npm 2>&1
note "stageD_npm_exit=$? npm_tail=$(tail -4 /tmp/stage-d.npm | tr '\n' ';')"
note "stageD_layout=$(ls "$STAGE" "$STAGE/lib" "$STAGE/lib/node_modules" 2>/dev/null | tr '\n' ' ' | head -c 300)"
for root in "$STAGE/lib/node_modules/openclaw" "$STAGE/node_modules/openclaw"; do
  [ -d "$root" ] || continue
  note "stageD_root=$root nested_modules=$(ls "$root/node_modules" 2>/dev/null | wc -l | tr -d ' ') hoisted=$(ls "$(dirname "$root")" 2>/dev/null | tr '\n' ' ' | head -c 200)"
  note "stageD_typebox=$(ls -d "$root/node_modules/typebox" "$(dirname "$root")/typebox" 2>/dev/null | tr '\n' ' ')"
  note "stageD_ai=$(ls -d "$root/node_modules/@openclaw/ai" "$(dirname "$root")/@openclaw/ai" 2>/dev/null | tr '\n' ' ')"
  ( cd "$root" && OPENCLAW_NO_RESPAWN=1 node dist/entry.js doctor --non-interactive --json ) \
    >/tmp/doctor-d.json 2>/tmp/doctor-d.err
  note "stageD_doctor_exit=$? doctor_err=$(tail -c 500 /tmp/doctor-d.err | tr '\n' ';')"
done
fi

say "update failure diagnostics"
while IFS= read -r f; do
  echo "## $f"
  head -c 2500 "$f"
  echo
done < <(ls -1t "$HOME"/.openclaw/logs/support/openclaw-update-failure-*.json 2>/dev/null | head -3)

say "verdict"
VERSION_OK=no
"$DRIVER_BIN" --version 2>&1 | tail -1 | grep -q "$CANDIDATE" && VERSION_OK=yes
DATA_OK=no
[ "$(cat "$HOME/.openclaw/proof-marker" 2>/dev/null)" = "MARKER-macos-186831" ] &&
  [ "$(cat "$HOME/.openclaw/workspace/note.txt" 2>/dev/null)" = "workspace-macos-186831" ] &&
  [ "$(cat "$HOME/.openclaw/proof/data.json" 2>/dev/null | tr -d '\n')" = '{"keep":"me","record":42}' ] && DATA_OK=yes
[ "$CONFIG_SHA_FINAL" = "$CONFIG_SHA_BEFORE" ] && CONFIG_OK=yes || CONFIG_OK=no
UPGRADE_ARM=none
[ "${UPDATE_C_EXIT:-1}" -eq 0 ] && UPGRADE_ARM=phaseC
[ "${UPDATE_B_EXIT:-1}" -eq 0 ] && UPGRADE_ARM=phaseB
VERDICT=FAIL
if [ "$UPGRADE_ARM" != none ] && [ "$VERSION_OK" = yes ] && [ "$DATA_OK" = yes ] &&
   [ "$CONFIG_OK" = yes ] && [ "$ARM_HEALTH" = "200" ] && [ -n "$ARM_PID" ]; then VERDICT=PASS; fi
note "VERDICT=$VERDICT upgradeArm=$UPGRADE_ARM phaseA_rpcExit=$UPDATE_RPC_EXIT phaseB_updateExit=$UPDATE_B_EXIT phaseC_updateExit=$UPDATE_C_EXIT versionAdvanced=$VERSION_OK dataIntact=$DATA_OK configIntact=$CONFIG_OK ${UPGRADE_ARM}_health=$ARM_HEALTH ${UPGRADE_ARM}_pid=$ARM_PID"
[ "$VERDICT" = PASS ] || exit 1

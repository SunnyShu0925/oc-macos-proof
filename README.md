# macOS Real-Transport Proof for openclaw PR #175204

GitHub Actions macOS runner that proves the launchd teardown-retry deadline fix
on a **real `launchctl` transport** (no mock) for
[openclaw/openclaw#175204](https://github.com/openclaw/openclaw/pull/175204).

## What it proves

`bootstrapLaunchAgentOrThrow` (src/daemon/launchd-runtime.ts) retries launchctl
bootstrap while a booted-out job tears down, bounded by a deadline. The PR fixes
the deadline to be computed from the monotonic clock (`performance.now()`) so a
wall-clock adjustment cannot truncate (forward jump) or inflate (rollback) the
retry budget.

This repo runs the production retry owner against a genuine `launchctl` child
process. A user-domain `launchctl bootstrap` answers a real EIO
("Bootstrap failed: 5: Input/output error", termination=exit code=5), which the
owner classifies as pending teardown (`isLaunchctlBootstrapPendingTeardown`).

## How to run

1. Actions → "macOS Real-Transport Proof (PR #175204)" → Run workflow
2. Enter the PR branch on `SunnyShu0925/openclaw`
   (default `fix/launchd-runtime-bootstrap-teardown-deadline-wall-clock-181`)
3. Read the step log for the VERDICT lines.

## Result (run 39013651390)

| Scenario | OLD (`Date.now`) | FIXED (`performance.now`) |
|---|---|---|
| forward +1,000,000 ms | rejected <2.5s (spurious) | pending (keeps retrying) |
| backward -5,000 ms | settled 344871ms (inflated) | settled 340130ms (honoured) |

Runner pins the system clock (NTP), so the wall-clock step is injected at the
OLD variant's remaining-budget read only; the launchctl transport and the
monotonic clock are real.

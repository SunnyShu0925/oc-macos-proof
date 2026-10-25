// ESM preload (node --import): forward-jump Date.now by PROOF_JUMP_MS once the
// process has been alive for PROOF_JUMP_AT_MS. Timer-driven so the jump lands at
// the same moment regardless of whether the code under test reads Date.now().
//
// Pre-fix launchd-stop deadlines are seeded and re-read with Date.now(); the
// jump therefore expires them early. Post-fix uses performance.now().
import { isMainThread } from "node:worker_threads";

const JUMP_MS = Number(process.env.PROOF_JUMP_MS || 0);
const AT_MS = Number(process.env.PROOF_JUMP_AT_MS || 0);

if (JUMP_MS > 0) {
  const realNow = Date.now.bind(Date);
  let offset = 0;
  let calls = 0;
  const t0 = realNow();

  Date.now = () => {
    calls += 1;
    return realNow() + offset;
  };

  setTimeout(() => {
    offset = JUMP_MS;
    console.log(
      `[clock-inject] Date.now forward-jumped +${JUMP_MS}ms at t~${realNow() - t0}ms ` +
        `(Date.now calls so far=${calls}, pid=${process.pid}, thread=${isMainThread ? "main" : "worker"})`,
    );
  }, AT_MS);

  console.log(
    `[clock-inject] armed: forward-jump +${JUMP_MS}ms at t~${AT_MS}ms ` +
      `(pid=${process.pid}, thread=${isMainThread ? "main" : "worker"})`,
  );
}

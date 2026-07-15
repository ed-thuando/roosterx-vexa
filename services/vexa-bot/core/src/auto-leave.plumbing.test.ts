/**
 * Source-shape tests for auto-leave silence plumbing (SPEC-AUTO-LEAVE-SILENCE-EMPTY).
 * TDD: fail before wiring noAudioActivityTimeout + inactive_no_audio path.
 */

import * as fs from "fs";
import * as path from "path";

let passed = 0;
let failed = 0;

function expectContains(name: string, body: string, needle: string | RegExp) {
  const ok = typeof needle === "string" ? body.includes(needle) : needle.test(body);
  if (ok) {
    console.log(`  \x1b[32mPASS\x1b[0m  ${name}`);
    passed++;
  } else {
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name}`);
    console.log(`        needle: ${needle}`);
    failed++;
  }
}

const root = __dirname; // services/vexa-bot/core/src
const dockerTs = fs.readFileSync(path.join(root, "docker.ts"), "utf-8");
const typesTs = fs.readFileSync(path.join(root, "types.ts"), "utf-8");
const meetingFlowTs = fs.readFileSync(
  path.join(root, "platforms/shared/meetingFlow.ts"),
  "utf-8",
);
const unifiedCbTs = fs.readFileSync(
  path.join(root, "services/unified-callback.ts"),
  "utf-8",
);

console.log("\n=== Auto-leave silence plumbing ===");

expectContains(
  "docker.ts automaticLeave has noAudioActivityTimeout",
  dockerTs,
  "noAudioActivityTimeout",
);
expectContains(
  "docker.ts default silence timeout is 600000",
  dockerTs,
  /noAudioActivityTimeout:\s*z\.number\(\)\.int\(\)\.default\(600000\)/,
);
expectContains(
  "types.ts automaticLeave includes noAudioActivityTimeout",
  typesTs,
  "noAudioActivityTimeout: number",
);
expectContains(
  "meetingFlow LeaveReason includes inactive_no_audio_timeout",
  meetingFlowTs,
  '"inactive_no_audio_timeout"',
);
expectContains(
  "meetingFlow generates inactiveNoAudioToken",
  meetingFlowTs,
  "BOT_INACTIVE_NO_AUDIO_TIMEOUT",
);
expectContains(
  "meetingFlow maps inactive token to inactive_no_audio_timeout leave",
  meetingFlowTs,
  'gracefulLeaveFunction(page, 0, "inactive_no_audio_timeout")',
);
expectContains(
  "unified-callback CompletionReason includes inactive_no_audio",
  unifiedCbTs,
  '"inactive_no_audio"',
);
expectContains(
  "unified-callback maps inactive_no_audio_timeout → inactive_no_audio",
  unifiedCbTs,
  /case\s+"inactive_no_audio_timeout"[\s\S]*inactive_no_audio/,
);

console.log(`\n=== auto-leave plumbing summary: ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);

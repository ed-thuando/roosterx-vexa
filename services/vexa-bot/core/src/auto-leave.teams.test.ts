/**
 * Source-shape tests for Teams silence auto-leave (Q1=A).
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

const recordingTs = fs.readFileSync(
  path.join(__dirname, "platforms/msteams/recording.ts"),
  "utf-8",
);

console.log("\n=== Teams silence auto-leave ===");

expectContains(
  "reads noAudioActivityTimeout from leaveCfg",
  recordingTs,
  "noAudioActivityTimeout",
);
expectContains(
  "arms silence clock at monitoring start (Q1=A)",
  recordingTs,
  /__vexaLastAudioActivityTs\s*=\s*Date\.now\(\)/,
);
expectContains(
  "rejects with TEAMS_BOT_INACTIVE_NO_AUDIO_TIMEOUT",
  recordingTs,
  "TEAMS_BOT_INACTIVE_NO_AUDIO_TIMEOUT",
);
expectContains(
  "stopMonitoring reason inactive_no_audio_timeout",
  recordingTs,
  '"inactive_no_audio_timeout"',
);

console.log(`\n=== teams silence summary: ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);

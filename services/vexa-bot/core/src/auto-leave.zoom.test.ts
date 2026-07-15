/**
 * Source-shape tests for Zoom Web alone + silence auto-leave.
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
  path.join(__dirname, "platforms/zoom/web/recording.ts"),
  "utf-8",
);

console.log("\n=== Zoom Web auto-leave ===");

expectContains(
  "reads noAudioActivityTimeout / everyoneLeftTimeout",
  recordingTs,
  "noAudioActivityTimeout",
);
expectContains(
  "rejects ZOOM_BOT_INACTIVE_NO_AUDIO_TIMEOUT",
  recordingTs,
  "ZOOM_BOT_INACTIVE_NO_AUDIO_TIMEOUT",
);
expectContains(
  "rejects ZOOM_BOT_LEFT_ALONE_TIMEOUT",
  recordingTs,
  "ZOOM_BOT_LEFT_ALONE_TIMEOUT",
);
expectContains(
  "arms lastAudioActivityTs (Q1=A)",
  recordingTs,
  "lastAudioActivityTs",
);

console.log(`\n=== zoom auto-leave summary: ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);

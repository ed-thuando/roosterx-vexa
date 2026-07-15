# Spec: Auto-leave on silence + empty meeting

**Status:** IMPLEMENT in progress — T1–T6 code done; manual M1–M10 + Meetix T7 pending  
**Date:** 2026-07-15  
**Scope:** RoosterX audio-only fork (`vexa-selfhost`) — GMeet + Teams first, then Zoom  
**Related code (already exists):**
- Alone / everyone-left watchdog: `services/vexa-bot/core/src/platforms/{googlemeet,msteams}/recording.ts` (+ Zoom Web now)
- Leave config schema: `automaticLeave` in `docker.ts` / `types.ts`
- API knobs: `AutomaticLeave` in `meeting-api/schemas.py` → injected in `meetings.py`
- Completion routing: `LEFT_ALONE` + `INACTIVE_NO_AUDIO` → `completed` in `callbacks.py`

---

## ASSUMPTIONS (validated 2026-07-15)

1. **Platforms:** Verify on Google Meet + MS Teams first; **still must implement Zoom** in the same feature before DONE. _(updated)_
2. **“No sound” = mixed audio RMS activity**, via existing `__vexaLastAudioActivityTs` (not Whisper/VAD, not captions). Video/screen-share with **no audio** counts as inactive.
3. **Silence rule fires even if participants remain** in the roster (all muted / present-but-silent). Distinct from everyone-left.
4. **Both outcomes → `status=completed`** (not `failed`), with distinct `completion_reason` + human message (**EN only**).
5. **Defaults** for RoosterX:
   - silence / inactive: **10 min** (`600000` ms)
   - everyone left / no participants: **10 min** (`600000` ms)
6. Adjustable via `POST /bots` → `automatic_leave` (+ optional `user.data.bot_config`), milliseconds.
7. Bot **graceful leave** → upload recording → unified callback (same path as `left_alone_timeout`).
8. “Message” = API/webhook fields (`completion_reason` + EN `message`); Meetix **shows** `completion_reason` (Worker/UI must accept new enum).

---

## Objective

Bot tự kết thúc cuộc họp khi meeting **không còn giá trị ghi**:

| Rule | Trigger | Default | Outcome |
|------|---------|---------|---------|
| **R1 — Inactive (silence)** | Không có audio energy (RMS) trong ≥ N ms từ lúc admitted (option A), kể cả vẫn còn người | `N = 600_000` (10 min) | `completed` + `inactive_no_audio` + `"Meeting inactive — no audio activity"` |
| **R2 — Everyone left** | Chỉ còn bot (participant count ≤ 1) trong ≥ M ms **sau khi đã từng có ≥2 người** | `M = 600_000` (10 min) | `completed` + `left_alone` + `"All participants have left the meeting"` |

**User:** RoosterX / Meetium ops + Meetix backend (webhook consumer).  
**Why:** Tránh bot treo ghi file rỗng / tiêu CPU khi meeting chết hoặc mọi người đi.

### Difficulty estimate (honest)

| Piece | Difficulty | Effort | Notes |
|-------|------------|--------|-------|
| **R2 everyone-left** | **Easy — mostly already built** | 0.5–1 day (verify + message + default align) | Watchdog exists on GMeet + Teams. `LEFT_ALONE` already → `completed`. Gaps: default in meeting-api is **15 min** (`max_time_left_alone=900000`), not 2 min; user-facing message not explicit. |
| **R1 silence / inactive** | **Medium-Low** | 1–1.5 days (+ tests) | New watchdog independent of participant count. Signal `__vexaLastAudioActivityTs` already exists on GMeet/Teams. Need: config field, new reason, meetingFlow token, callback classifier, false-positive rules. |
| **GMeet+Teams (R1+R2+tests)** | **Medium-Low** | **~2 days** | Verify first on these two. |
| **+ Zoom parity** | **Low–Medium** | **+0.5–1 day** | Same watchdog once GMeet/Teams proven. |
| **Full DONE (3 platforms)** | **Medium-Low** | **~2.5–3 days** | Separate branch/PR; not a 0.12 merge. |

**Verdict:** Tách branch/test riêng được. Order: GMeet → Teams → Zoom.

---

## Tech Stack

- Bot (in-page + Node): TypeScript / Playwright (`services/vexa-bot`)
- Meeting API: Python FastAPI (`services/meeting-api`)
- Config: `AutomaticLeave` + `bot_config.automaticLeave`
- Verification: source-shape / unit tests; manual Meet/Teams; optional `tests3` harness

## Commands

```bash
# --- Mac local (recommended) ---
./scripts/mac-test-auto-leave.sh bootstrap
./scripts/mac-test-auto-leave.sh spawn MEET_URL=https://meet.google.com/xxx-yyyy-zzz SCENARIO=silence
./scripts/mac-test-auto-leave.sh watch

# After bot/meeting-api code changes (faster):
./scripts/mac-test-auto-leave.sh rebuild

# Unit (CI-style)
cd services/vexa-bot/core && npx tsx src/auto-leave.gmeet.test.ts
cd services/meeting-api && python -m pytest tests/test_auto_leave_contracts.py -q
```

## Project Structure

```
services/vexa-bot/core/src/
  docker.ts / types.ts          → add silenceTimeout to automaticLeave
  platforms/shared/meetingFlow.ts → map new Error token → leave reason
  platforms/googlemeet/recording.ts → silence watchdog (+ existing alone)
  platforms/msteams/recording.ts    → same
  services/unified-callback.ts      → map reason → completionReason

services/meeting-api/meeting_api/
  schemas.py    → AutomaticLeave + MeetingCompletionReason
  meetings.py   → SYSTEM_DEFAULTS + inject bot_config
  callbacks.py  → route new reason → completed + message

notes/SPEC-AUTO-LEAVE-SILENCE-EMPTY.md  → this spec
tests/…                                 → unit + manual + e2e cases below
```

## Code Style

Follow existing leave-path patterns:

```ts
// New leave token parallel to LEFT_ALONE
if (silenceMs >= silenceTimeoutSeconds) {
  stopMonitoring("inactive_no_audio_timeout", () =>
    reject(new Error("GOOGLE_MEET_BOT_INACTIVE_NO_AUDIO_TIMEOUT"))
  );
}
```

```python
# callbacks classifier: treat like LEFT_ALONE (legitimate end)
if requested_reason == MeetingCompletionReason.INACTIVE_NO_AUDIO:
    return MeetingStatus.COMPLETED, requested_reason, message
```

Naming: snake_case API (`no_audio_activity_timeout`), camelCase bot (`noAudioActivityTimeout`).

## Testing Strategy

| Level | What | Where |
|-------|------|-------|
| Unit / source-shape | Config wiring, token→reason map, classifier routes to completed | `admission`-style test or new `auto-leave.test.ts`; `test_callbacks.py` |
| Unit bot logic | Alone vs silence timers reset correctly (fake clocks / injected ts) | Prefer small extracted helpers if adding; else source-shape needles |
| Manual | Real GMeet + Teams with shortened timeouts | Checklist below |
| E2E | Scripted join → force conditions → assert meeting status + reason + message | `tests3` or Meeting Notes worker webhook assert |

Coverage bar for DONE: all Success Criteria checked; R1+R2 each have ≥1 automated + 1 manual pass on GMeet.

## Boundaries

- **Always:** Keep RoosterX audio-only defaults (`TRANSCRIPTION_ENABLED` false). Run unit tests before commit. Graceful leave + flush recording before exit.
- **Ask first:** Changing production SYSTEM_DEFAULTS for all users (15m → 2m alone); adding Zoom; webhook contract change for Meetix Worker; new enum values if Worker already validates completion_reason allowlist.
- **Never:** Auto-click Gemini consent; leave on short pauses (< default without override); treat DOM-alone without audio cross-check as enough for R2 (keep existing false-LEFT_ALONE guard); merge upstream 0.12 as part of this task.

---

## Behaviour detail

### R2 — Everyone left (mostly exists)

**Current behaviour:**
- When `participantCount <= 1`, increment `aloneTime` every 1s (with audio cross-validate: recent audio ⇒ don’t count alone).
- After speakers identified → timeout = `everyoneLeftTimeout` / `max_time_left_alone`.
- Error `*_BOT_LEFT_ALONE_TIMEOUT` → `left_alone_timeout` → callback `left_alone` → **completed**.

**Gaps vs product:**
1. meeting-api default `max_time_left_alone` = **15 min**, not 2 min → align RoosterX default to **120_000**.
2. Human message not fixed → set explicit message string on completed payload.
3. Document adjustable field: `automatic_leave.max_time_left_alone` (ms).

### R1 — Silence / inactive (new)

**Proposed behaviour:**
- Each 1s tick (same monitoring interval):  
  `silenceElapsed = now - __vexaLastAudioActivityTs` (if ts==0 after recording started, treat as silence from start *or* require “ever had audio” first — see Open Q).
- If `silenceElapsed >= noAudioActivityTimeout` → leave with `inactive_no_audio_timeout`.
- Independent of participant count (can fire while count ≥ 2).
- R1 and R2 both armed; **whichever fires first wins**.
- Grace: do not start silence clock until recording/audio pipeline is up (avoid join noise false trigger).

**Config:**
| Layer | Field | Default (RoosterX) |
|-------|-------|--------------------|
| API | `automatic_leave.no_audio_activity_timeout` (ms) | `600000` |
| Bot | `automaticLeave.noAudioActivityTimeout` | same |
| Env / user.bot_config | optional override | — |

**Completion:**
- `completion_reason = inactive_no_audio` (new enum)
- `message = "Meeting inactive — no audio activity"` (EN canonical; workers can localize)
- status `completed`

---

## Success Criteria

1. GMeet: all humans leave → within **~M±5s** bot leaves; meeting `completed` + `left_alone` + message mentions participants left.
2. Teams: same as (1).
3. GMeet: ≥2 humans stay muted/silent → after **~N±10s** bot leaves; `completed` + `inactive_no_audio` + message mentions inactive / no audio.
4. Teams: same as (3).
5. Short talk bursts reset silence timer (speak at T+N-30s → no leave at N).
6. Participant count flicker + recent audio does **not** false-trigger R2 (existing cross-validate still holds).
7. Per-request override shortens both timers for test (e.g. 30s / 60s) without rebuild.
8. Recording for session still uploaded (if any audio earlier); meeting not stuck `active`/`stopping`.
9. Automated: callback classifier test for new reason; source-shape/config wiring test; ≥1 e2e script or documented manual log attached in PR.

---

## Decisions locked (2026-07-15)

| # | Decision |
|---|----------|
| Q1 | **A** — silence clock starts when admitted / audio pipeline ready (no prior speech required) |
| Q2 | Default `max_time_left_alone` **15m → 10m** (aligned with silence) |
| Q3 | Meetix shows `completion_reason` → add `inactive_no_audio`; Worker/UI must accept it |
| Q4 | Messages **EN only** |
| Platforms | GMeet+Teams verify first → Zoom required before DONE |

### Locked EN messages

| Reason | `completion_reason` | `message` |
|--------|---------------------|-----------|
| Everyone left | `left_alone` | `All participants have left the meeting` |
| Silence / inactive | `inactive_no_audio` | `Meeting inactive — no audio activity` |

### R1 clock detail (Q1=A)

- Arm silence timer when monitoring starts post-admission (set `__vexaLastAudioActivityTs = Date.now()` at arm, or treat `ts==0` as `armTs`).
- Any RMS activity refreshes ts → timer resets.
- If never any speech from join → still leave at N.

---

## Test cases

### A. Manual checklist

Use shortened timeouts: `max_time_left_alone=30000`, `no_audio_activity_timeout=60000`.

| ID | Platform | Steps | Expect |
|----|----------|-------|--------|
| M1 | GMeet | Bot joins; 2 humans join; both leave; wait ≥30s | `completed`, `left_alone`, message “all … left” |
| M2 | GMeet | Bot joins; 2 humans stay muted ≥60s (no speaking) | `completed`, `inactive_no_audio`, message “not active” / no audio |
| M3 | GMeet | Same as M2 but speak briefly at 45s | Bot **still in** at 60s; leaves only after 60s silent from last speech |
| M4 | GMeet | Humans leave at T0 but one speaks until T+20 then leave | Alone timer starts after last audio / last participant; no premature leave |
| M5 | Teams | Repeat M1 | same as M1 |
| M6 | Teams | Repeat M2 | same as M2 |
| M7 | GMeet | Override omitted → defaults 10m / 10m visible in `meeting.data.resolved_timeouts` | values match product defaults |
| M8 | Either | During silence wait, stop bot via API | `stopped` path unchanged (not confused with R1) |
| M9 | Zoom | Repeat M1 after Zoom port | same as M1 |
| M10 | Zoom | Repeat M2 after Zoom port | same as M2 |

### B. Automated unit

| ID | Assert |
|----|--------|
| U1 | `MeetingCompletionReason.INACTIVE_NO_AUDIO` routes to `COMPLETED` (callbacks classifier) |
| U2 | `LEFT_ALONE` still → `COMPLETED` + stable message helper |
| U3 | `AutomaticLeave` accepts `no_audio_activity_timeout`; forbids unknown keys |
| U4 | Bot schema / injection maps API field → `automaticLeave.noAudioActivityTimeout` |
| U5 | Source-shape: monitoring loop references silence timeout + reject token |
| U6 | meetingFlow maps `*_INACTIVE_NO_AUDIO_TIMEOUT` → leave reason `inactive_no_audio_timeout` |

### C. E2E (scripted / semi-automated)

Prefer shortened timeouts. Harness options: existing `tests3` messy-meeting OR docker-compose + API + fake silence by disconnecting audio / muting.

| ID | Flow | Assert API |
|----|------|------------|
| E1 | Join GMeet fixture → remove all humans (or mock participant count≤1 for ≥M) | GET meeting: `status=completed`, `completion_reason=left_alone`, message contains “left” |
| E2 | Join → keep count≥2 → no audio activity for ≥N (or advance `__vexaLastAudioActivityTs` via test hook) | `status=completed`, `completion_reason=inactive_no_audio` |
| E3 | Join → inject audio activity every 20s for 2×N | still `active` |
| E4 | RoosterX webhook (Meetix) receives payload; Worker maps to item completion without 5xx | optional if Worker contract stable |

**Test hook (recommended for E2 without waiting 10m):**  
`window.__vexaLastAudioActivityTs = Date.now() - timeoutMs` via Playwright `page.evaluate` in e2e only (guard behind `BOT_TEST_HOOKS=1`).

---

## PLAN

Shipping order: **API/contracts → GMeet → Teams → verify → Zoom → Meetix enum**.

1. **Contracts (meeting-api)** — Add `inactive_no_audio` enum; `no_audio_activity_timeout` on `AutomaticLeave`; SYSTEM_DEFAULTS: `max_time_left_alone=120000`, `no_audio_activity_timeout=600000`; inject into `bot_config.automaticLeave`; EN message helper on completed exits for `left_alone` + `inactive_no_audio`; classifier routes new reason → COMPLETED.
2. **Bot shared** — Extend zod/`types` + `meetingFlow` + `unified-callback` for silence token/`inactive_no_audio`.
3. **GMeet R1+R2** — Silence watchdog (Q1=A) in monitoring loop; keep alone watchdog; enrich leave messages.
4. **Teams R1+R2** — Same as GMeet.
5. **Verify GMeet+Teams** — Unit U1–U6 + manual M1–M7 with short timeouts.
6. **Zoom** — Add alone + silence monitoring (missing today) + audio activity ts; manual M9–M10.
7. **Meetix Worker** — Accept/display `inactive_no_audio` (separate repo touch; ask before coding).

### Parallelism

- Steps 1–2 sequential (contracts first).
- Steps 3–4 sequential after 2 (same pattern).
- Step 7 can parallel once enum name frozen.
- Step 6 after 5 passes.

### Verification checkpoints

- After 1: pytest classifier + schema.
- After 3: GMeet M1–M3.
- After 4: Teams M5–M6.
- After 6: Zoom M9–M10 → DONE.

### Risk (updated)

1. False R1 on long quiet agendas → default 10m + adjustable.
2. False R2 → keep audio cross-validate.
3. Default alone 15m→10m (same as silence) — **accepted**.
4. Meetix must accept new enum — **known**.
5. Zoom has **no** alone monitor today → higher port cost than Teams.

---

## TASKS

- [ ] **T1: meeting-api contracts + defaults**
  - Acceptance: enum `INACTIVE_NO_AUDIO`; field `no_audio_activity_timeout`; defaults 10m/10m in `resolved_timeouts`; classifier → COMPLETED; EN messages for both reasons on callback/status payload
  - Verify: `pytest tests/test_callbacks.py -k "left_alone or inactive"` + schema unit
  - Files: `schemas.py`, `meetings.py`, `callbacks.py`, `tests/test_callbacks.py`, (+ message helper if needed)

- [ ] **T2: bot config + leave path plumbing**
  - Acceptance: `automaticLeave.noAudioActivityTimeout` in zod/types; meetingFlow maps `*_INACTIVE_NO_AUDIO_TIMEOUT` → `inactive_no_audio_timeout`; unified-callback → `inactive_no_audio`
  - Verify: source-shape / existing unit pattern
  - Files: `docker.ts`, `types.ts`, `meetingFlow.ts`, `unified-callback.ts`

- [ ] **T3: GMeet silence + alone message**
  - Acceptance: post-admission silence watchdog (Q1=A); R2 unchanged; leave reasons + messages
  - Verify: manual M1–M3 with 30s/60s overrides; source-shape U5
  - Files: `platforms/googlemeet/recording.ts` (± small test)

- [ ] **T4: Teams silence + alone message**
  - Acceptance: same as T3 on Teams
  - Verify: manual M5–M6
  - Files: `platforms/msteams/recording.ts`

- [ ] **T5: automated tests bundle**
  - Acceptance: U1–U6 green; short-timeout e2e E1/E2 doc or script landed
  - Verify: pytest + `npx tsx` source-shape
  - Files: `tests/test_callbacks.py`, bot tests, optional `tests3` / notes manual log

- [ ] **T6: Zoom alone + silence**
  - Acceptance: Zoom has R1+R2 parity (participant count + `__vexaLastAudioActivityTs`)
  - Verify: manual M9–M10
  - Files: `platforms/zoom/web/recording.ts` (and/or strategies) + meetingFlow Zoom tokens if missing

- [ ] **T7: Meetix Worker/UI (ask first)**
  - Acceptance: UI/API shows `inactive_no_audio` without error
  - Verify: webhook from completed meeting renders reason+message
  - Files: parent Meetix worker (out of this submodule)

---

*Stop here until you OK PLAN+TASKS → then IMPLEMENT starting at T1.*
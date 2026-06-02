# RoosterX-Vexa Handoff Document

**Date:** 2026-06-02
**Source:** Fork of Vexa (vexaai/vexa) with customizations
**Goal:** Audio-only meeting recording bot, production-ready, self-hosted
**Next Agent:** Please read this entire document before making any changes

---

## 1. Executive Summary

This is a **fork of Vexa** (originally vexaai/vexa, Apache 2.0 license) customized for RoosterX use case:
- **Use case:** Record audio from Google Meet and Microsoft Teams, upload to R2 (S3-compatible)
- **Do NOT need:** Transcription, Whisper, voice agent, TTS, dashboard, MCP, agent chat
- **Platform:** Mac M5 (ARM64) for dev, Linux x86_64 for production (Hetzner/K8s)
- **Architecture:** 1 container = 1 bot (K8s/Helm for production)

**Key difference from original Vexa:**
- Original: Full platform (transcription, dashboard, multi-tenant, voice agent)
- RoosterX: Stripped-down audio-only recorder + upload

---

## 2. What Was Done in This Session

### 2.1 Branch Created: `fix/apple-silicon-arm64-support`

**Purpose:** Make Vexa build and run natively on Apple Silicon (Mac M5)

**Files changed (7 files):**

| File | Change | Why |
|------|--------|-----|
| `services/vexa-bot/Dockerfile:4` | Removed `--platform=linux/amd64` | Allow Docker auto-detect arch |
| `services/vexa-bot/core/Dockerfile:18-20` | `COPY package.json` only + `npm install --ignore-scripts` | Fix workspace lockfile issue |
| `services/vexa-bot/core/Dockerfile:66-71` | Arch-aware AWS CLI URL (`uname -m`) | Install correct AWS CLI binary (aarch64/x86_64) |
| `deploy/compose/Makefile:21-24` | Added `DOCKER_BUILD_PLATFORM` variable | Allow platform override for CI |
| `deploy/compose/Makefile:151,158` | `--platform linux/amd64` → `$(DOCKER_BUILD_PLATFORM)` | Auto-detect on Mac, override on CI |
| `tests3/lib/hot-iterate.sh:82` | Removed `--platform linux/amd64` | Dev script works on ARM64 |
| `services/vexa-bot/run-zoom-bot.sh:35` | Removed `--platform linux/amd64` | Dev script works on ARM64 |

**Status:** ✅ Tested and working on Mac M5

### 2.2 Resource Measurements

#### Single Bot (Mac M5, ARM64, Google Meet)

| Metric | Recording OFF | Recording ON |
|--------|--------------|--------------|
| CPU | ~0.45 cores (45%) | ~0.57 cores (57%) |
| RAM | ~1.09 GiB | ~1.26 GiB |
| GPU process | 0 | 0 |

#### 3 Bots Concurrent (Mac M5, Same Meeting, Recording ON)

| Bot | CPU | RAM |
|-----|-----|-----|
| Bot 1 | 56.67% | 1,255 MiB |
| Bot 2 | 35.15% | 1,273 MiB |
| Bot 3 | 33.81% | 1,281 MiB |
| **Total** | **~94% (~1 core)** | **~3,809 MiB** |

#### Linux Reference (User's Data, 3 Bots, Different Meetings)

| Bot | CPU Mean | RAM Mean |
|-----|----------|----------|
| Bot A (GMeet) | 83.91% | 993.6 MiB |
| Bot B (GMeet) | 81.00% | 1,142.3 MiB |
| Bot C (Teams) | 77.44% | 1,125.4 MiB |
| **Total** | **168.36% (~1.7 cores)** | **~2,235 MiB** |

**Key insight:** Mac M5 CPU lower than Linux (stronger single-core), but RAM higher (Docker VM overhead).

---

## 3. Architecture

### 3.1 Vexa Standard (What We're Using)

```
1 Container = 1 Bot (isolated)
  ├─ Xvfb (:99)
  ├─ PulseAudio
  ├─ Chromium (Playwright)
  └─ Node.js bot (dist/docker.js)
     ├─ Audio capture (browser MediaRecorder or PulseAudio)
     ├─ Recording service → Upload to S3/R2
     └─ Unified callback → Meeting API
```

**Container resources per bot:**
```yaml
cpu_request: "1000m"      # ~1 core
cpu_limit: "1500m"        # 1.5 core max
memory_request: "1100Mi"  # ~1.1 GB
memory_limit: "2560Mi"    # 2.5 GB max
shm_size: "2GB"           # Chromium shared memory
```

### 3.2 Infrastructure (Docker Compose / K8s)

```
Internet
    │
┌───▼────────────────────────────────────┐
│  API Gateway (port 8056)                │
│    │                                    │
│  ├─ Admin API (users, tokens)           │
│  ├─ Meeting API (bot orchestration)     │
│  ├─ Runtime API (spawn bot containers) │
│  └─ Dashboard (Next.js) ← WILL REMOVE   │
│                                         │
│  Redis (pub/sub, state)                 │
│  PostgreSQL (meetings, users, tokens)  │
│  MinIO/S3/R2 (recordings storage)       │
└────────────────────────────────────────┘
```

### 3.3 Bot Lifecycle

```
POST /bots ──► Meeting API ──► Runtime API ──► Docker/K8s spawn
                    │                              │
                    ▼                              ▼
              DB: Meeting row              Container: vexa-bot
              Status: REQUESTED            Status: JOINING
                    │                              │
                    ▼                              ▼
              Callbacks                      Navigate to meeting URL
              (joining → active)             Fill name, click Join
                                             Status: AWAITING_ADMISSION
                                                    │
              Host admits bot ◄─────────────────────┘
                    │
                    ▼
              Status: ACTIVE
              Audio capture starts
              Recording begins
                    │
              Meeting ends / host removes
                    │
                    ▼
              Status: COMPLETED/FAILED
              Recording uploaded to S3/R2
              Container auto-removed
```

---

## 4. What to Strip (High Priority)

### 4.1 Services to Remove from Docker Compose / Helm

| Service | Why Remove |
|---------|-----------|
| `transcription-service` | No transcription needed |
| `tts-service` | No text-to-speech needed |
| `agent-api` | No AI agent chat |
| `mcp` | No Model Context Protocol |
| `dashboard` | No web UI needed |

### 4.2 Bot Code to Remove

**In `services/vexa-bot/core/src/index.ts`:**
- `initVoiceAgentServices()` call → Skip if `voiceAgentEnabled: false` (already done)
- `TranscriptionClient` initialization → Skip if `transcribeEnabled: false` (already done)
- `SegmentPublisher` → Only needed for real-time transcription streaming
- TTS service imports → Remove if not needed

**In `services/vexa-bot/core/src/services/`:**
- `transcription-client.ts` → Remove entirely
- `segment-publisher.ts` → Remove entirely (or keep minimal for Redis if needed)
- `tts-playback.ts` → Remove entirely
- `voice-agent.ts` → Remove entirely

**In `services/meeting-api/`:**
- Transcription-related endpoints → Remove or disable
- Dashboard serving routes → Remove
- Agent chat endpoints → Remove

### 4.3 Docker Image Size Optimization

**Current image size:** ~1.1 GB (ARM64)

**Can remove from Dockerfile:**
- MS Edge browser installation (Teams uses Chromium fallback on ARM64)
- VNC/noVNC/X11vnc if not needed for debugging (saves ~100MB)
- SSH server if not needed for browser session mode
- Browser session mode support if not needed

**Potential savings:** 200-400 MB per image

---

## 5. What to Keep (Critical)

### 5.1 Bot Core Services

| Service | File | Status |
|---------|------|--------|
| Audio capture | `services/audio.ts` | ✅ KEEP |
| Recording | `services/recording.ts` | ✅ KEEP |
| Unified callback | `services/unified-callback.ts` | ✅ KEEP |
| Bot join (GMeet) | `platforms/googlemeet/` | ✅ KEEP |
| Bot join (Teams) | `platforms/msteams/` | ✅ KEEP |
| Bot join (Zoom) | `platforms/zoom/` | ⚠️ Optional (custom later) |
| Redis message broker | `connect/` | ✅ KEEP (for commands) |

### 5.2 Infrastructure Services

| Service | Status | Notes |
|---------|--------|-------|
| API Gateway | ✅ KEEP | Entry point |
| Meeting API | ✅ KEEP | Bot orchestration |
| Runtime API | ✅ KEEP | Container spawning |
| Admin API | ✅ KEEP | User/token management |
| Redis | ✅ KEEP | State, pub/sub |
| PostgreSQL | ✅ KEEP | Persistent data |
| Object Storage (R2) | ✅ KEEP | Recording upload target |

### 5.3 Bot Config Flags (Audio-Only Mode)

```json
{
  "transcribeEnabled": false,
  "voiceAgentEnabled": false,
  "cameraEnabled": false,
  "videoReceiveEnabled": false,
  "recordingEnabled": true,
  "captureModes": ["audio"]
}
```

---

## 6. S3/R2 Configuration

### 6.1 Current S3/MinIO Support

Vexa already supports S3-compatible storage:
- Backend: `local`, `minio`, `s3`
- Config via env vars: `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`

### 6.2 R2 Configuration

For Cloudflare R2:
```bash
STORAGE_BACKEND=s3
S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
S3_BUCKET=roosterx-recordings
S3_ACCESS_KEY=<r2-access-key>
S3_SECRET_KEY=<r2-secret-key>
```

**Recording storage path format:**
```
recordings/<user_id>/<recording_id>/<session_uid>.wav
```

### 6.3 Recording Upload

**Current flow:**
1. Bot records audio to local file (WAV/WebM)
2. On meeting end, uploads multipart to meeting-api
3. Meeting-api saves to configured storage backend

**For audio-only:**
- Format: WAV or WebM (configurable)
- Upload: After meeting ends (not streaming)
- Retention: Configurable via env var

---

## 7. Known Issues & Limitations

### 7.1 Mac M5 Specific

| Issue | Status | Workaround |
|-------|--------|------------|
| MS Edge not available on ARM64 | ✅ Known | Teams uses Chromium fallback |
| Docker Desktop VM overhead | ✅ Known | RAM ~10-20% higher than Linux |
| `--in-process-gpu` vs SwiftShader | ✅ Working | No separate GPU process |

### 7.2 Production Limitations

| Issue | Severity | Plan |
|-------|----------|------|
| `max_per_user` concurrency not enforced | ⚠️ Medium | TODO: Implement in runtime-api |
| Per-user concurrency limit (`max_concurrent_bots`) | ⚠️ Medium | TODO: Enforce at runtime-api level |
| Redis single-node (no HA) | ⚠️ Low | Acceptable for v1 |
| No rate limiting on admin-api | ⚠️ Low | Acceptable for v1 |

### 7.3 Zoom (Future)

- Vexa's Zoom Web path uses Playwright (not native SDK)
- For enterprise Zoom with reCAPTCHA bypass, consider CloakBrowser or custom solution
- Plan: Handle Zoom in separate version/fork

---

## 8. Cost Estimates (100 Concurrent Bots)

### 8.1 Hetzner Cloud (Recommended)

| Component | Spec | Qty | Cost/Month |
|-----------|------|-----|------------|
| Worker nodes (CX32, 4C/8G) | 5 bot/node | 20 | €254 |
| Control plane (CX32) | API services | 2 | €25 |
| Load Balancer | Hetzner LB | 1 | €6 |
| Object Storage | 1TB | — | €5 |
| Block storage (DB) | 100GB | — | €5 |
| **Total** | | | **~€295 (~$320)** |

### 8.2 Break-Even vs Vexa API

| Metric | Value |
|--------|-------|
| Vexa API cost | $0.30/bot/hour |
| Self-host cost | ~$320/month (fixed, 100 bot capacity) |
| Break-even | ~1,067 bot-hours/month |
| At 8h/day, 22 days | 6+ concurrent bots → self-host cheaper |

---

## 9. Comparison: meeting-bot vs Vexa

### meeting-bot (screenappai)

**Pros:**
- CloakBrowser (C++ stealth) — undetectable
- Simple codebase (14 files)
- MIT license
- ffmpeg audio — high quality

**Cons:**
- `maxConcurrentJobs: 1` — no built-in scale
- No orchestrator — need build yourself
- No recording upload service
- No multi-tenancy
- No K8s/Helm

### Vexa (This Fork)

**Pros:**
- Production-ready infrastructure (K8s, Helm, runtime-api)
- 1 container = 1 bot (proper isolation)
- Recording + upload service built-in
- Multi-tenant (users, tokens)
- Auto-cleanup, lifecycle management

**Cons:**
- Over-engineered for simple use case (10+ services)
- Standard Playwright stealth (not CloakBrowser)
- Monorepo complexity
- ARM64 support requires fixes (already done)

---

## 10. Next Steps for Next Agent

### Priority 1: Create Fork & Sync

```bash
# Create fork on GitHub (or locally)
git clone https://github.com/roosterx/roosterx-vexa.git
cd roosterx-vexa

# Apply current changes from vexa
git checkout fix/apple-silicon-arm64-support
# Or cherry-pick the 7 files changed
```

### Priority 2: Strip Services

1. **docker-compose.yml**: Remove transcription-service, tts-service, agent-api, mcp, dashboard
2. **Helm chart**: Same removals
3. **vexa-bot code**: Remove transcription, segment-publisher, TTS imports
4. **meeting-api**: Remove dashboard routes, transcription endpoints
5. **Dockerfile**: Remove VNC/SSH if not needed

### Priority 3: Configure R2

```bash
# .env
STORAGE_BACKEND=s3
S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
S3_BUCKET=roosterx-recordings
S3_ACCESS_KEY=xxx
S3_SECRET_KEY=xxx
```

### Priority 4: Test

```bash
make build
make up
# Create bot via API
# Verify recording appears in R2 bucket
```

### Priority 5: Production Deploy

```bash
# K8s
helm install roosterx deploy/helm/charts/vexa \
  -f values-production.yaml \
  --namespace roosterx
```

---

## 11. Files Changed in This Session

```
 services/vexa-bot/Dockerfile                  |  2 +-
 services/vexa-bot/core/Dockerfile            |  7 ++++++-
 deploy/compose/Makefile                       |  4 ++--
 tests3/lib/hot-iterate.sh                     |  2 +-
 services/vexa-bot/run-zoom-bot.sh             |  1 -
 notes/infra-plan-audio-only-100-bots.md      | 12 +++++++++++
```

---

## 12. Key Contacts & Resources

- **Original repo:** https://github.com/vexaai/vexa
- **License:** Apache 2.0
- **Branch:** `fix/apple-silicon-arm64-support`
- **Infra plan:** `notes/infra-plan-audio-only-100-bots.md` (this repo)
- **DockerHub images:** `vexaai/vexa-bot`, etc.

---

**Prepared for next agent session. Please read all sections before making changes.**

---

## 13. IMPLEMENTED — Audio-Only Strip (2026-06-02)

Strategy chosen: **gate, do not delete**. Service source stays in `services/`
for upstream-merge ability; stripped features are disabled via flags/values and
the built images + runtime are slimmed. Deploy target: **full distributed
chart** (compose + `deploy/helm/charts/vexa`), container-per-bot, 100-bot scale.
Zoom Web + native SDK kept. VNC/SSH moved out of the default image build.

### 13.1 Corrections to earlier sections (verified against code)

- `deploy/compose/docker-compose.yml` only ever contained `mcp`, `dashboard`,
  `tts-service` from the strip list (transcription-service / agent-api /
  calendar-service / telegram-bot were already absent or commented).
- **Recordings do NOT upload to R2 from the bot.** `RecordingService.upload()/
  uploadChunk()` POST multipart over HTTP to meeting-api
  (`/internal/recordings/upload`); meeting-api writes to object storage via
  boto3 (`storage.py`). **R2 credentials live in meeting-api, not the bot.**
- `s3-sync.ts` + the bot's `awscli` are only for authenticated browser-userdata
  persistence (`authenticated && userdataS3Path`) — kept, it enables logged-in
  joins; unrelated to recording upload.
- S3/R2 env var names are `S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_SECURE`, `AWS_REGION` (the earlier
  `S3_ACCESS_KEY`/`S3_SECRET_KEY` names were wrong).

### 13.2 Changes made

| Area | File | Change |
|------|------|--------|
| Unblock boot | `services/api-gateway/main.py` | `MCP_URL` + `TRANSCRIPTION_COLLECTOR_URL` no longer mandatory at startup |
| Gate transcript | `services/meeting-api/meeting_api/config.py`, `main.py` | `TRANSCRIPTION_ENABLED` (default false) → skips xgroup_create + 3 collector tasks; `/readyz` still goes Ready |
| Audio-only default | `services/meeting-api/meeting_api/meetings.py` | `transcribe` defaults off (`TRANSCRIBE_DEFAULT` env); recording on, captureModes=audio |
| Compose | `deploy/compose/docker-compose.yml` | removed `mcp`/`dashboard`/`tts-service` + `tts-voices` volume; dropped dead service URLs; added `TRANSCRIPTION_ENABLED` + S3/R2 env passthrough; `POST_MEETING_HOOKS` default empty |
| Bot profile | `services/runtime-api/profiles.yaml` | removed transcription env injection into bots |
| Image slim | `services/vexa-bot/Dockerfile`, `core/Dockerfile` | VNC/SSH/socat/etc behind `--build-arg INSTALL_DEBUG_TOOLS=true` (default lean) |
| Runtime slim | `services/vexa-bot/core/entrypoint.sh` | meeting-mode VNC gated behind `ENABLE_VNC` (default off) |
| Build | `deploy/compose/Makefile` | IMAGES = core 4 only; `build` drops dashboard/lite; added `build-bot-image-debug` |
| Env template | `deploy/env-example` | transcription optional; R2 block + `TRANSCRIPTION_ENABLED`/`TRANSCRIBE_DEFAULT` |
| Helm | `deploy/helm/charts/vexa/values.yaml`, `deployment-meeting-api.yaml`, `deployment-api-gateway.yaml` | `ttsService`/`mcp` disabled; meeting-api gets `TRANSCRIPTION_ENABLED` + S3/R2 env; `MCP_URL` empty when mcp off (was hardcoding the dead mcp URL); transcription env removed from embedded profiles |

### 13.3 Run it (R2, compose)

```bash
# .env (copy from deploy/env-example), then set:
STORAGE_BACKEND=s3
S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
S3_BUCKET=roosterx-recordings
S3_SECURE=true
AWS_ACCESS_KEY_ID=<r2-key>
AWS_SECRET_ACCESS_KEY=<r2-secret>
AWS_REGION=auto
TRANSCRIPTION_ENABLED=false

cd deploy/compose && make build && make up
# create a bot via API → after it leaves, recording lands in the R2 bucket.
```

Debug image (watch the browser): `make build-bot-image-debug`, run the bot
container with `ENABLE_VNC=true` (noVNC on 6080).

### 13.4 Known residuals (consequence of gate-not-delete)

- Bot image still ships transcription/VAD npm deps (`onnxruntime-node`,
  `@jjhbw/silero-vad`, ~30 MB) and compiled-but-unused TS (transcription
  pipeline, tts/chat/screen). They never run when `transcribeEnabled=false`.
  To slim further, hard-delete those modules + deps (breaks easy upstream merge).
- `meeting-api` still carries the transcript collector code (just not started)
  and the `Transcription` DB table (unused). Harmless.
- `TTS_SERVICE_URL` / empty `TRANSCRIPTION_SERVICE_URL` still render in helm —
  harmless dangling strings; nothing dials them on the audio-only path.

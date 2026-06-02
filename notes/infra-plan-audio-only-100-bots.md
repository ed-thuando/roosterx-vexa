# Infra Plan: Audio-Only Recording, 100 Meetings Concurrent

**Date**: 2026-06-01
**Objective**: Deploy Vexa for 100 concurrent meeting bots, audio recording only (no transcription, no video, no voice agent), optimized for cost with horizontal scaling.

---

## 1. What We Can Drop

Audio-only recording means large savings:

| Capability | What's Skipped | Savings |
|-----------|---------------|---------|
| **Transcription** | Whisper GPU service, HTTP audio uploads from bot | 0 GPUs needed, ~10-15% CPU per bot |
| **Voice Agent** (`voiceAgentEnabled: false`) | TTS service, virtual mic, Redis voice-event pub/sub | ~5-10% CPU, ~100Mi RAM |
| **Video IN** (`videoReceiveEnabled: false`) | Incoming video track decode + rendering | **~87% CPU** (video block script) |
| **Video OUT** (`cameraEnabled: false`) | Canvas-based virtual camera rendering | ~5% CPU |

---

## 2. Per-Bot Resource Profile

### Current default (`meeting` profile from `services/runtime-api/profiles.yaml`)

```yaml
cpu_request: "1000m"
cpu_limit: "1500m"
memory_request: "1100Mi"
memory_limit: "2560Mi"
shm_size: 2147483648  # 2GB
```

**Measured p95 from load test (19 bots, audio-only config)**:
- CPU actual: ~780m
- Memory actual: ~977Mi

### Proposed custom profile (`meeting-recorder`)

```yaml
# services/runtime-api/profiles.yaml
meeting-recorder:
  image: "${BROWSER_IMAGE}"
  command: ["/app/vexa-bot/entrypoint.sh"]
  working_dir: "/app/vexa-bot"
  resources:
    cpu_request: "600m"
    cpu_limit: "1000m"
    memory_request: "800Mi"
    memory_limit: "1280Mi"
    shm_size: 2147483648
  idle_timeout: 900        # 15 min auto-cleanup
  auto_remove: true
```

### Bot config payload (POST /bots)

```json
{
  "platform": "google_meet",
  "meeting_url": "https://meet.google.com/xxx-xxxx-xxx",
  "voice_agent_enabled": false,
  "camera_enabled": false,
  "video_receive_enabled": false,
  "transcribe_enabled": false,
  "recording_enabled": true,
  "bot_name": "Recorder Bot"
}
```

### Per-node capacity (Hetzner CX32, 4 vCPU / 8 GB RAM)

```
CPU: 4 cores / 0.6 request  = 6.6 → 6 bots
RAM: 8 GB   / 1.28 limit    = 6.25 → 6 bots
Practical (headroom):       = 5 bots/node
```

```
100 bots / 5 bots per node = 20 worker nodes
```

---

## 3. Recommended Infrastructure

### Architecture

```
                        Internet
                           │
┌──────────────────────────▼──────────────────────────────┐
│                  Load Balancer (Hetzner LB)               │
│                       €5.90/month                        │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                Control Plane — K3s cluster               │
│                 2x CX32 (4C/8G) — €25.40                 │
│                                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │ API GW   │ │ Meeting  │ │ Runtime  │ │ Admin    │   │
│  │          │ │ API      │ │ API      │ │ API      │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │
│  ┌──────────┐ ┌──────────┐                              │
│  │ Redis    │ │PostgreSQL│  (block storage, 100GB)      │
│  └──────────┘ └──────────┘                              │
└─────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│               Worker Pool — K3s agents                   │
│               20x CX32 (4C/8G) — €254.00                 │
│                                                          │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐              │
│  │ Bot │ │ Bot │ │ Bot │ │ Bot │ │ Bot │  ×5 per node  │
│  │Pod  │ │Pod  │ │Pod  │ │Pod  │ │Pod  │              │
│  │     │ │     │ │     │ │     │ │     │              │
│  │Chro-│ │Chro-│ │Chro-│ │Chro-│ │Chro-│              │
│  │mium │ │mium │ │mium │ │mium │ │mium │              │
│  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘              │
│     │       │       │       │       │                   │
│     └───────┴───────┴───────┴───────┘                   │
│                      │                                  │
│              Audio WAV → local disk → batch upload      │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│            Object Storage (Hetzner, 1TB)                 │
│                      €5.00/month                         │
│                                                          │
│        recordings/<user_id>/<recording_id>/              │
└─────────────────────────────────────────────────────────┘
```

### Monthly Cost Breakdown

| Component | Spec | Qty | Unit Price | Total |
|-----------|------|-----|------------|-------|
| Worker nodes | CX32 (4C/8G, 80GB SSD) | 20 | €12.70 | **€254.00** |
| Control plane nodes | CX32 (4C/8G, 80GB SSD) | 2 | €12.70 | **€25.40** |
| Load Balancer | Hetzner LB | 1 | €5.90 | **€5.90** |
| Object Storage | 1TB | — | €5.00 | **€5.00** |
| Block Storage (DB + Redis) | 100GB | — | €5.00 | **€5.00** |
| **Total Infrastructure** | | | | **~€295** |
| Transcription | Not needed | — | — | **€0** |
| GPU | Not needed | — | — | **€0** |
| **GRAND TOTAL** | | | | **~$320/month** |

> Cost per bot per month: ~$3.20

---

## 4. Vexa API ($0.30/h) vs Self-host Comparison

### Break-even Point

```
Self-host: $320/month (fixed, max 100 concurrent bots)
API:       $0.30/bot/hour (unlimited scale)

Break-even = $320 / $0.30 = 1,067 bot-hours/month
```

**Below 1,067 bot-hours/month → API is cheaper. Above → Self-host is cheaper.**

### Scenario: 8h/day, 22 working days/month

| Concurrent Bots | Bot-hours/month | API Cost | Self-host | Recommendation |
|----------------|-----------------|----------|-----------|----------------|
| 2 | 352 | $106 | $320 | **API** |
| 3 | 528 | $158 | $320 | **API** |
| 5 | 880 | $264 | $320 | **API** |
| **6** | **1,056** | **$317** | $320 | ≈ Break-even |
| 7 | 1,232 | $370 | $320 | **Self-host** |
| 10 | 1,760 | $528 | $320 | **Self-host** |
| 15 | 2,640 | $792 | $320 | **Self-host** |
| 20 | 3,520 | $1,056 | $320 | **Self-host** |
| 50 | 8,800 | $2,640 | $320 | **Self-host** |
| 100 | 17,600 | $5,280 | $320 | **Self-host** |

### Scenario: 4h/batch, 2 batches/day, 22 days

| Concurrent Bots | Bot-hours/month | API Cost | Self-host | Recommendation |
|----------------|-----------------|----------|-----------|----------------|
| 10 | 880 | $264 | $320 | **API** |
| 13 | 1,144 | $343 | $320 | **Self-host** |
| 20 | 1,760 | $528 | $320 | **Self-host** |

### Scenario: 24/7 continuous

| Concurrent Bots | Bot-hours/month | API Cost | Self-host | Recommendation |
|----------------|-----------------|----------|-----------|----------------|
| 1 | 720 | $216 | $320 | **API** |
| **2** | **1,440** | **$432** | $320 | **Self-host** |
| 5 | 3,600 | $1,080 | $320 | **Self-host** |

### Visual Summary

```
Bot-hours/month →
  0         500       1,067      2,000       5,000+
  │          │          │          │           │
  │◄ API IS CHEAPER ──►│◄── SELF-HOST IS CHEAPER ──────►│
  │                     │                               │

Thresholds by scenario:
  ┌──────────────────────────────────┬──────────────────────┐
  │ Scenario                          │ Switch at            │
  ├──────────────────────────────────┼──────────────────────┤
  │ 1 bot 24/7                       │ Never (max 720h/mo)  │
  │ 2+ bots 24/7                     │ 2 bots               │
  │ 8h/day × 22 days                 │ 6+ concurrent        │
  │ 4h × 2 batches/day × 22 days    │ 13+ concurrent       │
  │ Any pattern                      │ 1,067 bot-hours/mo   │
  └──────────────────────────────────┴──────────────────────┘
```

### For 100 Concurrent Meetings (Your Use Case)

| | Monthly Cost |
|---|---|
| **Vexa API** (8h/day, 22d) | **$5,280** |
| **Self-host** (Hetzner, 20 nodes) | **$320** |
| **Savings** | **$4,960 (94% cheaper)** |

---

## 5. When to Use API vs Self-host

| Use API When | Use Self-host When |
|-------------|-------------------|
| **< 6 concurrent bots** (business hours) | **6+ concurrent bots** (business hours) |
| **< 2 bots 24/7** | **2+ bots 24/7** |
| **< ~1,000 bot-hours/month** | **> ~1,000 bot-hours/month** |
| MVP / POC phase | Stable, predictable scale |
| Spiky / unpredictable traffic | Steady traffic |
| Zero ops overhead needed | Data sovereignty required |
| No cloud expertise in team | DevOps capacity available |

---

## 6. Further Optimization Ideas

1. **S3 batch upload**: Write WAV to local disk, upload in chunks post-meeting (not real-time) → ~5-10% less CPU.
2. **Chromium headless**: Default already, no Xvfb needed → saves ~50Mi/bot.
3. **K3s instead of full K8s**: Lighter, runs on CX32 control plane without extra nodes.
4. **Off-peak scale**: If meetings are daytime only, cluster-autoscaler drops worker nodes to 0 overnight → cost drops to ~€100/month (8h utilization).
5. **Spot/preemptible workers**: If using cloud, spot instances save 60-80% for worker pool with fallback on-demand.

---

## 7. Implementation Checklist

- [ ] Create `meeting-recorder` profile in `services/runtime-api/profiles.yaml`
- [ ] Set profile override via `PROFILES_PATH` env var
- [ ] Deploy K3s control plane (2x CX32)
- [ ] Deploy 20 worker nodes with K3s agent
- [ ] Install Vexa Helm chart (`deploy/helm/charts/vexa`)
- [ ] Configure RBAC for runtime-api pod creation
- [ ] Set up Hetzner Object Storage for recordings
- [ ] Set `transcribeEnabled: false` default in bot config
- [ ] Set `voiceAgentEnabled: false` default
- [ ] Configure cluster-autoscaler for off-peak scale-down
- [ ] Set up monitoring (Grafana + Prometheus)
- [ ] Run load test: 5 → 20 → 50 → 100 concurrent bots

---

## 8. References

- `services/runtime-api/profiles.yaml` — Container profiles
- `services/vexa-bot/core/src/index.ts` — Bot startup and service initialization
- `services/vexa-bot/core/src/services/screen-content.ts` — `getVideoBlockInitScript()`
- `services/vexa-bot/README.md` — Bot capabilities and flags
- `docs/scaling.mdx` — Per-bot resources, capacity estimation
- `deploy/helm/` — Helm charts for K8s deployment
- `deploy/README.md` — Deployment options overview

---

## 9. Vexa vs meeting-bot (screenappai) — Full Comparison

### Tổng quan

| | **meeting-bot** (screenappai) | **Vexa** |
|---|---|---|
| **Bản chất** | 1 process = 1 bot ghi âm | Nền tảng đầy đủ: orchestrator + API + dashboard |
| **License** | MIT | Apache 2.0 |
| **Ngôn ngữ** | TypeScript (monolith, ~14 file) | Python (microservices) + Rust |
| **Phiên bản** | 1.2.4 | 0.10.6 |
| **Repo** | `/Users/edward/projects/agents/meeting-bot` | `/Users/edward/projects/agents/vexa` |

### Tính năng

| | meeting-bot | Vexa |
|---|---|---|
| Record audio | ✅ ffmpeg AAC | ✅ browser MediaRecorder |
| Transcribe realtime | ❌ | ✅ Whisper + diarization |
| Voice agent (TTS + speak) | ❌ | ✅ |
| Interactive (chat, screen share) | ❌ | ✅ |
| MCP server (Claude/Cursor) | ❌ | ✅ 17 tools |
| Dashboard UI | ❌ | ✅ Next.js |
| Multi-tenant | ⚠️ Basic (passthrough teamId) | ✅ Users, scoped tokens, isolated containers |
| Silence detection | ✅ PulseAudio parec + ffmpeg | ✅ |
| Auto-leave (lone/everyone left) | ✅ | ✅ |
| Webhook notification | ✅ | ✅ |
| Redis message queue | ✅ BLPOP/RPUSH | ✅ Pub/sub + streams |
| Zoom reCAPTCHA bypass | ✅ CloakBrowser + 2Captcha + PWA | ⚠️ Web client or SDK only |

### Kiến trúc bot join meeting

| | meeting-bot | Vexa |
|---|---|---|
| Spawn bot | `node index.js` → 1 process cố định | Meeting API → Runtime API → Docker/K8s container |
| Concurrent limit | **1 bot** (`maxConcurrentJobs: 1`) | Không giới hạn (scale theo container) |
| Browser engine | **CloakBrowser** (48 C++ patches) | Chromium chuẩn + puppeteer-extra-stealth |
| Audio capture | ffmpeg PulseAudio / avfoundation | PulseAudio (Zoom) / browser MediaRecorder |
| Upload model | Multipart sau meeting kết thúc | Chunked 15s realtime lên S3/MinIO |
| Headless mode | ✅ Có | ❌ Luôn headful + Xvfb |

### Deploy & Scale

| | meeting-bot | Vexa |
|---|---|---|
| Docker Compose | ✅ 1 service | ✅ Full stack |
| K8s / Helm | ❌ Chưa có (trong plan) | ✅ Helm chart sẵn |
| Auto-scale | ❌ 1 bot cố định | ✅ HPA + cluster-autoscaler |
| Production-readiness | Single app, chưa test ở scale | Monorepo production-grade, stage machine |

### Điểm mạnh riêng

**meeting-bot**:
- **Stealth vượt trội**: CloakBrowser 48 C++ patches (canvas, WebGL, audio, GPU) — undetectable bởi JS-based bot detection
- **Zoom reCAPTCHA bypass**: 4-layer: CloakBrowser + human-like interaction + 2Captcha + PWA endpoint
- **Đơn giản**: 1 repo, 1 Dockerfile, dễ hiểu, dễ fork
- **ffmpeg audio**: Chất lượng AAC native, silence detection qua parec

**Vexa**:
- **Scale**: Orchestrator spawn container riêng cho từng bot → scale ngang thực sự
- **Transcription realtime**: meeting-bot không có
- **Ecosystem**: Dashboard, MCP server, multi-tenancy, scoped tokens
- **Production-ready deploy**: Helm chart, managed services, quy trình release chặt chẽ

### Với bài toán 100 meeting audio-only

| | meeting-bot | Vexa |
|---|---|---|
| Cần code thêm | Redis consumer + K8s deploy + Helm + HPA | Có sẵn |
| Thời gian ship | 2-4 tuần | 1-2 ngày |
| Chi phí infra | ~€290/tháng (20 node) | ~€290/tháng (20 node) |
| Stealth risk | Thấp (CloakBrowser) | Trung bình (JS-level stealth) |
| Tương lai (transcription, agent) | Phải tự build | Bật flag là có |

### Khuyến nghị

| Dùng meeting-bot nếu | Dùng Vexa nếu |
|---|---|
| Chỉ cần record audio → upload | Sẽ cần transcription / voice agent sau này |
| Sợ bị detect bot (cần C++ stealth) | Cần scale ngang ngay (Helm + K8s có sẵn) |
| Đủ DevOps để tự build K8s/HPA | Cần multi-user, dashboard, scoped tokens |
| Muốn đơn giản tối đa (1 process) | Muốn production-grade không build infra |

---

## 10. Chromium Performance: Vexa vs meeting-bot

### 10.1 Browser Launch Args Comparison

| Flag | meeting-bot | Vexa |
|---|---|---|
| `--no-sandbox` | ✅ | ✅ |
| `--disable-setuid-sandbox` | ✅ | ✅ |
| `--disable-web-security` | ✅ | ✅ |
| `--disable-gpu` | | ✅ |
| `--in-process-gpu` | | ✅ |
| `--use-gl=angle` | ✅ | |
| `--use-angle=swiftshader` | ✅ | |
| `--use-fake-ui-for-media-stream` | Teams only | ✅ all bots |
| `--use-fake-device-for-media-stream` | Teams only | |
| `--use-file-for-fake-video-capture=/dev/null` | | ✅ all bots |
| `--enable-usermedia-screen-capturing` | ✅ | |
| `--allow-http-screen-capture` | ✅ | |
| `--auto-accept-this-tab-capture` | ✅ | |
| `--enable-audio-service-out-of-process` | ✅ | |
| `--autoplay-policy=no-user-gesture-required` | ✅ | |
| `--disable-features=IsolateOrigins,site-per-process` | | ✅ |
| `--disable-features=VizDisplayCompositor` | | ✅ |
| `--disable-blink-features=AutomationControlled` | Zoom only | ✅ auth + session |
| `--disable-site-isolation-trials` | | ✅ |

### 10.2 Per-Bot Resource Comparison (Audio-Only, Measured)

```
                           meeting-bot          Vexa
                           (hiện tại)           (hiện tại)

GPU strategy               riêng process        --disable-gpu
                           SwiftShader ↓        kill GPU hoàn toàn
                           357% CPU riêng       0% GPU

Video người khác           decode hết           BLOCK (track.enabled=false)
                           ngốn CPU             -87% CPU

Stealth                     ★★★★★ C++           ★★★ JS-level
                           undetectable          có fingerprint

CPU/bot (đo thực)          ~4.4 cores           ~1.15 cores (Zoom Web)
RAM/bot (đo thực)          ~1,240 MB            ~977 MB
Bot/node (CX32 4C/8G)      2-3 bot              5-6 bot
100 bot cần                34-50 node            20 node
```

### 10.3 Tối ưu meeting-bot: Giữ CloakBrowser + giảm CPU

#### ✅ NÊN LÀM: Thêm `--in-process-gpu`

```typescript
// src/lib/chromium.ts — meeting-bot, thêm 1 dòng:
'--use-gl=angle',
'--use-angle=swiftshader',
'--in-process-gpu',          // ← THÊM DÒNG NÀY
```

**Tại sao được**: `--in-process-gpu` gộp GPU process vào renderer process — pipeline WebGL/canvas giống hệt, CloakBrowser C++ patches vẫn chạy. Chỉ khác là không còn process riêng.

**Tiết kiệm**: ~3.6 cores/bot (357% CPU gpu-process biến mất)

#### ❌ KHÔNG ĐƯỢC LÀM: `--disable-gpu`

```typescript
// SAI — phá stealth CloakBrowser:
'--disable-gpu',       // Tắt GPU → C++ patches bị bypass
'--in-process-gpu',    // Vô dụng vì GPU đã tắt
```

CloakBrowser vá 48 điểm trong C++ ở tầng **GPU/WebGL/canvas/audio rendering pipeline**. `--disable-gpu` bypass toàn bộ pipeline đó → mất hết stealth. CloakBrowser có các flag `--fingerprint-gpu-vendor`, `--fingerprint-gpu-renderer` để kiểm soát giá trị spoof — chứng tỏ GPU path là một phần của cơ chế stealth.

#### ✅ NÊN LÀM: Thêm video block script (từ Vexa)

```javascript
// Inject vào page context, độc lập với GPU flags
window.RTCPeerConnection = new Proxy(window.RTCPeerConnection, {
  construct(target, args) {
    const pc = new target(...args);
    pc.addEventListener('track', (e) => {
      if (e.track.kind === 'video') {
        setTimeout(() => { e.track.enabled = false; }, 0);
      }
    });
    return pc;
  }
});
```

**Tiết kiệm**: ~87% CPU (không decode video từ người khác)

### 10.4 Kết quả dự kiến sau tối ưu

```
                    meeting-bot     meeting-bot     Vexa
                    (hiện tại)      (đã tối ưu)    (hiện tại)

GPU strategy        riêng process   in-process      --disable-gpu
                    357% CPU riêng   gộp vào render  0 GPU

Video người khác    decode hết      BLOCK           BLOCK
                    tốn CPU         -87% CPU        -87% CPU

Stealth             ★★★★★ C++       ★★★★★ C++       ★★★ JS
                    undetectable    undetectable     detectable

CPU/bot (dự kiến)   ~4.4 cores      ~1.5 cores      ~1.15 cores
RAM/bot             ~1,240 MB       ~1,100 MB       ~977 MB
Bot/node (CX32)     2-3             5-6             5-6
100 bot cần node    34-50           20              20
```

### 10.5 Tổng kết Chromium

| | meeting-bot tối ưu | Vexa |
|---|---|---|
| **Hiệu năng** | ~1.5 core/bot | ~1.15 core/bot |
| **Stealth** | ★★★★★ C++ undetectable | ★★★ JS-level |
| **Khác biệt** | +0.35 core/bot (SwiftShader duy trì cho stealth) | Base |
| **Đánh đổi** | 0.35 core đổi lấy C++ stealth — đáng giá | Đủ dùng nếu platform không detect JS stealth |

> **Kết luận**: Tối ưu meeting-bot với `--in-process-gpu` + video block → gần bằng Vexa về hiệu năng nhưng vượt trội về stealth. Với 100 bot, chênh lệch chỉ ~7 node (20 vs 27 node CX32, ~€90/tháng) — cái giá nhỏ cho C++ undetectable.

---

## 11. Real Measurement — Mac M5 (ARM64), Google Meet, Audio-Only

### Test Setup

- **Hardware**: Mac M5, 16 GB RAM, Docker Desktop
- **Image**: `vexa-bot:arm64-test` (native ARM64, branch `fix/apple-silicon-arm64-support`)
- **Meeting**: Google Meet `yhg-jiac-bbs`
- **Config**: `transcribeEnabled: false`, `voiceAgentEnabled: false`, `cameraEnabled: false`, `videoReceiveEnabled: false`, `recordingEnabled: false`
- **Date**: 2026-06-01

### 11.1 Container-Level Results (Active Meeting, Audio Capture Disabled)

| Metric | Measured |
|--------|----------|
| **CPU** | **~0.45 cores** (45% Docker) |
| **RAM** | **1.09 GiB** |
| **GPU processes** | **0** (confirmed: `--disable-gpu --in-process-gpu`) |
| **PIDS** | 139 |

### 11.2 Chromium Process Breakdown

| Process | RSS | % of Container |
|---------|-----|---------------|
| Renderer (Meet UI + SwiftShader) | 926 MB | 85% |
| Browser main | 317 MB | 29% |
| Network service | 116 MB | 11% |
| Audio service | 86 MB | 8% |
| Zygote × 2 | 116 MB | 11% |
| Crashpad × 2 | 5 MB | — |

### 11.3 Non-Chromium Overhead

| Process | RSS |
|---------|-----|
| Node.js (bot logic) | 103 MB |
| Xvfb (1920×1080) | 95 MB |
| Fluxbox (window manager) | 14 MB |
| PulseAudio | 13 MB |
| VNC + websockify (noVNC) | 49 MB |
| **Total overhead** | **~280 MB** |

### 11.4 Chrome Flags in Effect

```
--disable-gpu            # No hardware GPU — confirmed: 0 gpu-process
--in-process-gpu          # GPU work collapsed into renderer
--disable-features=VizDisplayCompositor,IsolateOrigins,site-per-process
--disable-site-isolation-trials
--disable-blink-features=AutomationControlled
--use-file-for-fake-video-capture=/dev/null
--use-fake-ui-for-media-stream
--no-sandbox --disable-setuid-sandbox
--incognito
```

---

## 12. Real Measurement — 3 Bots Concurrent (Mac M5, ARM64)

### Test Setup

- **Hardware**: Mac M5, 16 GB RAM, Docker Desktop
- **Image**: `vexa-bot:arm64-test`
- **Config**: `transcribeEnabled: false`, `voiceAgentEnabled: false`, `cameraEnabled: false`, `videoReceiveEnabled: false`, `recordingEnabled: false`
- **Bots**:
  - Bot 1: Google Meet `ong-tktg-oio`
  - Bot 2: Google Meet `inh-isaw-mre`
  - Bot 3: Microsoft Teams `9388680142360`
- **Date**: 2026-06-02

### 12.1 Per-Bot Results (All Active)

| Bot | Platform | CPU | RAM | PIDs | Status |
|-----|----------|-----|-----|------|--------|
| **Bot 1** | Google Meet | **72%** | **1.14 GiB** | 141 | Active |
| **Bot 2** | Google Meet | **156%** | **1.24 GiB** | 143 | Active |
| **Bot 3** | Microsoft Teams | **38-42%** | **922 MB** | 151 | Active |

### 12.2 Totals

| Metric | Value |
|--------|-------|
| **Total CPU** | **~2.7 cores** (266-270%) |
| **Total RAM** | **~3.3 GiB** |
| **Total PIDs** | 435 |

### 12.3 Per-Platform Comparison

| Platform | CPU active | RAM active | Efficiency |
|----------|-----------|------------|------------|
| Google Meet | 72-156% | 1.14-1.24 GiB | Medium |
| **Microsoft Teams** | **38-42%** | **922 MB** | **Best** |

- Teams uses **lowest RAM** (922 MB vs 1.14-1.24 GiB)
- Teams uses **lowest-mid CPU** (38-42%)
- Chromium renderer in Teams: 734MB RSS, 34% CPU (caption polling + audio routing)

### 12.4 Capacity on Mac M5

```
Mac M5 (8 cores, 16 GB RAM):
  3 bot concurrent: 2.7 cores + 3.3 GiB
  Remaining:      ~5.3 cores + ~12.7 GiB
  → Can run ~5-6 more bots on this machine
```

### 12.5 Notes

- All bots native ARM64, no Rosetta/QEMU
- Bot 2 (GMeet) had higher CPU (156%) — possibly more participants or heavier UI
- Teams bot has `recordingEnabled: false` — with recording, CPU would be higher
- Video block active on all 3 (`videoReceiveEnabled: false`)

---

## 13. Cross-Platform Comparison: Linux vs Mac M5

### User's Linux Data (Original code, recording ON)

**Infrastructure baseline (no bots):**

| Service | RAM (MiB) | CPU |
| :--- | :--- | :--- |
| Redis | 3.43 | ~0.25% |
| Postgres | 37.75 | ~2.85% |
| Dashboard | 39.96 | ~0.00% |
| API Gateway | 45.04 | ~0.18% |
| MCP | 51.81 | ~0.23% |
| Runtime API | 54.84 | ~0.23% |
| Admin API | 63.27 | ~0.17% |
| MinIO | 81.32 | ~0.06% |
| Meeting API | 107.90 | ~0.20% |
| TTS Service | 387.50 | ~0.30% |
| **Total infra** | **~872 MiB** | **~5%** |

**3 Bots concurrent (recording ON, transcription OFF):**

| Metric | Bot A (GMeet) | Bot B (GMeet) | Bot C (Teams) |
| :--- | :--- | :--- | :--- |
| **CPU Mean** | 95.28% | 113.07% | 59.90% |
| **RAM Mean** | 1,168.3 MiB | 588.6 MiB | 824.9 MiB |
| **RAM Peak** | 1,284.98 MiB | 650.44 MiB | 939.18 MiB |
| **PIDs** | ~149 | ~143 | ~143 |

### Mac M5 Data (ARM64 fix, recording OFF)

| Metric | Bot 1 (GMeet) | Bot 2 (GMeet) | Bot 3 (Teams) |
| :--- | :--- | :--- | :--- |
| **CPU** | 72% | 156% | 38-42% |
| **RAM** | 1,138 MiB | 1,238 MiB | 922 MiB |
| **PIDs** | 141 | 143 | 151 |

### Side-by-Side Comparison

| | Linux (recording ON) | Mac M5 (recording OFF) | Diff |
|---|---|---|---|
| **GMeet Bot A** | CPU 95%, RAM 1,168 MiB | CPU 72%, RAM 1,138 MiB | **-24% CPU**, -3% RAM |
| **GMeet Bot B** | CPU 113%, RAM 589 MiB | CPU 156%, RAM 1,238 MiB | +38% CPU, **+110% RAM** |
| **Teams** | CPU 60%, RAM 825 MiB | CPU 38-42%, RAM 922 MiB | **-30% CPU**, +12% RAM |

### Key Differences Explained

1. **Recording ON vs OFF**: Linux bots had `recordingEnabled: true` (webm), Mac bots had `recordingEnabled: false`. Recording adds ~20-30% CPU for audio pipeline
2. **Bot B RAM anomaly on Linux**: 589 MiB is unusually low — likely due to shared Chrome cache/memory deduplication when 2 GMeet bots run on same Linux host. Mac M5 Docker VM isolates containers more strictly
3. **Teams consistent**: Both platforms show Teams uses ~40-60% CPU and ~825-922 MiB RAM
4. **Infrastructure overhead**: Linux infra services add ~872 MiB baseline. Mac M5 Docker Desktop VM overhead not measured separately

### Combined totals (Linux, 3 bots + infra)

| | Value |
|---|---|
| **Infra services** | ~872 MiB RAM, ~5% CPU |
| **3 bots** | ~2,582 MiB RAM, ~268% CPU |
| **Total** | **~3,454 MiB RAM**, **~273% CPU** |

> With recording ON, a 4-core/8GB node can comfortably run 3 concurrent bots. For 100 bots: ~34 nodes (4C/8G) minimum.

### 11.5 Comparison: Measured vs Expected

| | Mac M5 Measured | Vexa Linux p95 | Delta |
|---|---|---|---|
| CPU | **0.45 cores** | 0.78 cores | **-42%** |
| RAM | **1.09 GiB** | 0.98 GiB | +11% |
| GPU process | 0 | 0 | ✓ same |

- CPU thấp hơn 42% so với Linux p95 — một phần do chưa có audio capture pipeline chạy
- RAM cao hơn 11% — có thể do ARM64 Chromium binary hoặc Docker VM overhead trên Mac
- `--disable-gpu --in-process-gpu` hoạt động chính xác trên ARM64: 0 GPU process

### 11.6 Notes

- **Audio capture đang tắt** trong test này (`recordingEnabled: false`) — CPU sẽ tăng khi bật audio pipeline
- Bot chạy native ARM64, không qua Rosetta/QEMU
- MS Edge tự động skip trên aarch64 (Teams support unavailable on ARM64)
- AWS CLI đã cài đúng bản `aarch64` thông qua arch-aware fix

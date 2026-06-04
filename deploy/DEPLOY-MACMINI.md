# Deploy — RoosterX audio-only recorder on a Mac Mini (public via Cloudflare Tunnel)

Audio-only Vexa fork: bots join Google Meet / MS Teams, record audio, upload to
Cloudflare R2. API-only (no web UI). This guide = stable single-host deploy on a
Mac Mini (Apple Silicon / arm64), exposed publicly through a Cloudflare Tunnel so
your backend can call the API.

> Everything here was verified live on Apple Silicon (build → boot → join Meet →
> record → R2). Two host-specific gotchas are baked in below (§9).

---

## 0. What runs

| Container | Role | Host port |
|---|---|---|
| api-gateway | REST entry (auth, rate-limit) | `:8056` (tunnel this) |
| meeting-api | bot lifecycle + recording upload → R2 | internal |
| runtime-api | spawns 1 container per bot (needs docker.sock) | `127.0.0.1:8090` |
| admin-api | users / API tokens | `127.0.0.1:8057` |
| postgres | metadata (meetings, recordings) | `127.0.0.1:5458` |
| redis | state / pub-sub | internal |
| vexa-bot (per meeting) | Playwright browser, audio capture | ephemeral |

Recordings live in **R2**; Postgres holds only metadata. Only `:8056` is meant to
be public.

---

## 1. Prerequisites (on the Mac Mini)

- **Container runtime.** For an always-on headless host use **OrbStack** or
  **Colima** (no GUI login required). Docker Desktop works but must stay logged
  into the macOS GUI session to keep running.
  ```bash
  brew install orbstack            # or: brew install colima docker
  # colima: colima start --cpu 6 --memory 12 --disk 60
  ```
- **git**, **make**, **cloudflared**:
  ```bash
  brew install git cloudflared
  ```
- Sizing: each bot ≈ 1 core + ~1–1.3 GB RAM + 2 GB shm. A 16 GB Mini → ~5–8
  concurrent bots. Give the runtime VM enough RAM (Colima `--memory`, Docker
  Desktop → Settings → Resources).

---

## 2. Get the code

```bash
git clone -b fix/apple-silicon-arm64-support https://github.com/ed-thuando/roosterx-vexa.git
cd roosterx-vexa
```

---

## 3. Configure `.env`

```bash
cp deploy/env-example .env
```

Edit `.env`. Minimum for production:

```dotenv
# --- secrets: generate fresh, never use the changeme defaults ---
ADMIN_TOKEN=<openssl rand -hex 32>
INTERNAL_API_SECRET=<openssl rand -hex 32>
BOT_API_TOKEN=<openssl rand -hex 32>

# --- bot image tag (see §4/§5; must match the tag you build) ---
IMAGE_TAG=latest
BROWSER_IMAGE=vexaai/vexa-bot:latest

# --- docker socket group (see §9.1; OrbStack/Docker Desktop usually 0) ---
DOCKER_GID=0

# --- audio-only ---
TRANSCRIPTION_ENABLED=false
TRANSCRIBE_DEFAULT=false

# --- storage: Cloudflare R2 (S3-compatible) ---
STORAGE_BACKEND=s3
S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
S3_BUCKET=<your-r2-bucket>
S3_SECURE=true
AWS_REGION=auto
AWS_ACCESS_KEY_ID=<r2-access-key-id>
AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>

# --- public URL (your tunnel hostname; §7) ---
PUBLIC_BASE_URL=https://api.yourdomain.com
```

Generate secrets: `openssl rand -hex 32` (run 3×).
**Delete any leftover duplicate `STORAGE_BACKEND=minio` line** — keep one (`=s3`).
`.env` is gitignored — keys never get committed.

---

## 4. Build images

### Option A — build on the Mini (recommended, simplest)

Native arm64, no registry. Builds the bot image + the 4 core services and writes
the tag to `deploy/compose/.last-tag`.

```bash
cd deploy/compose
make build
# lean bot image (no VNC/SSH). For a debuggable bot image instead:
#   make build-bot-image-debug   # adds VNC/SSH; run bot with ENABLE_VNC=true
```

### Option B — prebuild on another arm64 Mac, ship to the Mini

No registry (save/load over SSH):
```bash
# on the build machine
cd deploy/compose && make build
TAG=$(cat .last-tag)
docker save vexaai/api-gateway:$TAG vexaai/admin-api:$TAG vexaai/runtime-api:$TAG \
            vexaai/meeting-api:$TAG vexaai/vexa-bot:$TAG | gzip > /tmp/roosterx-$TAG.tgz
scp /tmp/roosterx-$TAG.tgz macmini:/tmp/
# on the Mini
gunzip -c /tmp/roosterx-$TAG.tgz | docker load
```

Or via a registry (Docker Hub / GHCR). The Makefile pushes to `$DOCKERHUB_USER`
(default `vexaai`):
```bash
docker login
DOCKERHUB_USER=<you> make publish          # pushes IMAGES + bot at .last-tag (+ :dev)
# on the Mini: docker login; docker pull <you>/<svc>:<tag>; retag to vexaai/* if
# you keep the compose namespace, or edit image names in docker-compose.yml.
```
> The compose file references the `vexaai/*` namespace. If you publish under a
> different user, either retag on the Mini or change the `image:` lines.

### Pin the tag (stable)

`make up` reuses the tag in `.last-tag` (no rebuild). To pin a known-good build so
restarts/reboots never surprise you, tag it `:latest` and point `.env` at it:
```bash
TAG=$(cat deploy/compose/.last-tag)
for s in api-gateway admin-api runtime-api meeting-api vexa-bot; do
  docker tag vexaai/$s:$TAG vexaai/$s:latest
done
# .env already has IMAGE_TAG=latest + BROWSER_IMAGE=vexaai/vexa-bot:latest
```

---

## 5. First run

```bash
cd deploy/compose
make up            # start the stack (no mcp/dashboard/tts — audio-only)
make init-db       # schema sync
make setup-api-key # creates a user + writes VEXA_API_KEY to .env
```

Grab the client key:
```bash
grep '^VEXA_API_KEY=' ../../.env
```
Mint more / set a concurrency cap:
```bash
ADMIN=$(grep '^ADMIN_TOKEN=' ../../.env | cut -d= -f2)
curl -X POST "http://localhost:8056/admin/users/1/tokens?scopes=bot,tx&name=prod" \
  -H "X-Admin-API-Key: $ADMIN"
```

---

## 6. Use the API (your backend → server-to-server)

```bash
KEY=<VEXA_API_KEY>
# start a recording bot
curl -X POST https://api.yourdomain.com/bots \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"platform":"google_meet","meeting_url":"https://meet.google.com/xxx-xxxx-xxx","bot_name":"Recorder"}'
# status / stop / recordings
curl https://api.yourdomain.com/bots/status -H "X-API-Key: $KEY"
curl -X DELETE https://api.yourdomain.com/bots/google_meet/xxx-xxxx-xxx -H "X-API-Key: $KEY"
curl https://api.yourdomain.com/recordings -H "X-API-Key: $KEY"
```
Defaults are audio-only (transcription off, video blocked, recording on).

**Webhook** (per-user, HMAC-signed; fires on status + `recording.completed`):
```bash
curl -X PUT https://api.yourdomain.com/user/webhook \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"webhook_url":"https://your.app/hook","webhook_secret":"<random>","webhook_events":{"completed":true}}'
```
Or per-bot via `X-User-Webhook-URL` / `-Secret` / `-Events` headers on `POST /bots`.

> Bots still hit Google Meet's waiting room — a human admits them unless you set up
> authenticated browser-userdata (logged-in Google session via `authenticated` +
> `userdataS3Path`).

---

## 7. Public access — Cloudflare Tunnel

Cloudflare terminates TLS at the edge and tunnels to `http://localhost:8056`. Only
the gateway is exposed; everything else binds `127.0.0.1`.

**Quick test (throwaway URL, no domain):**
```bash
cloudflared tunnel --url http://localhost:8056
```

**Production (your domain, persistent):**
```bash
cloudflared tunnel login
cloudflared tunnel create roosterx
cloudflared tunnel route dns roosterx api.yourdomain.com
```
`~/.cloudflared/config.yml`:
```yaml
tunnel: <tunnel-id>
credentials-file: /Users/<you>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: api.yourdomain.com
    service: http://localhost:8056
  - service: http_status:404
```
```bash
sudo cloudflared service install   # runs on boot
```

### ⚠️ Lock down `/admin/*`
`/admin/*` is reachable publicly through the gateway, guarded only by
`X-Admin-API-Key`. Use a strong random `ADMIN_TOKEN` (§3) and optionally put a
**Cloudflare Access** policy in front of the `/admin` path.

---

## 8. Survive reboots (stable)

- **Stack**: compose services use `restart: unless-stopped` — they restart on
  crash. They come back on reboot only if the runtime auto-starts (below) and you
  ran `make up` once.
- **Runtime**: OrbStack → enable "Start at login"; Colima → `colima start` in a
  LaunchAgent; Docker Desktop → "Start on login" + macOS auto-login.
- **Tunnel**: `sudo cloudflared service install` (LaunchDaemon) → starts on boot.
- After a fresh boot, confirm with §9 health checks.

---

## 9. Gotchas (hit live — handle these)

### 9.1 Docker socket group → runtime-api crash loop
runtime-api needs the docker socket. The default `group_add: ${DOCKER_GID:-998}`
is wrong on macOS, where the socket is `gid 0`:
```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine \
  stat -c '%g' /var/run/docker.sock
```
Put that number in `.env` as `DOCKER_GID=` (Docker Desktop/OrbStack → usually `0`).
Symptom if wrong: `runtime-api Restarting`, logs show
`ConnectionError ... PermissionError(13)`.

### 9.2 BROWSER_IMAGE tag
`make build` tags images `VERSION-<timestamp>` (in `.last-tag`), but `.env`
`BROWSER_IMAGE` may point at `:latest`. Either tag the build `:latest` (§4 pin) or
set `BROWSER_IMAGE` to the exact built tag. Symptom: bot never spawns / image-not-found.

### 9.3 One `STORAGE_BACKEND`
Duplicate `STORAGE_BACKEND` lines → last one wins, confusing. Keep a single `=s3`.

---

## 10. Verify

```bash
cd deploy/compose
docker compose --env-file ../../.env ps           # all healthy; runtime-api NOT restarting
docker logs vexa-meeting-api-1 2>&1 | grep -i "ready\|transcription_enabled\|collector"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8056/    # 200

# R2 roundtrip (proves creds/endpoint/bucket)
docker cp - vexa-meeting-api-1:/tmp/ < /dev/null 2>/dev/null
docker exec -e PYTHONPATH=/app vexa-meeting-api-1 python3 -c "
from meeting_api.storage import create_storage_client as f
c=f(); c.upload_file('healthcheck/ping.txt', b'ok','text/plain')
print('R2 list:', c.list_objects('healthcheck/')); c.delete_file('healthcheck/ping.txt'); print('R2 OK')"
```
Then a real end-to-end: `POST /bots` into a live meeting, admit the bot, stop it,
confirm `GET /recordings` shows `status: completed` and the object lands in R2.

---

## 11. Operate

- Logs: `docker logs -f vexa-meeting-api-1` (or `vexa-api-gateway-1`, `vexa-runtime-api-1`).
- Update: `git pull && cd deploy/compose && make build && make up` (recreates changed services).
- Rollback: point `IMAGE_TAG`/`BROWSER_IMAGE` at a previous pinned tag, `make up`.
- Backup: dump Postgres (`docker exec vexa-postgres-1 pg_dump ...`); recordings are
  already durable in R2.
- Stop: `make down`.

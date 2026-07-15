#!/usr/bin/env bash
# scripts/mac-test-auto-leave.sh — build + run auto-leave tests on Apple Silicon Mac
#
# Prereq: Docker/OrbStack/Colima running, git, make, curl, python3
#
# Quick path — Dashboard UI (recommended):
#   ./scripts/mac-test-auto-leave.sh dashboard SCENARIO=silence
#   open http://localhost:3001  → paste Meet URL → Join → watch completion_reason
#
# CLI path:
#   ./scripts/mac-test-auto-leave.sh bootstrap
#   ./scripts/mac-test-auto-leave.sh spawn MEET_URL=https://meet.google.com/xxx-yyyy-zzz SCENARIO=silence
#
# After code changes (meeting-api / bot):
#   ./scripts/mac-test-auto-leave.sh rebuild
#   ./scripts/mac-test-auto-leave.sh dashboard SCENARIO=silence
#
# Scenarios (short timeouts for local verify — applied to ALL users' bot_config):
#   silence — leave after ~30s no audio (humans may stay muted in call)
#   alone   — leave after ~30s once bot is alone (everyone else left)
#   defaults — use production defaults (10m silence / 10m alone) — slow
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_DIR="$ROOT/deploy/compose"
ENV_FILE="$ROOT/.env"
LAST_TAG_FILE="$COMPOSE_DIR/.last-tag"
TOKEN_CACHE="/tmp/.roosterx_mac_auto_leave_token"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
info(){ printf '→ %s\n' "$*"; }

die(){ red "ERROR: $*"; exit 1; }

need_docker(){
  docker info >/dev/null 2>&1 || die "Docker is not running (start OrbStack / Colima / Docker Desktop)"
}

ensure_env(){
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ROOT/deploy/env-example" "$ENV_FILE"
    ylw "Created .env from deploy/env-example"
    ylw "Edit secrets if you want; for local MinIO defaults are fine."
  fi
  # Local Mac defaults — audio-only
  grep -qE '^TRANSCRIPTION_ENABLED=' "$ENV_FILE" || echo 'TRANSCRIPTION_ENABLED=false' >> "$ENV_FILE"
  grep -qE '^TRANSCRIBE_DEFAULT=' "$ENV_FILE" || echo 'TRANSCRIBE_DEFAULT=false' >> "$ENV_FILE"
  # runtime-api needs docker.sock group: Colima=991 (guest docker), OrbStack/Desktop often 0
  # note: avoid var name GID — readonly in zsh
  local docker_gid="0"
  if docker context show 2>/dev/null | grep -qi colima \
     || docker info 2>/dev/null | grep -qi colima; then
    docker_gid="$(colima ssh -- stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 991)"
  elif [ -S /var/run/docker.sock ]; then
    docker_gid="$(stat -f '%g' /var/run/docker.sock 2>/dev/null || stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
  fi
  if grep -qE '^DOCKER_GID=' "$ENV_FILE"; then
    env_set DOCKER_GID "$docker_gid"
  else
    echo "DOCKER_GID=$docker_gid" >> "$ENV_FILE"
  fi
}

env_get(){
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

env_set(){
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # macOS sed -i needs ''
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

gw_port(){ local p; p="$(env_get API_GATEWAY_HOST_PORT)"; echo "${p:-8056}"; }
adm_port(){ local p; p="$(env_get ADMIN_API_PORT)"; echo "${p:-8057}"; }

pin_local_images(){
  [ -f "$LAST_TAG_FILE" ] || die "No .last-tag — run build first"
  local tag
  tag="$(cat "$LAST_TAG_FILE")"
  info "Pinning IMAGE_TAG + BROWSER_IMAGE to local build: $tag"
  env_set IMAGE_TAG "$tag"
  env_set BROWSER_IMAGE "vexaai/vexa-bot:$tag"
  for s in api-gateway admin-api runtime-api meeting-api vexa-bot; do
    docker image inspect "vexaai/$s:$tag" >/dev/null 2>&1 || die "missing image vexaai/$s:$tag — rebuild"
  done
  grn "Pinned. Bot will spawn from vexaai/vexa-bot:$tag"
}

cmd_build(){
  need_docker
  ensure_env
  info "Building bot + core services (native arm64) — this takes a while…"
  (cd "$COMPOSE_DIR" && make build)
  pin_local_images
  grn "Build done. Tag=$(cat "$LAST_TAG_FILE")"
}

cmd_rebuild(){
  # Faster loop: only bot + meeting-api (auto-leave surface)
  need_docker
  ensure_env
  local version build_tag
  version="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
  build_tag="${version}-$(date +%y%m%d-%H%M)"
  info "Rebuild meeting-api + vexa-bot as $build_tag"
  docker build -t "vexaai/vexa-bot:$build_tag" -f "$ROOT/services/vexa-bot/Dockerfile" "$ROOT/services/vexa-bot"
  (cd "$COMPOSE_DIR" && IMAGE_TAG="$build_tag" docker compose --env-file "$ENV_FILE" -f docker-compose.yml build meeting-api)
  # If other services missing for this tag, retag from previous .last-tag
  local prev=""
  [ -f "$LAST_TAG_FILE" ] && prev="$(cat "$LAST_TAG_FILE")"
  for s in api-gateway admin-api runtime-api; do
    if ! docker image inspect "vexaai/$s:$build_tag" >/dev/null 2>&1; then
      if [ -n "$prev" ] && docker image inspect "vexaai/$s:$prev" >/dev/null 2>&1; then
        docker tag "vexaai/$s:$prev" "vexaai/$s:$build_tag"
        info "Retagged vexaai/$s:$prev → $build_tag"
      else
        info "Building missing $s…"
        (cd "$COMPOSE_DIR" && IMAGE_TAG="$build_tag" docker compose --env-file "$ENV_FILE" -f docker-compose.yml build "$s")
      fi
    fi
  done
  echo "$build_tag" > "$LAST_TAG_FILE"
  pin_local_images
  info "Restarting stack with new images…"
  (cd "$COMPOSE_DIR" && make up)
  wait_gateway
  grn "Rebuild + up done ($build_tag)"
}

wait_gateway(){
  local port tries=0
  port="$(gw_port)"
  info "Waiting for gateway :$port …"
  until curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 \
     || curl -sf "http://127.0.0.1:$port/docs" >/dev/null 2>&1 \
     || curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" | grep -qE '200|301|302|404'; do
    tries=$((tries+1))
    [ "$tries" -lt 60 ] || die "gateway not up on :$port after 60s"
    sleep 1
  done
  grn "Gateway ready on :$port"
}

cmd_up(){
  need_docker
  ensure_env
  [ -f "$LAST_TAG_FILE" ] || die "No local build — run: $0 build"
  pin_local_images
  (cd "$COMPOSE_DIR" && make up && make init-db && make setup-api-key)
  wait_gateway
  grn "Stack up. API: http://127.0.0.1:$(gw_port)/docs"
  info "VEXA_API_KEY=$(env_get VEXA_API_KEY)"
}

cmd_bootstrap(){
  cmd_build
  cmd_up
  cat <<EOF

$(grn "Ready for manual auto-leave tests.")

Silence (humans stay muted ≥60s):
  $0 spawn MEET_URL=https://meet.google.com/xxx-yyyy-zzz SCENARIO=silence

Everyone left (~30s after humans leave):
  $0 spawn MEET_URL=https://meet.google.com/xxx-yyyy-zzz SCENARIO=alone

Teams:
  $0 spawn MEET_URL='https://teams.microsoft.com/l/meetup-join/...' PLATFORM=teams SCENARIO=silence

Zoom:
  $0 spawn MEET_URL='https://zoom.us/j/123?pwd=xxx' PLATFORM=zoom SCENARIO=alone

EOF
}

api_token(){
  local tok adm port uid
  tok="$(env_get VEXA_API_KEY)"
  if [ -n "$tok" ]; then echo "$tok"; return; fi
  if [ -f "$TOKEN_CACHE" ]; then cat "$TOKEN_CACHE"; return; fi
  adm="$(env_get ADMIN_TOKEN)"
  [ -n "$adm" ] || die "No VEXA_API_KEY / ADMIN_TOKEN in .env — run: $0 up"
  port="$(adm_port)"
  uid="$(curl -sf -X POST "http://127.0.0.1:$port/admin/users" \
    -H "Content-Type: application/json" -H "X-Admin-API-Key: $adm" \
    -d '{"email":"mac-auto-leave@local.test","name":"mac-auto-leave","max_concurrent_bots":5}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  [ -n "$uid" ] || die "could not create admin user"
  tok="$(curl -sf -X POST "http://127.0.0.1:$port/admin/users/$uid/tokens" \
    -H "X-Admin-API-Key: $adm" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
  [ -n "$tok" ] || die "could not mint token"
  printf '%s' "$tok" > "$TOKEN_CACHE"
  echo "$tok"
}

# Parse MEET_URL → platform hints + payload fields
build_bot_payload(){
  local url="$1" platform="${2:-}" scenario="${3:-silence}" bot_name="${4:-AutoLeaveTest}"
  python3 - "$url" "$platform" "$scenario" "$bot_name" <<'PY'
import json, sys, re
from urllib.parse import urlparse, parse_qs

url, platform, scenario, bot_name = sys.argv[1:5]
u = urlparse(url.strip())
host = (u.netloc or "").lower()
path = u.path or ""

if not platform or platform == "auto":
    if "meet.google.com" in host:
        platform = "google_meet"
    elif "teams.microsoft.com" in host or "teams.live.com" in host:
        platform = "teams"
    elif "zoom.us" in host or "zoom.com" in host:
        platform = "zoom"
    else:
        raise SystemExit(f"cannot detect platform from URL: {url}")

body = {"platform": platform, "bot_name": bot_name, "meeting_url": url}

if platform == "google_meet":
    code = path.strip("/").split("/")[0]
    if re.fullmatch(r"[a-z]{3}-[a-z]{4}-[a-z]{3}", code or ""):
        body["native_meeting_id"] = code
elif platform == "zoom":
    m = re.search(r"/j/(\d+)", path)
    if m:
        body["native_meeting_id"] = m.group(1)
    qs = parse_qs(u.query)
    if "pwd" in qs:
        body["passcode"] = qs["pwd"][0]

# Short timeouts for local verify
if scenario == "silence":
    body["automatic_leave"] = {
        "no_audio_activity_timeout": 30_000,   # 30s silence → inactive_no_audio
        "max_time_left_alone": 300_000,        # keep alone high so silence wins first
        "no_one_joined_timeout": 300_000,
    }
elif scenario == "alone":
    body["automatic_leave"] = {
        "max_time_left_alone": 30_000,         # 30s alone → left_alone
        "no_audio_activity_timeout": 600_000,  # keep silence high so alone wins
        "no_one_joined_timeout": 120_000,
    }
elif scenario == "defaults":
    pass  # server defaults: 10m silence / 10m alone
else:
    raise SystemExit(f"unknown SCENARIO={scenario} (silence|alone|defaults)")

print(json.dumps(body))
PY
}

cmd_spawn(){
  local meet_url="${MEET_URL:-}" platform="${PLATFORM:-auto}" scenario="${SCENARIO:-silence}"
  local bot_name="${BOT_NAME:-AutoLeaveTest}"
  [ -n "$meet_url" ] || die "MEET_URL required — e.g. MEET_URL=https://meet.google.com/xxx-yyyy-zzz"

  need_docker
  ensure_env
  wait_gateway

  local tok port payload resp mid status
  tok="$(api_token)"
  port="$(gw_port)"
  payload="$(build_bot_payload "$meet_url" "$platform" "$scenario" "$bot_name")"
  info "POST /bots scenario=$scenario"
  echo "$payload" | python3 -m json.tool
  resp="$(curl -sf -X POST "http://127.0.0.1:$port/bots" \
    -H "Content-Type: application/json" -H "X-API-Key: $tok" \
    -d "$payload" || true)"
  [ -n "$resp" ] || die "POST /bots failed (empty). Is gateway up? Check: docker compose -f deploy/compose/docker-compose.yml logs api-gateway --tail=40"

  mid="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("data",{}).get("id",""))' 2>/dev/null || true)"
  status="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status") or "")' 2>/dev/null || true)"
  [ -n "$mid" ] || die "no meeting id in response: $resp"

  grn "Spawned meeting id=$mid status=$status"
  echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
  echo ""
  info "Admit the bot in the meeting UI, then run the scenario:"
  case "$scenario" in
    silence) ylw "  Keep ≥1 human in the call MUTED / silent for ~30s → expect inactive_no_audio" ;;
    alone)   ylw "  Join with ≥2 humans, then ALL leave (bot alone) for ~30s → expect left_alone" ;;
    defaults) ylw "  Production timers: silence 10m / alone 10m" ;;
  esac
  echo ""
  info "Watch:"
  echo "  $0 watch MEETING_ID=$mid"
  echo "  docker ps --filter name=meeting-bot --format '{{.Names}}' | head -1 | xargs -I{} docker logs -f {}"
  echo "$mid" > /tmp/.roosterx_mac_auto_leave_meeting_id
}

cmd_watch(){
  local mid="${MEETING_ID:-}"
  [ -n "$mid" ] || mid="$(cat /tmp/.roosterx_mac_auto_leave_meeting_id 2>/dev/null || true)"
  [ -n "$mid" ] || die "MEETING_ID required (or spawn first)"

  local tok port tries=0 max_tries="${MAX_TRIES:-180}"
  tok="$(api_token)"
  port="$(gw_port)"
  info "Watching meeting $mid via GET /bots?include=data (timeout ${max_tries}s)…"

  while [ "$tries" -lt "$max_tries" ]; do
    local row status reason message
    row="$(curl -sf "http://127.0.0.1:$port/bots?include=data&limit=50" -H "X-API-Key: $tok" \
      | python3 -c '
import json,sys
mid=sys.argv[1]
d=json.load(sys.stdin)
meetings=d.get("meetings") if isinstance(d,dict) else d
if not isinstance(meetings,list):
    meetings=[]
m=next((x for x in meetings if str(x.get("id"))==mid), None)
if not m:
    print("|||")
    raise SystemExit(0)
data=m.get("data") if isinstance(m.get("data"),dict) else {}
st=m.get("status") or ""
reason=m.get("completion_reason") or data.get("completion_reason") or ""
message=data.get("message") or ""
print(f"{st}|{reason}|{message}")
' "$mid" 2>/dev/null || echo "|||")"

    status="${row%%|*}"
    rest="${row#*|}"
    reason="${rest%%|*}"
    message="${rest#*|}"

    printf '\r  [%3ds] status=%-12s reason=%-20s' "$tries" "${status:-?}" "${reason:-—}"
    if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
      echo ""
      grn "Terminal: status=$status completion_reason=$reason"
      [ -n "$message" ] && echo "  message=$message"
      case "$reason" in
        inactive_no_audio)
          grn "PASS — silence / inactive path"
          exit 0
          ;;
        left_alone)
          grn "PASS — everyone-left path"
          exit 0
          ;;
        *)
          ylw "Ended with unexpected reason=$reason (still terminal)"
          exit 0
          ;;
      esac
    fi
    tries=$((tries+1))
    sleep 1
  done
  echo ""
  die "timed out waiting for meeting $mid to complete"
}

cmd_logs(){
  local c
  c="$(docker ps --filter name=meeting-bot --format '{{.Names}}' | head -1)"
  [ -n "$c" ] || die "no running meeting-bot container"
  info "Tailing $c"
  exec docker logs -f "$c"
}

cmd_down(){
  (cd "$COMPOSE_DIR" && make down)
}

apply_user_auto_leave_defaults(){
  # Dashboard Join does not send automatic_leave — inject short timers on
  # EVERY user's data.bot_config (login may be admin OR any magic-link email).
  local scenario="${SCENARIO:-silence}" adm port payload
  adm="$(env_get ADMIN_TOKEN)"
  [ -n "$adm" ] || die "ADMIN_TOKEN missing in .env"
  port="$(adm_port)"

  case "$scenario" in
    silence)
      # 30s silence — keep alone high so silence wins first
      payload='{"data":{"bot_config":{"no_audio_activity_timeout":30000,"max_time_left_alone":300000,"no_one_joined_timeout":300000}}}'
      ;;
    alone)
      payload='{"data":{"bot_config":{"max_time_left_alone":30000,"no_audio_activity_timeout":600000,"no_one_joined_timeout":120000}}}'
      ;;
    defaults)
      payload='{"data":{"bot_config":{"no_audio_activity_timeout":600000,"max_time_left_alone":600000,"no_one_joined_timeout":600000}}}'
      ;;
    *) die "unknown SCENARIO=$scenario (silence|alone|defaults)" ;;
  esac

  python3 - "$port" "$adm" "$payload" <<'PY' || die "PATCH user bot_config failed"
import json, sys, urllib.request
port, adm, payload = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/admin/users",
    headers={"X-Admin-API-Key": adm},
)
users = json.load(urllib.request.urlopen(req))
if isinstance(users, dict):
    users = users.get("users") or users.get("data") or []
if not users:
    raise SystemExit("no users")
for u in users:
    uid = u["id"]
    r = urllib.request.Request(
        f"http://127.0.0.1:{port}/admin/users/{uid}",
        data=payload.encode(),
        headers={"Content-Type": "application/json", "X-Admin-API-Key": adm},
        method="PATCH",
    )
    urllib.request.urlopen(r).read()
    print(f"patched user {uid} ({u.get('email')})")
PY
  grn "All users bot_config set for SCENARIO=$scenario (silence=30s when silence)"
}

wait_dashboard(){
  local port tries=0
  port="$(env_get DASHBOARD_HOST_PORT)"; port="${port:-3001}"
  info "Waiting for dashboard :$port …"
  until curl -sf -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null \
     || curl -sf -o /dev/null "http://127.0.0.1:$port/login" 2>/dev/null; do
    tries=$((tries+1))
    [ "$tries" -lt 90 ] || die "dashboard not up on :$port — check: cd deploy/compose && make build-dashboard && make up-dashboard"
    sleep 1
  done
  grn "Dashboard ready → http://127.0.0.1:$port"
}

cmd_dashboard(){
  local scenario="${SCENARIO:-silence}"
  need_docker
  ensure_env
  grep -qE '^JWT_SECRET=' "$ENV_FILE" || echo 'JWT_SECRET=vexa-dev-jwt-secret-mac' >> "$ENV_FILE"
  # Skip SMTP / magic-link — dashboard direct login for local Mac testing
  if grep -qE '^VEXA_ALLOW_DIRECT_LOGIN=' "$ENV_FILE"; then
    env_set VEXA_ALLOW_DIRECT_LOGIN true
  else
    echo 'VEXA_ALLOW_DIRECT_LOGIN=true' >> "$ENV_FILE"
  fi

  if [ ! -f "$LAST_TAG_FILE" ]; then
    ylw "No local core build yet — running full build first…"
    cmd_build
  else
    pin_local_images
  fi

  info "Ensuring API stack is up…"
  (cd "$COMPOSE_DIR" && make up && make init-db && make setup-api-key)
  wait_gateway

  # Build dashboard image for current IMAGE_TAG if missing
  local tag dash_img
  tag="$(cat "$LAST_TAG_FILE")"
  dash_img="vexaai/dashboard:$tag"
  if ! docker image inspect "$dash_img" >/dev/null 2>&1; then
    info "Building dashboard image $dash_img (first time ~few min)…"
    (cd "$COMPOSE_DIR" && make build-dashboard)
  fi

  info "Starting stack + dashboard overlay…"
  (cd "$COMPOSE_DIR" && make up-dashboard)
  wait_dashboard
  apply_user_auto_leave_defaults

  local dport
  dport="$(env_get DASHBOARD_HOST_PORT)"; dport="${dport:-3001}"
  cat <<EOF

$(grn "Dashboard ready for auto-leave test")

  URL:      http://127.0.0.1:$dport
  Scenario: $scenario  (short timers already on admin@vexa.ai bot_config)

How to test:
  1. Open the URL above (login / magic-link as needed — local often auto-keys via VEXA_API_KEY)
  2. Paste a Meet / Teams / Zoom URL → Join / Launch bot
  3. Admit the bot in the meeting
  4. Run the scenario:
$(case "$scenario" in
  silence) echo "       · Keep people in call MUTED ≥ ~30s → status completed, reason inactive_no_audio" ;;
  alone)   echo "       · ≥2 humans join, then ALL leave → after ~30s → left_alone" ;;
  defaults) echo "       · Production timers: silence 10m / alone 10m" ;;
esac)
  5. Open the meeting detail — check completion_reason (+ message in data)

Switch scenario later without rebuild:
  $0 dashboard-timeouts SCENARIO=alone

Tail bot logs:
  $0 logs

EOF
  # Try opening browser on macOS
  if command -v open >/dev/null 2>&1; then
    open "http://127.0.0.1:$dport" 2>/dev/null || true
  fi
}

cmd_dashboard_timeouts(){
  need_docker
  ensure_env
  wait_gateway
  apply_user_auto_leave_defaults
  info "Next bots from dashboard will use SCENARIO=${SCENARIO:-silence} timers."
}

cmd_help(){
  cat <<EOF
Usage: $0 <command> [ENV=val …]

Commands:
  dashboard   *** recommended *** build/up API + Vexa dashboard, short timers, open UI
  dashboard-timeouts   only PATCH user bot_config for SCENARIO=…
  bootstrap   build + up API only (no dashboard)
  build       full image build (bot + 4 services)
  rebuild     fast rebuild meeting-api + bot, restart API stack
  up          start API stack from last local build
  spawn       POST /bots via CLI with short timeouts
  watch       poll meeting until completed
  logs        docker logs -f latest meeting-bot
  down        compose down

dashboard env:
  SCENARIO=silence|alone|defaults   (default: silence)

Examples:
  $0 dashboard SCENARIO=silence
  $0 dashboard SCENARIO=alone
  $0 dashboard-timeouts SCENARIO=defaults
EOF
}

# Allow KEY=val args before/after command
CMD="${1:-help}"
shift || true
for arg in "$@"; do
  case "$arg" in
    *=*) export "$arg" ;;
    *) die "unknown arg: $arg (use KEY=val)" ;;
  esac
done

case "$CMD" in
  dashboard) cmd_dashboard ;;
  dashboard-timeouts) cmd_dashboard_timeouts ;;
  bootstrap) cmd_bootstrap ;;
  build)     cmd_build ;;
  rebuild)   cmd_rebuild ;;
  up)        cmd_up ;;
  spawn)     cmd_spawn ;;
  watch)     cmd_watch ;;
  logs)      cmd_logs ;;
  down)      cmd_down ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $CMD — try: $0 help" ;;
esac

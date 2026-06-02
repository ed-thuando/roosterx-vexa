# ==============================================================================
# Stage 1: Build native addon (Zoom SDK wrapper)
# ==============================================================================
FROM node:20-bullseye AS native-builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    python3 \
    libssl-dev \
    qtbase5-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/vexa-bot

# Copy package files for root workspace
COPY package*.json ./
COPY binding.gyp ./

# Copy Zoom SDK (if present) and native source
COPY core/src/platforms/zoom/native/ ./core/src/platforms/zoom/native/

# Install dependencies without triggering native postinstall hooks.
# Native addon build is handled explicitly below on best-effort basis.
RUN npm install --ignore-scripts

# Build native addon (will skip if SDK not present)
RUN npm run build:native || echo "[Build] Native addon build skipped (SDK not available)"

# ==============================================================================
# Stage 2: Build TypeScript
# ==============================================================================
FROM mcr.microsoft.com/playwright:v1.56.0-jammy AS ts-builder

WORKDIR /app/vexa-bot

# Install TypeScript build dependencies
RUN apt-get update && apt-get install -y \
    xvfb \
    ffmpeg \
    x11-utils \
    pulseaudio \
    x11-xserver-utils \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace files
COPY core/package*.json ./core/
COPY core/tsconfig.json ./core/
COPY core/build-browser-utils.js ./core/

# Install TypeScript dependencies
WORKDIR /app/vexa-bot/core
RUN npm install
RUN npm install -g typescript

# Copy TypeScript source and assets (default avatar logo)
COPY core/src/ ./src/
COPY core/assets/ ./assets/

# Build TypeScript
RUN npm run build

# Install Playwright browsers
RUN npx playwright install-deps && npx playwright install --with-deps

# Install MS Edge for Teams support (x86_64 only)
RUN arch=$(uname -m) && if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then \
    cd /app/vexa-bot/core && npx playwright install msedge; \
    else \
    echo "Skipping msedge installation on $arch (not supported)"; \
    fi

# ==============================================================================
# Stage 3: Runtime
# ==============================================================================
FROM mcr.microsoft.com/playwright:v1.56.0-jammy AS runtime

WORKDIR /app/vexa-bot

# RoosterX audio-only fork: the VNC/SSH/remote-control stack is opt-in.
# Default build is lean (audio-record-only). Build with
# --build-arg INSTALL_DEBUG_TOOLS=true to include the live-browser debug
# stack, then run the container with ENABLE_VNC=true to start it.
ARG INSTALL_DEBUG_TOOLS=false

# Install runtime dependencies.
# Always: Xvfb + PulseAudio (audio capture), libssl3 / libxcb-xtest0 (browser),
# awscli (authenticated browser-userdata sync), curl + git.
# Debug-only (INSTALL_DEBUG_TOOLS=true): xephyr, fluxbox, x11vnc, novnc,
# websockify, socat, openssh-server — only for watching/controlling the
# browser; not needed for headless audio recording.
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    pulseaudio \
    libssl3 \
    libxcb-xtest0 \
    awscli \
    curl \
    git \
    && if [ "$INSTALL_DEBUG_TOOLS" = "true" ]; then \
         apt-get install -y --no-install-recommends \
           xserver-xephyr fluxbox x11vnc novnc python3-websockify socat openssh-server \
         && mkdir -p /run/sshd \
         && sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
         && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config ; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace package files (for runtime dependencies)
COPY --from=native-builder /app/vexa-bot/package*.json ./
COPY --from=native-builder /app/vexa-bot/node_modules ./node_modules

# Copy built native addon (if exists)
COPY --from=native-builder /app/vexa-bot/build ./build

# Copy Zoom SDK libraries (if present)
COPY --from=native-builder /app/vexa-bot/core/src/platforms/zoom/native/zoom_meeting_sdk ./core/src/platforms/zoom/native/zoom_meeting_sdk

# Copy TypeScript build artifacts and assets (default avatar logo)
COPY --from=ts-builder /app/vexa-bot/core/package*.json ./core/
COPY --from=ts-builder /app/vexa-bot/core/node_modules ./core/node_modules
COPY --from=ts-builder /app/vexa-bot/core/dist ./core/dist
COPY --from=ts-builder /app/vexa-bot/core/assets ./core/assets

# Install MS Edge in runtime stage (x86_64 only)
RUN arch=$(uname -m) && if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then \
    cd /app/vexa-bot/core && npx playwright install msedge; \
    else \
    echo "Skipping msedge installation on $arch (not supported)"; \
    fi

# Ensure Playwright cache has proper permissions
RUN mkdir -p /root/ms-playwright && chmod -R 777 /root/ms-playwright

# Create storage directories
RUN mkdir -p /app/vexa-bot/storage/screenshots /app/vexa-bot/storage/logs /app/vexa-bot/storage/temp && \
    chmod -R 777 /app/vexa-bot/storage

# Copy entrypoint script
COPY core/entrypoint.sh /app/vexa-bot/entrypoint.sh
RUN chmod +x /app/vexa-bot/entrypoint.sh

# Set environment
ENV DISPLAY=:99

# Expose noVNC web interface and SSH for browser session mode
EXPOSE 6080 22

# Set working directory for runtime
WORKDIR /app/vexa-bot/core

# Run entrypoint
CMD ["/app/vexa-bot/entrypoint.sh"]

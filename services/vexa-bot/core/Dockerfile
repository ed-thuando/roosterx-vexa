# --- Build Stage ---
FROM mcr.microsoft.com/playwright:v1.56.0-jammy AS base

# Install required OS dependencies (e.g., for Xvfb and other utilities)
RUN apt-get update && apt-get install -y \
    xvfb \
    ffmpeg \
    x11-utils \
    pulseaudio \
    x11-xserver-utils \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy package files and install dependencies with npm
COPY package.json ./
RUN npm install --ignore-scripts
# Install TypeScript globally to avoid permission issues
RUN npm install -g typescript
# Copy the rest of the application source code
COPY . .

# Build the TypeScript code and browser utilities bundle
RUN npm run build

# Install Playwright dependencies (if not already installed via npm)
RUN npx playwright install-deps && npx playwright install --with-deps

# Install MS Edge for Teams support (skip on ARM64 - not supported)
RUN arch=$(uname -m) && if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then \
    npx playwright install msedge || true; \
    else \
    echo "Skipping msedge installation on $arch (not supported)"; \
    fi

# --- Runtime Stage ---
FROM mcr.microsoft.com/playwright:v1.56.0-jammy AS runtime

# Set working directory
WORKDIR /app

# RoosterX audio-only fork: VNC/SSH stack is opt-in (see services/vexa-bot/Dockerfile).
# Build with --build-arg INSTALL_DEBUG_TOOLS=true for a debuggable image.
ARG INSTALL_DEBUG_TOOLS=false

# Install runtime dependencies.
# Always: Xvfb, ffmpeg, PulseAudio, X11 utils, unzip + curl (awscli install below).
# Debug-only: xephyr, fluxbox, x11vnc, novnc, websockify, socat, autocutsel,
# openssh-server, sshpass — only for watching/controlling the browser.
RUN DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xvfb \
    ffmpeg \
    pulseaudio \
    x11-utils \
    x11-xserver-utils \
    unzip \
    curl \
    && if [ "$INSTALL_DEBUG_TOOLS" = "true" ]; then \
         DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
           xserver-xephyr fluxbox x11vnc socat autocutsel openssh-server sshpass python3-websockify novnc ; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI for S3/MinIO sync (used by authenticated bot mode)
RUN ARCH=$(uname -m) && case "$ARCH" in \
    x86_64|amd64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;; \
    aarch64|arm64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;; \
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac \
    && curl -fsSL "$AWSCLI_URL" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Copy the built application and node_modules from the base stage
COPY --from=base /app /app

# Install MS Edge in runtime stage as well (skip on ARM64 - not supported)
RUN arch=$(uname -m) && if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then \
    npx playwright install msedge || true; \
    else \
    echo "Skipping msedge installation on $arch (not supported)"; \
    fi

# Ensure the Playwright cache directory has proper permissions (adjust path if needed)
RUN mkdir -p /root/ms-playwright && chmod -R 777 /root/ms-playwright

# Create storage directory structure for bot data (screenshots, logs, etc.)
RUN mkdir -p /app/storage/screenshots /app/storage/logs /app/storage/temp && chmod -R 777 /app/storage

# Copy an entrypoint script that will start Xvfb and run our bot
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose DISPLAY port for headful browser operations (adjust as needed)
ENV DISPLAY=:99

# Set the command to run our entrypoint script
CMD ["/app/entrypoint.sh"]

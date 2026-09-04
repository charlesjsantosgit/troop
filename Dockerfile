# syntax=docker/dockerfile:1

ARG GODOT_VERSION=4.7
ARG GODOT_RELEASE=4.7-stable
ARG GODOT_LINUX_SHA256=0b1a6c54c2c619c12e169fe9241edda4b81080b519451cec2984bf0d2c6cb73c
ARG GODOT_TEMPLATES_SHA256=9714459dc071907c0f3d5f17d608faf69e7cda21331fc5d39c4503ffa4e99eec

FROM ubuntu:24.04 AS builder

ARG GODOT_VERSION
ARG GODOT_RELEASE
ARG GODOT_LINUX_SHA256
ARG GODOT_TEMPLATES_SHA256

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        file \
        libasound2t64 \
        libfontconfig1 \
        libgl1 \
        libpulse0 \
        libudev1 \
        libx11-6 \
        libxcursor1 \
        libxext6 \
        libxi6 \
        libxinerama1 \
        libxrandr2 \
        libxrender1 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 5 \
        --output /tmp/godot.zip \
        "https://github.com/godotengine/godot-builds/releases/download/${GODOT_RELEASE}/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && printf '%s  %s\n' "$GODOT_LINUX_SHA256" /tmp/godot.zip | sha256sum -c - \
    && unzip -q /tmp/godot.zip -d /tmp/godot \
    && install -m 0755 \
        "/tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64" \
        /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip

RUN curl --fail --location --retry 5 \
        --output /tmp/godot-templates.tpz \
        "https://github.com/godotengine/godot-builds/releases/download/${GODOT_RELEASE}/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" \
    && printf '%s  %s\n' "$GODOT_TEMPLATES_SHA256" /tmp/godot-templates.tpz | sha256sum -c - \
    && mkdir -p "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable" \
    && unzip -q /tmp/godot-templates.tpz -d /tmp/godot-templates \
    && cp -R /tmp/godot-templates/templates/. \
        "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable/" \
    && rm -rf /tmp/godot-templates /tmp/godot-templates.tpz

WORKDIR /src
COPY . .

# Parse/import the project and run the existing source smoke fixture before an
# image can be published. The final export uses Godot's dedicated-server mode.
RUN godot --headless --path /src --import \
    && godot --headless --path /src \
        --script res://tests/voicetest.gd \
    && godot --headless --path /src \
        --script res://tests/netsecuritytest.gd \
    && godot --headless --path /src res://scenes/main.tscn \
        --quit-after 1200 -- smoke 2>&1 | tee /tmp/troop-smoke.log \
    && grep --quiet '^SMOKE_OK ' /tmp/troop-smoke.log \
    && mkdir -p /out \
    && godot --headless --path /src --export-release \
        "Linux Server" /out/troop-server.x86_64 \
    && test -x /out/troop-server.x86_64 \
    && TROOP_BIND_IP=127.0.0.1 TROOP_SERVER_PORT=30623 \
        timeout 30s /out/troop-server.x86_64 \
        --headless --quit -- server 2>&1 | tee /tmp/troop-server-boot.log \
    && grep --quiet '^DEDICATED_SERVER_READY .*bind=127.0.0.1 port=30623 ' \
        /tmp/troop-server-boot.log

FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        util-linux \
        libasound2t64 \
        libfontconfig1 \
        libgl1 \
        libpulse0 \
        libudev1 \
        libx11-6 \
        libxcursor1 \
        libxext6 \
        libxi6 \
        libxinerama1 \
        libxrandr2 \
        libxrender1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin --uid 10001 troop

WORKDIR /app
COPY --from=builder --chown=troop:troop \
    /out/troop-server.x86_64 /app/troop-server.x86_64

COPY --chmod=0755 server-entrypoint.sh /usr/local/bin/troop-start

EXPOSE 30623/udp

# `server` is a project user argument because everything after `--` is exposed
# through OS.get_cmdline_user_args(). Main starts peer 1 as a headless authority.
ENTRYPOINT ["/usr/local/bin/troop-start"]
CMD ["server"]

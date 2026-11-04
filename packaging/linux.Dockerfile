# Ubuntu 24.04 baseline (glibc 2.39, Qt 6.4). Build natively or with Docker QEMU.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build pkg-config ca-certificates curl python3 git \
    qt6-base-dev libqt6svg6-dev libepoxy-dev libavcodec-dev libavformat-dev \
    libavutil-dev libswscale-dev libswresample-dev libjansson-dev libcurl4-openssl-dev \
    libx11-dev libx11-xcb-dev libxcb-randr0-dev libxcb-xinerama0-dev libxcb-xinput-dev \
    libgl-dev libegl-dev libdrm-dev libwayland-dev libxkbcommon-dev uuid-dev \
    extra-cmake-modules libpulse-dev uthash-dev libsimde-dev dpkg-dev file xvfb xauth mesa-utils \
    && rm -rf /var/lib/apt/lists/*
ARG OBS_VERSION=31.1.0
ARG OBS_SHA256=ba903f3848cfabd9ea1205aea14b69e83a2eb43ad6f3f7cc80a6a900bce0e56e
RUN curl --fail --location --retry 3 "https://github.com/obsproject/obs-studio/archive/refs/tags/${OBS_VERSION}.tar.gz" -o /tmp/obs.tar.gz \
    && echo "${OBS_SHA256}  /tmp/obs.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/obs.tar.gz -C /tmp \
    && cmake -S "/tmp/obs-studio-${OBS_VERSION}" -B /tmp/obs-build -G Ninja \
       -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/obs -DCMAKE_INSTALL_LIBDIR=lib \
       -DENABLE_PLUGINS=OFF -DENABLE_FRONTEND=OFF -DENABLE_UI=OFF -DENABLE_SCRIPTING=OFF \
       -DOBS_VERSION_OVERRIDE=${OBS_VERSION} \
    && cmake --build /tmp/obs-build --target obs-frontend-api libobs-opengl --parallel 4 \
    && cmake --install /tmp/obs-build --component Development \
    && cmake --install /tmp/obs-build --component Runtime \
    && rm -f /tmp/obs.tar.gz
ENV CMAKE_PREFIX_PATH=/opt/obs
ENV LD_LIBRARY_PATH=/opt/obs/lib
WORKDIR /work

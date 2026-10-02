# Pinned ARM64 Swift 6.3 toolchain. This image is only for Linux test execution.
FROM docker.io/library/swift@sha256:474fb554869ff6aaccba428f7cccc43bf4f88978b7a83fd1fcc6a66ac6681394

RUN apt-get update \
    && apt-get install -y --no-install-recommends make curl libarchive-dev libbz2-dev liblzma-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

ENV CI=1
WORKDIR /source

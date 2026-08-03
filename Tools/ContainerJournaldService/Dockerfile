# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM golang:1.25.6-bookworm@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e AS build

ARG SYSTEMD_VERSION=252.39-1~deb12u2
ENV GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=1 GOOS=linux GOARCH=arm64
WORKDIR /src
COPY debian-snapshot.sources /etc/apt/sources.list.d/container-snapshot.sources
RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends "libsystemd-dev=${SYSTEMD_VERSION}" \
    && rm -rf /var/lib/apt/lists/*
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN go test -mod=readonly ./... \
    && go build -mod=readonly -trimpath -buildvcs=false -ldflags='-buildid=' \
        -o /out/container-journald-service .

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

ARG SYSTEMD_VERSION=252.39-1~deb12u2
COPY debian-snapshot.sources /etc/apt/sources.list.d/container-snapshot.sources
RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends "systemd=${SYSTEMD_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/machine-id \
    && : > /etc/machine-id
COPY --from=build /out/container-journald-service /usr/local/libexec/container-journald-service
COPY entrypoint.sh /usr/local/libexec/container-journald-entrypoint
RUN chmod 0755 \
    /usr/local/libexec/container-journald-service \
    /usr/local/libexec/container-journald-entrypoint

ARG SERVICE_SOURCE_SHA256=unverified
LABEL org.opencontainers.image.source="https://github.com/stephenlclarke/container" \
    org.opencontainers.image.title="container journald service" \
    org.opencontainers.image.vendor="container project" \
    org.opencontainers.image.version="1" \
    io.github.stephenlclarke.container.source-sha256="${SERVICE_SOURCE_SHA256}"

ENTRYPOINT ["/usr/local/libexec/container-journald-entrypoint"]

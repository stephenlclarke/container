# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

FROM golang:1.25.6-bookworm@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e AS service-build

ENV GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=arm64
WORKDIR /src
COPY --from=plugin_service go.mod go.sum ./
RUN go mod download
COPY --from=plugin_service *.go ./
RUN go test -mod=readonly ./... \
    && go build -mod=readonly -trimpath -buildvcs=false -ldflags='-buildid=' \
        -o /out/container-docker-plugin-service .

FROM golang:1.25.6-bookworm@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e AS plugin-build

ENV GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=arm64
WORKDIR /src
COPY go.mod ./
COPY main.go main_test.go ./
RUN go test -mod=readonly ./... \
    && go build -mod=readonly -trimpath -buildvcs=false -ldflags='-buildid=' \
        -o /out/container-docker-plugin-fixture .

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

COPY --from=service-build /out/container-docker-plugin-service /usr/local/libexec/container-docker-plugin-service
COPY --from=plugin-build /out/container-docker-plugin-fixture /usr/local/libexec/container-docker-plugin-fixture
COPY entrypoint.sh /usr/local/libexec/container-docker-plugin-entrypoint
RUN chmod 0755 \
    /usr/local/libexec/container-docker-plugin-entrypoint \
    /usr/local/libexec/container-docker-plugin-fixture \
    /usr/local/libexec/container-docker-plugin-service

ARG SERVICE_SOURCE_SHA256=unverified
ARG FIXTURE_SOURCE_SHA256=unverified
LABEL org.opencontainers.image.source="https://github.com/stephenlclarke/container" \
    org.opencontainers.image.title="container Docker logging-plugin certification fixture" \
    org.opencontainers.image.vendor="container project" \
    org.opencontainers.image.version="1" \
    io.github.stephenlclarke.container.fixture-source-sha256="${FIXTURE_SOURCE_SHA256}" \
    io.github.stephenlclarke.container.service-source-sha256="${SERVICE_SOURCE_SHA256}"

ENTRYPOINT ["/usr/local/libexec/container-docker-plugin-entrypoint"]

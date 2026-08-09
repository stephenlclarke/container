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

ENV GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=arm64
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN go test -mod=readonly ./... \
    && go build -mod=readonly -trimpath -buildvcs=false -ldflags='-buildid=' \
        -o /out/container-gelf-service .

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

COPY --from=build /out/container-gelf-service /usr/local/libexec/container-gelf-service
RUN chmod 0755 /usr/local/libexec/container-gelf-service

ARG SERVICE_SOURCE_SHA256=unverified
LABEL org.opencontainers.image.source="https://github.com/stephenlclarke/container" \
    org.opencontainers.image.title="container GELF TCP service" \
    org.opencontainers.image.vendor="container project" \
    org.opencontainers.image.version="1" \
    io.github.stephenlclarke.container.source-sha256="${SERVICE_SOURCE_SHA256}"

ENTRYPOINT ["/usr/local/libexec/container-gelf-service"]

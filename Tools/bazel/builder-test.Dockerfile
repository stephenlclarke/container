ARG BUILD_IMAGE=docker.io/library/golang@sha256:56961d79ea8129efddcc0b8643fd8a5416b4e6228cfd477e3fd61deb2672c587
FROM ${BUILD_IMAGE} AS tests
RUN apk add --no-cache build-base
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY . .
# Test the exact production image toolchain; go.mod declares a minimum version.
RUN mkdir /evidence && go version > /evidence/toolchain.txt
RUN test -z "$(gofmt -l ./*.go ./pkg)"
RUN --mount=type=cache,target=/root/.cache/go-build go vet -mod=vendor ./...
RUN --mount=type=cache,target=/root/.cache/go-build \
    (go test -mod=vendor -race -coverprofile=/evidence/coverage.out -json ./... > /evidence/tests.json; \
    result=$?; cat /evidence/tests.json; exit "$result")
RUN go tool cover -func=/evidence/coverage.out > /evidence/coverage-summary.txt
FROM scratch AS evidence
COPY --from=tests /evidence/ /

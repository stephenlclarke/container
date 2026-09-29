# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Container-only Bazel qualification. See Tools/bazel/README.md.
LAYER ?= container
PREFLIGHT_PROFILE ?= build
RUNNER_APP_OUTPUT ?= $(QUALIFICATION_EVIDENCE)/Container Build Runner.app
RUNNER_SIGNING_IDENTITY ?= BDDA5D3A8836437C2EFA24CDACE0FEBFBEF20633
.PHONY: bazel-runner-app
# Build only; an operator must associate an idle runner during one-time setup.
bazel-runner-app:
	@test ! -e "$(RUNNER_APP_OUTPUT)" || { printf '%s\n' 'Choose a new RUNNER_APP_OUTPUT; existing apps are preserved.'; exit 2; }
	@mkdir -p "$(RUNNER_APP_OUTPUT)/Contents/MacOS"
	@cp Tools/bazel/runner/Info.plist "$(RUNNER_APP_OUTPUT)/Contents/Info.plist"
	@xcrun swiftc -O Tools/bazel/runner/RunnerMain.swift -o "$(RUNNER_APP_OUTPUT)/Contents/MacOS/ContainerBuildRunner"
	@codesign --force --options runtime --timestamp=none --sign "$(RUNNER_SIGNING_IDENTITY)" "$(RUNNER_APP_OUTPUT)"
	@codesign --verify --strict "$(RUNNER_APP_OUTPUT)"
.PHONY: bazel-preflight bazel-repository-test
bazel-preflight:
	@python3 Tools/bazel/preflight.py --profile "$(PREFLIGHT_PROFILE)"
bazel-repository-test:
	@Tools/bazel/run.sh test //:repository-tests
.PHONY: bazel-build bazel-test bazel-host-test bazel-tools-test
bazel-build:
	@Tools/bazel/run.sh build //:$(LAYER)
bazel-test:
	@Tools/bazel/run.sh test //:$(LAYER)-tests
bazel-host-test:
	@env -u CI Tools/bazel/run.sh test //:$(LAYER)-host-tests --test_env=CI --test_env=CONTAINER_HOST_TESTS=1 --strategy=TestRunner=local --test_timeout=120 --nocache_test_results
bazel-tools-test:
	@for script in Tools/bazel/*.sh; do bash -n "$$script" || exit; done
	@shellcheck Tools/bazel/*.sh
	@Tools/bazel/run.sh --help
	@Tools/bazel/test_runner.sh --help
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/bazel -p 'test_*.py'

.PHONY: bazel-dependency-test bazel-test-all bazel-check
bazel-dependency-test:
	@Tools/bazel/run.sh test //:dependency-tests
bazel-test-all:
	@Tools/bazel/run.sh test //:qualified-tests
bazel-check: bazel-tools-test
	@$(MAKE) bazel-build
	@$(MAKE) bazel-test

.PHONY: bazel-integration-build bazel-integration-test
bazel-integration-build:
	@Tools/bazel/run.sh build //:runtime-integration
bazel-integration-test:
	@test -n "$(CONTAINER_CLI_PATH)" && test -x "$(CONTAINER_CLI_PATH)" || { echo "Set CONTAINER_CLI_PATH to the CLI for the prepared test installation."; exit 2; }
	@Tools/bazel/run.sh test //:runtime-integration-tests --test_env=CONTAINER_CLI_PATH="$(CONTAINER_CLI_PATH)" --strategy=TestRunner=local --nocache_test_results --test_timeout=1800

.PHONY: bazel-runtime-integration
bazel-runtime-integration:
	@test -n "$(PREPARED_RUNTIME)" || { printf '%s\n' 'Set PREPARED_RUNTIME to matching runtime preparation evidence.'; exit 2; }
	@python3 Tools/bazel/runtime_integration.py --prepared "$(PREPARED_RUNTIME)" \
		--evidence "$(QUALIFICATION_EVIDENCE)/integration" $(INTEGRATION_ARGS)

.PHONY: bazel-eof-integration
bazel-eof-integration:
	@test -n "$(PREPARED_RUNTIME)" || { printf '%s\n' 'Set PREPARED_RUNTIME to matching runtime preparation evidence.'; exit 2; }
	@python3 Tools/bazel/runtime_integration.py --prepared "$(PREPARED_RUNTIME)" \
		--evidence "$(QUALIFICATION_EVIDENCE)/eof-integration" \
		--layer Run --test-filter '^TestCLIPrimaryInputEOF/'

.PHONY: bazel-release-artifact
bazel-release-artifact:
	@test -n "$(PREPARED_RUNTIME)" && test -n "$(SERVICE_ARTIFACTS)" || { printf '%s\n' 'Set PREPARED_RUNTIME and SERVICE_ARTIFACTS to source-matched evidence.'; exit 2; }
	@python3 Tools/bazel/release_artifact.py --prepared "$(PREPARED_RUNTIME)" \
		--service-artifacts "$(SERVICE_ARTIFACTS)" --evidence "$(QUALIFICATION_EVIDENCE)/release" $(RELEASE_ARGS)

.PHONY: bazel-service-artifacts
bazel-service-artifacts:
	@python3 Tools/bazel/service_artifacts.py --context "$(DOCKER_CONTEXT)" --evidence "$(QUALIFICATION_EVIDENCE)/services"

.PHONY: bazel-service-integration bazel-quality bazel-github-quality
bazel-service-integration:
	@python3 Tools/bazel/service_integration.py --context "$(DOCKER_CONTEXT)" --evidence "$(QUALIFICATION_EVIDENCE)/service-integration"
bazel-quality:
	@python3 Tools/bazel/quality.py --coverage "$(QUALIFICATION_EVIDENCE)/combined-coverage" --evidence "$(QUALIFICATION_EVIDENCE)/quality"
bazel-github-quality:
	@python3 Tools/bazel/github_quality.py --evidence "$(QUALIFICATION_EVIDENCE)/github-quality"

.PHONY: bazel-vm-integration
bazel-vm-integration:
	@python3 Tools/bazel/vm_integration.py --guest-artifact "$(QUALIFICATION_EVIDENCE)/guest-runc/guest-artifact.json" \
		--evidence "$(QUALIFICATION_EVIDENCE)/vm-integration" $(VM_INTEGRATION_ARGS)

.PHONY: bazel-maintenance
bazel-maintenance:
	@python3 Tools/bazel/maintenance.py --evidence "$(QUALIFICATION_EVIDENCE)/maintenance"

.PHONY: bazel-coverage bazel-combined-coverage
bazel-coverage:
	@python3 Tools/bazel/coverage.py --evidence "$(QUALIFICATION_EVIDENCE)/coverage"

bazel-combined-coverage:
	@python3 Tools/bazel/combined_coverage.py --unit "$(QUALIFICATION_EVIDENCE)/coverage" \
		--integration "$(QUALIFICATION_EVIDENCE)/integration/coverage" --evidence "$(QUALIFICATION_EVIDENCE)/combined-coverage"

BENCHMARK_TRIALS ?= 7
BENCHMARK_RUN ?= $(shell date -u +%Y%m%dT%H%M%SZ)
.PHONY: bazel-guest-build bazel-guest-runc-build
bazel-guest-build:
	@python3 Tools/bazel/preflight.py --profile build
	@python3 Tools/bazel/guest_artifact.py --evidence "$(HOME)/Library/Application Support/ContainerFamily/retained/container-only/guest-build/$(BENCHMARK_RUN)"
bazel-guest-runc-build:
	@python3 Tools/bazel/preflight.py --profile build
	@python3 Tools/bazel/guest_artifact.py --with-runc --evidence "$(QUALIFICATION_EVIDENCE)/guest-runc"
.PHONY: bazel-fork-benchmark
bazel-fork-benchmark:
	@python3 Tools/bazel/fork_benchmark.py \
		--evidence "$(HOME)/Library/Application Support/ContainerFamily/retained/container-only/fork-comparison/$(BENCHMARK_RUN)" \
		--scratch "/Volumes/SSD/cf/container-only/fork-comparison/$(BENCHMARK_RUN)" $(BENCHMARK_ARGS)

.PHONY: bazel-runtime-benchmark bazel-final
bazel-runtime-benchmark:
	@python3 Tools/bazel/runtime_benchmark.py --prepare --trials "$(BENCHMARK_TRIALS)" \
		--evidence "$(HOME)/Library/Application Support/ContainerFamily/retained/container-only/runtime-benchmark/$(BENCHMARK_RUN)"

# Final qualification is explicit; normal layer tests remain VM-free and cached.
bazel-final: bazel-tools-test
	@$(MAKE) bazel-test-all
	@$(MAKE) bazel-runtime-benchmark BENCHMARK_RUN="$(BENCHMARK_RUN)"

DOCKER_CONTEXT ?= colima
.PHONY: bazel-docker-benchmark
bazel-docker-benchmark:
	@python3 Tools/bazel/docker_benchmark.py --context "$(DOCKER_CONTEXT)" --trials "$(BENCHMARK_TRIALS)" \
		--evidence "$(HOME)/Library/Application Support/ContainerFamily/retained/container-only/docker-benchmark/$(BENCHMARK_RUN)"

QUALIFICATION_EVIDENCE ?= $(HOME)/Library/Application Support/ContainerFamily/retained/container-only/artifact-check/$(BENCHMARK_RUN)
.PHONY: bazel-linux-test bazel-builder-build bazel-artifact-check bazel-unattended-artifacts
bazel-linux-test:
	@python3 Tools/bazel/linux_tests.py --context "$(DOCKER_CONTEXT)" --evidence "$(QUALIFICATION_EVIDENCE)/linux"
bazel-builder-build:
	@python3 Tools/bazel/builder_artifact.py --context "$(DOCKER_CONTEXT)" --evidence "$(QUALIFICATION_EVIDENCE)/builder"
# This checkpoint consumes published guest/builder artifacts through a live CLI.
# Complete release qualification also requires the integration and release gates.
bazel-artifact-check: bazel-tools-test
	@python3 Tools/bazel/published_lower.py --kind guest --evidence "$(QUALIFICATION_EVIDENCE)/guest"
	@$(MAKE) bazel-linux-test
	@python3 Tools/bazel/published_lower.py --kind builder --evidence "$(QUALIFICATION_EVIDENCE)/builder"
	@python3 Tools/bazel/runtime_benchmark.py --prepare --candidate-only --trials 1 --context "$(DOCKER_CONTEXT)" \
		--guest-artifact "$(QUALIFICATION_EVIDENCE)/guest/guest-artifact.json" \
		--builder-artifact "$(QUALIFICATION_EVIDENCE)/builder/builder-artifact.json" \
		--evidence "$(QUALIFICATION_EVIDENCE)/runtime-smoke"
bazel-unattended-artifacts:
	@python3 Tools/bazel/unattended.py --evidence "$(QUALIFICATION_EVIDENCE)"

.PHONY: bazel-qualify bazel-unattended bazel-reference-admission bazel-unattended-reference-admission bazel-recover bazel-release-install
bazel-reference-admission:
	@python3 Tools/bazel/qualification.py --reference-admission --evidence "$(QUALIFICATION_EVIDENCE)" --trials "$(BENCHMARK_TRIALS)"
bazel-unattended-reference-admission:
	@python3 Tools/bazel/unattended.py --profile release --target bazel-reference-admission --evidence "$(QUALIFICATION_EVIDENCE)"
bazel-qualify:
	@python3 Tools/bazel/qualification.py --evidence "$(QUALIFICATION_EVIDENCE)" --trials "$(BENCHMARK_TRIALS)"
bazel-unattended:
	@python3 Tools/bazel/unattended.py --profile release --target bazel-qualify --evidence "$(QUALIFICATION_EVIDENCE)"
bazel-recover:
	@python3 Tools/bazel/recover_unattended.py --evidence "$(QUALIFICATION_EVIDENCE)"
bazel-release-install:
	@python3 Tools/bazel/release_install.py --release "$(QUALIFICATION_EVIDENCE)/release" --evidence "$(QUALIFICATION_EVIDENCE)/install"

.PHONY: bazel-docs
bazel-docs:
	@python3 Tools/bazel/documentation.py --evidence "$(QUALIFICATION_EVIDENCE)/documentation"

.PHONY: bazel-codeql
bazel-codeql:
	@python3 Tools/bazel/codeql.py --evidence "$(QUALIFICATION_EVIDENCE)/codeql"

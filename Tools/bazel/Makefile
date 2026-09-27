# Container-only Bazel qualification. See Tools/bazel/README.md.
LAYER ?= container
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

BENCHMARK_TRIALS ?= 7
BENCHMARK_RUN ?= $(shell date -u +%Y%m%dT%H%M%SZ)
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

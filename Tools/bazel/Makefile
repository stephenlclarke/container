# Container-only Bazel qualification. See Tools/bazel/README.md.
LAYER ?= system
.PHONY: bazel-build bazel-test bazel-host-test bazel-tools-test
bazel-build:
	@Tools/bazel/run.sh build //:$(LAYER)
bazel-test:
	@Tools/bazel/run.sh test //:$(LAYER)-tests
bazel-host-test:
	@Tools/bazel/run.sh test //:$(LAYER)-host-tests --test_env=CONTAINER_HOST_NETWORK_TESTS=1 --test_timeout=120
bazel-tools-test:
	@for script in Tools/bazel/*.sh; do bash -n "$$script" || exit; done
	@shellcheck Tools/bazel/*.sh
	@Tools/bazel/run.sh --help
	@Tools/bazel/test_runner.sh --help
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/bazel -p 'test_*.py'

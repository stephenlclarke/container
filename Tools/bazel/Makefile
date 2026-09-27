# Container-only Bazel qualification. See Tools/bazel/README.md.
LAYER ?= system
.PHONY: bazel-build bazel-test bazel-tools-test
bazel-build:
	@Tools/bazel/run.sh build //:$(LAYER)
bazel-test:
	@Tools/bazel/run.sh test //:$(LAYER)-tests
bazel-tools-test:
	@bash -n Tools/bazel/run.sh
	@shellcheck Tools/bazel/run.sh
	@Tools/bazel/run.sh --help
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/bazel -p 'test_*.py'

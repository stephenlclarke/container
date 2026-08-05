#!/usr/bin/env python3
"""Certify an installed readable Docker logging plugin on one macOS host."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


DRIVER = "container-fixture-readable"
ALIASES = {"container-fixture", DRIVER}
DEFAULT_IMAGE = "docker.io/library/alpine:3.22"
EXPECTED_CYCLE = "plugin-bootplugin-stop"


def executable(value: str) -> str:
    candidate = Path(value).expanduser()
    if candidate.parent != Path(".") or candidate.is_absolute():
        if not candidate.is_file():
            raise argparse.ArgumentTypeError(f"executable does not exist: {candidate}")
        return str(candidate.resolve())
    resolved = shutil.which(value)
    if resolved is None:
        raise argparse.ArgumentTypeError(f"executable is not on PATH: {value}")
    return resolved


def command(
    arguments: list[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"command failed ({result.returncode}): {detail}")
    return result


def docker(arguments: argparse.Namespace, *values: str, check: bool = True):
    return command(
        [arguments.docker, "--host", arguments.docker_host, *values],
        check=check,
    )


def native(arguments: argparse.Namespace, *values: str, check: bool = True):
    return command([arguments.container, *values], check=check)


def inspect(arguments: argparse.Namespace) -> dict[str, object]:
    contents = json.loads(docker(arguments, "inspect", arguments.name).stdout)
    if not isinstance(contents, list) or len(contents) != 1:
        raise RuntimeError("Docker inspect did not return exactly one container")
    container = contents[0]
    if not isinstance(container, dict):
        raise RuntimeError("Docker inspect returned an invalid container")
    return container


def state(container: dict[str, object]) -> str:
    value = container.get("State")
    if not isinstance(value, dict) or not isinstance(value.get("Status"), str):
        raise RuntimeError("Docker inspect omitted State.Status")
    return value["Status"]


def assert_driver(container: dict[str, object]) -> None:
    host_config = container.get("HostConfig")
    if not isinstance(host_config, dict):
        raise RuntimeError("Docker inspect omitted HostConfig")
    log_config = host_config.get("LogConfig")
    if not isinstance(log_config, dict) or log_config.get("Type") != DRIVER:
        raise RuntimeError("Docker inspect did not project the selected log driver")


def wait_for_state(
    arguments: argparse.Namespace,
    expected: str,
    timeout: float = 10.0,
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    last = "unknown"
    while time.monotonic() < deadline:
        container = inspect(arguments)
        last = state(container)
        if last == expected:
            return container
        time.sleep(0.1)
    raise RuntimeError(f"Docker state remained {last!r}; expected {expected!r}")


def history(arguments: argparse.Namespace) -> str:
    return docker(arguments, "logs", arguments.name).stdout


def native_cycle(arguments: argparse.Namespace, expected_history: str) -> None:
    native(arguments, "start", arguments.name)
    container = wait_for_state(arguments, "running")
    assert_driver(container)
    native(arguments, "stop", arguments.name)
    actual = history(arguments)
    if actual != expected_history:
        raise RuntimeError(
            f"plugin history mismatch: expected {expected_history!r}, got {actual!r}"
        )


def certify(arguments: argparse.Namespace) -> dict[str, object]:
    catalogue = json.loads(docker(arguments, "info", "--format", "{{json .Plugins.Log}}").stdout)
    if not isinstance(catalogue, list) or not ALIASES.issubset(set(catalogue)):
        raise RuntimeError("installed plugin aliases are absent from Docker info")

    existing = docker(arguments, "inspect", arguments.name, check=False)
    if existing.returncode == 0:
        raise RuntimeError(f"refusing to replace existing container {arguments.name!r}")

    created = False
    try:
        native(
            arguments,
            "create",
            "--platform",
            "linux/arm64",
            "--name",
            arguments.name,
            "--log-driver",
            DRIVER,
            arguments.image,
            "sh",
            "-c",
            'echo plugin-boot; trap "echo plugin-stop; exit 0" TERM; '
            "while :; do sleep 1; done",
        )
        created = True
        assert_driver(inspect(arguments))

        native_cycle(arguments, EXPECTED_CYCLE)
        native_cycle(arguments, EXPECTED_CYCLE * 2)

        stopped = inspect(arguments)
        projected_state = state(stopped)
        public_start = docker(arguments, "start", arguments.name, check=False)
        public_control = public_start.returncode == 0
        public_control_detail = ""
        if public_control:
            wait_for_state(arguments, "running")
            public_stop = docker(arguments, "stop", "--time", "3", arguments.name)
            public_control_detail = public_stop.stdout.strip()
        else:
            public_control_detail = (
                public_start.stderr.strip() or public_start.stdout.strip()
            )

        if arguments.require_public_control and not public_control:
            raise RuntimeError(f"Docker public control is unavailable: {public_control_detail}")
        if arguments.require_state_projection and projected_state != "exited":
            raise RuntimeError(
                "Docker stopped-state projection is "
                f"{projected_state!r}, expected 'exited'"
            )

        return {
            "catalogueAliases": sorted(ALIASES),
            "driver": DRIVER,
            "history": history(arguments),
            "nativeLifecycleCycles": 2,
            "publicControl": {
                "available": public_control,
                "detail": public_control_detail,
            },
            "publicInspect": True,
            "publicLogs": True,
            "schemaVersion": 1,
            "stoppedStateProjection": projected_state,
        }
    finally:
        if created:
            native(arguments, "delete", "--force", arguments.name, check=False)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", type=executable, default="container")
    parser.add_argument("--docker", type=executable, default="docker")
    parser.add_argument("--docker-host", required=True)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--name", default="logging-plugin-certification")
    parser.add_argument("--require-public-control", action="store_true")
    parser.add_argument("--require-state-projection", action="store_true")
    return parser.parse_args()


def main() -> int:
    try:
        evidence = certify(parse_arguments())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"Docker plugin certification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

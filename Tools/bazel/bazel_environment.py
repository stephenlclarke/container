"""Limit Bazel's recorded client environment to intentional build inputs."""

from collections.abc import Mapping
import os
import sys


BUILD_VARIABLES = frozenset({
    'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ',
    'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'GIT_COMMIT', 'CI',
})
BUILD_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
BUILD_TEMP = '/Volumes/SSD/cf/container-only/tmp/'


def bazel_environment(source: Mapping[str, str]) -> dict[str, str]:
    # Bazel records client_env in its event stream. Never inherit credentials,
    # including unknown names; quality/notary dispatch keeps its own environment.
    environment = {key: value for key, value in source.items() if key in BUILD_VARIABLES}
    environment.update(PATH=BUILD_PATH, TMPDIR=BUILD_TEMP, TMP=BUILD_TEMP, TEMP=BUILD_TEMP)
    return environment


if __name__ == '__main__':
    os.execve(sys.argv[1], sys.argv[1:], bazel_environment(os.environ))

#!/usr/bin/env python3
"""Bounded, noninteractive admission checks; never emit credential values."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request

from runtime_benchmark import IDENTITY, BAZEL, BAZEL_SHA, STORAGE

CONFIG = Path.home() / 'Library/Application Support/ContainerFamily/config/unattended.json'


def command(args: list[str], *, env: dict | None = None, timeout: int = 20) -> tuple[int, str]:
    """Capture diagnostics privately: only explicit, safe fields reach the report."""
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, timeout=timeout, env=env)
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''


def github_environment() -> dict:
    # Interactive `gh auth refresh` updates the keyring, not an inherited token.
    # Use the keyring consistently for publication and permission admission.
    return {k: v for k, v in os.environ.items() if k not in {'GH_TOKEN', 'GITHUB_TOKEN'}}


def token_scopes(headers: str) -> set[str]:
    match = re.search(r'^x-oauth-scopes:\s*(.*)$', headers, re.I | re.M)
    return {scope.strip() for scope in match[1].split(',')} if match else set()


def sonar_authenticated() -> bool:
    token = os.environ.get('SONAR_TOKEN') or os.environ.get('SONAR_TOKEN_PERSONAL')
    if not token:
        return False
    encoded = base64.b64encode((token + ':').encode()).decode()
    request = urllib.request.Request('https://sonarcloud.io/api/authentication/validate',
                                     headers={'Authorization': 'Basic ' + encoded})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response).get('valid') is True
    except (OSError, ValueError, urllib.error.URLError):
        return False


def check(profile: str, config: dict) -> dict:
    checks = []

    def record(name: str, ready: bool, action: str) -> None:
        checks.append({'check': name, 'ready': ready, 'action': '' if ready else action})

    enrollment = Path.home() / 'Library/Application Support/ContainerFamily/retained/workflow/ssd-volume.uuid'
    status, raw = command(['/usr/sbin/diskutil', 'info', '-plist', '/Volumes/SSD'])
    try:
        disk = plistlib.loads(raw.encode()) if status == 0 else {}
        enrolled = enrollment.read_text().strip()
        disk_ready = (disk.get('VolumeUUID') == enrolled and disk.get('MountPoint') == '/Volumes/SSD'
                      and disk.get('Internal') is False)
    except (OSError, ValueError, plistlib.InvalidFileException):
        disk_ready = False
    record('enrolled-ssd', disk_ready, 'Connect the enrolled external SSD; do not redirect the workflow to another disk.')
    try:
        bazel_ready = hashlib.sha256(BAZEL.read_bytes()).hexdigest() == BAZEL_SHA
    except OSError:
        bazel_ready = False
    record('pinned-bazel', bazel_ready, 'Restore the checksum-pinned Bazel executable recorded in the workflow.')
    for name in ['python3', 'shellcheck', 'git']:
        record('tool-' + name, shutil.which(name) is not None, 'Install ' + name + ' before starting verification.')
    status, _ = command(['/usr/bin/xcrun', 'swift', '--version'])
    record('swift-toolchain', status == 0, 'Select the supported Xcode/Swift toolchain and finish its first-launch setup.')

    if profile in {'runtime', 'release'}:
        identity = config.get('signing_identity', IDENTITY)
        status, identities = command(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
        signing_ready = status == 0 and identity in identities
        if signing_ready and disk_ready:
            STORAGE.joinpath('tmp').mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='signing-preflight-', dir=STORAGE / 'tmp') as directory:
                probe = Path(directory) / 'probe'
                # Preserve executable contents, never the protected system flags.
                shutil.copyfile('/usr/bin/true', probe)
                probe.chmod(0o700)
                status, _ = command(['/usr/bin/codesign', '--force', '--sign', identity,
                                     '--timestamp=none', str(probe)])
                signing_ready = status == 0
                if signing_ready:
                    status, _ = command(['/usr/bin/codesign', '--verify', '--strict', str(probe)])
                    signing_ready = status == 0
        record('unattended-signing', signing_ready, 'Unlock the signing Keychain and authorize codesign for the configured Developer ID key during setup.')
        for name in ['docker', 'colima']:
            record('tool-' + name, shutil.which(name) is not None, 'Install ' + name + ' before runtime verification.')
        status, output = command(['/bin/launchctl', 'list'])
        active = [parts[2] for line in output.splitlines() if len(parts := line.split()) == 3
                  and parts[0] != '-' and parts[2].startswith(('com.apple.container.', 'sh.brew.container'))]
        record('apple-runtime-slot', status == 0 and not active,
               'Stop the existing Apple/Homebrew container installation after saving its workloads; the verifier will not displace an active installation.')

    if profile == 'release':
        record('tool-codeql', (STORAGE / 'toolchains/codeql-2.27.1/codeql/codeql').is_file(),
               'Install the checksum-pinned CodeQL 2.27.1 macOS toolchain in container-only storage before release qualification.')
        status, _ = command([str(STORAGE / 'toolchains/codeql-2.27.1/codeql/swift/tools/osx64/extractor'), '--version'], timeout=45)
        record('codeql-swift-extractor', status == 0,
               'Install Apple Rosetta during setup and verify the pinned CodeQL Swift extractor launches before release qualification.')
        for name in ['sonar-scanner', 'crane']:
            record('tool-' + name, shutil.which(name) is not None, 'Install ' + name + ' before release qualification.')
        status, response = command(['gh', 'api', '--include', 'user'], env=github_environment())
        scopes = token_scopes(response)
        record('github-repository-and-package-access', status == 0 and {'repo', 'write:packages'} <= scopes,
               'Run env -u GITHUB_TOKEN -u GH_TOKEN gh auth refresh --hostname github.com --scopes read:packages,write:packages and complete browser authorization.')
        record('sonar-authentication', sonar_authenticated(), 'Configure a valid Sonar token through the existing secure credential source.')
        from quality import analysis_context
        try:
            revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
            analysis_context(revision)
            quality_context_ready = True
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            quality_context_ready = False
        record('sonar-analysis-context', quality_context_ready,
               'Push this committed topic branch to its existing Stephen-owned pull request targeting main before qualification.')
        notary_profile = config.get('notary_profile')
        status = 2
        if isinstance(notary_profile, str) and notary_profile.strip():
            status, _ = command(['/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile',
                                 notary_profile, '--output-format', 'json'], timeout=30)
        record('apple-notarization', status == 0,
               'Store notarization credentials using xcrun notarytool store-credentials, then set notary_profile in the local unattended configuration.')

    return {'schema': 1, 'profile': profile, 'ready': all(row['ready'] for row in checks),
            'checks': checks,
            'limits': ['This does not grant or certify macOS privacy permissions. Live tests use bounded probes and report any missing approval.',
                       'Credential checks do not establish repository-specific quality gates or release qualification.']}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['build', 'runtime', 'release'], default='build')
    parser.add_argument('--config', type=Path, default=CONFIG)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text()) if args.config.exists() else {}
        if not isinstance(config, dict):
            raise ValueError('Expected an object')
    except (OSError, ValueError):
        # A parse error can contain the input itself, including pasted credentials.
        report = {'schema': 1, 'profile': args.profile, 'ready': False,
                  'checks': [{'check': 'configuration', 'ready': False,
                              'action': 'Repair the local JSON configuration; keep credential values in Keychain or the existing secure source.'}]}
    else:
        try:
            report = check(args.profile, config)
        except (OSError, ValueError) as error:
            report = {'schema': 1, 'profile': args.profile, 'ready': False,
                      'checks': [{'check': 'preflight-execution', 'ready': False,
                                  'action': 'Inspect local preflight setup (' + type(error).__name__ + '); no build was started.'}]}
    output = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output)
    print(output, end='')
    return 0 if report['ready'] else 2


if __name__ == '__main__':
    raise SystemExit(main())

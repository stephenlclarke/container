#!/usr/bin/env python3
"""Package verified Bazel outputs with the original release recipe and optional notarization."""

import argparse
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

from fork_benchmark import ROOT, STORAGE, Runner, digest, install_signal_handlers
from preflight import CONFIG
from runtime_benchmark import IDENTITY
from runtime_integration import verify_prepared

SERVICES = {'journald': 'ContainerJournaldService', 'gelf': 'ContainerGELFService'}


def run_command(runner: Runner, name: str, args: list[str], timeout: int = 300) -> Path:
    row = runner.run('release', 'fork', name, 0, args, ROOT, timeout)
    if row['status']:
        raise RuntimeError(name + ' failed; see ' + row['log'])
    return Path(row['log'])


def copy_products(prepared: Path, output: Path) -> dict:
    """Reject changed outputs before the packaging recipe re-signs its own copies."""
    fingerprint = json.loads((prepared / 'fork-fingerprint.json').read_text())
    install = Path(fingerprint['install'])
    output.mkdir()
    for relative, expected in fingerprint['binaries'].items():
        source = install / relative
        if digest(source) != expected:
            raise RuntimeError('Prepared release output changed: ' + relative)
        destination = output / source.name
        if destination.exists():
            raise RuntimeError('Ambiguous product name: ' + source.name)
        shutil.copyfile(source, destination)
        destination.chmod(0o755 if source.suffix != '.json' else 0o644)
    return fingerprint


def service_directories(runner: Runner, receipt: Path, output: Path) -> dict[str, Path]:
    """Revalidate the original source-bound manifests; a seed receipt is not proof."""
    assets = json.loads(receipt.read_text())['assets']
    if sorted(row['service'] for row in assets) != sorted(SERVICES):
        raise RuntimeError('Expected exactly the journald and gelf service artifacts')
    directories = {}
    for row in assets:
        name = row['service']
        destination = output / name
        destination.mkdir(parents=True)
        for field, suffix in [('archive', '.oci.tar'), ('manifest', '.manifest.json')]:
            shutil.copyfile(row[field], destination / ('container-' + name + '-service' + suffix))
        tool = ROOT / 'Tools' / SERVICES[name] / 'build.py'
        run_command(runner, name + '-verify', ['python3', str(tool), 'verify',
                    '--archive', str(destination / ('container-' + name + '-service.oci.tar')),
                    '--manifest', str(destination / ('container-' + name + '-service.manifest.json'))])
        directories[name] = destination
    return directories


def notarize(runner: Runner, archive: Path, profile: str) -> dict:
    """Persist the submission ID before bounded waiting, including failure logs."""
    common = ['--keychain-profile', profile, '--output-format', 'json', '--no-progress']
    submitted = run_command(runner, 'notary-submit',
                            ['xcrun', 'notarytool', 'submit', str(archive), *common], 600)
    record = json.loads(submitted.read_text())
    submission = record['id']
    (runner.evidence / 'notary-submission.json').write_text(json.dumps(record, indent=2) + '\n')
    row = runner.run('release', 'fork', 'notary-wait', 0,
                     ['xcrun', 'notarytool', 'wait', submission, '--timeout', '30m', *common], ROOT, 1830)
    status_log = run_command(runner, 'notary-info', ['xcrun', 'notarytool', 'info', submission, *common])
    status = json.loads(status_log.read_text())
    (runner.evidence / 'notary-status.json').write_text(json.dumps(status, indent=2) + '\n')
    if status['status'] in {'Accepted', 'Invalid', 'Rejected'}:
        run_command(runner, 'notary-log', ['xcrun', 'notarytool', 'log', submission,
                    '--keychain-profile', profile, str(runner.evidence / 'notary-log.json')])
    if row['status'] or status['status'] != 'Accepted':
        raise RuntimeError('Notarization did not reach Accepted; submission ' + submission)
    return status


def build(evidence: Path, prepared: Path, services: Path, profile: str | None) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    runner.env['COPYFILE_DISABLE'] = '1'
    result = {'passed': False, 'notarized': False, 'failures': []}
    try:
        verify_prepared(prepared)
        for name in ['source-inputs.json', 'fork-fingerprint.json', 'guest-artifact.json', 'builder-artifact.json']:
            shutil.copy2(prepared / name, evidence / name)
        (STORAGE / 'release').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='package-', dir=STORAGE / 'release') as temporary:
            work = Path(temporary)
            products = work / 'products'
            copy_products(prepared, products)
            directories = service_directories(runner, services, work / 'services')
            archive = work / 'container-homebrew-arm64.tar.gz'
            package_arguments = ['make', '-o', 'build', '-o', 'semantic-helper',
                        'BUILD_CONFIGURATION=release', 'BUILD_BIN_DIR=' + str(products),
                        'STAGING_DIR=' + str(work / 'staging') + '/', 'HOMEBREW_ARCHIVE=' + str(archive),
                        'SEMANTIC_HELPER_BINARY=' + str(products / 'container-semantic-helper'),
                        'SEMANTIC_HELPER_MANIFEST=' + str(products / 'container-semantic-helper.manifest.json'),
                        'JOURNALD_SERVICE_BUILD_DIR=' + str(directories['journald']),
                        'GELF_SERVICE_BUILD_DIR=' + str(directories['gelf']),
                        'CONTAINER_SERVICE_WORKLOADS_PREBUILT=true',
                        'CODESIGN_OPTS=--force --sign ' + IDENTITY + ' --options runtime --timestamp']
            run_command(runner, 'package', package_arguments + ['homebrew-package'], 600)
            retained = evidence / archive.name
            shutil.copyfile(archive, retained)
            shutil.copyfile(Path(str(archive) + '.sha256'), Path(str(retained) + '.sha256'))
            run_command(runner, 'verify-signatures', ['bash', 'Scripts/verify-developer-id-archive.sh', str(retained)])
            # Apple's notary service accepts ZIP, PKG and DMG. Keep the original
            # tar distribution and submit the identical signed payload as ZIP.
            payload = work / 'payload'
            payload.mkdir()
            with tarfile.open(retained) as package:
                package.extractall(payload, filter='data')
            zip_archive = evidence / 'container-homebrew-arm64.zip'
            run_command(runner, 'zip', ['ditto', '-c', '-k', str(payload), str(zip_archive)])
            run_command(runner, 'installed-version', [str(payload / 'bin/container'), '--version'])
            verify_prepared(prepared)
            installer = evidence / 'container-installer-unsigned.pkg'
            run_command(runner, 'installer', package_arguments + ['installer-pkg', 'PKG_PATH=' + str(installer)], 600)
            run_command(runner, 'installer-expand', ['pkgutil', '--expand-full', str(installer), str(work / 'installer')])
            installer_payload = work / 'installer/Payload'
            # The native installer excludes only Homebrew's pre-upgrade guard script.
            expected_installer = {str(p.relative_to(payload)): digest(p) for p in payload.rglob('*')
                                  if p.is_file() and p.relative_to(payload).as_posix() != 'libexec/ensure-container-stopped.sh'}
            # Signing timestamps can differ between the two original recipes. Verify
            # Mach-O signatures separately and compare every non-Mach-O payload file.
            for relative in expected_installer:
                installed = installer_payload / relative
                if not installed.is_file():
                    raise RuntimeError('Installer omitted payload: ' + relative)
                if installed.read_bytes()[:4] in {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'}:
                    run_command(runner, 'installer-signature-' + installed.name,
                                ['codesign', '--verify', '--strict', str(installed)])
                elif relative.endswith('container-semantic-helper.manifest.json'):
                    continue  # The original recipe verifies this signed-binary hash manifest.
                elif digest(installed) != expected_installer[relative]:
                    raise RuntimeError('Installer payload differs from archive: ' + relative)
            actual_installer = {str(p.relative_to(installer_payload)) for p in installer_payload.rglob('*') if p.is_file()}
            if actual_installer != set(expected_installer):
                raise RuntimeError('Installer contains unexpected payload files')
            result['installer_signed'] = False
            symbols = json.loads((prepared / 'debug-symbols.json').read_text())
            if digest(Path(symbols['archive'])) != symbols['sha256']:
                raise RuntimeError('Release debug-symbol archive changed')
            shutil.copy2(symbols['archive'], evidence / 'container-dSYM.zip')
            result['debug_symbols'] = symbols
            result['archives'] = {p.name: digest(p) for p in (retained, zip_archive, installer, evidence / 'container-dSYM.zip')}
            result['payload'] = {str(p.relative_to(payload)): digest(p) for p in sorted(payload.rglob('*')) if p.is_file()}
            result['source'] = json.loads((prepared / 'source-inputs.json').read_text())['fork']
            if profile:
                result['notary'] = notarize(runner, zip_archive, profile)
                result['notarized'] = True
            result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'release-artifact.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--service-artifacts', type=Path, required=True, help='Journald/GELF archive and manifest paths')
    parser.add_argument('--notarize', action='store_true')
    args = parser.parse_args()
    profile = None
    if args.notarize:
        profile = json.loads(CONFIG.read_text()).get('notary_profile')
        if not profile:
            parser.error('Configure a Keychain notary_profile before requesting notarization')
    build(args.evidence, args.prepared, args.service_artifacts, profile)


if __name__ == '__main__':
    main()

"""Authenticate the supplemental Q153 Colima configuration used by Docker timing."""

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile

from benchmark_reference import ARCHIVE_SHA256, ASSET_ID as BENCHMARK_ASSET_ID, SOURCE, TAG

NAME = 'historical-container-environment-15361ce5.json'
SUPPLEMENT_TAG = 'benchmark-environment-15361ce5-5e990fc9faa2'
RELEASE_ID = 399337224
ASSET_ID = 598691544
ASSET_SHA256 = '5e990fc9faa271f71c860284f6653967c1fdbe9423f650aea38b130d8f2a8e58'
LEASE_SHA256 = '5830bb2dd792af7cc01e087ed8b7b2dc945e3a2fd8ab9410760f864af509e4b2'
QUALIFICATION_SHA256 = '2e38085862eb51d860448f2379362ca01c6e14febd9f564e00004be66f8044fb'
ACCEPTANCE_SHA256 = '92aa06fc1bbbbbaea046165c3dfc841f384766abd1ac46f406ff81c79fe5fb2e'
DOCKER_INFO_SHA256 = '065584927ca7e3473cd13bb20e81401d397c1cdf7f027cc7a7a2250fe376dff4'
CACHE_ROOT = Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/benchmark-references'
PROFILE_KEYS = {'name', 'status', 'arch', 'cpus', 'memory', 'disk', 'runtime'}
LEASE_KEYS = {'started_by_this_run', 'restored', 'profile', 'docker_context', 'config_sha256'}
STAGES = ('tools', 'dependencies', 'container', 'maintenance', 'documentation', 'host',
          'guest', 'guest-runc', 'linux', 'builder', 'services', 'service-integration',
          'runtime-smoke', 'vm-integration', 'integration', 'coverage', 'combined-coverage',
          'component-benchmarks', 'runtime-benchmark', 'docker-benchmark',
          'github-quality', 'release', 'install')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def configuration(lease: dict) -> dict:
    """Keep the acquisition identity; restoration status is operational state."""
    if set(lease) != LEASE_KEYS or set(lease['profile']) != PROFILE_KEYS:
        raise RuntimeError('Colima lease schema differs from the pinned historical record')
    profile = lease['profile']
    if (lease['started_by_this_run'] is not True or profile['name'] != 'default'
            or profile['status'] != 'Stopped' or profile['arch'] != 'aarch64'
            or profile['runtime'] != 'docker' or lease['docker_context'] != 'default'
            or not isinstance(profile['cpus'], int) or isinstance(profile['cpus'], bool)
            or not isinstance(profile['memory'], int) or isinstance(profile['memory'], bool)
            or not isinstance(profile['disk'], int) or isinstance(profile['disk'], bool)
            or min(profile['cpus'], profile['memory'], profile['disk']) <= 0
            or not isinstance(lease['config_sha256'], str)
            or len(lease['config_sha256']) != 64):
        raise RuntimeError('Colima configured resource identity is invalid')
    return {'profile': profile, 'restorationContextBefore': lease['docker_context'],
            'configSHA256': lease['config_sha256']}


def read(path: Path) -> dict:
    if not isinstance(ASSET_ID, int) or not isinstance(ASSET_SHA256, str) or len(ASSET_SHA256) != 64:
        raise RuntimeError('Supplemental Docker environment asset has no published lock')
    if path.is_symlink() or not path.is_file() or sha256(path.read_bytes()) != ASSET_SHA256:
        raise RuntimeError('Supplemental Docker environment asset differs from published digest')
    document = json.loads(path.read_text())
    expected_keys = {'schema', 'kind', 'source', 'run', 'historical', 'derivedFromRetainedEvidence',
                     'benchmarkReference', 'publishedQualificationProvenance', 'qualification',
                     'colimaLease', 'observedDockerEngine', 'reviewedAtUTC', 'limitation',
                     'benchmarkDockerContext'}
    if (set(document) != expected_keys or document['schema'] != 1
            or document['kind'] != 'historical-container-configured-environment'):
        raise RuntimeError('Supplemental Docker environment schema differs')
    benchmark = document['benchmarkReference']
    if (set(benchmark) != {'repository', 'tag', 'releaseId', 'assetId', 'asset', 'sha256', 'sourceLogSHA256'}
            or benchmark != {'repository': 'stephenlclarke/container', 'tag': TAG,
                             'releaseId': 398272413, 'assetId': BENCHMARK_ASSET_ID,
                             'asset': 'historical-container-benchmark-15361ce5.zip',
                             'sha256': ARCHIVE_SHA256, 'sourceLogSHA256': DOCKER_INFO_SHA256}):
        raise RuntimeError('Supplemental Docker benchmark reference differs')
    published = document['publishedQualificationProvenance']
    if (set(published) != {'repository', 'tag', 'releaseId', 'assetId', 'asset', 'sha256',
                            'acceptanceSHA256'}
            or published != {'repository': 'stephenlclarke/container', 'tag': TAG,
                             'releaseId': 398272413, 'assetId': 595467023,
                             'asset': 'qualified-container-assets.json',
                             'sha256': '5d0247f127067a7fa420fe9e75aecc22096d26c8f542bf6548d20d6a45def08a',
                             'acceptanceSHA256': ACCEPTANCE_SHA256}):
        raise RuntimeError('Supplemental Docker qualification provenance differs')
    qualification = document['qualification']
    if (set(qualification) != {'sha256', 'passed', 'source', 'failures', 'stages'}
            or qualification['sha256'] != QUALIFICATION_SHA256
            or qualification['passed'] is not True or qualification['source'] != SOURCE
            or qualification['failures'] != []
            or qualification['stages'] != [
                {'name': name, 'state': 'reviewed-differences' if name == 'component-benchmarks' else 'passed'}
                for name in STAGES
            ]):
        raise RuntimeError('Supplemental Docker accepted qualification differs')
    lease = document['colimaLease']
    try:
        reviewed_at = datetime.fromisoformat(document['reviewedAtUTC'])
    except (TypeError, ValueError):
        reviewed_at = None
    if (set(lease) != {'sha256', 'utf8'} or lease['sha256'] != LEASE_SHA256
            or document['source'] != SOURCE or document['run'] != '15361ce5-20260928T090931Z'
            or document['historical'] is not True or document['derivedFromRetainedEvidence'] is not True
            or document['observedDockerEngine'].get('sourceLogSHA256') != DOCKER_INFO_SHA256
            or document['benchmarkDockerContext'] != 'colima'
            or reviewed_at is None or reviewed_at.utcoffset() != timezone.utc.utcoffset(None)
            or not isinstance(document['limitation'], str) or not document['limitation']):
        raise RuntimeError('Supplemental Docker environment provenance differs')
    raw = lease['utf8'].encode('utf-8')
    if sha256(raw) != LEASE_SHA256:
        raise RuntimeError('Original Colima lease differs from retained accepted bytes')
    document['configuredEnvironment'] = configuration(json.loads(raw))
    return document


def fetch() -> dict:
    """Fetch once; exact bytes and historical provenance are rechecked offline."""
    if not isinstance(ASSET_ID, int) or not isinstance(ASSET_SHA256, str) or len(ASSET_SHA256) != 64:
        raise RuntimeError('Supplemental Docker environment asset has no published lock')
    target = CACHE_ROOT / ASSET_SHA256 / NAME
    if target.exists() or target.is_symlink():
        return read(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.docker-environment-', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            subprocess.run(['gh', 'api', '--hostname', 'github.com',
                            f'repos/stephenlclarke/container/releases/assets/{ASSET_ID}',
                            '-H', 'Accept: application/octet-stream'], stdout=stream,
                           stdin=subprocess.DEVNULL, check=True, timeout=120)
        document = read(Path(temporary))
        os.replace(temporary, target)
        return document
    finally:
        Path(temporary).unlink(missing_ok=True)

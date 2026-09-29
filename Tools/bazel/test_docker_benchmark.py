"""Reuse the Docker reference without dispatching any historical workload."""

import json
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import docker_benchmark as docker
import docker_resource_reference as resource


def sample_reference():
    rows = [dict(component='runtime-stack', lane='docker', fixture=fixture, trial=trial,
                 seconds=1.0, status=0) for fixture in docker.FIXTURES for trial in range(1, 8)]
    rows += [dict(component='runtime-stack', lane='docker', fixture='setup-' + str(index), trial=0,
                  seconds=1.0, status=0) for index in range(16)]
    return {'identityLimit': 'Historical measured binary differs from released binary.',
            'protocol': {'dockerContext': 'colima', 'dockerTrials': 7, 'dockerImage': docker.ALPINE,
                         'dockerArchitecture': 'linux/arm64', 'dockerServiceCPUs': 1, 'dockerServiceMemory': '512m',
                         'dockerEngine': dict(docker.engine_identity(VERSION, INFO, '5.5.1'),
                                              sourceLogSHA256=resource.DOCKER_INFO_SHA256)},
            'phaseHosts': {'runtimeBenchmark': dict(model='M', memoryBytes=1, macOSVersion='27', macOSBuild='A', architecture='arm64')},
            'docker': {'raw': rows, 'medians': {fixture: 1 for fixture in docker.FIXTURES}}}


VERSION = {'Client': {'Version': '29.8.1'}, 'Server': {'Version': '29.2.1'}}
INFO = {'Architecture': 'aarch64', 'CgroupVersion': '2', 'NCPU': 4, 'MemTotal': 8309010432,
        'KernelVersion': '6.8.0-100-generic', 'OperatingSystem': 'Ubuntu 24.04.4 LTS', 'Driver': 'overlayfs'}
LEASE = {'started_by_this_run': True, 'restored': False,
         'profile': {'name': 'default', 'status': 'Stopped', 'arch': 'aarch64', 'cpus': 4,
                     'memory': 8589934592, 'disk': 107374182400, 'runtime': 'docker'},
         'docker_context': 'default', 'config_sha256': '3ea581168f1773e28fda26303a3194c5439838e8e48401a6f2717731e18636c7'}
SUPPLEMENT = {'configuredEnvironment': resource.configuration(LEASE),
              'colimaLease': {'sha256': resource.LEASE_SHA256},
              'benchmarkDockerContext': 'colima',
              'observedDockerEngine': sample_reference()['protocol']['dockerEngine']}


class DockerReferenceTests(unittest.TestCase):
    def test_workload_change_rejects_reuse_before_engine_commands(self):
        source = Path(docker.__file__).read_text()
        self.assertIn('bytes(128 * 1024 * 1024)', source)
        changed = source.replace('bytes(128 * 1024 * 1024)', 'bytes(64 * 1024 * 1024)')
        with tempfile.TemporaryDirectory() as temporary, \
                patch('benchmark_reference.fetch', return_value=sample_reference()), \
                patch('docker_resource_reference.fetch', return_value=SUPPLEMENT), \
                patch('component_reference.original', return_value=changed.encode()), \
                patch.object(docker.Runner, 'run') as command:
            with self.assertRaisesRegex(RuntimeError, 'workload or timing boundary'):
                docker.reuse(Path(temporary), 'colima', 7)
            command.assert_not_called()

    def test_missing_failed_nonfinite_or_mismatched_reference_rejected(self):
        for mutation in ('trial-count', 'context', 'image', 'missing', 'duplicate', 'failure', 'nan', 'median'):
            data = sample_reference()
            if mutation == 'trial-count': data['protocol']['dockerTrials'] = 6
            if mutation == 'context': data['protocol']['dockerContext'] = 'other'
            if mutation == 'image': data['protocol']['dockerImage'] = 'other'
            if mutation == 'missing': data['docker']['raw'].pop()
            if mutation == 'duplicate': data['docker']['raw'][-1] = data['docker']['raw'][0]
            if mutation == 'failure': data['docker']['raw'][0]['status'] = 124
            if mutation == 'nan': data['docker']['raw'][0]['seconds'] = float('nan')
            if mutation == 'median': data['docker']['medians'][docker.FIXTURES[0]] = 2
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                docker.historical_samples(data, 'colima', 7)

    def test_reuse_only_checks_selected_engine_and_never_runs_workload(self):
        for changed_engine in (False, True):
            with self.subTest(changed_engine=changed_engine), tempfile.TemporaryDirectory() as temporary:
                evidence = Path(temporary) / 'evidence'
                (Path(temporary) / 'colima-lease.json').write_text(json.dumps(LEASE))
                (Path(temporary) / 'qualification.json').write_text(json.dumps({'source': 'Q-current'}))
                (Path(temporary) / 'host-lease.json').write_text(json.dumps({
                    'evidence': str(Path(temporary)), 'acquired': True, 'restored': False,
                    'owner': 100, 'command_lock': str(Path(temporary) / 'commands.lock')}))
                config = Path(temporary) / '.colima/default/colima.yaml'
                config.parent.mkdir(parents=True)
                config.write_text('memory: 8GiB\n')
                calls = []
                current_info = dict(INFO, NCPU=8) if changed_engine else dict(INFO, MemTotal=INFO['MemTotal'] + 12288)
                def run(runner, component, lane, fixture, trial, args, cwd, timeout):
                    calls.append(args)
                    output = {'engine': json.dumps(VERSION), 'engine-info': json.dumps(current_info),
                              'compose-version': 'v5.5.1'}[fixture]
                    log = evidence / (fixture + '.log')
                    log.write_text(output)
                    row = dict(status=0, log=str(log), fixture=fixture, seconds=1, trial=trial)
                    runner.rows.append(row)
                    return row
                def host(args, unused):
                    if args == ['git', 'rev-parse', 'HEAD']:
                        return 'Q-current'
                    return {'hw.model': 'M', 'hw.memsize': '1', '-productVersion': '27',
                            '-buildVersion': 'A', '-m': 'arm64'}[args[-1]]
                live = dict(LEASE['profile'], status='Running')
                with patch('benchmark_reference.fetch', return_value=sample_reference()), \
                        patch('benchmark_reference.retain'), patch('component_reference.command', side_effect=host), \
                        patch('component_reference.original', return_value=Path(docker.__file__).read_bytes()), \
                        patch.object(docker.Path, 'home', return_value=Path(temporary)), \
                        patch.object(docker, 'host_processes', return_value={
                            os.getpid(): {'uid': os.getuid(), 'parent': 100},
                            100: {'uid': os.getuid(), 'parent': 1}}), \
                        patch.dict(os.environ, {docker.COMMAND_LOCK_ENV: str(Path(temporary) / 'commands.lock')}), \
                        patch.object(docker.subprocess, 'check_output', return_value=json.dumps(live)), \
                        patch.object(docker.Runner, 'run', run):
                    # Preserve the local saved-configuration hash without accessing the real profile.
                    saved_hash = hashlib.sha256(config.read_bytes()).hexdigest()
                    current = json.loads((Path(temporary) / 'colima-lease.json').read_text())
                    current['config_sha256'] = saved_hash
                    old = resource.configuration(current)
                    patched_supplement = dict(SUPPLEMENT, configuredEnvironment=old)
                    (Path(temporary) / 'colima-lease.json').write_text(json.dumps(current))
                    with patch('docker_resource_reference.fetch', return_value=patched_supplement):
                        if changed_engine:
                            with self.assertRaisesRegex(RuntimeError, 'engine differs'):
                                docker.reuse(evidence, 'colima', 7)
                            self.assertFalse((evidence / 'acceptance.json').exists())
                        else:
                            docker.reuse(evidence, 'colima', 7)
                            result = json.loads((evidence / 'acceptance.json').read_text())
                            self.assertTrue(result['passed'])
                            self.assertTrue(result['historical'])
                            self.assertFalse(result['workloads_executed'])
                            self.assertFalse(result['assertions_replayed'])
                            admission = json.loads((evidence / 'engine-admission.json').read_text())
                            self.assertEqual(admission['usableMemoryBytes']['historical'], INFO['MemTotal'])
                            self.assertEqual(admission['usableMemoryBytes']['current'], INFO['MemTotal'] + 12288)
                            self.assertEqual(admission['usableMemoryBytes']['difference'], 12288)
                            self.assertEqual(admission['configuredEnvironment'], old)
                            raw = json.loads((evidence / 'results.json').read_text())
                            self.assertEqual(len(raw), 72)
                            self.assertTrue(all(row['historical'] for row in raw))
                self.assertEqual(calls, [['docker', '--context', 'colima', 'version', '--format', '{{json .}}'],
                                         ['docker', '--context', 'colima', 'info', '--format', '{{json .}}'],
                                         ['docker', '--context', 'colima', 'compose', 'version', '--short']])

    def test_active_qualification_rejects_stale_owner_or_wrong_command_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / 'docker-benchmark'
            lock = str(Path(temporary) / 'commands.lock')
            qualification = {'source': 'Q-current'}
            lease = {'evidence': temporary, 'acquired': True, 'restored': False,
                     'owner': 100, 'command_lock': lock}
            inventory = {201: {'uid': 501, 'parent': 100},
                         100: {'uid': 501, 'parent': 1}}
            environment = {docker.COMMAND_LOCK_ENV: lock}
            docker.require_active_qualification(evidence, qualification, lease, 'Q-current',
                                                inventory, 201, 501, environment)
            with self.assertRaisesRegex(RuntimeError, 'live ancestor'):
                docker.require_active_qualification(evidence, qualification, dict(lease, owner=999),
                                                    'Q-current', inventory, 201, 501, environment)
            with self.assertRaisesRegex(RuntimeError, 'live ancestor'):
                docker.require_active_qualification(evidence, qualification, lease, 'Q-current',
                                                    {201: {'uid': 502, 'parent': 100}, 100: inventory[100]},
                                                    201, 501, environment)
            with self.assertRaisesRegex(RuntimeError, 'active exact-source'):
                docker.require_active_qualification(evidence, qualification,
                                                    dict(lease, command_lock='/wrong/commands.lock'),
                                                    'Q-current', inventory, 201, 501, environment)
            with self.assertRaisesRegex(RuntimeError, 'active exact-source'):
                docker.require_active_qualification(evidence, qualification, lease, 'Q-current',
                                                    inventory, 201, 501,
                                                    {docker.COMMAND_LOCK_ENV: '/wrong/commands.lock'})

    def test_configured_allocation_and_every_other_engine_field_remain_exact(self):
        old = sample_reference()['protocol']['dockerEngine']
        actual = dict(docker.engine_identity(VERSION, INFO, '5.5.1'), memoryBytes=INFO['MemTotal'] + 12288)
        live = dict(LEASE['profile'], status='Running')
        config_sha = LEASE['config_sha256']
        accepted = docker.admit_engine(actual, old, SUPPLEMENT, LEASE, 'current-log-sha',
                                      'colima', live, config_sha)
        self.assertEqual(accepted['usableMemoryBytes']['difference'], 12288)
        for mutation in ('memory', 'config_sha256', 'cpus'):
            current = json.loads(json.dumps(LEASE))
            if mutation == 'config_sha256':
                current[mutation] = '0' * 64
            else:
                current['profile'][mutation] += 1
            with self.subTest(mutation=mutation), self.assertRaisesRegex(RuntimeError, 'Configured Colima'):
                docker.admit_engine(actual, old, SUPPLEMENT, current, 'current-log-sha',
                                   'colima', live, config_sha)
        for mutation in ('kernelVersion', 'storageDriver', 'serverVersion'):
            current = dict(actual, **{mutation: 'different'})
            with self.subTest(mutation=mutation), self.assertRaisesRegex(RuntimeError, 'engine differs'):
                docker.admit_engine(current, old, SUPPLEMENT, LEASE, 'current-log-sha',
                                   'colima', live, config_sha)
        for invalid in (None, 0, -1, 8589934593, True, float('nan')):
            with self.subTest(memory=invalid), self.assertRaisesRegex(RuntimeError, 'observation is invalid'):
                docker.admit_engine(dict(actual, memoryBytes=invalid), old, SUPPLEMENT, LEASE,
                                   'current-log-sha', 'colima', live, config_sha)
        for context, profile, saved in [('other', live, config_sha),
                                         ('colima', dict(live, memory=live['memory'] + 1), config_sha),
                                         ('colima', live, '0' * 64)]:
            with self.subTest(context=context, profile=profile, saved=saved), self.assertRaises(RuntimeError):
                docker.admit_engine(actual, old, SUPPLEMENT, LEASE, 'current-log-sha',
                                   context, profile, saved)
        with self.assertRaisesRegex(RuntimeError, 'already restored'):
            docker.admit_engine(actual, old, SUPPLEMENT, dict(LEASE, restored=True),
                               'current-log-sha', 'colima', live, config_sha)

    def test_supplemental_asset_and_retained_original_lease_are_hash_checked(self):
        lease_bytes = json.dumps(LEASE, indent=2).encode()
        document = {'schema': 1, 'kind': 'historical-container-configured-environment', 'source': resource.SOURCE,
                    'run': '15361ce5-20260928T090931Z', 'historical': True,
                    'derivedFromRetainedEvidence': True,
                    'benchmarkReference': {'repository': 'stephenlclarke/container', 'tag': resource.TAG,
                                           'releaseId': 398272413, 'assetId': resource.BENCHMARK_ASSET_ID,
                                           'asset': 'historical-container-benchmark-15361ce5.zip',
                                           'sha256': resource.ARCHIVE_SHA256,
                                           'sourceLogSHA256': resource.DOCKER_INFO_SHA256},
                    'publishedQualificationProvenance': {'repository': 'stephenlclarke/container',
                                                         'tag': resource.TAG, 'releaseId': 398272413,
                                                         'assetId': 595467023, 'asset': 'qualified-container-assets.json',
                                                         'sha256': '5d0247f127067a7fa420fe9e75aecc22096d26c8f542bf6548d20d6a45def08a',
                                                         'acceptanceSHA256': resource.ACCEPTANCE_SHA256},
                    'qualification': {'sha256': resource.QUALIFICATION_SHA256, 'passed': True,
                                      'source': resource.SOURCE, 'failures': [],
                                      'stages': [
                                          {'name': name, 'state': 'reviewed-differences' if name == 'component-benchmarks' else 'passed'}
                                          for name in resource.STAGES
                                      ]},
                    'colimaLease': {'utf8': lease_bytes.decode(),
                                    'sha256': hashlib.sha256(lease_bytes).hexdigest()},
                    'observedDockerEngine': sample_reference()['protocol']['dockerEngine'],
                    'benchmarkDockerContext': 'colima',
                    'reviewedAtUTC': '2026-09-29T00:00:00+00:00',
                    'limitation': 'Historical guest usable memory is an observation, not configured allocation.'}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'supplement.json'
            data = json.dumps(document).encode()
            path.write_bytes(data)
            with patch.object(resource, 'ASSET_ID', 123), \
                    patch.object(resource, 'ASSET_SHA256', hashlib.sha256(data).hexdigest()), \
                    patch.object(resource, 'LEASE_SHA256', document['colimaLease']['sha256']):
                self.assertEqual(resource.read(path)['configuredEnvironment'], resource.configuration(LEASE))
                changed = json.loads(json.dumps(document))
                changed['qualification']['stages'][0]['name'] = 'invented-stage'
                changed_bytes = json.dumps(changed).encode()
                path.write_bytes(changed_bytes)
                with patch.object(resource, 'ASSET_SHA256', hashlib.sha256(changed_bytes).hexdigest()):
                    with self.assertRaisesRegex(RuntimeError, 'accepted qualification'):
                        resource.read(path)
                document['colimaLease']['utf8'] += ' '
                path.write_text(json.dumps(document))
                with self.assertRaisesRegex(RuntimeError, 'published digest'):
                    resource.read(path)


if __name__ == '__main__':
    unittest.main()

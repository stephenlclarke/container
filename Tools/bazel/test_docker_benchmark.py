"""Reuse the Docker reference without dispatching any historical workload."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import docker_benchmark as docker


def sample_reference():
    rows = [dict(component='runtime-stack', lane='docker', fixture=fixture, trial=trial,
                 seconds=1.0, status=0) for fixture in docker.FIXTURES for trial in range(1, 8)]
    rows += [dict(component='runtime-stack', lane='docker', fixture='setup-' + str(index), trial=0,
                  seconds=1.0, status=0) for index in range(16)]
    return {'identityLimit': 'Historical measured binary differs from released binary.',
            'protocol': {'dockerContext': 'colima', 'dockerTrials': 7, 'dockerImage': docker.ALPINE,
                         'dockerArchitecture': 'linux/arm64', 'dockerServiceCPUs': 1, 'dockerServiceMemory': '512m',
                         'dockerEngine': docker.engine_identity(VERSION, INFO, '5.5.1')},
            'phaseHosts': {'runtimeBenchmark': dict(model='M', memoryBytes=1, macOSVersion='27', macOSBuild='A', architecture='arm64')},
            'docker': {'raw': rows, 'medians': {fixture: 1 for fixture in docker.FIXTURES}}}


VERSION = {'Client': {'Version': '29.8.1'}, 'Server': {'Version': '29.2.1'}}
INFO = {'Architecture': 'aarch64', 'CgroupVersion': '2', 'NCPU': 4, 'MemTotal': 8309010432,
        'KernelVersion': '6.8.0-100-generic', 'OperatingSystem': 'Ubuntu 24.04.4 LTS', 'Driver': 'overlayfs'}


class DockerReferenceTests(unittest.TestCase):
    def test_workload_change_rejects_reuse_before_engine_commands(self):
        source = Path(docker.__file__).read_text()
        self.assertIn('bytes(128 * 1024 * 1024)', source)
        changed = source.replace('bytes(128 * 1024 * 1024)', 'bytes(64 * 1024 * 1024)')
        with tempfile.TemporaryDirectory() as temporary, \
                patch('benchmark_reference.fetch', return_value=sample_reference()), \
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
                calls = []
                current_info = dict(INFO, NCPU=8) if changed_engine else INFO
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
                    return {'hw.model': 'M', 'hw.memsize': '1', '-productVersion': '27',
                            '-buildVersion': 'A', '-m': 'arm64'}[args[-1]]
                with patch('benchmark_reference.fetch', return_value=sample_reference()), \
                        patch('benchmark_reference.retain'), patch('component_reference.command', side_effect=host), \
                        patch('component_reference.original', return_value=Path(docker.__file__).read_bytes()), \
                        patch.object(docker.Runner, 'run', run):
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
                        raw = json.loads((evidence / 'results.json').read_text())
                        self.assertEqual(len(raw), 72)
                        self.assertTrue(all(row['historical'] for row in raw))
                self.assertEqual(calls, [['docker', '--context', 'colima', 'version', '--format', '{{json .}}'],
                                         ['docker', '--context', 'colima', 'info', '--format', '{{json .}}'],
                                         ['docker', '--context', 'colima', 'compose', 'version', '--short']])


if __name__ == '__main__':
    unittest.main()

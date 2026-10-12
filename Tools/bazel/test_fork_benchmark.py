"""Check that paired reporting retains failures and compares matching fixtures."""

import json
import fcntl
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import sys
import time
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from fork_benchmark import (COMMAND_LOCK_ENV, Runner, command_lease,
                            historical_cli_help_phase_ratios, tls_executable, tls_samples)


class CommandLeaseTests(unittest.TestCase):
    def test_nested_interrupt_waits_for_inner_group_and_releases_lease(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'commands.lock'
            lock.touch(mode=0o600)
            (root / 'parent-evidence').mkdir()
            (root / 'child-evidence').mkdir()
            (root / 'grandchild-evidence').mkdir()
            script = root / 'nested.py'
            tools = str(Path(__file__).resolve().parent)
            script.write_text('\n'.join([
                'import inspect, os, pathlib, signal, sys, time',
                f'sys.path.insert(0, {tools!r})',
                'from fork_benchmark import COMMAND_LOCK_ENV, Runner',
                'root = pathlib.Path(sys.argv[2])',
                'mode = sys.argv[1]',
                'if mode == "leaf":',
                '    signal.signal(signal.SIGTERM, signal.SIG_IGN)',
                '    (root / "leaf.pid").write_text(str(os.getpid()))',
                '    while True: time.sleep(1)',
                'if mode in ("child", "grandchild"):',
                '    def delayed_stop(signum, frame):',
                '        (root / (mode + "-term")).write_text(str(signum))',
                '        time.sleep(2)',
                '        raise SystemExit(128 + signum)',
                '    signal.signal(signal.SIGTERM, delayed_stop)',
                '    (root / (mode + ".pid")).write_text(str(os.getpid()))',
                'if mode == "parent":',
                '    signal.signal(signal.SIGINT, lambda signum, frame: (_ for _ in ()).throw(SystemExit(128 + signum)))',
                'runner = Runner(root / (mode + "-evidence"), root)',
                'runner.env[COMMAND_LOCK_ENV] = str(root / "commands.lock")',
                'grace = 240 if mode == "parent" else 180',
                '# The predecessor has no stop_grace parameter: exercise its real ten-second path.',
                'options = {"stop_grace": grace} if mode != "grandchild" and "stop_grace" in inspect.signature(runner.run).parameters else {}',
                'next_mode = {"parent": "child", "child": "grandchild", "grandchild": "leaf"}[mode]',
                'try:',
                '    runner.run("nested", mode, "cancel", 0, [sys.executable, __file__, next_mode, str(root)], root, timeout=35, **options)',
                'finally:',
                '    if mode in ("child", "grandchild"):',
                '        time.sleep(2)',
                '        (root / (mode + "-cleanup")).write_text("complete")',
            ]) + '\n')

            def owned_alive(pid, mode):
                row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat=,command='],
                                     capture_output=True, text=True, timeout=3).stdout.strip()
                fields = row.split(None, 1)
                return (len(fields) == 2 and not fields[0].startswith('Z')
                        and str(script) in fields[1] and f' {mode} {root}' in fields[1])

            def lease_available():
                with lock.open() as descriptor:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return True
                    except BlockingIOError:
                        return False

            parent = subprocess.Popen([sys.executable, str(script), 'parent', str(root)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      start_new_session=True)
            owned = {}
            try:
                deadline = time.monotonic() + 8
                while not (root / 'leaf.pid').exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue((root / 'leaf.pid').exists(), 'nested child did not become ready')
                owned = {mode: int((root / (mode + '.pid')).read_text()) for mode in ('child', 'grandchild', 'leaf')}
                self.assertTrue(owned_alive(owned['leaf'], 'leaf'))
                self.assertFalse(lease_available())
                os.kill(parent.pid, signal.SIGINT)
                self.assertEqual(parent.wait(timeout=25), 130)
                self.assertTrue((root / 'child-term').exists())
                self.assertTrue((root / 'grandchild-term').exists())
                self.assertFalse(owned_alive(owned['leaf'], 'leaf'))
                self.assertTrue(lease_available())
                self.assertTrue((root / 'child-cleanup').exists())
                self.assertTrue((root / 'grandchild-cleanup').exists())
            finally:
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=5)
                # A failed readiness assertion can precede the leaf PID file.
                # Match only this temporary script and root before killing fakes.
                listing = subprocess.check_output(['/bin/ps', '-axo', 'pid=,stat=,command='],
                                                  text=True, timeout=3)
                for row in listing.splitlines():
                    fields = row.split(None, 2)
                    if len(fields) != 3 or fields[1].startswith('Z') or str(script) not in fields[2]:
                        continue
                    if any(f' {mode} {root}' in fields[2] for mode in ('child', 'grandchild', 'leaf')):
                        try:
                            os.kill(int(fields[0]), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                deadline = time.monotonic() + 5
                while not lease_available() and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(lease_available(), 'fake command lease survived cleanup')

    def test_exclusive_recovery_prevents_command_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'commands.lock'
            lock.touch(mode=0o600)
            runner = Runner(root, root)
            runner.env[COMMAND_LOCK_ENV] = str(lock)
            with lock.open() as recovery, patch('fork_benchmark.subprocess.Popen') as spawn:
                fcntl.flock(recovery, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    runner.run('probe', 'fork', 'blocked', 0, ['unused'], root)
            spawn.assert_not_called()

    def test_spawn_failure_closes_command_lease(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'commands.lock'
            lock.touch(mode=0o600)
            runner = Runner(root, root)
            runner.env[COMMAND_LOCK_ENV] = str(lock)
            with self.assertRaises(FileNotFoundError):
                runner.run('probe', 'fork', 'missing', 0, [str(root / 'missing')], root)
            with lock.open() as recovery:
                fcntl.flock(recovery, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock.chmod(0o666)
            with self.assertRaisesRegex(RuntimeError, 'private single-owner'):
                with command_lease(runner.env):
                    self.fail('Unsafe lock admitted')

    def test_orphaned_make_controller_retains_lease_between_stages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'commands.lock'
            lock.touch(mode=0o600)
            tools = str(Path(__file__).resolve().parent)
            (root / 'controller.py').write_text(
                'import json, os, pathlib, subprocess, sys, time\n'
                f'sys.path.insert(0, {tools!r})\n'
                'from fork_benchmark import Runner\n'
                f'root = pathlib.Path({str(root)!r})\n'
                'Runner(root, root).run("nested", "fork", "exit", 0, [sys.executable, "-c", "pass"], root)\n'
                'parents = {int(p): int(q) for p, q in (line.split() for line in subprocess.check_output(\n'
                '    ["/bin/ps", "-axo", "pid=,ppid="], text=True).splitlines())}\n'
                'driver = int((root / "driver.pid").read_text())\n'
                'owned, pid = [], os.getpid()\n'
                'while pid != driver and pid in parents:\n'
                '    owned.append(pid); pid = parents[pid]\n'
                'assert pid == driver\n'
                '(root / "ready.json").write_text(json.dumps(owned))\n'
                'time.sleep(30)\n')
            (root / 'Makefile').write_text(f'probe:\n\t@/bin/sh -c \'"{sys.executable}" "{root / "controller.py"}"\'\n')
            driver_code = (
                'import os, pathlib, sys\n'
                f'sys.path.insert(0, {tools!r})\n'
                'from fork_benchmark import COMMAND_LOCK_ENV, Runner\n'
                f'root = pathlib.Path({str(root)!r})\n'
                '(root / "driver.pid").write_text(str(os.getpid()))\n'
                'runner = Runner(root, root)\n'
                'runner.env[COMMAND_LOCK_ENV] = str(root / "commands.lock")\n'
                'runner.run("controller", "fork", "make", 0, ["make", "probe"], root, timeout=30)\n')
            owned = []
            driver = subprocess.Popen([sys.executable, '-c', driver_code], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                deadline = time.monotonic() + 8
                while not (root / 'ready.json').exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue((root / 'ready.json').exists(), 'make/controller chain did not reach its stage boundary')
                owned = json.loads((root / 'ready.json').read_text())
                driver.kill()
                driver.wait(timeout=5)
                for pid in owned[1:]:
                    os.kill(pid, signal.SIGKILL)
                # The controller has finished its nested command. Only the
                # descriptor inherited through make/sh excludes recovery now.
                with lock.open() as recovery:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(recovery, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    os.kill(owned[0], signal.SIGKILL)
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            fcntl.flock(recovery, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic() >= deadline:
                                self.fail('Command lease survived every owned controller')
                            time.sleep(0.02)
            finally:
                if driver.poll() is None:
                    driver.kill()
                driver.wait(timeout=5)
                for pid in owned:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # The explicitly owned test process is already gone.


class ReportTests(unittest.TestCase):
    @staticmethod
    def historical_help_rows(stock_first=0.75, fork_first=0.85,
                             stock_repeated=0.08, fork_repeated=0.12):
        lanes = {'stock': [], 'fork': []}
        for trial in range(11):
            for lane, first, repeated in [('stock', stock_first, stock_repeated),
                                          ('fork', fork_first, fork_repeated)]:
                lanes[lane].append(dict(component='container', fixture='cli-run-help',
                                        lane=lane, trial=trial, seconds=first if trial == 0 else repeated,
                                        status=0, historical=lane == 'stock', log='retained.log'))
        return lanes

    def test_historical_help_separates_initial_and_repeated_invocations(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            lanes = self.historical_help_rows()
            runner.rows = lanes['fork']
            runner.reference_rows = lanes['stock']
            runner.report()
            row = json.loads((evidence / 'matrix.json').read_text())[0]
            self.assertEqual(row['comparison'], 'historical')
            self.assertEqual(row['phase_ratios'], {'first-invocation': 0.85 / 0.75,
                                                    'repeated-invocation': 0.12 / 0.08})
            self.assertEqual(row['worst_trial_ratio'], 1.5)
            self.assertTrue(row['passed'])
            self.assertEqual(len(json.loads((evidence / 'results.json').read_text())), 11)
            self.assertEqual(len(json.loads((evidence / 'historical-results.json').read_text())), 11)
            self.assertIn('First invocation: 1.133x. Repeated invocations: 1.500x.',
                          (evidence / 'matrix.md').read_text())
            cases = [case for case in ET.parse(evidence / 'timings.xml').iter('testcase')
                     if case.get('name') == 'cli-run-help/historical-phases']
            self.assertEqual(len(cases), 1)
            self.assertEqual({p.get('name') for p in cases[0].iter('property')},
                             {'first-invocation-ratio', 'repeated-invocation-ratio'})
            self.assertFalse(any(True for _ in cases[0].iter('failure')))

    def test_historical_help_rejects_true_tenfold_in_either_phase(self):
        for named, kwargs in [('first', {'fork_first': 7.5}),
                              ('repeated', {'fork_repeated': 0.8})]:
            with self.subTest(phase=named), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                runner = Runner(evidence, evidence)
                lanes = self.historical_help_rows(**kwargs)
                runner.rows = lanes['fork']
                runner.reference_rows = lanes['stock']
                runner.report()
                row = json.loads((evidence / 'matrix.json').read_text())[0]
                self.assertEqual(row['worst_trial_ratio'], 10)
                self.assertFalse(row['passed'])
                failures = list(ET.parse(evidence / 'timings.xml').iter('failure'))
                self.assertEqual(len(failures), 1)
                self.assertIn(named if named == 'repeated' else 'first', failures[0].get('message'))

    def test_historical_help_requires_all_unique_successful_finite_trials(self):
        for name in ('missing', 'duplicate', 'nan', 'infinite', 'zero', 'failed',
                     'boolean_trial', 'historical_flag', 'historical_string',
                     'historical_int', 'fork_historical_int', 'wrong_lane'):
            lanes = self.historical_help_rows()
            rows = (lanes['stock'] if name in ('missing', 'nan', 'infinite', 'historical_flag',
                                               'historical_string', 'historical_int') else lanes['fork'])
            if name == 'missing': rows.pop()
            if name == 'duplicate': rows[-1]['trial'] = 0
            if name == 'nan': rows[1]['seconds'] = math.nan
            if name == 'infinite': rows[1]['seconds'] = math.inf
            if name == 'zero': rows[1]['seconds'] = 0
            if name == 'failed': rows[1]['status'] = 124
            if name == 'boolean_trial': rows[1]['trial'] = True
            if name == 'historical_flag': rows[1]['historical'] = False
            if name == 'historical_string': rows[1]['historical'] = 'true'
            if name == 'historical_int': rows[1]['historical'] = 1
            if name == 'fork_historical_int': rows[1]['historical'] = 0
            if name == 'wrong_lane': rows[1]['lane'] = 'stock'
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'Historical CLI help'):
                historical_cli_help_phase_ratios(lanes)

    def test_historical_help_cannot_skip_a_missing_reference_lane(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            runner.rows = self.historical_help_rows()['fork']
            runner.reference_rows = [dict(component='container', fixture='cli-version', lane='stock',
                                          trial=0, seconds=0.02, status=0, historical=True)]
            with self.assertRaisesRegex(RuntimeError, 'missing an entire measurement lane'):
                runner.report()
            self.assertEqual(len(json.loads((evidence / 'results.json').read_text())), 11)

    def test_cleanup_runs_both_lanes_when_measurement_or_first_cleanup_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = Runner(Path(directory), Path(directory))
            with patch.object(runner, 'run', side_effect=[OSError('first lane'), {'status': 0}]) as command:
                with self.assertRaisesRegex(RuntimeError, 'Bazel cleanup failed'):
                    with runner.bazel_session('swift-nio-ssl'):
                        raise ValueError('measurement failed')
            self.assertEqual([call.args[1] for call in command.call_args_list], ['stock', 'fork'])
            self.assertTrue(all(call.kwargs['timeout'] == 60 for call in command.call_args_list))

    def test_tls_discovers_executable_among_release_debug_outputs(self):
        name = 'bazel-out/opt/bin/NIOSSLPerformanceTester.rspm.__impl'
        debug = name + '.dSYM/Contents/Resources/DWARF/NIOSSLPerformanceTester.rspm.__impl'
        self.assertEqual(tls_executable(name + '\n' + debug, Path('/execroot')), Path('/execroot') / name)
        for files in (debug, name + '\nother/' + name):
            with self.subTest(files=files), self.assertRaises(RuntimeError):
                tls_executable(files, Path('/execroot'))

    def test_tls_accepts_ten_completed_release_samples(self):
        text = 'measuring: repeated_handshakes: ' + '0.125, ' * 10 + '\n'
        self.assertEqual(tls_samples(text, 'repeated_handshakes'), [0.125] * 10)

    def test_tls_rejects_debug_skipped_incomplete_or_invalid_measurements(self):
        good = 'measuring: repeated_handshakes: ' + '0.125, ' * 10 + '\n'
        for text in ('DEBUG MODE\n' + good, 'skipping repeated_handshakes', good + good,
                     good.replace('repeated_handshakes', 'many_writes_512b'),
                     good.replace('0.125, ', '', 1), good.replace('0.125', 'nan', 1),
                     good.replace('0.125', 'inf', 1), good.replace('0.125', '0', 1)):
            with self.subTest(output=text), self.assertRaises(ValueError):
                tls_samples(text, 'repeated_handshakes')

    def test_successful_command_does_not_sleep_polling_for_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            # A measurement must not acquire a delay from the parent's timeout
            # polling loop. This deterministically catches the old implementation.
            with patch('subprocess.time.sleep', side_effect=AssertionError('polling delay')):
                row = runner.run('probe', 'fork', 'precise-exit', 0,
                                 [sys.executable, '-c', 'pass'], evidence, timeout=5)
            self.assertEqual(row['status'], 0)

    def test_command_preserves_output_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            row = runner.run('probe', 'fork', 'exit', 0,
                             [sys.executable, '-c', 'print("retained-output"); raise SystemExit(7)'],
                             evidence, timeout=5)
            self.assertEqual(row['status'], 7)
            self.assertIn('retained-output', Path(row['log']).read_text())

    def test_deadline_kills_and_reaps_child_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            row = runner.run('probe', 'fork', 'timeout', 0,
                             [sys.executable, '-c', 'import time; print("started", flush=True); time.sleep(30)'],
                             evidence, timeout=0.5)
            self.assertEqual(row['status'], 124)
            self.assertLess(row['seconds'], 5)
            self.assertIn('started', Path(row['log']).read_text())
            self.assertEqual(json.loads((evidence / 'results.json').read_text())[0]['status'], 124)

    def test_timeout_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            marker = evidence / 'orphan-survived'
            child = 'import time,pathlib; time.sleep(1.5); pathlib.Path(' + repr(str(marker)) + ').touch()'
            parent = ('import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' +
                      repr(child) + ']); time.sleep(30)')
            with patch('threading.excepthook') as errors:
                row = runner.run('probe', 'fork', 'descendant-timeout', 0,
                                 [sys.executable, '-c', parent], evidence, timeout=0.5)
            errors.assert_not_called()
            self.assertEqual(row['status'], 124)
            import time
            time.sleep(1.5)
            self.assertFalse(marker.exists())

    def test_median_does_not_hide_a_tenfold_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            for trial, seconds in enumerate([1, 10, 1]):
                for lane, duration in [('stock', 1), ('fork', seconds)]:
                    runner.rows.append(dict(component='container', lane=lane,
                                            fixture='build', seconds=duration, status=0,
                                            trial=trial, log='retained.log'))
            runner.report()
            row = json.loads((evidence / 'matrix.json').read_text())[0]
            self.assertEqual(row['ratio'], 1)
            self.assertEqual(row['worst_trial_ratio'], 10)
            self.assertFalse(row['passed'])

    def test_matching_fixture_regression_and_failure_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            runner = Runner(evidence, evidence)
            for lane, name, seconds, status in [
                ('stock', 'prepare-build', 100, 0),
                ('fork', 'prepare-build', 1, 0),
                ('stock', 'archive', 1, 0),
                ('fork', 'archive', 10, 0),
                ('stock', 'oci', 2, 0),
                ('fork', 'oci', 3, 1),
            ]:
                runner.rows.append(dict(component='containerization', lane=lane,
                                        fixture=name, seconds=seconds, status=status,
                                        trial=0, log='retained.log'))
            runner.report()
            matrix = json.loads((evidence / 'matrix.json').read_text())
            self.assertEqual([r['fixture'] for r in matrix], ['archive', 'oci'])
            self.assertEqual([r['ratio'] for r in matrix], [10, None])
            self.assertFalse(any(r['passed'] for r in matrix))
            junit = ET.parse(evidence / 'timings.xml')
            self.assertEqual(len(list(junit.iter('failure'))), 2)
            self.assertEqual(len(json.loads((evidence / 'results.json').read_text())), 6)


if __name__ == '__main__':
    unittest.main()

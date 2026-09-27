"""Reject active/replaced workers and release the shared inode only after cleanup."""

from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import host_lease as module


LABEL = 'actions.runner.stephenlclarke-container.container-only-mbp'


def process(pid=400, *, parent=1, group=400, name='Runner.Listener', started='original'):
    return dict(pid=pid, parent=parent, group=group, uid=os.getuid(), state='T',
                started=started, program='/runner/bin/' + name)


class HostLeaseTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        # Ordinary fixtures model a local caller; Actions ancestry tests opt in
        # explicitly instead of inheriting the machine running this test suite.
        self.stack.enter_context(patch.dict(os.environ, GITHUB_ACTIONS='false'))
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(patch.object(module, 'LOCK', self.root / 'runtime.lock'))
        self.stack.enter_context(patch.object(module, 'JOURNAL', self.root / 'recovery.json'))
        self.lease = module.HostLease(self.root)
        self.addCleanup(self.lease.close)

    def row(self):
        return dict(label=LABEL, process=process(), bootout_started=False, restored=False)

    def test_busy_shared_lock_never_inspects_or_stops_services(self):
        with module.LOCK.open('w') as held, patch.object(module, 'labels') as labels:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.lease.acquire()
            self.lease.restore()
            labels.assert_not_called()

    def test_unsafe_lock_is_not_followed(self):
        other = self.root / 'other'
        other.write_text('preserve')
        module.LOCK.symlink_to(other)
        with self.assertRaises(OSError):
            self.lease.acquire()
        self.assertEqual(other.read_text(), 'preserve')

    def test_previous_recovery_record_is_preserved(self):
        module.JOURNAL.write_text('prior authority')
        with self.assertRaisesRegex(RuntimeError, 'Previous host restoration'):
            self.lease.acquire()
        self.lease.restore()
        self.assertEqual(module.JOURNAL.read_text(), 'prior authority')

    def test_failed_cleanup_cannot_replace_another_runs_recovery_record(self):
        original = json.dumps({'owner': 123, 'evidence': '/previous/run'})
        module.JOURNAL.write_text(original)
        with self.assertRaisesRegex(RuntimeError, 'another run'):
            self.lease.restore(restore_workers=False)
        self.assertEqual(module.JOURNAL.read_text(), original)

    def test_shared_lock_remains_held_through_worker_restoration(self):
        with patch.object(module, 'labels', return_value={}), patch.object(module, 'processes', return_value={}):
            self.lease.acquire()
            self.lease.restore()
            with module.LOCK.open() as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.lease.close()
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertFalse(module.JOURNAL.exists())

    @unittest.skipUnless(Path('/usr/bin/lockf').exists(), 'macOS family lock tool')
    def test_shared_inode_interoperates_with_existing_family_lockf(self):
        with module.LOCK.open('a') as owner, module.LOCK.open('a') as contender:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            args = ['/usr/bin/lockf', '-t', '1', str(contender.fileno())]
            rejected = subprocess.run(args, pass_fds=(contender.fileno(),), capture_output=True, timeout=4)
            self.assertEqual(rejected.returncode, 75)
            fcntl.flock(owner, fcntl.LOCK_UN)
            accepted = subprocess.run(args, pass_fds=(contender.fileno(),), capture_output=True, timeout=4)
            self.assertEqual(accepted.returncode, 0)
            with self.assertRaises(BlockingIOError):
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_known_busy_runner_is_never_suspended(self):
        with patch.object(module, 'runner_state', return_value={'busy': True}), patch.object(module.os, 'killpg') as kill:
            with self.assertRaisesRegex(RuntimeError, 'Active cooperating runner'):
                self.lease.quiesce(self.row())
        kill.assert_not_called()

    def test_assignment_racing_idle_check_is_resumed_without_bootout(self):
        row = self.row()
        self.lease.rows.append(row)
        with patch.object(module, 'runner_state', side_effect=[{'busy': False}, {'busy': True}]), \
                patch.object(module, 'processes', return_value={400: process()}), \
                patch.object(module.os, 'killpg') as kill, patch.object(module, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'Active cooperating runner'):
                self.lease.quiesce(row)
        self.assertEqual(kill.call_args_list[0].args, (400, signal.SIGSTOP))
        self.assertEqual(kill.call_args_list[1].args, (400, signal.SIGCONT))
        command.assert_not_called()
        self.assertFalse(row['bootout_started'])
        durable = json.loads(module.JOURNAL.read_text())
        self.assertEqual(durable['suspended'][0]['members'][0]['pid'], 400)

    def test_local_worker_blocks_even_when_remote_is_idle(self):
        inventory = {400: process(), 401: process(401, parent=400, name='Runner.Worker')}
        with patch.object(module, 'runner_state', return_value={'busy': False}), \
                patch.object(module, 'processes', return_value=inventory), patch.object(module.os, 'killpg') as kill:
            with self.assertRaisesRegex(RuntimeError, 'Active worker'):
                self.lease.quiesce(self.row())
        kill.assert_not_called()

    def test_resume_surviving_child_after_service_leader_exits(self):
        child = process(401, parent=400)
        self.lease.suspended = [{'group': 400, 'members': [process(), child]}]
        with patch.object(module, 'processes', return_value={401: child}), patch.object(module.os, 'killpg') as kill:
            self.lease.resume()
        kill.assert_called_once_with(400, signal.SIGCONT)

    def test_child_spawned_before_freeze_is_resumed_after_leader_exit(self):
        row = self.row()
        self.lease.rows.append(row)
        leader, child = process(), process(401, parent=400)
        with patch.object(self.lease, 'idle'), \
                patch.object(module, 'processes', side_effect=[
                    {400: leader}, {400: leader}, {400: leader, 401: child}, {401: child}, {}]), \
                patch.object(module, 'labels', return_value={}), patch.object(module, 'command'), \
                patch.object(module.os, 'killpg') as kill:
            self.lease.quiesce(row)
        self.assertEqual(kill.call_args_list[-1].args, (400, signal.SIGCONT))
        durable = json.loads(module.JOURNAL.read_text())
        self.assertEqual([p['pid'] for p in durable['suspended'][0]['members']], [400, 401])

    def test_reused_process_group_is_never_signalled(self):
        self.lease.suspended = [{'group': 400, 'members': [process()]}]
        with patch.object(module, 'processes', return_value={400: process(started='replacement')}), \
                patch.object(module.os, 'killpg') as kill:
            with self.assertRaisesRegex(RuntimeError, 'Could not resume'):
                self.lease.resume()
        kill.assert_not_called()

    def test_claimed_current_runner_requires_actual_ancestry(self):
        environment = dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY='stephenlclarke/container', RUNNER_NAME='container-only-mbp')
        with patch.dict(os.environ, environment):
            with self.assertRaisesRegex(RuntimeError, 'process ancestry'):
                self.lease.current_runner({LABEL: 400}, {})
            inventory = {400: process(), 401: process(401, parent=400, name='Runner.Worker'),
                         os.getpid(): process(os.getpid(), parent=401, name='python')}
            self.assertEqual(self.lease.current_runner({LABEL: 400}, inventory), LABEL)

    def test_original_runtime_cleanup_failure_does_not_restart_workers(self):
        row = self.row()
        row['bootout_started'] = True
        self.lease.rows.append(row)
        with patch.object(module, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'workers remain quiesced'):
                self.lease.restore(restore_workers=False)
        command.assert_not_called()
        self.assertTrue(module.JOURNAL.exists())
        self.assertFalse(row['restored'])

    def test_restored_engine_connection_refusal_remains_a_readiness_wait(self):
        row = dict(label=module.ENGINE, path='/saved/engine.plist')
        with patch.object(module, 'labels', return_value={module.ENGINE: 500}), \
                patch.object(module, 'command', side_effect=[
                    'path = /saved/engine.plist', 'unix:///private/tmp/engine.sock', RuntimeError('curl failed'),
                    'path = /saved/engine.plist', 'unix:///private/tmp/engine.sock', 'OK']) as command, \
                patch.object(module.time, 'sleep'):
            module.wait_for(lambda: self.lease.ready(row), 1)
            self.assertEqual(command.call_count, 6)


if __name__ == '__main__':
    unittest.main()

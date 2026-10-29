"""Real child-process crashes; all business state is synthetic, no network/device."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from journal import Journal
from test_policy import DATE

ROOT = Path(__file__).resolve().parent


class ProcessRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()
        self.temp.cleanup()

    def start_child(self, body):
        source = (
            'import pathlib, sys, time, fcntl\n'
            'from journal import Journal, atomic_json\n'
            'folder=pathlib.Path(sys.argv[1])\n' + body +
            '\nprint("READY",flush=True)\ntime.sleep(30)\n'
        )
        env = {**os.environ, 'PYTHONPATH': str(ROOT), 'PYTHONDONTWRITEBYTECODE': '1'}
        child = subprocess.Popen(
            [sys.executable, '-c', source, str(self.folder)], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.children.append(child)
        # Bounded readiness: the marker follows the real journal fsync.
        import select
        ready, _, _ = select.select([child.stdout], [], [], 5)
        self.assertTrue(ready, 'child did not persist intent before deadline')
        self.assertEqual(child.stdout.readline().strip(), 'READY')
        return child

    def recover_in_new_process(self, fixture):
        source = (
            'import json,pathlib,sys\n'
            'from journal import Journal\n'
            'from policy import run_workflow,UncertainAction\n'
            'from test_policy import Adapter,DATE,PINS,raw\n'
            'folder=pathlib.Path(sys.argv[1]);adapter=Adapter(' + fixture + ')\n'
            'try:\n result=run_workflow(adapter,Journal(folder),DATE,True,PINS);status=result["status"]\n'
            'except UncertainAction:\n status="UNKNOWN"\n'
            'print(json.dumps({"status":status,"signs":adapter.signs,"collects":adapter.collects,"pending":Journal(folder).pending}))\n'
        )
        env = {**os.environ, 'PYTHONPATH': str(ROOT), 'PYTHONDONTWRITEBYTECODE': '1'}
        result = subprocess.run([sys.executable, '-c', source, str(self.folder)],
                                env=env, capture_output=True, text=True, timeout=5, check=True)
        return json.loads(result.stdout)

    def crash(self, child):
        child.send_signal(signal.SIGKILL)
        self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)

    def test_sign_accepted_then_sigkill_reconciles_without_replay(self):
        child = self.start_child(
            "j=Journal(folder)\nj.begin({'kind':'SIGN','date':'" + DATE + "'})\n"
        )
        self.crash(child)
        self.assertEqual(Journal(self.folder).pending['kind'], 'SIGN')
        result = self.recover_in_new_process('raw(signed=True)')
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual((result['signs'], result['collects']), (0, 0))
        self.assertIsNone(result['pending'])

    def test_collection_accepted_then_sigkill_reconciles_without_replay(self):
        child = self.start_child(
            "j=Journal(folder)\nj.begin({'kind':'COLLECT','date':'" + DATE +
            "','ids':['7'],'beforeBalance':'10','expectedDelta':'2'})\n"
        )
        self.crash(child)
        result = self.recover_in_new_process("raw(signed=True, balance='12')")
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['collects'], 0)
        self.assertIsNone(result['pending'])

    def test_unknown_collection_survives_sigkill_and_stays_blocked(self):
        child = self.start_child(
            "j=Journal(folder)\nj.begin({'kind':'COLLECT','date':'" + DATE +
            "','ids':['7'],'beforeBalance':'10','expectedDelta':'2'})\n"
        )
        self.crash(child)
        result = self.recover_in_new_process("raw(signed=True, balance='10')")
        self.assertEqual(result['status'], 'UNKNOWN')
        self.assertEqual(result['collects'], 0)
        self.assertEqual(result['pending']['kind'], 'COLLECT')

    def test_real_flock_is_released_on_process_death(self):
        child = self.start_child(
            "lock=open(folder/'runner.lock','a')\n"
            "fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
        )
        with open(self.folder/'runner.lock', 'a') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.crash(child)
            fcntl.flock(lock, fcntl.LOCK_EX|fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)


if __name__ == '__main__':
    unittest.main()

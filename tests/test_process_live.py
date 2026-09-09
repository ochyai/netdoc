"""Use only freshly created /bin/sleep children; never touch user applications."""
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'macOS process integration')
class OwnedProcessTests(unittest.TestCase):
    def exercise_pause(self, interrupt):
        target = subprocess.Popen(['/bin/sleep', '30'])
        controller = None
        try:
            controller = subprocess.Popen([str(ROOT / 'netdoc'), '--pause', str(target.pid),
                '5' if interrupt else '1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True)
            stopped = False
            for _ in range(40):
                state = subprocess.check_output(['ps', '-p', str(target.pid), '-o', 'state='], text=True)
                if 'T' in state:
                    stopped = True
                    break
                if controller.poll() is not None:
                    break
                time.sleep(.05)
            if interrupt and controller.poll() is None:
                os.killpg(controller.pid, signal.SIGINT)
            output, error = controller.communicate(timeout=7)
            time.sleep(.1)
            state = subprocess.check_output(['ps', '-p', str(target.pid), '-o', 'state='], text=True)
            self.assertTrue(stopped, output + error)
            self.assertNotIn('T', state, output + error)
            self.assertEqual(controller.returncode, 130 if interrupt else 0, output + error)
        finally:
            if target.poll() is None:
                os.kill(target.pid, signal.SIGCONT)
                target.terminate()
                target.wait(timeout=2)
            if controller and controller.poll() is None:
                os.killpg(controller.pid, signal.SIGTERM)
                controller.wait(timeout=2)

    def test_timer_resumes_owned_process(self):
        self.exercise_pause(False)

    def test_ctrl_c_resumes_owned_process(self):
        self.exercise_pause(True)


if __name__ == '__main__':
    unittest.main()

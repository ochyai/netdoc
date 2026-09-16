"""Public entry points and common invariants, without live network/config changes."""
import json
import os
import pty
import select
import signal
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(["/bin/bash", str(ROOT / "netdoc"), *args],
                              capture_output=True, text=True, timeout=5)

    def source(self, body):
        with tempfile.TemporaryDirectory() as conf:
            env = dict(os.environ, NETDOC_LIBRARY_ONLY="1", NETDOC_HOME=conf)
            return subprocess.run(["/bin/bash", "-c",
                'source "$1" --check\n' + body, "test", str(ROOT / "netdoc")],
                capture_output=True, text=True, env=env, timeout=10)

    def test_help_and_version(self):
        r = self.run_cli("--help")
        self.assertEqual(r.returncode, 0, r.stderr)
        for arg in ("--fix", "--plan", "--restore", "--pause"):
            self.assertIn(arg, r.stdout)
        self.assertIn("0.5.0", self.run_cli("--version").stdout)

    def test_invalid_arguments_fail_before_probes(self):
        for args in (("--check", "unexpected"), ("--watch", "0"),
                     ("--watch", "x"), ("--pause",), ("--missing",)):
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 2)

    def test_json_escaping_latest_facts_and_finding_schema(self):
        r = self.source(r'''
            fact result before
            fact result after
            fact 'a"b' 'path\to\thing "quoted"'
            fact multiline $'a\nb\tc'
            finding 40 warn 'title "quoted"' 'C:\path'
            exec 3>&1
            emit_json
        ''')
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual(data["facts"]["result"], "after")
        self.assertEqual(data["facts"]['a"b'], 'path\\to\\thing "quoted"')
        self.assertEqual(data["facts"]["multiline"], "a b c")
        self.assertEqual(data["findings"], [{"priority": 40, "severity": "warn",
                                          "title": 'title "quoted"', "fix": "C:\\path"}])

    def test_noninteractive_ask_never_approves_defaults(self):
        r = self.source('MODE=fix\nask "change?" Y\nprintf "result=%s\\n" "$?"')
        self.assertIn("result=1", r.stdout)

    def test_fact_replacement(self):
        r = self.source('fact dns_status broken\nfact dns_status ok\ngetf dns_status')
        self.assertEqual(r.stdout.strip(), "ok")

    def test_service_names_with_spaces(self):
        r = self.source('''
            networksetup() { printf '(1) USB Ethernet\\n(Hardware Port: USB, Device: en7)\\n(2) Wi-Fi Office\\n(Hardware Port: Wi-Fi, Device: en0)\\n'; }
            service_for_interface en0
        ''')
        self.assertEqual(r.stdout.strip(), "Wi-Fi Office")


class PerformanceTests(unittest.TestCase):
    source = CliTests.source
    def test_dns_recovery_does_not_hide_remaining_congestion(self):
        r = self.source('''
            fact down_mbps 20
            history_save() { :; }
            section_quality() {
                fact down_mbps 22
                fact networkquality_status ok
                fact dns_status normal
                fact queueing_observed yes
                finding 40 warn congestion residual
            }
            performance_retest
            printf "result=%s\\n" "$?"
            printf "before=%s after=%s outcome=%s\\n" "$(getf before_repair_down_mbps)" "$(getf down_mbps)" "$(getf performance_outcome)"
        ''')
        self.assertIn("result=1", r.stdout)
        self.assertIn("before=20 after=22 outcome=residual_bottleneck", r.stdout)

    def test_missing_after_measurement_is_unverified(self):
        r = self.source('''
            history_save() { :; }
            section_quality() { fact networkquality_status failed; }
            performance_retest
            printf "result=%s\\n" "$?"
            getf performance_outcome
        ''')
        self.assertIn("result=1", r.stdout)
        self.assertIn("unverified", r.stdout)

    def test_successful_measurement_preserves_limited_outcome(self):
        r = self.source('''
            history_save() { :; }
            section_quality() {
                fact networkquality_status ok
                fact dns_status normal
                fact queueing_observed no
            }
            performance_retest
            printf "result=%s\\n" "$?"
            getf performance_outcome
        ''')
        self.assertIn("result=0", r.stdout)
        self.assertIn("measured", r.stdout)


class TerminalTests(unittest.TestCase):
    def test_interactive_authentication_can_read_terminal(self):
        with tempfile.TemporaryDirectory() as td:
            fake_sudo = Path(td) / "sudo"
            fake_sudo.write_text("#!/bin/bash\nif [ \"$1\" = -n ]; then exit 1; fi\nread -r -p 'TEST-AUTH> ' answer\n[ \"$answer\" = test ]\n")
            fake_sudo.chmod(0o755)
            pid, fd = pty.fork()
            if pid == 0:
                env = dict(os.environ, NETDOC_LIBRARY_ONLY="1", NETDOC_HOME=td,
                           PATH=td + os.pathsep + os.environ['PATH'])
                os.execvpe('/bin/bash', ['/bin/bash', '-c',
                    'source "$1" --check; MODE=fix; repair_authorize_sudo; printf "RESULT=%s\\n" "$?"',
                    'test', str(ROOT / 'netdoc')], env)
            output = b''
            answered = False
            reaped = False
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], .1)[0]:
                        try:
                            chunk = os.read(fd, 8192)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                    if b'TEST-AUTH> ' in output and not answered:
                        os.write(fd, b'test\n')
                        answered = True
                    ended, _ = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        reaped = True
                        break
                self.assertTrue(answered, output.decode(errors='replace'))
                self.assertIn(b'RESULT=0', output)
            finally:
                if not reaped:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)
                os.close(fd)


class DeadlineTests(unittest.TestCase):
    def run_core(self, body, *args):
        return subprocess.run(["/bin/bash", "-c", 'source "$1"\nshift\n' + body,
            "test", str(ROOT / "lib/core.sh"), *args], capture_output=True,
            text=True, timeout=8)

    def test_deadline_preserves_output_and_status(self):
        r = self.run_core('run_bounded 3 /bin/bash -c \'echo good; echo err >&2; exit 7\'')
        self.assertEqual(r.returncode, 7)
        self.assertEqual(r.stdout.strip(), "good")
        self.assertEqual(r.stderr.strip(), "err")

    def test_deadline_terminates_command_and_descendants(self):
        with tempfile.TemporaryDirectory() as td:
            pidfile = Path(td) / "pid"
            marker = Path(td) / "should-not-exist"
            start = time.monotonic()
            r = self.run_core('run_bounded 1 /bin/bash -c \'echo $$ > "$1"; (sleep 2; touch "$2") & wait\' test "$1" "$2"', str(pidfile), str(marker))
            self.assertEqual(r.returncode, 124, r.stderr)
            self.assertLess(time.monotonic() - start, 3)
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            time.sleep(1)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()

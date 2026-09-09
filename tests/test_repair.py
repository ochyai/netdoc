"""Repair tests: commands are shell functions; no host configuration is changed."""
import os
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'lib' / 'repair.sh'

PRELUDE = r'''
set -u
MODE=fix
CONF_DIR="$CASE_DIR/conf"
FACTS="$CASE_DIR/facts"
FIND="$CASE_DIR/findings"
CALLS="$CASE_DIR/calls"
: >"$FACTS"; : >"$FIND"; : >"$CALLS"
mkdir -p "$CONF_DIR"
DEFIF=en0
REPAIR_TEST_NETWORK=alpha
REPAIR_TEST_SERVICE=Wi-Fi
DNS_STATE="$CASE_DIR/dns"
printf '9.9.9.9\n149.112.112.112\n' >"$DNS_STATE"
fact() { printf '%s\t%s\n' "$1" "$2" >>"$FACTS"; }
getf() { awk -F'\t' -v k="$1" '$1==k{v=$2} END{print v}' "$FACTS"; }
finding() { :; }
ok() { echo "OK $*"; }
ng() { echo "NG $*"; }
warn() { echo "WARN $*"; }
step() { :; }
info() { echo "INFO $*"; }
note() { :; }
ask() { echo ask >>"$CALLS"; return 0; }
run_bounded() { shift; "$@"; }
sudo() {
  echo "sudo $*" >>"$CALLS"
  if [ "${SUDO_FAIL:-0}" = 1 ]; then return 1; fi
  [ "${1:-}" = -n ] && shift
  "$@"
}
route() { printf 'gateway: 192.168.0.1\ninterface: en0\n'; }
arp() {
  if [ "$REPAIR_TEST_NETWORK" = alpha ]; then echo '? (192.168.0.1) at aa:bb:cc:dd:ee:ff on en0';
  else echo '? (192.168.0.1) at aa:bb:cc:dd:ee:00 on en0'; fi
}
networksetup() {
  case "$1" in
    -listnetworkserviceorder) printf '(1) %s\n(Hardware Port: Wi-Fi, Device: en0)\n' "$REPAIR_TEST_SERVICE" ;;
    -getairportnetwork) echo 'Current Wi-Fi Network: Fixture' ;;
    -getdnsservers) cat "$DNS_STATE" ;;
    -setdnsservers)
      echo "networksetup $*" >>"$CALLS"
      if [ "${SET_FAIL:-0}" = 1 ]; then echo 'Error: The command failed'; return 0; fi
      shift 2
      if [ "$1" = empty ]; then echo "There aren't any DNS Servers set on Wi-Fi." >"$DNS_STATE";
      else printf '%s\n' "$@" >"$DNS_STATE"; fi ;;
    -getinfo) printf '%s\n' "${DHCP_CONFIG:-DHCP Configuration}" ;;
    *) echo "UNEXPECTED networksetup $*" >>"$CALLS"; return 99 ;;
  esac
}
ipconfig() {
  case "$1" in
    getifaddr) [ "${DHCP_IP+x}" = x ] && printf '%s\n' "$DHCP_IP" || echo 192.168.0.10 ;;
    set) echo "ipconfig $*" >>"$CALLS" ;;
  esac
}
dscacheutil() { echo "dscacheutil $*" >>"$CALLS"; }
killall() { echo "killall $*" >>"$CALLS"; }
source "$REPAIR_LIB"
repair_dns_snapshot() { printf '%s\n' "${SNAPSHOT:-0 2 0 resolver_failure no yes}"; }
'''


DHCP_FALLBACK_FIXTURE = r'''
DEFIF=''
DHCP_IP=169.254.10.20
route() { return 1; }
networksetup() {
  case "$1" in
    -listallhardwareports) printf 'Hardware Port: Wi-Fi\nDevice: en0\nHardware Port: USB LAN\nDevice: en7\n' ;;
    -listnetworkserviceorder) printf '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n(2) USB LAN\n(Hardware Port: USB LAN, Device: en7)\n' ;;
    -getinfo) printf '%s\n' "${DHCP_CONFIG:-DHCP Configuration}" ;;
    *) return 99 ;;
  esac
}
ifconfig() {
  case "$1" in
    en0) printf 'en0: flags=8863<UP>\n\tstatus: active\n' ;;
    en7) printf 'en7: flags=8863<UP>\n\tstatus: %s\n' "${SECOND_IF_STATE:-inactive}" ;;
    *) return 1 ;;
  esac
}
'''


class RepairTests(unittest.TestCase):
    def run_shell(self, script, expected=0):
        with tempfile.TemporaryDirectory(prefix='netdoc-repair-test-') as tmp:
            env = dict(os.environ, CASE_DIR=tmp, REPAIR_LIB=str(LIB))
            result = subprocess.run(['/bin/bash', '-c', PRELUDE + '\n' + script],
                                    env=env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result.stdout

    def test_no_evidence_does_not_mutate(self):
        output = self.run_shell('''
section_repair
[ ! -s "$CALLS" ] || exit 3
[ "$(getf repair_outcome)" = no_evidence ] || exit 4
section_retest && exit 5
exit 0
''')
        self.assertIn('根拠', output)

    def test_plan_only(self):
        self.run_shell('''
MODE=plan
fact dns_cache_candidate yes
fact dns_repair_candidate yes
section_repair
[ ! -s "$CALLS" ]
''')

    def test_auto_only_evidenced_cache(self):
        self.run_shell('''
MODE=auto
SNAPSHOT='0 0 0 cache_failure yes no'
fact dns_cache_candidate yes
fact dns_repair_candidate yes
DHCP_IP=169.254.1.2
section_repair
! grep -q '^ask' "$CALLS" || exit 4
! grep -qE 'networksetup|ipconfig set' "$CALLS" || exit 5
grep -q 'sudo -n dscacheutil -flushcache' "$CALLS" || exit 6
SNAPSHOT='2 0 2 normal no no'
section_retest || exit 7
[ "$(getf repair_cache)" = verified ]
''')

    def test_auto_never_authenticates_interactively(self):
        self.run_shell('''
MODE=auto
SUDO_FAIL=1
SNAPSHOT='0 0 0 cache_failure yes no'
fact dns_cache_candidate yes
section_repair
! grep -qE 'sudo -v|^ask|flushcache' "$CALLS"
''')

    def test_dns_change_bad_retest_restores_exact_original(self):
        self.run_shell('''
fact dns_repair_candidate yes
section_repair
backup="$REPAIR_DNS_ACTIVE"
[ -d "$backup" ] || exit 3
[ "$(cat "$DNS_STATE")" = "$(printf '1.1.1.1\n8.8.8.8')" ] || exit 4
SNAPSHOT='0 2 1 resolver_failure no yes'
section_retest && exit 5
[ "$(cat "$DNS_STATE")" = "$(printf '9.9.9.9\n149.112.112.112')" ] || exit 6
[ "$(getf repair_dns)" = rolled_back ] || exit 7
[ "$(cat "$backup/dns.original")" = "$(cat "$DNS_STATE")" ] || exit 8
[ "$(stat -f %Lp "$backup/dns.original")" = 400 ] || exit 9
exit 0
''')

    def test_single_http_success_is_not_recovery(self):
        self.run_shell('''
fact dns_repair_candidate yes
section_repair
SNAPSHOT='2 2 1 inconclusive no no'
section_retest && exit 5
[ "$(getf repair_dns)" = rolled_back ]
''')

    def test_good_retest_keeps_dns_and_preserves_backup(self):
        self.run_shell('''
fact dns_repair_candidate yes
section_repair
backup="$REPAIR_DNS_ACTIVE"
SNAPSHOT='2 0 2 normal no no'
section_retest || exit 3
[ -z "$REPAIR_DNS_ACTIVE" ] || exit 4
[ "$(getf repair_dns)" = verified ] || exit 5
[ "$(cat "$backup/dns.original")" = "$(printf '9.9.9.9\n149.112.112.112')" ] || exit 6
restore_changes "$(basename "$backup")" || exit 7
[ "$(cat "$DNS_STATE")" = "$(cat "$backup/dns.original")" ]
''')

    def test_fresh_probe_rejects_stale_candidate(self):
        self.run_shell('''
fact dns_repair_candidate yes
SNAPSHOT='1 2 1 inconclusive no no'
section_repair
! grep -q 'networksetup -setdnsservers' "$CALLS"
''')

    def test_no_backup_never_clears_dns(self):
        self.run_shell('''
restore_dns && exit 4
[ ! -s "$CALLS" ]
''')

    def test_service_changed_does_not_restore(self):
        self.run_shell('''
repair_save_dns || exit 3
REPAIR_TEST_SERVICE=Ethernet
repair_restore_backup "$REPAIR_DNS_ACTIVE" && exit 4
[ ! -s "$CALLS" ]
''')

    def test_network_changed_does_not_restore(self):
        self.run_shell('''
repair_save_dns || exit 3
REPAIR_TEST_NETWORK=beta
repair_restore_backup "$REPAIR_DNS_ACTIVE" && exit 4
[ ! -s "$CALLS" ]
''')

    def test_user_edit_does_not_get_overwritten(self):
        self.run_shell('''
repair_save_dns || exit 3
echo 4.4.4.4 >"$DNS_STATE"
repair_restore_backup "$REPAIR_DNS_ACTIVE" && exit 4
[ ! -s "$CALLS" ]
''')

    def test_missing_dns_data_aborts_backup(self):
        self.run_shell('''
: >"$DNS_STATE"
repair_save_dns && exit 4
[ ! -s "$CALLS" ]
''')

    def test_error_text_from_networksetup_is_failure(self):
        self.run_shell('''
SET_FAIL=1
repair_set_dns Wi-Fi 1.1.1.1 && exit 4
exit 0
''')

    def test_auto_dns_original_restores_empty_exactly(self):
        self.run_shell('''
echo "There aren't any DNS Servers set on Wi-Fi." >"$DNS_STATE"
fact dns_repair_candidate yes
section_repair
[ "$(cat "$REPAIR_DNS_ACTIVE/dns.original")" = empty ] || exit 3
section_retest && exit 4
[ "$(repair_read_dns Wi-Fi)" = empty ]
''')

    def test_backup_never_overwritten(self):
        self.run_shell('''
repair_save_dns || exit 3
first="$REPAIR_DNS_ACTIVE"
echo 4.4.4.4 >"$DNS_STATE"
repair_save_dns || exit 4
[ "$first" != "$REPAIR_DNS_ACTIVE" ] || exit 5
[ "$(cat "$first/dns.original")" = "$(printf '9.9.9.9\n149.112.112.112')" ]
''')

    def test_dhcp_only_on_proven_dhcp_self_assigned(self):
        self.run_shell('''
DHCP_CONFIG='Manual Configuration'
DHCP_IP=169.254.1.2
repair_dhcp_candidate && exit 4
DHCP_CONFIG='DHCP Configuration'
repair_dhcp_candidate || exit 5
section_repair
grep -q 'ipconfig set en0 DHCP' "$CALLS" || exit 6
! grep -q BOOTP "$CALLS"
''')

    def test_dhcp_without_route_selects_one_active_dhcp_interface(self):
        self.run_shell(DHCP_FALLBACK_FIXTURE + r'''
repair_dhcp_candidate || exit 3
[ "$REPAIR_DHCP_IF" = en0 ] || exit 4
[ "$REPAIR_DHCP_SERVICE" = Wi-Fi ] || exit 5
[ -z "$DEFIF" ] || exit 6
DHCP_IP=''
repair_dhcp_candidate || exit 7
section_repair
grep -q 'ipconfig set en0 DHCP' "$CALLS" || exit 8
[ -z "$DEFIF" ]
''')

    def test_dhcp_without_route_rejects_multiple_candidates(self):
        self.run_shell(DHCP_FALLBACK_FIXTURE + r'''
SECOND_IF_STATE=active
repair_dhcp_candidate && exit 3
[ -z "$REPAIR_DHCP_IF" ] || exit 4
[ -z "$DEFIF" ] || exit 5
[ ! -s "$CALLS" ]
''')

    def test_dhcp_without_route_rejects_static_configuration(self):
        self.run_shell(DHCP_FALLBACK_FIXTURE + r'''
DHCP_CONFIG='Manual Configuration'
repair_dhcp_candidate && exit 3
[ -z "$REPAIR_DHCP_IF" ] || exit 4
[ ! -s "$CALLS" ]
''')

    def test_dhcp_without_route_rechecks_new_route(self):
        self.run_shell(DHCP_FALLBACK_FIXTURE + r'''
route() { printf 'interface: en0\n'; }
repair_dhcp_candidate && exit 3
[ -z "$REPAIR_DHCP_IF" ] || exit 4
[ ! -s "$CALLS" ]
''')

    def test_cleanup_rolls_back_pending_change(self):
        self.run_shell('''
fact dns_repair_candidate yes
section_repair
repair_cleanup
[ "$(cat "$DNS_STATE")" = "$(printf '9.9.9.9\n149.112.112.112')" ]
''')

    def test_restore_traversal_rejected(self):
        self.run_shell('''
restore_changes '../../outside' && exit 3
[ ! -s "$CALLS" ]
''')

    def test_pause_stubs_resume_same_process(self):
        self.run_shell(r'''
repair_process_identity() { printf '%s Wed Sep 9 10:00:00 2026 /usr/bin/curl\n' "$(id -u)"; }
ps() {
  case "$*" in
    *comm=*) echo /usr/bin/curl ;;
    *state=*) echo S ;;
    *ppid=*) echo 1 ;;
  esac
}
kill() { echo "kill $*" >>"$CALLS"; }
sleep() { :; }
pause_process 98765 1 || exit 3
grep -q 'kill -STOP 98765' "$CALLS" || exit 4
grep -q 'kill -CONT 98765' "$CALLS"
''')

    def test_pause_refuses_system_process(self):
        self.run_shell(r'''
repair_process_identity() { printf '%s Wed Sep 9 10:00:00 2026 /System/Library/daemon\n' "$(id -u)"; }
ps() {
  case "$*" in
    *comm=*) echo /System/Library/daemon ;;
    *ppid=*) echo 1 ;;
  esac
}
kill() { echo "kill $*" >>"$CALLS"; }
pause_process 98765 1 && exit 3
[ ! -s "$CALLS" ]
''')

    def test_pause_refuses_identity_change_before_resume(self):
        self.run_shell(r'''
repair_process_identity() { echo replacement-process; }
kill() { echo "kill $*" >>"$CALLS"; }
repair_process_resume 98765 original-process && exit 3
[ ! -s "$CALLS" ]
''')

    def test_partial_write_is_recorded_without_claiming_success(self):
        self.run_shell(r'''
fact dns_repair_candidate yes
repair_set_dns() { echo 1.1.1.1 >"$DNS_STATE"; return 1; }
section_repair
[ "$(getf repair_dns)" = rollback_failed ] || exit 3
[ -n "$REPAIR_DNS_ACTIVE" ] || exit 4
SNAPSHOT='2 0 2 normal no no'
section_retest && exit 5
[ "$(getf repair_dns)" = rollback_failed ]
''')

    def test_cache_recovery_keeps_initial_baseline(self):
        self.run_shell(r'''
fact dns_cache_candidate yes
fact dns_repair_candidate yes
SNAPSHOT='0 0 0 cache_failure yes no'
repair_flush_cache() { REPAIR_CACHE_ATTEMPTED=1; SNAPSHOT='2 0 2 normal no no'; }
section_repair
[ "$REPAIR_BEFORE" = '0 0 0 cache_failure yes no' ] || exit 3
section_retest || exit 4
[ "$(getf repair_cache)" = verified ]
''')

    def test_shared_probe_snapshot_does_not_change_facts(self):
        self.run_shell(r'''
unset -f repair_dns_snapshot
source "$REPAIR_LIB"
quality_dns_probe() {
  fact unintended mutation
  finding unintended mutation
  printf 'www.apple.com\tyes\tyes\t0\tno\tno\tno\t1\nwww.cloudflare.com\tyes\tyes\t0\tno\tno\tno\t1\n' >"$1/dns.rows"
  printf 'dns_status\tnormal\ndns_cache_candidate\tno\ndns_repair_candidate\tno\n' >"$1/dns.parsed"
}
[ "$(repair_dns_snapshot)" = '2 0 2 normal no no' ] || exit 3
[ ! -s "$FACTS" ] || exit 4
[ ! -s "$CALLS" ]
''')

    def test_pause_interrupt_resumes_and_cleans_timer(self):
        # SIGTERM targets only this isolated test process group. The process
        # being "paused" is synthetic, and STOP/CONT are captured in a log.
        script = PRELUDE + r'''
repair_process_identity() { printf '%s Wed Sep 9 10:00:00 2026 /usr/bin/curl\n' "$(id -u)"; }
ps() {
  case "$*" in
    *comm=*) echo /usr/bin/curl ;;
    *state=*) echo S ;;
    *ppid=*) echo 1 ;;
  esac
}
kill() {
  case "$*" in
    '-STOP 98765'|'-CONT 98765') echo "kill $*" >>"$CALLS" ;;
    *) builtin kill "$@" ;;
  esac
}
pause_process 98765 30
'''
        with tempfile.TemporaryDirectory(prefix='netdoc-pause-test-') as tmp:
            env = dict(os.environ, CASE_DIR=tmp, REPAIR_LIB=str(LIB))
            proc = subprocess.Popen(['/bin/bash', '-c', script], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, start_new_session=True)
            try:
                log = Path(tmp) / 'calls'
                limit = time.monotonic() + 5
                while time.monotonic() < limit:
                    if log.exists() and '-STOP 98765' in log.read_text():
                        break
                    time.sleep(.02)
                else:
                    self.fail('pause fixture did not start')
                os.killpg(proc.pid, signal.SIGTERM)
                proc.communicate(timeout=5)
                self.assertIn('-CONT 98765', log.read_text())
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()

    def test_pause_reparenting_does_not_prevent_resume(self):
        self.run_shell(r'''
TEST_PARENT=1234
ps() {
  case "$*" in
    *uid=*)
      if [[ "$*" == *ppid=* ]]; then
        printf '%s %s Wed Sep 9 10:00:00 2026 /usr/bin/curl\n' "$(id -u)" "$TEST_PARENT"
      else
        printf '%s Wed Sep 9 10:00:00 2026 /usr/bin/curl\n' "$(id -u)"
      fi ;;
    *ppid=*) echo "$TEST_PARENT" ;;
  esac
}
kill() { echo "kill $*" >>"$CALLS"; }
original=$(repair_process_identity 98765)
TEST_PARENT=1
repair_process_resume 98765 "$original" || exit 3
grep -q 'kill -CONT 98765' "$CALLS"
''')

    def test_pause_refuses_lowercase_codex(self):
        self.run_shell(r'''
repair_process_identity() { printf '%s Wed Sep 9 10:00:00 2026 /opt/homebrew/bin/codex\n' "$(id -u)"; }
ps() {
  case "$*" in
    *comm=*) echo /opt/homebrew/bin/codex ;;
    *ppid=*) echo 1 ;;
  esac
}
kill() { echo "kill $*" >>"$CALLS"; }
pause_process 98765 1 && exit 3
[ ! -s "$CALLS" ]
''')

    def test_pause_duration_bound(self):
        self.run_shell('''
kill() { echo "kill $*" >>"$CALLS"; }
pause_process 98765 301 && exit 3
[ ! -s "$CALLS" ]
''')


if __name__ == '__main__':
    unittest.main()

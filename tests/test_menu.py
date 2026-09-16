"""Menu tests: every command is a shell stub; no host configuration is changed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPAIR_LIB = ROOT / 'lib' / 'repair.sh'
MENU_LIB = ROOT / 'lib' / 'menu.sh'

PRELUDE = r'''
set -u
MODE=fix
CONF_DIR="$CASE_DIR/conf"
FACTS="$CASE_DIR/facts"
FIND="$CASE_DIR/findings"
CALLS="$CASE_DIR/calls"
: >"$FACTS"; : >"$FIND"; : >"$CALLS"
mkdir -p "$CONF_DIR"
DEFIF=en0; DEFGW=192.168.0.1; TS_BIN=""
DIM=''; RST=''; GRN=''; RED=''; BLD=''
DNS_STATE="$CASE_DIR/dns"
printf '9.9.9.9\n149.112.112.112\n' >"$DNS_STATE"
fact() { printf '%s\t%s\n' "$1" "$2" >>"$FACTS"; }
getf() { awk -F'\t' -v k="$1" '$1==k{v=$2} END{print v}' "$FACTS"; }
finding() { :; }
ok() { echo "OK $*"; }
ng() { echo "NG $*"; }
warn() { echo "WARN $*"; }
step() { echo "STEP $*"; }
info() { echo "INFO $*"; }
note() { :; }
hr() { :; }
# ANSWERS: space-separated y/n consumed in order; missing answers mean "n".
ask() {
  local a; echo "ask $1" >>"$CALLS"
  a="${ANSWERS%% *}"; [ "$a" = "$ANSWERS" ] && ANSWERS="" || ANSWERS="${ANSWERS#* }"
  [ "$a" = y ]
}
run_bounded() { shift; "$@"; }
env() { while [ "${1:-}" = -u ]; do shift 2; done; "$@"; }
sudo() {
  echo "sudo $*" >>"$CALLS"
  if [ "${SUDO_FAIL:-0}" = 1 ]; then return 1; fi
  [ "${1:-}" = -n ] && shift
  "$@"
}
route() { printf 'gateway: 192.168.0.1\ninterface: en0\n'; }
arp() { echo '? (192.168.0.1) at aa:bb:cc:dd:ee:ff on en0'; }
networksetup() {
  case "$1" in
    -listnetworkserviceorder) printf '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n' ;;
    -listallhardwareports) printf 'Hardware Port: Wi-Fi\nDevice: en0\n' ;;
    -getairportnetwork) echo 'Current Wi-Fi Network: TestNet' ;;
    -getdnsservers) cat "$DNS_STATE" ;;
    -setdnsservers) shift; shift; echo "setdns $*" >>"$CALLS"; printf '%s\n' "$@" >"$DNS_STATE" ;;
    -setv6off|-setairportpower) echo "networksetup $*" >>"$CALLS" ;;
    *) echo "UNEXPECTED networksetup $*" >>"$CALLS"; return 99 ;;
  esac
}
ipconfig() { case "$1" in getifaddr) echo 192.168.0.10 ;; set) echo "ipconfig $*" >>"$CALLS" ;; esac; }
dscacheutil() { echo "dscacheutil $*" >>"$CALLS"; }
killall() { echo "killall $*" >>"$CALLS"; }
ifconfig() { echo "ifconfig $*" >>"$CALLS"; }
sntp() { echo "sntp $*" >>"$CALLS"; }
ping() { return 1; }
curl() { echo "${CURL_CODE:-200}"; }
sleep() { :; }
source "$REPAIR_LIB"
source "$MENU_LIB"
repair_dns_snapshot() { printf '%s\n' "${SNAPSHOT:-2 2 2 normal no no}"; }
'''


class MenuTests(unittest.TestCase):
    def run_shell(self, script, expected=0):
        with tempfile.TemporaryDirectory(prefix='netdoc-menu-test-') as tmp:
            env = dict(os.environ, CASE_DIR=tmp, REPAIR_LIB=str(REPAIR_LIB), MENU_LIB=str(MENU_LIB))
            result = subprocess.run(['/bin/bash', '-c', PRELUDE + '\n' + script],
                                    env=env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result.stdout

    def test_menu_is_offered_without_evidence(self):
        # v0.4 regression: with no evidence nothing was ever offered. The menu must ask.
        out = self.run_shell('''
ANSWERS=""
section_menu
grep -c '^ask ' "$CALLS"
[ "$MENU_ATTEMPTED" = 0 ] || exit 3
[ ! -s "$FACTS" ] || { grep -q '^menu_' "$FACTS" && exit 4; }
''')
        self.assertGreaterEqual(int(out.strip().splitlines()[-1]), 5)

    def test_declined_items_do_not_mutate(self):
        self.run_shell('''
ANSWERS="n n n n n n n n n n"
section_menu
grep -vq '^ask ' "$CALLS" && exit 3
[ "$MENU_ATTEMPTED" = 0 ] || exit 4
section_menu_retest && exit 5
exit 0
''')

    def test_cache_and_dhcp_run_when_accepted(self):
        self.run_shell('''
ANSWERS="y y"
section_menu
grep -q 'dscacheutil -flushcache' "$CALLS" || exit 3
grep -q 'killall -HUP mDNSResponder' "$CALLS" || exit 4
grep -q 'ipconfig set en0 DHCP' "$CALLS" || exit 5
[ "$MENU_ATTEMPTED" = 1 ] || exit 6
grep -q '^menu_cache	performed' "$FACTS" || exit 7
grep -q '^menu_dhcp	performed' "$FACTS" || exit 8
section_menu_retest || exit 9
grep -q '^repair_outcome	menu_alive' "$FACTS" || exit 10
''')

    def test_sudo_failure_skips_without_mutation(self):
        self.run_shell('''
SUDO_FAIL=1 ANSWERS="y y"
section_menu
grep -q 'dscacheutil' "$CALLS" && exit 3
grep -q 'ipconfig set' "$CALLS" && exit 4
[ "$MENU_ATTEMPTED" = 0 ] || exit 5
exit 0
''')

    def test_pinned_dns_kept_when_retest_works(self):
        self.run_shell('''
ANSWERS="n n y"
section_menu
grep -q 'setdns 1.1.1.1 8.8.8.8' "$CALLS" || exit 3
[ "$MENU_DNS_PINNED" = 1 ] || exit 4
[ -n "$REPAIR_DNS_ACTIVE" ] || exit 5
[ -f "$REPAIR_DNS_ACTIVE/dns.original" ] || exit 6
SNAPSHOT="2 2 2 normal no no" section_menu_retest || exit 7
grep -q '^repair_dns	kept' "$FACTS" || exit 8
[ -z "$REPAIR_DNS_ACTIVE" ] || exit 9
[ "$(cat "$DNS_STATE")" = "$(printf '1.1.1.1\n8.8.8.8')" ] || exit 10
''')

    def test_pinned_dns_rolled_back_when_retest_fails(self):
        self.run_shell('''
ANSWERS="n n y"
section_menu
SNAPSHOT="0 0 0 resolver_failure no yes" CURL_CODE=000 section_menu_retest && exit 3
grep -q '^repair_dns	rolled_back' "$FACTS" || exit 4
[ "$(cat "$DNS_STATE")" = "$(printf '9.9.9.9\n149.112.112.112')" ] || exit 5
grep -q '^repair_outcome	unresolved' "$FACTS" || exit 6
''')

    def test_menu_silent_outside_fix_modes(self):
        for mode in ('check', 'plan', 'auto', 'full'):
            with self.subTest(mode=mode):
                self.run_shell(f'''
MODE={mode} ANSWERS="y y y y y y y y y y"
section_menu
[ ! -s "$CALLS" ] || exit 3
[ "$MENU_ATTEMPTED" = 0 ] || exit 4
''')

    def test_conditional_items_appear_with_facts(self):
        self.run_shell('''
fact captive possible; fact clock_skew 500; fact mtu_if 1500; fact proxy_env "http_proxy=x"
open() { echo "open $*" >>"$CALLS"; }
ANSWERS="y n n n y y y n n"
section_menu <<<""
grep -q '^open http://captive.apple.com/' "$CALLS" || exit 3
grep -q '^ask \\[6\\]' "$CALLS" || exit 4
grep -q '^menu_proxy_test	200' "$FACTS" || exit 5
grep -q '^mtu_real	unknown' "$FACTS" || exit 6
grep -q 'ifconfig' "$CALLS" && exit 7
grep -q 'sntp -sS time.apple.com' "$CALLS" || exit 8
grep -q '^menu_clock	performed' "$FACTS" || exit 9
''')


if __name__ == '__main__':
    unittest.main()

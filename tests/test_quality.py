"""Offline regressions for read-only quality parsing and classification.

No tests run real network commands or sudo. Fixtures cover the macOS output
formats used by the tool, especially lifetime counters and failed downloads.
"""
import pathlib
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / "lib" / "quality.sh"


def run_shell(command, stdin=""):
    completed = subprocess.run(
        ["/bin/bash", "-u", "-o", "pipefail", "-c", f"source {shlex.quote(str(LIB))}\n{command}"],
        input=stdin,
        text=True,
        capture_output=True,
        check=True,
    )
    return completed.stdout


def parse(function, text="", *args):
    output = run_shell(" ".join([function] + [shlex.quote(str(x)) for x in args]), text)
    return dict(line.split("\t", 1) for line in output.splitlines())


def classify(**facts):
    with tempfile.NamedTemporaryFile(mode="w") as fixture:
        for key, value in facts.items():
            fixture.write(f"{key}\t{value}\n")
        fixture.flush()
        return parse(f"FACTS={shlex.quote(fixture.name)} quality_classify")


class PingTests(unittest.TestCase):
    def test_bsd_average_is_second_number_and_stddev_is_fourth(self):
        result = parse("quality_parse_ping", """PING 1.1.1.1 (1.1.1.1): 56 data bytes
8 packets transmitted, 7 packets received, 12.5% packet loss
round-trip min/avg/max/stddev = 10.125/20.250/45.500/8.125 ms
""")
        self.assertEqual(result["rtt"], "20.250")
        self.assertEqual(result["jitter"], "8.125")
        self.assertEqual(result["loss"], "12.5")
        self.assertEqual(result["received"], "7")

    def test_linux_format(self):
        result = parse("quality_parse_ping", "5 packets transmitted, 5 received, 0% packet loss, time 401ms\nrtt min/avg/max/mdev = 1.002/2.003/3.004/0.125 ms\n")
        self.assertEqual(result["rtt"], "2.003")
        self.assertEqual(result["loss"], "0")

    def test_no_reply_is_not_zero_latency(self):
        result = parse("quality_parse_ping", "8 packets transmitted, 0 packets received, 100.0% packet loss\n")
        self.assertEqual(result["rtt"], "unknown")
        self.assertEqual(result["loss"], "100.0")

    def test_command_error_does_not_invent_loss(self):
        result = parse("quality_parse_ping", "ping: cannot resolve example: Unknown host\n")
        self.assertEqual(result["loss"], "unknown")
        self.assertEqual(result["rtt"], "unknown")


class NettopTests(unittest.TestCase):
    def test_lifetime_counter_and_new_process_counter_are_discarded(self):
        result = parse("quality_parse_nettop", """,bytes_in,bytes_out,
ancient.1,999999999999,888888888888,
download.22,100000,200000,
,bytes_in,bytes_out,
ancient.1,0,0,
download.22,2000000,0,
new.33,999999999999,0,
,bytes_in,bytes_out,
ancient.1,0,0,
download.22,2000000,0,
new.33,0,0,
,bytes_in,bytes_out,
ancient.1,0,0,
download.22,2000000,0,
new.33,0,0,
""", 2)
        self.assertEqual(result["top"], "download")
        self.assertEqual(result["top_pid"], "22")
        self.assertEqual(result["top_mbps"], "8.000")
        self.assertEqual(result["seconds"], "6")

    def test_interface_filter_excludes_localhost_and_other_interfaces(self):
        result = parse("quality_parse_nettop", """,interface,bytes_in,bytes_out,
local.1,,999999999,0,
tcp4 127.0.0.1:1<->127.0.0.1:2,lo0,999999999,0,
remote.2,,999999999,0,
tcp4 192.168.1.2:1<->1.1.1.1:443,en0,999999999,0,
vpn.3,,999999999,0,
tcp4 100.1.1.1:1<->100.2.2.2:443,utun0,999999999,0,
,interface,bytes_in,bytes_out,
local.1,,900000000,0,
tcp4 127.0.0.1:1<->127.0.0.1:2,lo0,900000000,0,
remote.2,,1000000,0,
tcp4 192.168.1.2:1<->1.1.1.1:443,en0,1000000,0,
vpn.3,,900000000,0,
tcp4 100.1.1.1:1<->100.2.2.2:443,utun0,900000000,0,
""", 2, "en0")
        self.assertEqual(result["top"], "remote")
        self.assertEqual(result["top_mbps"], "4.000")

    def test_new_connection_cumulative_counter_excluded(self):
        result = parse("quality_parse_nettop", """,interface,bytes_in,bytes_out,
app.1,,100,0,
tcp4 local:1<->remote:1,en0,100,0,
,interface,bytes_in,bytes_out,
app.1,,999999999,0,
tcp4 local:1<->remote:1,en0,250000,0,
tcp4 local:2<->remote:2,en0,999999999,0,
""", 2, "en0")
        self.assertEqual(result["top_mbps"], "1.000")

    def test_counter_reappearing_after_gap_is_not_assumed_delta(self):
        result = parse("quality_parse_nettop", """,bytes_in,bytes_out,
app.1,1,0,
other.2,1,0,
,bytes_in,bytes_out,
other.2,0,0,
,bytes_in,bytes_out,
app.1,999999999,0,
other.2,0,0,
""", 2)
        self.assertEqual(result["top_mbps"], "0.000")

    def test_single_sample_unknown_not_zero(self):
        result = parse("quality_parse_nettop", ",bytes_in,bytes_out,\napp.123,99999,99999,\n", 2)
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["top_mbps"], "unknown")

    def test_empty_and_permission_failure_unknown(self):
        for sample in ("", "nettop: permission denied\n"):
            self.assertEqual(parse("quality_parse_nettop", sample, 2)["top_mbps"], "unknown")

    def test_header_reordering_names_with_commas_and_negative_delta(self):
        result = parse("quality_parse_nettop", """,bytes_out,bytes_in,
"Google, Browser.123",100,100,
,bytes_out,bytes_in,
"Google, Browser.123",-28,250000,
""", 2)
        self.assertEqual(result["top"], "Google, Browser")
        self.assertEqual(result["top_pid"], "123")
        self.assertEqual(result["top_mbps"], "1.000")


class SpeedTests(unittest.TestCase):
    def test_networkquality_multiline_real_macos_format(self):
        result = parse("quality_parse_networkquality", """==== CAPACITY ====
Uplink capacity: 72.320 Mbps
Downlink capacity: 43.945 Mbps
==== LATENCY ====
Idle Latency:
  512 RPM (116.960 milliseconds)
Uplink Responsiveness: Low
  97 RPM (615.645 milliseconds)
Downlink Responsiveness: Low
  140 RPM (425.918 milliseconds)
""")
        self.assertEqual(result, dict(down_mbps="43.945", up_mbps="72.320", idle_ms="116.960", loaded_down_ms="425.918", loaded_up_ms="615.645"))

    def test_networkquality_summary_and_units(self):
        result = parse("quality_parse_networkquality", """==== SUMMARY ====
Uplink capacity: 1234.000 Kbps
Downlink capacity: 1.250 Gbps
Uplink Responsiveness: Low (615.645 milliseconds | 97 RPM)
Downlink Responsiveness: Low (425.918 milliseconds | 140 RPM)
Idle Latency: 116.960 milliseconds | 512 RPM
""")
        self.assertEqual(result["up_mbps"], "1.234")
        self.assertEqual(result["down_mbps"], "1250.000")
        self.assertEqual(result["loaded_down_ms"], "425.918")
        self.assertEqual(result["idle_ms"], "116.960")

    def test_networkquality_error_has_unknown_numbers(self):
        result = parse("quality_parse_networkquality", "Error: configuration download failed\n")
        self.assertTrue(all(value == "unknown" for value in result.values()))

    def test_curl_valid_full_body(self):
        result = parse("quality_parse_curl_speed", "200 5000000 1250000", 0, 5000000)
        self.assertEqual(result["single_status"], "ok")
        self.assertEqual(result["single_down_mbps"], "10.000")

    def test_429_is_service_failure_even_if_curl_exits_successfully(self):
        result = parse("quality_parse_curl_speed", "429 98 10000", 0, 5000000)
        self.assertEqual(result["single_status"], "service_rate_limited")
        self.assertEqual(result["single_down_mbps"], "unknown")

    def test_timeout_partial_body_is_not_successful_throughput(self):
        result = parse("quality_parse_curl_speed", "200 1200000 60000", 28, 5000000)
        self.assertEqual(result["single_status"], "timeout")
        self.assertEqual(result["single_down_mbps"], "unknown")

    def test_error_document_and_empty_body_do_not_become_line_speed(self):
        for body in ("200 98 123", "503 5000000 1250000", "000 0 0", "200 5000000 0"):
            result = parse("quality_parse_curl_speed", body, 0, 5000000)
            self.assertNotEqual(result["single_status"], "ok")
            self.assertEqual(result["single_down_mbps"], "unknown")


class DNSTests(unittest.TestCase):
    def test_dig_stats_with_a_answer(self):
        result = parse("quality_parse_dig", """;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 111
;; ANSWER SECTION:
www.apple.com. 60 IN CNAME www.example.net.
www.example.net. 60 IN A 17.1.2.3
;; Query time: 19 msec
""")
        self.assertEqual(result, dict(ok="yes", status="NOERROR", ms="19", address="17.1.2.3"))

    def test_dig_noerror_without_answer_is_not_success(self):
        self.assertEqual(parse("quality_parse_dig", ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 111\n")["ok"], "no")

    def test_normal_dns_never_recommends_public_dns(self):
        result = parse("quality_parse_dns_decision", "apple\tyes\tyes\t0\tno\tno\tno\t850\ncloudflare\tyes\tyes\t0\tno\tno\tno\t900\n")
        self.assertEqual(result["dns_status"], "normal")
        self.assertEqual(result["dns_repair_candidate"], "no")
        self.assertEqual(result["dns_cache_candidate"], "no")

    def test_system_resolution_failure_but_dig_success_cache_candidate(self):
        result = parse("quality_parse_dns_decision", "apple\tyes\tno\t6\tno\tno\tno\t12\ncloudflare\tyes\tno\t6\tno\tno\tno\t4\n")
        self.assertEqual(result["dns_status"], "cache_failure")
        self.assertEqual(result["dns_cache_candidate"], "yes")
        self.assertEqual(result["dns_repair_candidate"], "no")

    def test_corroborated_resolver_failure_with_two_public_resolvers(self):
        result = parse("quality_parse_dns_decision", "apple\tno\tno\t6\tyes\tyes\tyes\tunknown\ncloudflare\tno\tno\t6\tyes\tyes\tyes\tunknown\n")
        self.assertEqual(result["dns_status"], "resolver_failure")
        self.assertEqual(result["dns_repair_candidate"], "yes")

    def test_no_dns_candidate_from_one_domain_or_icmp_or_https_timeout(self):
        for rows in (
            "apple\tno\tno\t6\tyes\tyes\tyes\tunknown\n",
            "apple\tno\tno\t6\tyes\tyes\tyes\tunknown\napple\tno\tno\t6\tyes\tyes\tyes\tunknown\n",
            "apple\tno\tno\t28\tyes\tyes\tyes\tunknown\ncloudflare\tno\tno\t28\tyes\tyes\tyes\tunknown\n",
            "apple\tno\tno\t6\tyes\tno\tyes\tunknown\ncloudflare\tno\tno\t6\tyes\tno\tyes\tunknown\n",
        ):
            result = parse("quality_parse_dns_decision", rows)
            self.assertEqual(result["dns_repair_candidate"], "no")
            self.assertEqual(result["dns_cache_candidate"], "no")


class ClassificationTests(unittest.TestCase):
    def test_external_packet_loss_alone_never_implies_wifi_or_mtu(self):
        result = classify(gw_rtt="2", gw_loss="0", rtt="30", loss="50", external2_loss="100", wifi_ssid="home", mtu_if="1500")
        self.assertEqual(result["bottleneck"], "unknown")
        self.assertNotIn("mtu_real", result)

    def test_unknown_process_measurement_never_implies_idle_or_occupancy(self):
        result = classify(process_capture_status="unknown", process_top_mbps="unknown", down_mbps="10", up_mbps="5", networkquality_status="ok")
        self.assertEqual(result["local_traffic_candidate"], "no")
        self.assertEqual(result["bottleneck"], "unknown")

    def test_total_localhost_inclusive_process_measurement_does_not_trigger(self):
        result = classify(process_all_top_mbps="2000", process_all_top_in_mbps="2000", process_capture_status="unknown", down_mbps="10", up_mbps="5", networkquality_status="ok")
        self.assertEqual(result["local_traffic_candidate"], "no")

    def test_interface_traffic_compared_against_measured_direction_only(self):
        result = classify(process_capture_status="ok", process_top_in_mbps="1", process_top_out_mbps="6", down_mbps="100", up_mbps="10", networkquality_status="ok")
        self.assertEqual(result["bottleneck"], "local_traffic")
        self.assertEqual(result["local_traffic_candidate"], "possible")
        self.assertNotIn("process_stop_candidate", result)

    def test_stable_gateway_but_loaded_application_latency_upstream_candidate(self):
        result = classify(networkquality_status="ok", idle_ms="20", loaded_down_ms="450", loaded_up_ms="400", gw_rtt="2", loaded_gw_rtt="4", gw_loss="0", loaded_gw_loss="0")
        self.assertEqual(result["bottleneck"], "upstream")
        self.assertEqual(result["bottleneck_confidence"], "medium")

    def test_loaded_gateway_latency_wifi_candidate(self):
        result = classify(networkquality_status="ok", idle_ms="20", loaded_down_ms="450", loaded_up_ms="400", gw_rtt="2", loaded_gw_rtt="140", gw_loss="0", loaded_gw_loss="0", wifi_ssid="home")
        self.assertEqual(result["bottleneck"], "local_wifi")

    def test_failed_speed_measurement_not_evidence_of_queueing(self):
        result = classify(networkquality_status="failed", idle_ms="20", loaded_down_ms="450", loaded_up_ms="400", gw_rtt="2", loaded_gw_rtt="4", gw_loss="0", loaded_gw_loss="0")
        self.assertEqual(result["bottleneck"], "unknown")

    def test_noise_floor_is_not_mistaken_for_weak_signal(self):
        result = classify(gw_rtt="40", wifi_signal="-58 dBm / -97 dBm", wifi_ssid="home")
        self.assertEqual(result["bottleneck"], "unknown")
        result = classify(gw_rtt="40", wifi_signal="-78 dBm / -97 dBm", wifi_ssid="home")
        self.assertEqual(result["bottleneck"], "local_wifi")


class ImportTests(unittest.TestCase):
    def test_import_is_silent_and_does_not_execute_measurements(self):
        self.assertEqual(run_shell(":"), "")


class CompositionTests(unittest.TestCase):
    def test_check_skips_load_and_records_processes_before_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            output = run_shell(f"""
FACTS={shlex.quote(directory + '/facts')}
: > "$FACTS"
fact() {{ printf '%s\\t%s\\n' "$1" "$2" >> "$FACTS"; }}
getf() {{ awk -F '\\t' -v k="$1" '$1==k{{v=$2}} END{{print v}}' "$FACTS"; }}
step() {{ :; }}; info() {{ :; }}; note() {{ :; }}; warn() {{ :; }}; finding() {{ :; }}
quality_process_probe() {{ echo processes; }}
quality_idle_pings() {{ echo pings; }}
quality_dns_probe() {{ echo dns; }}
quality_speed_probe() {{ echo UNEXPECTED_HEAVY_NETWORK_MEASUREMENT; }}
ifconfig() {{ echo 'en0: flags=active mtu 1500'; }}
DEFIF=en0; MODE=check
section_quality
printf 'heavy=%s\\n' "$(getf networkquality_status)"
printf 'mtu=%s\\n' "$(getf mtu_if)"
""")
        self.assertEqual(output.splitlines(), ["processes", "pings", "dns", "heavy=skipped", "mtu=1500"])

    def test_dns_probe_normal_uses_two_domains_and_never_queries_public_servers(self):
        with tempfile.TemporaryDirectory() as directory:
            output = run_shell(f"""
WORK={shlex.quote(directory)}
fact() {{ :; }}; info() {{ :; }}; note() {{ :; }}; warn() {{ :; }}; ok() {{ :; }}; finding() {{ :; }}
run_bounded() {{
  shift
  case "$1" in
    dig)
      case "$2" in @*) echo UNEXPECTED_PUBLIC_QUERY >> "$WORK/unexpected"; return 1 ;; esac
      printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 123\\nwww.example.net. 60 IN A 17.1.2.3\\n;; Query time: 12 msec\\n'
      ;;
    dscacheutil) echo 'ip_address: 17.1.2.3' ;;
    curl) echo '200 0.001' ;;
    *) return 127 ;;
  esac
}}
quality_dns_probe "$WORK"
cat "$WORK/dns.parsed"
[ ! -f "$WORK/unexpected" ]
""")
        result = dict(line.split("\t", 1) for line in output.splitlines())
        self.assertEqual(result["dns_domains_tested"], "2")
        self.assertEqual(result["dns_status"], "normal")
        self.assertEqual(result["dns_repair_candidate"], "no")

    def test_dns_probe_requires_working_forced_https_for_alternative_dns(self):
        with tempfile.TemporaryDirectory() as directory:
            output = run_shell(f"""
WORK={shlex.quote(directory)}
fact() {{ :; }}; info() {{ :; }}; note() {{ :; }}; warn() {{ :; }}; ok() {{ :; }}; finding() {{ :; }}
run_bounded() {{
  shift
  case "$1" in
    dig)
      case "$2" in
        @*) printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 123\\nwww.example.net. 60 IN A 17.1.2.3\\n;; Query time: 12 msec\\n' ;;
        *) echo ';; connection timed out; no servers could be reached'; return 9 ;;
      esac
      ;;
    dscacheutil) return 0 ;;
    curl)
      case " $* " in
        *' --resolve '*) echo '200'; return 0 ;;
        *) echo '000 0'; return 6 ;;
      esac
      ;;
    *) return 127 ;;
  esac
}}
quality_dns_probe "$WORK"
cat "$WORK/dns.parsed"
""")
        result = dict(line.split("\t", 1) for line in output.splitlines())
        self.assertEqual(result["dns_domains_tested"], "2")
        self.assertEqual(result["dns_status"], "resolver_failure")
        self.assertEqual(result["dns_repair_candidate"], "yes")


if __name__ == "__main__":
    unittest.main()

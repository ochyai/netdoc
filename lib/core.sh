#!/usr/bin/env bash
# Common helpers, compatible with the macOS /bin/bash 3.2.

# Enforce a deadline on a command and its children. Perl/POSIX ship with macOS.
# Exit 124 denotes a deadline; the original command exit code is otherwise kept.
run_bounded() {
  local deadline="$1"; shift
  /usr/bin/perl -MPOSIX -e '
    my $seconds = shift @ARGV;
    die "invalid timeout\n" unless $seconds =~ /^\d+$/ && $seconds > 0;
    my $pid = fork(); die "fork failed\n" unless defined $pid;
    if ($pid == 0) {
      POSIX::setpgid(0, 0);
      exec { $ARGV[0] } @ARGV;
      exit 127;
    }
    eval { POSIX::setpgid($pid, $pid) };
    my $stop = sub {
      my ($code) = @_;
      kill "TERM", -$pid;
      select undef, undef, undef, 0.25;
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit $code;
    };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{INT}  = sub { $stop->(130) };
    $SIG{TERM} = sub { $stop->(143) };
    $SIG{HUP}  = sub { $stop->(129) };
    alarm $seconds;
    waitpid($pid, 0);
    my $status = $?;
    alarm 0;
    exit (($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$deadline" "$@"
}

json_field() {
  /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

service_for_interface() {
  networksetup -listnetworkserviceorder 2>/dev/null |
    awk -v d="Device: $1)" 'index($0,d){print prev;exit} /^\([0-9]+\)/{prev=substr($0,index($0,") ")+2)}'
}

# Emit valid JSON with last observation winning. TSV fields have no raw controls.
emit_json() {
  {
    printf '{"netdoc":"%s","facts":{' "$VERSION"
    awk -F '\t' '
      function esc(s, i,c,out) {
        out=""; for(i=1;i<=length(s);i++) {
          c=substr(s,i,1);
          if(c=="\\") out=out "\\\\";
          else if(c=="\"") out=out "\\\"";
          else out=out c;
        } return out;
      }
      !($1 in vals){keys[++n]=$1} {vals[$1]=$2}
      END {for(i=1;i<=n;i++) printf "%s\"%s\":\"%s\"",(i==1?"":","),esc(keys[i]),esc(vals[keys[i]])}
    ' "$FACTS"
    printf '},"findings":['
    awk -F '\t' '
      function esc(s, i,c,out) {
        out=""; for(i=1;i<=length(s);i++) {
          c=substr(s,i,1);
          if(c=="\\") out=out "\\\\";
          else if(c=="\"") out=out "\\\"";
          else out=out c;
        } return out;
      }
      {printf "%s{\"priority\":%d,\"severity\":\"%s\",\"title\":\"%s\",\"fix\":\"%s\"}",
        (NR==1?"":","),$1,esc($2),esc($3),esc($4)}
    ' "$FIND"
    printf ']}\n'
  } >&3
}

# Called only after a real, verified repair. Keep DNS recovery and overall
# network performance as separate outcomes and do not reuse stale findings.
performance_retest() {
  local key before after label quality_findings route_info
  step "7. 修復前後の速度・応答比較"
  for key in down_mbps up_mbps single_down_mbps idle_ms loaded_down_ms loaded_up_ms; do
    fact "before_repair_$key" "$(getf "$key")"
  done
  # DHCP recovery may have created a default route that was absent at diagnosis.
  route_info=$(route -n get default 2>/dev/null)
  DEFIF=$(printf '%s\n' "$route_info" | awk '/interface:/{print $2;exit}')
  DEFGW=$(printf '%s\n' "$route_info" | awk '/gateway:/{print $2;exit}')
  fact default_if "$DEFIF"; fact gateway "$DEFGW"
  quality_findings="$FIND"
  FIND=$(mktemp -t netdoc.after-findings) || return 1
  section_quality
  for key in down_mbps up_mbps single_down_mbps idle_ms loaded_down_ms loaded_up_ms; do
    before=$(getf "before_repair_$key"); after=$(getf "$key")
    case "$key" in
      down_mbps) label="下り Mbps" ;;
      up_mbps) label="上り Mbps" ;;
      single_down_mbps) label="単一接続の下り Mbps" ;;
      idle_ms) label="通常時の応答 ms" ;;
      loaded_down_ms) label="ダウンロード中の応答 ms" ;;
      loaded_up_ms) label="アップロード中の応答 ms" ;;
    esac
    info "$label: ${before:-unknown} → ${after:-unknown}"
  done
  if [ -s "$FIND" ]; then cat "$FIND" >>"$quality_findings"; fi
  rm -f "$FIND"; FIND="$quality_findings"
  history_save
  if [ "$(getf networkquality_status)" != ok ]; then
    fact performance_outcome unverified
    warn "修復した症状は改善しましたが、回線性能の再測定は成立しませんでした"
    return 1
  fi
  if [ "$(getf queueing_observed)" = yes ] || [ "$(getf dns_status)" != normal ]; then
    fact performance_outcome residual_bottleneck
    warn "修復した症状の改善後も、回線全体の詰まりが残っています"
    note "$(getf bottleneck_limit)"
    return 1
  fi
  fact performance_outcome measured
  ok "修復後の回線性能を測定しました。今回の負荷試験で大きな待ち時間の増加は検出されませんでした"
  note "数値の変化には測定先や時間帯の影響もあるため、すべてのアプリの復旧を保証するものではありません"
}

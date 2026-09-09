#!/usr/bin/env bash
# Read-only network measurements. Source this file; it does not run on import.
# macOS / bash 3.2, using only system tools. Parsers accept stdin and emit TSV.

quality_parse_ping() {
  LC_ALL=C awk '
    BEGIN { loss="unknown"; avg="unknown"; jitter="unknown"; sent="unknown"; received="unknown" }
    /packets transmitted/ {
      sent=$1; received=$4
      for (i=1;i<=NF;i++) if ($i ~ /%$/) { loss=$i; sub(/%$/,"",loss) }
    }
    /round-trip|rtt min/ {
      s=$0; sub(/^.*=[[:space:]]*/,"",s); split(s,a,"/")
      if (a[2] ~ /^[0-9]+([.][0-9]+)?$/) avg=a[2]
      sub(/[[:space:]].*$/,"",a[4]); if(a[4] ~ /^[0-9]+([.][0-9]+)?$/) jitter=a[4]
    }
    END { printf "rtt\t%s\nloss\t%s\njitter\t%s\nsent\t%s\nreceived\t%s\n",avg,loss,jitter,sent,received }
  '
}

quality_parse_nettop() { # interval_seconds [exact_interface]; no interface = -P input
  LC_ALL=C awk -v interval="${1:-2}" -v iface="${2:-}" '
    # CSV names may contain spaces, commas, quotes, or dots before the PID.
    function csv(line,a,   i,c,q,n,value) {
      n=1; q=0; value=""
      for(i=1;i<=length(line);i++) {
        c=substr(line,i,1)
        if(c=="\"") { if(q && substr(line,i+1,1)=="\"") {value=value "\"";i++} else q=!q }
        else if(c=="," && !q) {a[n++]=value;value=""} else value=value c
      }
      a[n]=value; return n
    }
    { sub(/\r$/,"",$0); n=csv($0,a) }
    a[1]=="" {
      ni=0; no=0; nf=0
      for(i=2;i<=n;i++) {if(a[i]=="bytes_in") ni=i; if(a[i]=="bytes_out") no=i; if(a[i]=="interface") nf=i}
      if(ni && no) {samples++; current=""}
      next
    }
    !ni || !no {next}
    a[1] !~ /^(tcp|udp|quic)[46] / && a[1] ~ /[.][0-9]+$/ {
      current=a[1]
      if(iface!="") next
      key=current
    }
    iface!="" {
      if(nf==0 || a[nf]!=iface || current=="" || a[1] !~ /^(tcp|udp|quic)[46] /) next
      key=current SUBSEP a[1] SUBSEP a[nf]
    }
    iface=="" && a[1]!=current {next}
    {
      if(a[ni] !~ /^-?[0-9]+$/ || a[no] !~ /^-?[0-9]+$/) next
      rows++
      # A newly observed process/flow may expose a lifetime counter, even in -d.
      # Discard its first observation, including objects appearing after sample 1.
      if(!(key in seen)) {seen[key]=samples;next}
      if(seen[key]==samples || samples<2) next
      if(seen[key]!=samples-1) {seen[key]=samples;next}
      seen[key]=samples
      rx=(a[ni]+0<0 ? 0 : a[ni]+0); tx=(a[no]+0<0 ? 0 : a[no]+0)
      valid++; rin[current]+=rx; rout[current]+=tx
    }
    END {
      if(samples<2 || valid==0 || interval<=0) {
        print "status\tunknown\ntop\tunknown\ntop_pid\tunknown\ntop_mbps\tunknown\ntop_in_mbps\tunknown\ntop_out_mbps\tunknown";exit
      }
      best=""; total=-1
      for(p in rin) if(rin[p]+rout[p]>total || (rin[p]+rout[p]==total && p<best)) {best=p;total=rin[p]+rout[p]}
      seconds=(samples-1)*interval; pid=best; sub(/^.*[.]/,"",pid); name=best; sub(/[.][0-9]+$/,"",name)
      gsub(/[\t\r\n]/," ",name)
      printf "status\tok\nsamples\t%d\nseconds\t%d\ntop\t%s\ntop_pid\t%s\ntop_mbps\t%.3f\ntop_in_mbps\t%.3f\ntop_out_mbps\t%.3f\n",samples,seconds,name,pid,total*8/seconds/1000000,rin[best]*8/seconds/1000000,rout[best]*8/seconds/1000000
    }
  '
}

quality_parse_networkquality() {
  tr '\r' '\n' | LC_ALL=C awk '
    BEGIN { down="unknown";up="unknown";idle="unknown";ld="unknown";lu="unknown";context="" }
    function numeric(s) {return s ~ /^[0-9]+([.][0-9]+)?$/}
    function rate(s,   n,a,i,m) {
      n=split(s,a,/[[:space:]]+/)
      for(i=2;i<=n;i++) if(a[i] ~ /^(Kbps|Mbps|Gbps)$/ && numeric(a[i-1])) {
        m=1;if(a[i]=="Kbps")m=.001;if(a[i]=="Gbps")m=1000;return sprintf("%.3f",a[i-1]*m)
      }
      return "unknown"
    }
    function latency(s,   n,a,i) {
      gsub(/[()|,]/," ",s);n=split(s,a,/[[:space:]]+/)
      for(i=2;i<=n;i++) if(a[i] ~ /^(milliseconds|ms)$/ && numeric(a[i-1])) return a[i-1]
      return "unknown"
    }
    {
      low=tolower($0)
      if(low ~ /downlink capacity:/) {v=rate($0);if(v!="unknown")down=v;context="";next}
      if(low ~ /uplink capacity:/) {v=rate($0);if(v!="unknown")up=v;context="";next}
      if(low ~ /idle latency:/) context="idle"
      else if(low ~ /uplink responsiveness:/) context="up"
      else if(low ~ /downlink responsiveness:/) context="down"
      else if(low ~ /^====/) context=""
      v=latency($0)
      if(v!="unknown" && context!="") {if(context=="idle")idle=v;if(context=="up")lu=v;if(context=="down")ld=v;context=""}
    }
    END { printf "down_mbps\t%s\nup_mbps\t%s\nidle_ms\t%s\nloaded_down_ms\t%s\nloaded_up_ms\t%s\n",down,up,idle,ld,lu }
  '
}

quality_parse_curl_speed() { # curl_exit expected_bytes; input: http_code bytes speed_download
  LC_ALL=C awk -v rc="$1" -v expected="${2:-5000000}" '
    BEGIN {code="unknown";bytes="unknown";speed="unknown";status="failed";value="unknown"}
    NF>=3 {code=$1;bytes=$2;speed=$3}
    END {
      if(rc==0 && code==200 && bytes ~ /^[0-9]+([.][0-9]+)?$/ && bytes==expected && speed ~ /^[0-9]+([.][0-9]+)?$/ && speed>0) {status="ok";value=sprintf("%.3f",speed*8/1000000)}
      else if(code==429) status="service_rate_limited"
      else if(rc==28) status="timeout"
      else if(rc==0 && code==200) status="invalid_body"
      printf "single_status\t%s\nsingle_http_code\t%s\nsingle_exit\t%s\nsingle_bytes\t%s\nsingle_down_mbps\t%s\n",status,code,rc,bytes,value
    }
  '
}

quality_parse_dig() { # input: dig +stats output; require an actual A answer
  LC_ALL=C awk '
    BEGIN {status="unknown";ms="unknown";address="unknown"}
    /status: / {s=$0;sub(/^.*status: /,"",s);sub(/,.*/,"",s);status=s}
    /^;; Query time:/ && $4 ~ /^[0-9]+$/ {ms=$4}
    $0 !~ /^;/ && $4=="A" && $5 ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ {address=$5}
    END {if(status=="NOERROR" && address!="unknown")ok="yes";else ok="no";printf "ok\t%s\nstatus\t%s\nms\t%s\naddress\t%s\n",ok,status,ms,address}
  '
}

quality_parse_dns_decision() { # domain, dig_ok, system_ok, curl_exit, public_a_ok, public_b_ok, forced_https_ok, dig_ms
  LC_ALL=C awk -F'\t' '
    NF>=8 {
      if(seen[$1]++) next
      n++;if($2=="yes") digs++;if($3=="yes") systems++;if($4==0) https++
      if($3=="no" && $4==6) failures++
      if($5=="yes" && $6=="yes" && $7=="yes") alternative++
      if($8 ~ /^[0-9]+$/) {sum+=$8;timings++}
    }
    END {
      status="inconclusive";cache="no";repair="no"
      if(n>=2 && systems==n && https==n) status="normal"
      else if(n>=2 && failures==n && digs==n) {status="cache_failure";cache="yes"}
      else if(n>=2 && failures==n && digs==0 && alternative==n) {status="resolver_failure";repair="yes"}
      ms="unknown";if(timings>0)ms=sprintf("%.1f",sum/timings)
      printf "dns_status\t%s\ndns_cache_candidate\t%s\ndns_repair_candidate\t%s\ndns_ms\t%s\ndns_domains_tested\t%d\n",status,cache,repair,ms,n
    }
  '
}

quality_store() { # prefix; input: key<TAB>value
  local key value
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] && fact "$1$key" "$value"
  done
}

quality_value() { # TSV file key
  awk -F'\t' -v key="$2" '$1==key {print $2;exit}' "$1"
}

quality_dns_one() { # directory domain. No facts written by concurrent workers.
  local dir="$1" domain="$2" rc result digok sysok address code pub1=no pub2=no forced=no
  run_bounded 5 dig +time=2 +tries=1 +stats "$domain" A >"$dir/dig" 2>"$dir/dig.err" || true
  quality_parse_dig <"$dir/dig" >"$dir/dig.parsed"
  digok=$(quality_value "$dir/dig.parsed" ok)
  run_bounded 5 dscacheutil -q host -a name "$domain" >"$dir/system" 2>"$dir/system.err" || true
  sysok=no
  grep -Eq '(^|[[:space:]])(ip_address|ipv6_address):[[:space:]]+[^[:space:]]' "$dir/system" && sysok=yes
  rc=0
  run_bounded 8 curl --noproxy '*' -sS -I -o /dev/null --max-time 6 --connect-timeout 4 \
    -w '%{http_code} %{time_namelookup}' "https://$domain/" >"$dir/curl" 2>"$dir/curl.err" || rc=$?
  # Only perform public-resolver comparisons after corroborated system failure.
  if [ "$digok" = no ] && [ "$sysok" = no ] && [ "$rc" -eq 6 ]; then
    run_bounded 5 dig @1.1.1.1 +time=2 +tries=1 +stats "$domain" A >"$dir/public1" 2>"$dir/public1.err" || true
    run_bounded 5 dig @8.8.8.8 +time=2 +tries=1 +stats "$domain" A >"$dir/public2" 2>"$dir/public2.err" || true
    quality_parse_dig <"$dir/public1" >"$dir/public1.parsed"
    quality_parse_dig <"$dir/public2" >"$dir/public2.parsed"
    pub1=$(quality_value "$dir/public1.parsed" ok); pub2=$(quality_value "$dir/public2.parsed" ok)
    if [ "$pub1" = yes ] && [ "$pub2" = yes ]; then
      address=$(quality_value "$dir/public1.parsed" address)
      if run_bounded 8 curl --noproxy '*' -sS -I -o /dev/null --max-time 6 --connect-timeout 4 \
        --resolve "$domain:443:$address" -w '%{http_code}' "https://$domain/" >"$dir/forced" 2>"$dir/forced.err"; then
        code=$(cat "$dir/forced")
        case "$code" in 2??|3??) forced=yes ;; esac
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$domain" "$digok" "$sysok" "$rc" "$pub1" "$pub2" "$forced" "$(quality_value "$dir/dig.parsed" ms)" >"$dir/result"
}

quality_dns_probe() { # private working directory; also usable for a same-probe repair retest
  local dir="$1" p1 p2
  mkdir -p "$dir/dns-apple" "$dir/dns-cloudflare"
  quality_dns_one "$dir/dns-apple" www.apple.com & p1=$!
  quality_dns_one "$dir/dns-cloudflare" www.cloudflare.com & p2=$!
  wait "$p1" || true; wait "$p2" || true
  cat "$dir/dns-apple/result" "$dir/dns-cloudflare/result" >"$dir/dns.rows"
  quality_parse_dns_decision <"$dir/dns.rows" >"$dir/dns.parsed"
  quality_store "" <"$dir/dns.parsed"
  case "$(quality_value "$dir/dns.parsed" dns_status)" in
    normal) ok "DNS: 2ドメインでシステム名前解決とHTTPS成功 (dig平均 $(quality_value "$dir/dns.parsed" dns_ms) ms)" ;;
    cache_failure) warn "DNS: digは成功するがシステム名前解決とHTTPSが2ドメインで失敗"; finding 15 warn "DNSキャッシュ・システムリゾルバの不調候補" "DNSキャッシュ消去後、同じ2ドメインを再検証" ;;
    resolver_failure) warn "DNS: 設定中のDNSで失敗、公開DNSと直接HTTPSで成功を確認"; finding 15 warn "設定中のDNSリゾルバの不調候補" "DNS設定をバックアップし、代替DNSを試して同条件で再検証" ;;
    *) info "DNS: 結果が一致しないため原因は未確定" ;;
  esac
}

quality_process_probe() { # directory; capture before any deliberate bandwidth load
  local dir="$1" p1 p2 rc1=0 rc2=0
  if ! command -v nettop >/dev/null 2>&1; then
    fact process_capture_status unknown; fact process_top unknown; fact process_top_pid unknown
    fact process_top_mbps unknown; fact process_top_in_mbps unknown; fact process_top_out_mbps unknown
    fact process_top_scope unknown
    info "アプリ通信量: nettopを利用できず不明"; return
  fi
  run_bounded 12 nettop -P -L 4 -s 2 -d -x -J bytes_in,bytes_out -n >"$dir/process-all" 2>"$dir/process-all.err" & p1=$!
  run_bounded 12 nettop -L 4 -s 2 -d -x -J interface,bytes_in,bytes_out -n >"$dir/process-if" 2>"$dir/process-if.err" & p2=$!
  wait "$p1" || rc1=$?; wait "$p2" || rc2=$?
  if [ "$rc1" -eq 0 ]; then
    quality_parse_nettop 2 <"$dir/process-all" >"$dir/process-all.parsed"
  else quality_parse_nettop 2 </dev/null >"$dir/process-all.parsed"; fi
  quality_store process_all_ <"$dir/process-all.parsed"
  if [ -n "${DEFIF:-}" ] && [ "$rc2" -eq 0 ]; then
    quality_parse_nettop 2 "$DEFIF" <"$dir/process-if" >"$dir/process-if.parsed"
  else
    quality_parse_nettop 2 "unknown" </dev/null >"$dir/process-if.parsed"
  fi
  quality_store process_ <"$dir/process-if.parsed"
  fact process_capture_status "$(quality_value "$dir/process-if.parsed" status)"
  fact process_top_scope "${DEFIF:-unknown}"
  if [ "$(quality_value "$dir/process-if.parsed" status)" = ok ]; then
    info "アプリ通信量 ($DEFIF): $(quality_value "$dir/process-if.parsed" top) [PID $(quality_value "$dir/process-if.parsed" top_pid)] 下り $(quality_value "$dir/process-if.parsed" top_in_mbps) / 上り $(quality_value "$dir/process-if.parsed" top_out_mbps) Mbps"
    note "6秒の差分。初回累計・localhost・別IFを除外。LAN通信も含むため回線占有とは断定しません"
  else
    info "アプリ通信量: 有効な差分を取得できず不明（通信ゼロとは区別）"
  fi
}

quality_ping_store() { # raw_path prefix
  quality_parse_ping <"$1" | quality_store "$2"
}

quality_idle_pings() {
  local dir="$1" p1="" p2 p3
  if [ -n "${DEFGW:-}" ]; then
    run_bounded 8 ping -n -c 8 -i 0.5 -t 6 -W 1000 "$DEFGW" >"$dir/gw.ping" 2>"$dir/gw.err" & p1=$!
  else : >"$dir/gw.ping"; fi
  run_bounded 8 ping -n -c 8 -i 0.5 -t 6 -W 1000 1.1.1.1 >"$dir/ext.ping" 2>"$dir/ext.err" & p2=$!
  run_bounded 8 ping -n -c 8 -i 0.5 -t 6 -W 1000 8.8.8.8 >"$dir/ext2.ping" 2>"$dir/ext2.err" & p3=$!
  [ -z "$p1" ] || wait "$p1" || true
  wait "$p2" || true; wait "$p3" || true
  quality_ping_store "$dir/gw.ping" gw_
  quality_ping_store "$dir/ext.ping" ""
  quality_ping_store "$dir/ext2.ping" external2_
  info "遅延/ICMP欠落: GW $(getf gw_rtt) ms / $(getf gw_loss)%、1.1.1.1 $(getf rtt) ms / $(getf loss)%、8.8.8.8 $(getf external2_rtt) ms / $(getf external2_loss)%"
  note "ICMPの欠落は応答制限でも発生します。これだけでWi-Fi障害やMTU不整合とは判定しません"
}

quality_speed_probe() {
  local dir="$1" p1="" p2 p3 rc=0 key value status=unavailable
  if command -v networkQuality >/dev/null 2>&1; then
    info "速度と負荷時の応答を測定中（最大45秒、大きな通信量が発生します）"
    # These are direct children owned by this probe. Stop only these PIDs.
    if [ -n "${DEFGW:-}" ]; then
      LC_ALL=C ping -n -c 44 -i 1 -t 44 -W 1000 "$DEFGW" >"$dir/loaded-gw" 2>"$dir/loaded-gw.err" & p1=$!
    else : >"$dir/loaded-gw"; fi
    LC_ALL=C ping -n -c 44 -i 1 -t 44 -W 1000 1.1.1.1 >"$dir/loaded-ext" 2>"$dir/loaded-ext.err" & p2=$!
    LC_ALL=C ping -n -c 44 -i 1 -t 44 -W 1000 8.8.8.8 >"$dir/loaded-ext2" 2>"$dir/loaded-ext2.err" & p3=$!
    run_bounded 45 env LC_ALL=C networkQuality -s -M 35 -v >"$dir/networkquality" 2>"$dir/networkquality.err" || rc=$?
    [ -z "$p1" ] || kill -INT "$p1" 2>/dev/null || true
    kill -INT "$p2" "$p3" 2>/dev/null || true
    [ -z "$p1" ] || wait "$p1" || true
    wait "$p2" || true; wait "$p3" || true
    quality_ping_store "$dir/loaded-gw" loaded_gw_
    quality_ping_store "$dir/loaded-ext" loaded_external_
    quality_ping_store "$dir/loaded-ext2" loaded_external2_
    quality_parse_networkquality <"$dir/networkquality" >"$dir/networkquality.parsed"
    quality_store "" <"$dir/networkquality.parsed"
    status=failed
    if [ "$rc" -eq 0 ]; then
      status=partial
      if [ "$(getf down_mbps)" != unknown ] && [ "$(getf up_mbps)" != unknown ]; then status=ok; fi
    fi
    fact networkquality_exit "$rc"
    if [ "$status" = ok ]; then
      info "回線速度: 下り $(getf down_mbps) / 上り $(getf up_mbps) Mbps; 平常 $(getf idle_ms) ms / 負荷時 下り $(getf loaded_down_ms) ms・上り $(getf loaded_up_ms) ms"
    else
      warn "回線測定は未完了 ($status, exit $rc)。下り $(getf down_mbps) / 上り $(getf up_mbps) Mbps は途中の参考値です"
    fi
  else
    for key in down_mbps up_mbps idle_ms loaded_down_ms loaded_up_ms; do fact "$key" unknown; done
    info "networkQualityを利用できず、回線全体の測定は不明"
  fi
  fact networkquality_status "$status"
  rc=0
  run_bounded 22 curl --noproxy '*' -sS -o /dev/null --max-time 20 --connect-timeout 5 --max-filesize 5000000 \
    -w '%{http_code} %{size_download} %{speed_download}' 'https://speed.cloudflare.com/__down?bytes=5000000' >"$dir/single" 2>"$dir/single.err" || rc=$?
  quality_parse_curl_speed "$rc" 5000000 <"$dir/single" >"$dir/single.parsed"
  quality_store "" <"$dir/single.parsed"
  if [ "$(getf single_status)" = ok ]; then
    info "単一接続 (5 MB): $(getf single_down_mbps) Mbps"
  else
    info "単一接続: 測定不成立 ($(getf single_status), HTTP $(getf single_http_code), exit $(getf single_exit))"
  fi
}

quality_classify() { # pure classification over measured facts; never creates process stop candidates
  LC_ALL=C awk -F'\t' '
    {f[$1]=$2}
    function num(v) {return v ~ /^[0-9]+([.][0-9]+)?$/}
    function high(v,t) {return num(v) && v+0>=t}
    function growth(base,loaded) {return num(base) && num(loaded) && loaded-base>=50 && loaded>=base*2}
    END {
      cause="unknown";confidence="low";local="no";queue="no"
      split(f["wifi_signal"],signal,/[[:space:]]+/);rssi=signal[1]
      limit="単一端末・短時間の測定。AP、ルーター、ISPの切り分けには有線や別回線との比較が必要"
      if(f["networkquality_status"]=="ok" && (growth(f["idle_ms"],f["loaded_down_ms"]) || growth(f["idle_ms"],f["loaded_up_ms"]))) queue="yes"
      if(f["process_capture_status"]=="ok" && f["networkquality_status"]=="ok" && (high(f["process_top_in_mbps"],1) && num(f["down_mbps"]) && f["down_mbps"]>0 && f["process_top_in_mbps"]>=f["down_mbps"]*.5 || high(f["process_top_out_mbps"],1) && num(f["up_mbps"]) && f["up_mbps"]>0 && f["process_top_out_mbps"]>=f["up_mbps"]*.5)) local="possible"
      if(f["dns_cache_candidate"]=="yes" || f["dns_repair_candidate"]=="yes") {cause="dns";confidence="medium"}
      else if(local=="possible") {cause="local_traffic";confidence="medium";limit="同一IFの通信量と後の回線測定との比較。LAN通信・測定時刻差を含むためアプリ停止で改善するとは未確認"}
      else if(queue=="yes") {
        if(num(f["loaded_gw_rtt"]) && num(f["gw_rtt"]) && f["gw_loss"]==0 && f["loaded_gw_loss"]==0 && f["loaded_gw_rtt"]-f["gw_rtt"]<15 && f["loaded_gw_rtt"]<25) {cause="upstream";confidence="medium"}
        else if(growth(f["gw_rtt"],f["loaded_gw_rtt"])) {cause="local_link";confidence="medium";if(f["wifi_ssid"]!="")cause="local_wifi"}
      }
      else if(high(f["gw_rtt"],30) && rssi ~ /^-[0-9]+$/ && rssi+0<=-75) {cause="local_wifi";confidence="low"}
      printf "bottleneck\t%s\nbottleneck_confidence\t%s\nbottleneck_limit\t%s\nlocal_traffic_candidate\t%s\nqueueing_observed\t%s\n",cause,confidence,limit,local,queue
    }
  ' "$FACTS"
}

section_quality() {
  local dir mtu key label certainty
  step "2. 回線の質と詰まりの切り分け"
  dir=$(mktemp -d -t netdoc.quality) || return 1
  quality_process_probe "$dir"
  quality_idle_pings "$dir"
  quality_dns_probe "$dir"
  mtu=unknown
  if [ -n "${DEFIF:-}" ]; then
    mtu=$(ifconfig "$DEFIF" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="mtu"){print $(i+1);exit}}')
  fi
  fact mtu_if "${mtu:-unknown}"
  fact mtu_observation "インターフェース設定のみ。経路MTUは未確定。ICMP欠落から変更値を推定しない"
  info "MTU: 設定 ${mtu:-unknown}（経路MTUの推定・自動変更は行いません）"
  case "${MODE:-check}" in
    speed|full|report|json|fix|auto|plan) quality_speed_probe "$dir" ;;
    *) fact networkquality_status skipped; info "負荷測定: 省略（netdoc --speed / --full で実行）" ;;
  esac
  quality_classify >"$dir/classification"
  quality_store "" <"$dir/classification"
  case "$(getf bottleneck)" in
    upstream) finding 40 warn "負荷時にルーターより先の応答遅延が増える傾向" "有線で再測定。変わらなければルーターの帯域制御やISP混雑を確認" ;;
    local_wifi|local_link) finding 40 warn "Macからルーターまでの区間に遅延増大の疑い" "有線で比較、APの近くや別のWi-Fi帯域で再測定" ;;
    local_traffic) finding 40 warn "実測回線速度に対して大きいアプリ通信量を観測" "アプリの転送内容を確認し、必要なら netdoc --pause $(getf process_top_pid) 60 で一時停止して比較" ;;
  esac
  if [ "$(getf queueing_observed)" = yes ]; then
    warn "負荷時の待ち時間が増大しています。Webや動画の応答に影響する可能性があります"
    if [ "$(getf bottleneck)" = unknown ]; then
      finding 40 warn "負荷時の応答遅延は増大しているが区間は未確定" "有線接続や別の回線で同じ測定を比較し、Wi-Fiとルーターより先を切り分ける"
    fi
  fi
  case "$(getf bottleneck)" in
    upstream) label="ルーターより先の回線" ;;
    local_wifi) label="MacとWi-Fiアクセスポイントの間" ;;
    local_link) label="Macとルーターの間" ;;
    local_traffic) label="Macのアプリによる大きな通信" ;;
    dns) label="DNSの名前解決" ;;
    *) label="区間・原因は未確定" ;;
  esac
  case "$(getf bottleneck_confidence)" in medium) certainty="中" ;; high) certainty="高" ;; *) certainty="低" ;; esac
  info "詰まりの候補: ${label}（確度 ${certainty}）"
  note "$(getf bottleneck_limit)"
  note "実測値は時間帯・測定先・同じ回線を使う他の端末の通信でも変わります"
  rm -rf "$dir"
}

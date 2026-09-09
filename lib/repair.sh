#!/usr/bin/env bash
# Evidence-led repairs for macOS. Sourcing this file never changes settings.
# The caller provides fact/getf, output helpers, ask, and run_bounded.
# Call repair_cleanup from the caller's EXIT/INT/TERM/HUP cleanup trap.

REPAIR_DNS_ACTIVE=""
REPAIR_DNS_BEFORE=""
REPAIR_DNS_PENDING_VALID=0
REPAIR_CACHE_ATTEMPTED=0
REPAIR_DHCP_ATTEMPTED=0
REPAIR_DNS_ATTEMPTED=0
REPAIR_PRIVILEGED=0
REPAIR_BEFORE=""

repair_service_for_interface() {
  [ -n "${1:-}" ] || return 1
  LC_ALL=C networksetup -listnetworkserviceorder 2>/dev/null |
    awk -v d="Device: $1)" 'index($0,d){print prev; exit} /^\([0-9]+\) /{prev=substr($0,index($0,") ")+2)}'
}

# Re-read identity every time; a previous diagnosis is not an identity guard.
repair_context() {
  local route_info mac ssid
  route_info=$(route -n get default 2>/dev/null) || return 1
  REPAIR_IF=$(printf '%s\n' "$route_info" | awk '/interface:/{print $2; exit}')
  REPAIR_GW=$(printf '%s\n' "$route_info" | awk '/gateway:/{print $2; exit}')
  [ -n "$REPAIR_IF" ] && [ -n "$REPAIR_GW" ] || return 1
  REPAIR_SERVICE=$(repair_service_for_interface "$REPAIR_IF")
  [ -n "$REPAIR_SERVICE" ] || return 1
  mac=$(arp -n "$REPAIR_GW" 2>/dev/null | awk '/ at / && $4 ~ /^[0-9a-fA-F:]+$/ {print tolower($4); exit}')
  ssid=$(LC_ALL=C networksetup -getairportnetwork "$REPAIR_IF" 2>/dev/null |
    sed -n 's/^Current Wi-Fi Network: //p')
  # Gateway IP alone is shared by many networks and is not a sufficient guard.
  [ -n "$mac$ssid" ] || return 1
  REPAIR_FINGERPRINT=$(printf '%s\n' "$REPAIR_IF" "$REPAIR_SERVICE" "$REPAIR_GW" "$mac" "$ssid" | cksum | awk '{print $1 ":" $2}')
}

repair_authorize_sudo() {
  [ "$REPAIR_PRIVILEGED" = 1 ] && return 0
  if run_bounded 5 sudo -n true >/dev/null 2>&1; then
    REPAIR_PRIVILEGED=1; return 0
  fi
  [ "${MODE:-check}" != auto ] && [ -t 0 ] || {
    warn "管理者権限を無人で取得できません。変更をスキップします"; return 1;
  }
  # Only entered after an explicit repair choice. Never ask in unattended mode.
  # sudo must retain the foreground terminal to read its password. The bounded
  # runner isolates process groups for network probes and cannot be used here.
  if sudo -v; then REPAIR_PRIVILEGED=1; return 0; fi
  warn "管理者認証できませんでした。変更をスキップします"
  return 1
}

repair_dns_values_valid() {
  awk '
    NF != 1 {bad=1; next}
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {n=split($0,a,"."); for(i=1;i<=n;i++) if(a[i]>255)bad=1; count++; next}
    /^[0-9A-Fa-f:]+(%[A-Za-z0-9_.-]+)?$/ && /:/ {count++; next}
    {bad=1}
    END {exit (bad || count==0)}'
}

repair_read_dns() {
  local value
  value=$(LC_ALL=C networksetup -getdnsservers "$1" 2>&1) || return 1
  case "$value" in
    "There aren't any DNS Servers set on "*) printf 'empty\n'; return 0 ;;
  esac
  printf '%s\n' "$value" | repair_dns_values_valid || return 1
  printf '%s\n' "$value"
}

repair_set_dns() {
  local service="$1" values="$2" output rc value
  local args=()
  if [ "$values" = empty ]; then
    args=(empty)
  else
    printf '%s\n' "$values" | repair_dns_values_valid || return 1
    while IFS= read -r value; do args[${#args[@]}]="$value"; done <<<"$values"
  fi
  output=$(run_bounded 15 sudo -n networksetup -setdnsservers "$service" "${args[@]}" 2>&1)
  rc=$?
  [ "$rc" = 0 ] || { warn "DNS設定コマンドが失敗しました: $output"; return 1; }
  if printf '%s\n' "$output" | grep -qiE 'error|not a valid|not found|not permitted|permission denied|failed'; then
    warn "DNS設定が拒否されました: $output"; return 1
  fi
  [ "$(repair_read_dns "$service")" = "$values" ] || {
    warn "DNS設定の読み戻しが一致しません"; return 1;
  }
}

repair_private_root() {
  local root="${CONF_DIR:-$HOME/.netdoc}/repairs"
  [ ! -L "${CONF_DIR:-$HOME/.netdoc}" ] && [ ! -L "$root" ] || return 1
  (umask 077; mkdir -p "$root") || return 1
  [ "$(stat -f %u "$root" 2>/dev/null)" = "$(id -u)" ] || return 1
  chmod 700 "$root" || return 1
  printf '%s\n' "$root"
}

repair_save_dns() {
  local root dir old
  repair_context || { warn "ネットワークを一意に識別できず、DNS変更を中止します"; return 1; }
  old=$(repair_read_dns "$REPAIR_SERVICE") || { warn "元のDNS設定を取得できません"; return 1; }
  root=$(repair_private_root) || { warn "安全なバックアップ先を作れません"; return 1; }
  dir=$(umask 077; mktemp -d "$root/dns-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
  (
    umask 077
    printf '%s\n' "$REPAIR_SERVICE" >"$dir/service"
    printf '%s\n' "$REPAIR_IF" >"$dir/interface"
    printf '%s\n' "$REPAIR_FINGERPRINT" >"$dir/network"
    printf '%s\n' "$old" >"$dir/dns.original"
    printf '%s\n' '1.1.1.1' '8.8.8.8' >"$dir/dns.applied"
    printf '%s\n' 'netdoc-dns-backup-v1' >"$dir/format"
    chmod 400 "$dir"/*
  ) || return 1
  REPAIR_DNS_ACTIVE="$dir"
  fact repair_backup "$dir"
}

repair_backup_valid() {
  local dir="$1" root file
  root="${CONF_DIR:-$HOME/.netdoc}/repairs"
  [ ! -L "$root" ] && [ ! -L "${CONF_DIR:-$HOME/.netdoc}" ] || return 1
  case "$dir" in "$root"/dns-*) ;; *) return 1 ;; esac
  case "${dir#"$root"/}" in */*|*..*) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ "$(stat -f %u "$dir" 2>/dev/null)" = "$(id -u)" ] || return 1
  for file in service interface network dns.original dns.applied format; do
    [ -f "$dir/$file" ] && [ ! -L "$dir/$file" ] || return 1
    [ "$(stat -f %u "$dir/$file" 2>/dev/null)" = "$(id -u)" ] || return 1
  done
  [ "$(cat "$dir/format")" = netdoc-dns-backup-v1 ] || return 1
  repair_context || return 1
  [ "$(cat "$dir/service")" = "$REPAIR_SERVICE" ] &&
    [ "$(cat "$dir/interface")" = "$REPAIR_IF" ] &&
    [ "$(cat "$dir/network")" = "$REPAIR_FINGERPRINT" ]
}

repair_restore_backup() {
  local dir="$1" current original applied
  repair_backup_valid "$dir" || {
    warn "復元を中止: 保存時のサービス・ネットワークと一致しないか、バックアップが不正です"; return 1;
  }
  original=$(cat "$dir/dns.original")
  applied=$(cat "$dir/dns.applied")
  current=$(repair_read_dns "$REPAIR_SERVICE") || { warn "現在のDNSを読めず復元できません"; return 1; }
  [ "$current" = "$original" ] && { ok "DNSは保存時の設定と一致しています"; return 0; }
  [ "$current" = "$applied" ] || {
    warn "保存後にDNSが別の値へ変わっています。上書きせず復元を中止します"; return 1;
  }
  repair_authorize_sudo || return 1
  repair_set_dns "$REPAIR_SERVICE" "$original" || {
    ng "DNS復元に失敗しました。バックアップ: $dir"; return 1;
  }
  ok "DNSを保存時の設定に復元しました: $REPAIR_SERVICE"
  fact dns_restore verified
}

restore_changes() {
  local selected="${1:-latest}" root dir
  root="${CONF_DIR:-$HOME/.netdoc}/repairs"
  if [ "$selected" = latest ]; then
    dir=$(ls -dt "$root"/dns-* 2>/dev/null | head -1)
  else
    case "$selected" in */*|*..*|'') warn "復元IDは dns- で始まるバックアップ名を指定してください"; return 1 ;; esac
    dir="$root/$selected"
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || {
    warn "復元用バックアップがありません。DNS設定は変更していません"; return 1;
  }
  repair_restore_backup "$dir"
}
restore_dns() { restore_changes "${1:-latest}"; }

# Probe the exact same names and HTTP routes before and after a change.
# Results: system DNS successes, public DNS successes, HTTPS successes.
repair_dns_snapshot() {
  local dir status
  # Use the diagnosis probe itself: both domains, system resolver, direct
  # HTTPS, and (only on matched failures) two public resolvers + pinned HTTPS.
  if ! declare -F quality_dns_probe >/dev/null; then
    printf '0 0 0 unavailable no no\n'; return 1
  fi
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/netdoc-retest.XXXXXX") || return 1
  (fact() { :; }; finding() { :; }; quality_dns_probe "$dir") >/dev/null 2>&1
  if [ ! -s "$dir/dns.rows" ] || [ ! -s "$dir/dns.parsed" ]; then
    rm -rf "$dir"; printf '0 0 0 unavailable no no\n'; return 1
  fi
  awk -F'\t' '
    $2=="yes" {dig++}
    $3=="yes" {s++}
    $4==0 {h++}
    $5=="yes" && $6=="yes" && $7=="yes" {p++}
    END {printf "%d %d %d ",s,p,h}' "$dir/dns.rows"
  status=$(awk -F'\t' '$1=="dns_status"{print $2}' "$dir/dns.parsed")
  printf '%s %s %s\n' "${status:-unavailable}" \
    "$(awk -F'\t' '$1=="dns_cache_candidate"{print $2}' "$dir/dns.parsed")" \
    "$(awk -F'\t' '$1=="dns_repair_candidate"{print $2}' "$dir/dns.parsed")"
  rm -rf "$dir"
}

repair_flush_cache() {
  repair_authorize_sudo || return 1
  REPAIR_CACHE_ATTEMPTED=1
  if run_bounded 10 sudo -n dscacheutil -flushcache && run_bounded 10 sudo -n killall -HUP mDNSResponder; then
    fact repair_cache performed
    info "DNSキャッシュを消去しました。改善は再テストで確認します"
  else
    fact repair_cache failed
    warn "DNSキャッシュ消去の一部または全部が失敗しました"
    return 1
  fi
}

repair_dhcp_interface_candidate() {
  local interface="${1:-}" service config ip
  [ -n "$interface" ] || return 1
  service=$(repair_service_for_interface "$interface")
  [ -n "$service" ] || return 1
  config=$(LC_ALL=C networksetup -getinfo "$service" 2>/dev/null) || return 1
  printf '%s\n' "$config" | grep -q '^DHCP Configuration$' || return 1
  ip=$(ipconfig getifaddr "$interface" 2>/dev/null)
  case "$ip" in ''|169.254.*|0.0.0.0) ;; *) return 1 ;; esac
  REPAIR_DHCP_IF="$interface"
  REPAIR_DHCP_SERVICE="$service"
}

repair_dhcp_candidate() {
  local interface state selected_if="" selected_service="" count=0 current_route
  REPAIR_DHCP_IF=""; REPAIR_DHCP_SERVICE=""
  if [ -n "${DEFIF:-}" ]; then
    repair_dhcp_interface_candidate "$DEFIF"
    return $?
  fi
  # Missing IPv4 routes are expected when DHCP fails. Consider only hardware
  # interfaces with a live link; keep DEFIF empty because it denotes a route.
  current_route=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  [ -z "$current_route" ] || return 1
  while IFS= read -r interface; do
    [ -n "$interface" ] || continue
    state=$(ifconfig "$interface" 2>/dev/null) || continue
    printf '%s\n' "$state" | grep -qE '^[[:space:]]*status: active[[:space:]]*$' || continue
    if repair_dhcp_interface_candidate "$interface"; then
      selected_if="$REPAIR_DHCP_IF"; selected_service="$REPAIR_DHCP_SERVICE"
      count=$((count+1))
    fi
  done <<EOF_INTERFACES
$(LC_ALL=C networksetup -listallhardwareports 2>/dev/null | awk '/^Device: / && !seen[$2]++{print $2}')
EOF_INTERFACES
  REPAIR_DHCP_IF=""; REPAIR_DHCP_SERVICE=""
  [ "$count" = 1 ] || return 1
  REPAIR_DHCP_IF="$selected_if"; REPAIR_DHCP_SERVICE="$selected_service"
}

section_repair() {
  local cache dns candidates=0 old_service old_if before_s before_p before_h before_status fresh_cache fresh_dns fresh_snapshot
  step "5. 根拠のある修復"
  cache=$(getf dns_cache_candidate); dns=$(getf dns_repair_candidate)
  REPAIR_BEFORE=""; REPAIR_DNS_ACTIVE=""; REPAIR_CACHE_ATTEMPTED=0; REPAIR_DHCP_ATTEMPTED=0; REPAIR_DNS_ATTEMPTED=0; REPAIR_DNS_PENDING_VALID=0
  if [ "$cache" = yes ]; then
    candidates=$((candidates+1)); info "候補: DNSキャッシュ消去（通常DNSとシステムの応答に不一致）"
  fi
  if [ "$dns" = yes ]; then
    candidates=$((candidates+1)); info "候補: 現在のサービスのDNSを1.1.1.1 / 8.8.8.8へ一時変更（複数の名前解決失敗を確認）"
    note "保存・再検証し、改善しない場合は復元します。社内・VPN専用名への影響があり、選択した場合だけ実行します"
  fi
  if repair_dhcp_candidate; then
    candidates=$((candidates+1)); info "候補: $REPAIR_DHCP_SERVICE のDHCPを再取得（DHCP設定かつIPv4未取得/自己割当）"
  fi
  [ "${MODE:-check}" = plan ] && { info "--plan: 変更はしていません"; return 0; }
  case "${MODE:-check}" in auto|interactive|fix|full) ;; *) return 0 ;; esac
  if [ "$candidates" = 0 ]; then
    fact repair_outcome no_evidence
    info "このMacの設定を変える根拠はありません"
    note "遅延・損失・速度低下が続く場合は上流側確認必要: 有線との比較、ルーターの混雑制御、契約回線・プロバイダーを確認してください"
    return 0
  fi
  if [ "$cache" = yes ]; then
    if [ "$MODE" = auto ] || ask "DNSキャッシュを消去しますか（管理者権限が必要）" N; then
      REPAIR_BEFORE=$(repair_dns_snapshot)
      read -r before_s before_p before_h before_status fresh_cache fresh_dns <<<"$REPAIR_BEFORE"
      if [ "$fresh_cache" = yes ]; then
        repair_flush_cache || true
      else info "再確認でDNS症状が消えたため、キャッシュ消去はスキップしました"; fi
    fi
  fi
  if [ "$dns" = yes ] && [ "$MODE" != auto ]; then
    if ask "バックアップを保存してDNSを一時変更し、改善しなければ戻しますか" N; then
      fresh_snapshot=$(repair_dns_snapshot)
      [ -n "$REPAIR_BEFORE" ] || REPAIR_BEFORE="$fresh_snapshot"
      read -r before_s before_p before_h before_status fresh_cache fresh_dns <<<"$fresh_snapshot"
      if [ "$fresh_dns" = yes ] && [ "$before_s" = 0 ] && [ "$before_p" = 2 ]; then
        if repair_authorize_sudo && repair_save_dns; then
          old_service="$REPAIR_SERVICE"; old_if="$REPAIR_IF"
          if repair_backup_valid "$REPAIR_DNS_ACTIVE" && [ "$REPAIR_SERVICE" = "$old_service" ] && [ "$REPAIR_IF" = "$old_if" ]; then
            REPAIR_DNS_ATTEMPTED=1
            if repair_set_dns "$REPAIR_SERVICE" "$(cat "$REPAIR_DNS_ACTIVE/dns.applied")"; then
              REPAIR_DNS_PENDING_VALID=1
              fact repair_dns performed
              info "DNSを一時変更しました。複数宛先の再テストを行います"
            else
              warn "DNS変更を確認できません。元の設定への復元を試みます"
              if repair_restore_backup "$REPAIR_DNS_ACTIVE"; then
                fact repair_dns rolled_back; REPAIR_DNS_ACTIVE=""
              else
                fact repair_dns rollback_failed
                ng "元のDNSへの復元を確認できません。バックアップ: $REPAIR_DNS_ACTIVE"
              fi
            fi
          else warn "変更前にネットワークが変わりました。DNS変更を中止しました"; REPAIR_DNS_ACTIVE=""; fi
        fi
      else info "再確認で複数DNS失敗を再現できず、DNS変更はスキップしました"; fi
    fi
  elif [ "$dns" = yes ]; then
    info "DNSの固定は選択が必要です。netdoc --fix で実行できます"
  fi
  if [ "$MODE" != auto ] && repair_dhcp_candidate; then
    old_service="$REPAIR_DHCP_SERVICE"; old_if="$REPAIR_DHCP_IF"
    if ask "$REPAIR_DHCP_SERVICE のDHCPリースを再取得しますか（一時的に通信が途切れます）" N; then
      if repair_dhcp_candidate && [ "$old_service" = "$REPAIR_DHCP_SERVICE" ] && [ "$old_if" = "$REPAIR_DHCP_IF" ] && repair_authorize_sudo; then
        REPAIR_DHCP_ATTEMPTED=1
        if run_bounded 20 sudo -n ipconfig set "$REPAIR_DHCP_IF" DHCP; then
          fact repair_dhcp performed; info "DHCP取得を要求しました。アドレス取得は再テストで確認します"
        else fact repair_dhcp failed; warn "DHCP再取得要求が失敗しました"; fi
      fi
    fi
  fi
  return 0
}

section_retest() {
  local result s p h status fresh_cache fresh_dns bs bp bh before_status before_cache before_dns ip verified=0 failed=0
  step "6. 修復後の再テスト"
  if [ "$REPAIR_CACHE_ATTEMPTED" = 0 ] && [ "$REPAIR_DNS_ATTEMPTED" = 0 ] && [ "$REPAIR_DHCP_ATTEMPTED" = 0 ]; then
    info "修復は実行されていません。診断結果を確認してください"; return 1
  fi
  result=$(repair_dns_snapshot)
  read -r s p h status fresh_cache fresh_dns <<<"$result"
  fact retest_dns_system "$s/2"; fact retest_dns_public "$p/2"; fact retest_https "$h/2"
  info "再測定: システムDNS $s/2、公開DNS $p/2、HTTPS $h/2"
  if [ -n "$REPAIR_BEFORE" ]; then
    read -r bs bp bh before_status before_cache before_dns <<<"$REPAIR_BEFORE"
    if [ "$s" = 2 ] && [ "$h" = 2 ] && { [ "$s" -gt "$bs" ] || [ "$h" -gt "$bh" ]; }; then verified=1; fi
    # Public DNS is intentionally not queried after the normal resolver recovers.
    [ "$status" = unavailable ] && verified=0
  fi
  if [ -n "$REPAIR_DNS_ACTIVE" ]; then
    if [ "$verified" = 1 ] && [ "$REPAIR_DNS_PENDING_VALID" = 1 ] && repair_backup_valid "$REPAIR_DNS_ACTIVE"; then
      fact repair_dns verified
      ok "複数宛先でDNS症状の改善を確認しました。復元: netdoc --restore $(basename "$REPAIR_DNS_ACTIVE")"
      REPAIR_DNS_ACTIVE=""
    else
      warn "DNS症状の改善を確認できません。設定を復元します"
      if repair_restore_backup "$REPAIR_DNS_ACTIVE"; then
        fact repair_dns rolled_back; REPAIR_DNS_ACTIVE=""
      else
        fact repair_dns rollback_failed
        ng "復元を確認できません。バックアップを保持しています: $REPAIR_DNS_ACTIVE"
      fi
      failed=1
    fi
  fi
  if [ "$REPAIR_CACHE_ATTEMPTED" = 1 ]; then
    if [ "$verified" = 1 ]; then fact repair_cache verified; ok "DNS症状の改善を確認しました";
    else fact repair_cache unverified; warn "DNSキャッシュ消去による改善は確認できません"; failed=1; fi
  fi
  if [ "$REPAIR_DHCP_ATTEMPTED" = 1 ]; then
    ip=$(ipconfig getifaddr "$REPAIR_DHCP_IF" 2>/dev/null)
    case "$ip" in ''|169.254.*|0.0.0.0) failed=1 ;; *)
      if [ "$(repair_service_for_interface "$REPAIR_DHCP_IF")" = "$REPAIR_DHCP_SERVICE" ] && [ "$s" = 2 ] && [ "$h" = 2 ]; then
        ok "IPv4取得と複数宛先への疎通を確認しました: $ip"; fact repair_dhcp verified; verified=1
      else failed=1; fi ;;
    esac
  fi
  note "DNS・疎通の改善は回線速度全体の復旧を意味しません。速度・負荷時遅延は netdoc --speed で比較してください"
  if [ "$failed" = 0 ] && [ "$verified" = 1 ]; then fact repair_outcome verified; return 0; fi
  fact repair_outcome unresolved
  warn "症状が残るか、改善を検証できません。上流側確認必要です"
  return 1
}

repair_cleanup() {
  # The EXIT trap is an extra guard for interruption between mutation/retest.
  if [ -n "${REPAIR_DNS_ACTIVE:-}" ]; then
    warn "未検証のDNS変更を復元します"
    # Cleanup must never wait for credentials, even after an interrupted prompt.
    local MODE=auto
    repair_restore_backup "$REPAIR_DNS_ACTIVE" || true
    REPAIR_DNS_ACTIVE=""
  fi
}

# PPID changes when a parent exits; it is ancestry, not process identity.
repair_process_identity() {
  LC_ALL=C ps -p "$1" -o uid= -o lstart= -o comm= 2>/dev/null | sed 's/^ *//'
}
repair_process_resume() {
  [ "$(repair_process_identity "$1")" = "$2" ] || return 1
  kill -CONT "$1" 2>/dev/null
}

# Explicit --pause selection only; never called by automatic repair.
# Subshell-owned traps preserve the caller's trap and a detached timer also
# resumes after an uncatchable SIGKILL of the controlling process.
pause_process() (
  # Globals are confined to this subshell and remain available in EXIT traps.
  # Bash 3.2 destroys function-local variables before a subshell EXIT trap.
  pid="${1:-}"; seconds="${2:-60}"; timer=""; stopped=0; pause_dir=""
  ident=""; uid=""; rest=""; command=""; state=""; ancestor=""
  case "$pid:$seconds" in *[!0-9:]*|:*|*:) warn "PIDと秒数は整数で指定してください"; return 2 ;; esac
  [ "$pid" -gt 1 ] && [ "$seconds" -ge 1 ] && [ "$seconds" -le 300 ] || {
    warn "停止時間は1〜300秒、PIDは2以上で指定してください"; return 2;
  }
  ident=$(repair_process_identity "$pid")
  [ -n "$ident" ] || { warn "対象プロセスがありません"; return 1; }
  read -r uid rest <<<"$ident"
  [ "$uid" = "$(id -u)" ] && [ "$uid" != 0 ] || { warn "自分が所有する通常プロセスだけ一時停止できます"; return 1; }
  ancestor="$$"
  while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] 2>/dev/null; do
    [ "$pid" != "$ancestor" ] || { warn "netdoc自身や親プロセスは停止できません"; return 1; }
    ancestor=$(ps -p "$ancestor" -o ppid= 2>/dev/null | tr -d ' ')
  done
  command=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null)
  case "$command" in
    /System/*|/usr/sbin/*|/usr/libexec/*|/sbin/*|*WireGuard*|*wireguard*|*ZeroTier*|*Tailscale*|*tailscale*|*VPN*|*vpn*|*network*|*Network*|*mDNSResponder*|*configd*|*wifid*|*nesessionmanager*|*neagent*|*launchd*|*WindowServer*|*loginwindow*|*Codex*|*codex*|*Terminal*|*iTerm*)
      warn "システム・ネットワーク・実行環境のプロセスは停止できません"; return 1 ;;
  esac
  case "${command##*/}" in bash|sh|zsh|fish|csh|tcsh|sudo|su|ssh|sshd|login|tmux|screen|netdoc)
    warn "シェル・接続・制御プロセスは停止できません"; return 1 ;;
  esac
  state=$(ps -p "$pid" -o state= 2>/dev/null)
  case "$state" in *T*) warn "対象はすでに停止状態です。変更しません"; return 1 ;; esac
  [ "$(repair_process_identity "$pid")" = "$ident" ] || { warn "プロセスが変わりました。中止します"; return 1; }
  pause_cleanup() {
    if [ "$stopped" = 1 ]; then
      if repair_process_resume "$pid" "$ident"; then info "PID $pid を再開しました";
      else warn "PID $pid が終了/交代したためシグナルを送っていません"; fi
      stopped=0
    fi
    if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; timer=""; fi
    [ -z "$pause_dir" ] || rm -rf "$pause_dir"
  }
  trap 'pause_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  pause_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/netdoc-pause.XXXXXX") || return 1
  (
    child=""; polls=0
    watchdog_cleanup() {
      if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
      repair_process_resume "$pid" "$ident" || true
      rm -rf "$pause_dir"
    }
    trap 'watchdog_cleanup' EXIT
    trap 'exit 143' TERM
    trap '' HUP INT
    # Start the duration after STOP; if its controller dies in that tiny gap,
    # still CONT after at most ten seconds. Never resume before STOP then exit.
    while [ ! -f "$pause_dir/stopped" ] && [ "$polls" -lt 10 ]; do
      sleep 1 & child=$!; wait "$child" || true; child=""; polls=$((polls+1))
    done
    if [ -f "$pause_dir/stopped" ]; then
      sleep "$seconds" & child=$!; wait "$child" || true; child=""
    fi
  ) </dev/null >/dev/null 2>&1 &
  timer=$!
  stopped=1
  if ! kill -STOP "$pid" 2>/dev/null; then warn "一時停止できませんでした"; return 1; fi
  : >"$pause_dir/stopped"
  info "PID $pid ($command) を $seconds 秒間停止しました。時間終了またはCtrl-Cで再開します"
  wait "$timer" 2>/dev/null || true
  timer=""
  pause_cleanup
)

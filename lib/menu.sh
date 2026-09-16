#!/usr/bin/env bash
# Hands-on repair menu (v0.3 style): try the usual fixes top-down without
# waiting for diagnostic evidence. Only in fix/interactive mode, only on a TTY,
# and only when the user says yes to each item. DNS changes still go through
# the backup/restore machinery in repair.sh.
# The caller provides fact/getf, output helpers, ask, run_bounded, and repair.sh.

MENU_ATTEMPTED=0
MENU_DNS_PINNED=0
MENU_LOG=""

menu_did() { MENU_ATTEMPTED=1; MENU_LOG="${MENU_LOG:+$MENU_LOG, }$1"; fact "menu_$2" performed; }

# Path MTU by DF ping; prints nothing when the probe is inconclusive.
menu_probe_mtu() {
  local host="$1" lo=1200 hi=1472 mid best=""
  run_bounded 4 ping -c1 -W1000 -D -s "$hi" "$host" >/dev/null 2>&1 && { echo $((hi+28)); return 0; }
  run_bounded 4 ping -c1 -W1000 -D -s "$lo" "$host" >/dev/null 2>&1 || return 1
  while [ $((hi-lo)) -gt 8 ]; do
    mid=$(((lo+hi)/2))
    if run_bounded 4 ping -c1 -W1000 -D -s "$mid" "$host" >/dev/null 2>&1; then lo=$mid; best=$mid; else hi=$mid; fi
  done
  [ -n "$best" ] && echo $((best+28))
}

# Pin DNS with a backup; kept only if the retest still resolves and connects.
menu_pin_dns() {
  local old_service old_if
  repair_authorize_sudo && repair_save_dns || return 1
  old_service="$REPAIR_SERVICE"; old_if="$REPAIR_IF"
  if ! repair_backup_valid "$REPAIR_DNS_ACTIVE" || [ "$REPAIR_SERVICE" != "$old_service" ] || [ "$REPAIR_IF" != "$old_if" ]; then
    warn "変更前にネットワークが変わりました。DNS変更を中止しました"; REPAIR_DNS_ACTIVE=""; return 1
  fi
  if repair_set_dns "$REPAIR_SERVICE" "$(cat "$REPAIR_DNS_ACTIVE/dns.applied")"; then
    MENU_DNS_PINNED=1; fact repair_dns performed
    ok "DNSを 1.1.1.1 / 8.8.8.8 にしました  ${DIM}戻す: netdoc --restore $(basename "$REPAIR_DNS_ACTIVE")${RST}"
    run_bounded 10 sudo -n dscacheutil -flushcache >/dev/null 2>&1 || true
    return 0
  fi
  warn "DNS変更を確認できません。元に戻します"
  if repair_restore_backup "$REPAIR_DNS_ACTIVE"; then fact repair_dns rolled_back; REPAIR_DNS_ACTIVE=""
  else fact repair_dns rollback_failed; ng "復元を確認できません。バックアップ: $REPAIR_DNS_ACTIVE"; fi
  return 1
}

section_menu() {
  local svc wifi_if newip code skew mtu_if mtu_real exit_node ts_state
  case "${MODE:-check}" in fix|interactive) ;; *) return 0 ;; esac
  step "5b. 手で試す修復 ${DIM}（上から順がおすすめ・各項目で y/n）${RST}"
  note "根拠が揃っていなくても、経験上よく効く順に並べています。戻し方は各行に書きます"
  svc=$(repair_service_for_interface "${DEFIF:-}")

  if [ "$(getf captive)" = possible ]; then
    ask "[0] captive portal をブラウザで開く" Y && {
      open "http://captive.apple.com/" 2>/dev/null
      info "ログインを済ませたら Enter"; read -r
      menu_did "captive" captive; }
  fi

  ask "[1] DNSキャッシュを消す ${DIM}(sudo)${RST}" Y && {
    if repair_authorize_sudo; then
      if run_bounded 10 sudo -n dscacheutil -flushcache && run_bounded 10 sudo -n killall -HUP mDNSResponder; then
        ok "DNSキャッシュを消しました"; menu_did "DNSキャッシュ消去" cache
      else warn "DNSキャッシュ消去に失敗しました"; fi
    fi; }

  [ -n "${DEFIF:-}" ] && ask "[2] DHCPリースを取り直す ${DIM}(sudo・数秒切れます)${RST}" Y && {
    if repair_authorize_sudo; then
      run_bounded 10 sudo -n ipconfig set "$DEFIF" BOOTP >/dev/null 2>&1; sleep 1
      run_bounded 20 sudo -n ipconfig set "$DEFIF" DHCP >/dev/null 2>&1; sleep 3
      newip=$(ipconfig getifaddr "$DEFIF" 2>/dev/null)
      case "$newip" in ''|169.254.*) warn "IP取得待ち（数秒後に netdoc --where で確認）" ;; *) ok "新しいIP: $newip" ;; esac
      menu_did "DHCP再取得" dhcp
    fi; }

  [ -n "$svc" ] && ask "[3] DNSを 1.1.1.1 / 8.8.8.8 に固定する ${DIM}（バックアップして戻せます）${RST}" N && {
    menu_pin_dns && menu_did "DNS固定" dns; }

  if [ -n "${TS_BIN:-}" ]; then
    ts_state=$(getf tailscale_state); exit_node=$(getf exit_node)
    if [ "$ts_state" = Running ]; then
      [ -n "$exit_node" ] && ask "[4] Tailscale の exit node を外す" Y && {
        "$TS_BIN" set --exit-node= && { ok "exit node を解除"; menu_did "exit node解除" exit_node; }; }
      ask "[5] Tailscale を切る ${DIM}（VPNを嫌うゲスト網で。戻す: tailscale up）${RST}" N && {
        "$TS_BIN" down && { ok "Tailscale down"; menu_did "Tailscale down" tailscale_down; }; }
    else
      ask "[5] Tailscale を繋ぐ" N && { "$TS_BIN" up && { ok "Tailscale up"; menu_did "Tailscale up" tailscale_up; }; }
    fi
  fi

  [ -n "$(getf proxy_env)" ] && ask "[6] プロキシ環境変数を外して疎通を試す ${DIM}（設定は変えません）${RST}" Y && {
    code=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://api.anthropic.com/ 2>/dev/null)
    if printf '%s' "$code" | grep -qE '^[2-4]'; then
      ok "プロキシを外したら通った (HTTP $code)"
      note "原因はプロキシ設定です。シェル設定の proxy 変数を消してください"
    else info "プロキシを外しても変わらず (HTTP ${code:-なし})"; fi
    fact menu_proxy_test "${code:-none}"; }

  mtu_if=$(getf mtu_if)
  if [ -n "${DEFIF:-}" ] && [ "${mtu_if:-unknown}" != unknown ]; then
    ask "[7] 経路MTUを実測して、低ければ合わせる ${DIM}(sudo)${RST}" N && {
      mtu_real=$(menu_probe_mtu 1.1.1.1)
      [ -z "$mtu_real" ] && [ -n "${DEFGW:-}" ] && mtu_real=$(menu_probe_mtu "$DEFGW")
      fact mtu_real "${mtu_real:-unknown}"
      if [ -z "$mtu_real" ]; then info "MTU実測は不成立（DFピングが通らず）。変更しません"
      elif [ "$mtu_real" -lt "$mtu_if" ] 2>/dev/null; then
        if repair_authorize_sudo && run_bounded 10 sudo -n ifconfig "$DEFIF" mtu "$mtu_real"; then
          ok "MTU=$mtu_real  ${DIM}戻す: sudo ifconfig $DEFIF mtu $mtu_if${RST}"; menu_did "MTU $mtu_if→$mtu_real" mtu
        else warn "MTU変更に失敗しました"; fi
      else info "実測MTU $mtu_real は設定 $mtu_if 以上。変更不要"; fi; }
  fi

  skew=$(getf clock_skew)
  [ -n "$skew" ] && [ "$skew" -gt 120 ] 2>/dev/null && ask "[8] 時計を合わせる ${DIM}(sudo)${RST}" Y && {
    if repair_authorize_sudo && run_bounded 20 sudo -n sntp -sS time.apple.com >/dev/null 2>&1; then
      ok "時刻を同期しました"; menu_did "時刻同期" clock
    else warn "時刻同期に失敗しました"; fi; }

  [ -n "$svc" ] && ask "[9] IPv6 を切る ${DIM}（IPv6が壊れている網で効く。戻す: networksetup -setv6automatic '$svc'）${RST}" N && {
    if repair_authorize_sudo && run_bounded 10 sudo -n networksetup -setv6off "$svc"; then
      ok "IPv6 off ($svc)"; menu_did "IPv6 off" ipv6_off
    else warn "IPv6の無効化に失敗しました"; fi; }

  wifi_if=$(LC_ALL=C networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
  [ -n "$wifi_if" ] && ask "[10] Wi-Fi を切って入れ直す ${DIM}（10秒ほど切れます）${RST}" N && {
    networksetup -setairportpower "$wifi_if" off; sleep 3
    networksetup -setairportpower "$wifi_if" on;  sleep 5
    ok "Wi-Fi 再起動（IP: $(ipconfig getifaddr "$wifi_if" 2>/dev/null || echo 取得中)）"; menu_did "Wi-Fi再起動" wifi; }

  [ "$MENU_ATTEMPTED" = 1 ] || info "手動修復は選択されませんでした"
  return 0
}

# After menu repairs: does it work now? Keep a pinned DNS only if names still
# resolve and HTTPS connects; otherwise roll it back. No causality claims.
section_menu_retest() {
  local s p h status c1 c2 code alive=0
  [ "$MENU_ATTEMPTED" = 1 ] || return 1
  step "6. 修復後の再テスト ${DIM}（実行: ${MENU_LOG}）${RST}"
  sleep 2
  read -r s p h status c1 c2 <<<"$(repair_dns_snapshot)"
  fact retest_dns_system "$s/2"; fact retest_https "$h/2"
  info "名前解決 $s/2、HTTPS $h/2"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://api.anthropic.com/ 2>/dev/null)
  if printf '%s' "$code" | grep -qE '^[2-4]'; then ok "api.anthropic.com  (HTTP $code)"; alive=1
  else ng "api.anthropic.com  まだ届かない"; fi
  if [ "$MENU_DNS_PINNED" = 1 ] && [ -n "$REPAIR_DNS_ACTIVE" ]; then
    if [ "$s" = 2 ] && [ "$h" = 2 ]; then
      fact repair_dns kept
      ok "固定DNSで名前解決とHTTPSが通っています。このまま維持  ${DIM}戻す: netdoc --restore $(basename "$REPAIR_DNS_ACTIVE")${RST}"
      REPAIR_DNS_ACTIVE=""
    else
      warn "固定DNSでも名前解決が通らないため、元の設定に戻します"
      if repair_restore_backup "$REPAIR_DNS_ACTIVE"; then fact repair_dns rolled_back; REPAIR_DNS_ACTIVE=""
      else fact repair_dns rollback_failed; ng "復元を確認できません。バックアップ: $REPAIR_DNS_ACTIVE"; fi
    fi
  fi
  hr
  if [ "$alive" = 1 ] && [ "$h" = 2 ]; then
    fact repair_outcome menu_alive
    printf "${GRN}${BLD}✓ 通っています。${RST} ${DIM}体感が変わらなければ回線側（AP・ルーター・ISP）が残りの候補です${RST}\n"
    return 0
  fi
  fact repair_outcome unresolved
  printf "${RED}${BLD}✗ まだ繋がりません。${RST}\n\n"
  info "次に試すこと（効く順）:"
  info "  1. iPhone のテザリングに切り替える — 網が原因かを2分で確定できる"
  info "  2. netdoc --llm で、どの段（DNS/TCP/TLS/HTTP）で死んでいるかを見る"
  info "  3. TLS が「傍受?」なら企業の中間装置。その網では原理的に通らない"
  info "  4. env | grep -i proxy を確認"
  return 1
}

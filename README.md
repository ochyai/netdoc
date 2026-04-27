# netdoc 🩺

ゲストネット切替後に **Claude Code / API / SSH が動かなくなる** あの瞬間を 1 コマンドで解決する macOS 用ネットワークドクター。

DNSキャッシュ・DHCPリース・captive portal・Tailscale・Wi-Fi・MTU を順に診断して、対話メニューで安全に修復します。

```
🩺 netdoc  — ネットワーク診断＆修復

▶ 1. 現在のネットワーク状況
  ✓ デフォルトIF : en0  (gw 172.20.10.1)
  ✓ IPv4         : 172.20.10.2
  ✓ Wi-Fi SSID   : DMG_GUEST
  ℹ DNS          : 1.1.1.1,8.8.8.8

▶ 2. 接続テスト
  ✓ DNS解決      : api.anthropic.com
  ✗ HTTPS api.anthropic.com : 到達不可 (これがClaude Codeの不調原因)
  ! Captive portal の可能性あり — ブラウザでログインが必要かも
```

## インストール

```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/ochyai/netdoc/main/netdoc -o ~/bin/netdoc
chmod +x ~/bin/netdoc
```

`~/bin` が `PATH` に入っていれば、どこからでも `netdoc` で起動できます。

または `git clone`：

```bash
git clone https://github.com/ochyai/netdoc.git ~/netdoc
ln -sf ~/netdoc/netdoc ~/bin/netdoc
```

## 使い方

```bash
netdoc           # 対話モード（推奨）— 一個ずつ確認しながら修復
netdoc --auto    # 安全な修復を全部自動で実行
netdoc --check   # 診断のみ。何もいじらない
netdoc --help    # ヘルプ
```

## 何を見ているか

| 区分 | チェック内容 |
|---|---|
| 状況 | デフォルトIF・GW・IPv4・Wi-Fi SSID・DNS・Tailscale state |
| DNS  | `api.anthropic.com` / `github.com` / `www.google.com` の解決 |
| L3   | `ping 1.1.1.1` |
| L7   | `https://api.anthropic.com/` の HTTP コード |
| ゲスト | `captive.apple.com` の応答で captive portal を検出 |

## 何を修復できるか

`[y/N]` で個別に承認できます。`sudo` は本当に必要な時だけ要求。

| # | 操作 | 中身 |
|---|---|---|
| 0 | Captive portal を開く | `open http://captive.apple.com/` |
| 1 | DNSキャッシュ clear | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` |
| 2 | DHCP リース更新 | `ipconfig set $IF BOOTP` → `DHCP` |
| 3 | Tailscale 切断/再接続 | `tailscale down` / `up`（VPNを嫌うネット用） |
| 4 | Wi-Fi 電源 OFF→ON | `networksetup -setairportpower` |
| 5 | MTU を 1400 に下げる | `ifconfig $IF mtu 1400`（戻し方も表示） |

修復後に `api.anthropic.com` への HTTPS を再テストして合否判定。失敗時はテザリング切替・MTU 追加削減・proxy 環境変数チェックなどフォールバックを案内します。

## 想定シーン

- 企業ゲスト Wi-Fi（DMG MORI、ホテル、カンファレンス会場）に繋いだ後 Claude Code が固まる
- 前のネットの古い DNS / IP を引きずって名前解決が壊れる
- Tailscale が DERP relay 経由になって細い
- captive portal を踏み忘れている

## 要件

- macOS（`networksetup` / `ipconfig` / `scutil` / `dig` / `route` / `curl` を使用）
- bash 3.2+（macOS 標準）
- Tailscale 連携は `/Applications/Tailscale.app` がある時だけ有効化

## ライセンス

MIT

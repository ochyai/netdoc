# netdoc 🩺

**「LLM に繋がらない」を、どこで死んでいるかまで落として直す** macOS 用ネットワークドクター。

DNS → TCP → TLS → HTTP を**段階に分けて**測るので、原因が名前解決なのか、ポート塞ぎなのか、
TLS 傍受なのか、そもそも認証なのかが一目で分かります。Anthropic API だけでなく、
**手元や tailnet 上の自分の LLM サーバ**（ollama / LM Studio / llama.cpp / OpenAI互換）も
まとめて面倒を見ます。

```
▶ 3. LLM に届くか （DNS → TCP → TLS → HTTP のどこで死ぬか）
  ✓ Anthropic API         DNS 160.79.104.10  TCP 開  TLS OK    HTTP 404 41ms   404(APIルートでは正常)
  ✓ ollama (ローカル)     DNS 不要           TCP 開  TLS -     HTTP 200 16ms   モデル28本
  ✓ ollama @studio        DNS 不要           TCP 開  TLS -     HTTP 200 105ms  モデル19本
  ! 社内API               DNS 10.0.0.9       TCP 開  TLS 傍受? HTTP 200 88ms   証明書の発行者=Corp Proxy CA

▶ 4. 所見
  ● TLSが傍受されている (api.example.com)
    → 企業/ゲスト網の中間装置。社内CAを信頼するか、テザリングに切替
```

## インストール

```bash
git clone https://github.com/ochyai/netdoc.git ~/netdoc
mkdir -p ~/bin && ln -sf ~/netdoc/netdoc ~/bin/netdoc
```

または1ファイルだけ:

```bash
curl -fsSL https://raw.githubusercontent.com/ochyai/netdoc/main/netdoc -o ~/bin/netdoc
chmod +x ~/bin/netdoc
```

bash 3.2（macOS標準）で動きます。外部依存なし。`jq` があれば `--json` が読みやすくなります。

## 使い方

```bash
netdoc                 対話モード（診断 → 修復メニュー）
netdoc --check         診断のみ。何もいじらない
netdoc --llm           LLM への疎通だけを段階で調べる   ← いちばん使う
netdoc --stream        LLM の初トークンまでの時間を実測   ← 「固まる」の正体はだいたいこれ
netdoc --auto          安全な修復を自動で実行
netdoc --speed         回線速度・遅延・ジッタ・MTU だけ測る
netdoc --full          速度測定まで含めて全部
netdoc --where         いまどこに居るか（IP・ISP・Wi-Fi・経路）だけ
netdoc --history       この網での過去の記録と比べる
netdoc --discover      tailnet と手元から LLM サーバを探して登録する
netdoc --targets       調べに行く先の一覧を見る
netdoc --json          全結果を JSON で出す（機械可読）
netdoc --report [PATH] Markdown レポートを書き出す（人に見せる用）
netdoc --watch [SEC]   定期監視。状態が変わったときだけ表示
netdoc --restore-dns   固定したDNSを元に戻す
```

## 何を見ているか

### 1. いまどこに居るか

デフォルト経路とゲートウェイ／生きている全インターフェースとIP／Wi-Fi の SSID・
PHYモード・チャネル・信号対雑音比・送信レート／DNS サーバ／**グローバルIPと出口**／
Tailscale の状態（**直結か DERP 中継か**、exit node）／プロキシ環境変数とシステムプロキシ／
**時計のずれ**（数分ずれると TLS が落ちます）。

### 2. 回線の質

ゲートウェイとインターネットへの**遅延・ジッタ・パケットロス**／DNS 解決にかかる時間／
**MTU の実測**（1400 を決め打ちせず、通る最大パケットを二分探索）／
**下り・上りのスループット**（Cloudflare の速度測定エンドポイント）／tailnet 越しの遅延。

### 3. LLM に届くか

`~/.netdoc/targets.conf` に書いた宛先ごとに、次を**段階に分けて**測ります。

| 段 | 見ているもの | ここで落ちたら |
|---|---|---|
| DNS | 名前解決。**公開DNSの答えと突き合わせる** | 解決不可＝DNS設定／不一致＝DNSの書き換え |
| TCP | ポートが開いているか | ファイアウォール・ポート封鎖・相手が落ちている |
| TLS | ハンドシェイクと**証明書の発行者** | 発行者が公開CAでなければ**企業の中間装置が傍受** |
| HTTP | ステータスと応答時間 | 407＝プロキシ認証／000＝握り潰し |

種別が `ollama` なら `/api/tags` を読んで**モデル数まで**、`openai` なら `/healthz` か
`/v1/models` を見て、サーバが本当に応答しているかまで確認します。

captive portal の有無、`ANTHROPIC_API_KEY` が環境変数に入っていないか
（**古い鍵が残っていると 401 になり、回線のせいに見える**）も併せて見ます。

### 4. 所見

**まず1つだけ名指しします。** 見つけたものを全部並べても、どれが原因なのかは分かりません。
検出内容に優先度（10=通信が成立していない／20=成立するが壊れている／30=相手側や認証／
40=遅い・細い）を持たせ、いちばん上のものを「いちばんありそうな原因」として立てます。
優先度30より軽いものしか無ければ、**原因だと断定せず**「決定的な問題は見つかりませんでした」
と言います。

```
▶ 4. 所見
  いちばんありそうな原因
    ollama @gpubox はモデルを読み込んでいない
    → 初回の応答に数秒〜数十秒かかります。常駐させるなら OLLAMA_KEEP_ALIVE=-1

  ほかに見えているもの
  ● Tailscaleが中継経由
    → UDP 41641 が塞がれている可能性。可能なら別網へ
```

## 「繋がらない」の多くは、繋がっている

体感として一番多い失敗は、通信が切れていることではなく
**最初のトークンが返ってくるまでが長い**ことです。netdoc はそこを実測します。

```bash
netdoc --stream
```

```
▶ ストリーミングの初動 （実際に生成させます）
  ✓ ollama (ローカル)  : 初トークンまで 0.04秒   my-model:8b
  ! ollama @studio     : 初トークンまで 11.85秒  starcoder2:15b
    冷えた状態からの読み込み。常駐させるなら OLLAMA_KEEP_ALIVE=-1
  ! ollama @gpubox    : 初トークンまで 16.21秒  gemma3:4b
```

`--stream` は実際にモデルを起こすので明示指定のときだけ動きます。通常の診断では
`/api/ps` を読むだけ（副作用なし）で「未ロード＝初回は待たされる」ことを言い当てます。

また HTTP の時間表示は**全体時間ではなく最初のバイトまで（TTFB）**です。LLM で体感を
決めるのはそちらだからです。

## 前回との比較

同じ網に繋いだ回数と、前回からの変化を覚えています。「今日だけ遅い」のか
「この網はいつもこう」なのかが分かります。

```
  ℹ この網は 4回目 （前回 2026-09-04 15:31:07）
  ✓ DNS解決     : 380ms（前回 12ms から悪化）
```

網の指紋は SSID かゲートウェイの MAC。記録は `~/.netdoc/history.tsv`。

## 自分の LLM サーバを登録する

```bash
netdoc --discover
```

手元（11434 / 1234 / 8080 / 8787）と tailnet 上の全ピアを走査して、実際に応答した
ものだけを `~/.netdoc/targets.conf` に追記します。手で書いても構いません。

```
# 名前 | URL | 種別(http|ollama|openai)
Anthropic API      | https://api.anthropic.com/     | http
ollama (ローカル)   | http://127.0.0.1:11434        | ollama
ollama @studio     | http://100.x.x.x:11434        | ollama
社内API            | https://llm.example.com       | openai
```

**この設定は `~/.netdoc/` に置かれ、リポジトリには入りません。**

## 何を修復できるか

`[y/N]` で個別に承認します。`sudo` は本当に必要なときだけ要求します。

| # | 操作 | 効く場面 |
|---|---|---|
| 0 | captive portal を開く | ログインが必要な網 |
| 1 | DNSキャッシュを消す | 前の網の答えを引きずっている |
| 2 | DHCPリースを取り直す | IP がおかしい |
| 3 | **DNS を 1.1.1.1 / 8.8.8.8 に固定** | DNS の書き換え・DNS が遅い（`--restore-dns` で戻せます） |
| 4 | Tailscale の exit node を外す | exit node 経由で詰まっている |
| 5 | Tailscale を切る／繋ぐ | VPN を嫌うゲスト網 |
| 6 | **プロキシ環境変数を外して試す** | `HTTPS_PROXY` が効いている（設定は壊しません） |
| 7 | **MTU を実測値に下げる** | 大きなパケットが黙って捨てられて HTTPS が固まる |
| 8 | 時計を合わせる | ずれて TLS が落ちている |
| 9 | IPv6 を切る | IPv6 が壊れている網 |
| 10 | Wi-Fi を入れ直す | 最後の手段 |

修復後に自動で再テストし、駄目なら次に試すことを効く順に出します。

## 速さ

壊れている網ほど「調べるのに待たされる」のが困るので、既定では重い測定を省きます。

| | |
|---|---|
| `netdoc --where` | 約1秒 |
| `netdoc --check` | 約9秒（宛先は並列に叩きます） |
| `netdoc --speed` / `--full` | +15秒ほど（スループット測定を含むため） |

Wi-Fi の詳細は Wi-Fi 接続時だけ取得し、ICMP が塞がれている網では MTU 探索の宛先を
自動で切り替えます。

## 想定シーン

- 企業ゲスト Wi-Fi・ホテル・会場に繋いだ直後に Claude Code が固まる
- **社内の中間装置が TLS を割っていて、ブラウザは通るのに CLI だけ落ちる**
- 手元では動くのに、tailnet 越しの ollama にだけ繋がらない
- 「繋がらない」と思ったら実は**古い API キーによる 401** だった
- MTU が合っておらず、短い応答は返るのに長い生成だけ途中で固まる
- **IPv6 のアドレスはあるのに v6 が死んでいて、接続のたびに数秒待たされる**
- 相手の ollama がモデルを落としていて、初回だけ十数秒かかる

## ライセンス

MIT

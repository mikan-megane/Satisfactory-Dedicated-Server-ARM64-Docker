# Satisfactory 専用サーバー for ARM64 (Docker)

ARM64 マシン（Oracle Cloud Ampere、AWS Graviton、Raspberry Pi 5 など）で
Satisfactory の公式専用サーバーを Docker で動かすための構成です。

Linux 版サーバーバイナリは **x86-64 のみ** なので、
[FEX-Emu](https://github.com/FEX-Emu/FEX) でエミュレーションします。
`--privileged` も `binfmt_misc` 登録も QEMU も不要です。

> **ARM64 専用です。** イメージは実際に動かす ARM64 マシン上でビルドして
> ください。x86-64 でのクロスビルドには対応していません。

---

## クラッシュ問題について

以前のこのプロジェクトは 2024 年の FEX コミットを固定しており、クライアントが
接続したとき（コンベアベルト関連）にサーバーが落ちていました。
原因はエミュレータ側の float→整数変換のバグで、FEX-2501 で修正されています
（リリースノートに "Satisfactory's server crashing" と明記）。
Satisfactory 1.2.2 でも、後半のワールドにクライアントが参加するときの
ゲーム側クラッシュが修正されています。

このイメージは古い FEX をソースビルドせず、**公式 PPA の最新 FEX**
（執筆時点 2611.1）と現行の安定版サーバー（1.2.5）を使います。

このリポジトリの検証環境（Ubuntu 24.04 ARM64 / 4 vCPU / 23 GB RAM）では次を確認済みです。

- イメージのクリーンビルドと SteamCMD による新規インストール
- HTTPS API からの新規ワールド作成
- マップロード（エミュレーションで約 40 秒）と通常のシミュレーション
- オートセーブ、正常終了時のセーブ、再起動後のワールド復元
- 数分間のアイドル状態でクラッシュなし

テスト環境に実際のゲームクライアントがなかったため、クライアント接続そのものは
未検証ですが、以前のクラッシュ原因は FEX 側・ゲーム側の両方で修正済みです。

---

## 必要なもの

| 項目 | 最小 | 推奨 |
| --- | --- | --- |
| CPU | ARMv8.0-A / 4 vCPU | 8 vCPU（シングルコア性能が高いもの） |
| メモリ | 8 GB | 16 GB（大規模ワールド / 4人以上） |
| ディスク | 空き 8 GB | 15 GB 以上（セーブとバックアップが増えます） |
| カーネル | Linux 5.15 以上 | 各ディストリビューションの現行カーネル |
| Docker | 24 以上 + Compose v2 | 現行の Docker Engine |
| OS | Ubuntu 22.04/24.04 ARM64、Debian ARM64 | Ubuntu 24.04 ARM64 |

サーバーは強いシングルスレッド性能を要求します。エミュレーションのため
ネイティブ x86-64 の概ね 2〜4 倍の CPU 時間がかかります。
2 vCPU の無料枠 VM で大きな工場を動かすのは現実的ではありません。

---

## クイックスタート

```bash
git clone https://github.com/mikan-megane/Satisfactory-Dedicated-Server-ARM64-Docker.git
cd Satisfactory-Dedicated-Server-ARM64-Docker

cp .env.example .env
# データディレクトリの所有者と PUID/PGID を一致させる
sed -i "s/^PUID=.*/PUID=$(id -u)/; s/^PGID=.*/PGID=$(id -g)/" .env

docker compose up -d --build
docker compose logs -f
```

初回起動時に次の 2 つをダウンロードします（合計 5〜15 分程度）。

1. FEX の x86-64 rootfs（圧縮 約 500 MB / 展開後 約 1.9 GB、`./fex-data` に保存）
2. Satisfactory 専用サーバー（約 2.9 GB、`./satisfactory` に保存）

SteamCMD は自己アップデート直後の 1 回目だけ
`Failed to install app '1690800' (Missing configuration)` で失敗することがあります。
entrypoint が自動でリトライするため、このメッセージのあとに成功ログが出れば正常です。
2 回目以降は再利用し、Steam のビルド ID チェックだけ行います。
ログに次のような行が出て、`docker compose ps` が `(healthy)` になれば起動完了です。

```
LogNet: Name:GameNetDriver ... IpNetDriver listening on port 7777
```

### ポート

| ポート | プロトコル | 用途 |
| --- | --- | --- |
| 7777 | TCP | HTTPS Server API + ゲーム通信 |
| 7777 | UDP | ゲーム通信 + 軽量クエリ |
| 8888 | TCP | Reliable messaging（1.1 以降必須） |

**3 つすべて**をホストのファイアウォールと、Oracle Cloud の場合は VCN の
セキュリティリストで開放してください。Docker が直接ポートを公開するため、
`ufw` のルールは公開ポートには適用されません。

`SERVER_GAME_PORT` / `SERVER_MESSAGING_PORT` を変更した場合は、ホスト側と
コンテナ側を 1:1 で公開し、`-Port` / `-ReliablePort` も自動で渡されます
（7778/8889 で動作確認済み）。`17777:7777` のような非対称なマッピングにしないでください
（サーバーは内部ポートをクライアントに通知します）。

`SERVER_GAME_PORT` を変更するとサーバーが参照する設定ファイル
（`ServerSettings.<ポート>.sav`）も変わるため、未 claim の新規サーバーとして起動し、
自動ロードのセッションも引き継がれません。再度 claim し、セーブを一度ロードしてください。
特別な理由がなければゲームポートは 7777 のままにしてください。

---

## 最初の接続

1. Satisfactory を起動し、**Server Manager** を開く
2. `<公開IP>:7777` をサーバーとして追加
3. 管理者パスワードを設定してサーバーを claim する

初回起動時は未 claim なので、API からも claim できます。

```bash
# 1) InitialAdmin トークンを取得（未 claim のときだけ有効）
curl -sk -X POST https://YOUR_IP:7777/api/v1 \
  -H 'Content-Type: application/json' \
  -d '{"function":"PasswordlessLogin","data":{"MinimumPrivilegeLevel":"InitialAdmin"}}'

# 2) 返ってきたトークンで claim
curl -sk -X POST https://YOUR_IP:7777/api/v1 \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer PASTE_TOKEN_HERE' \
  -d '{"function":"ClaimServer","data":{"ServerName":"My Factory","AdminPassword":"change-me"}}'
```

---

## 設定

`.env.example` を `.env` にコピーして編集します（Compose が自動で読みます）。

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` | `./satisfactory`、`./config`、`./fex-data` の所有者。ホストの `id -u` / `id -g` に合わせる |
| `FEX_ARCH` | `auto` | `auto` / `armv8.0` / `armv8.2` / `armv8.4`。`auto` はビルドマシンの CPU から選択 |
| `SERVER_GAME_PORT` | `7777` | ゲーム/API ポート（TCP+UDP）。`-Port` として渡される |
| `SERVER_MESSAGING_PORT` | `8888` | Reliable messaging ポート（TCP）。`-ReliablePort` として渡される |
| `ALWAYS_UPDATE_ON_START` | `true` | 起動時に Steam のビルド ID を確認し、変わったときだけ更新 |
| `EXPERIMENTAL_BRANCH` | `false` | `experimental` ブランチをインストール |
| `EXTRA_PARAMS` | 空 | `FactoryServer.sh` への追加引数。空の場合は `-log -unattended -ini:Engine:[HTTPServer.Listeners]:DefaultBindAddress=any` |

### FEX の CPU 選択

イメージには 1 種類の FEX しか入りません。`FEX_ARCH=auto` は
**ビルド時** に `/proc/cpuinfo` を見て選択します。

| CPU | パッケージ |
| --- | --- |
| ARMv8.4+（Graviton 3/4、Neoverse V2） | `fex-emu-armv8.4` |
| ARMv8.2+（Ampere Altra、Graviton 2、Neoverse N1） | `fex-emu-armv8.2` |
| ARMv8.0/8.1（Raspberry Pi 4/5 など） | `fex-emu-armv8.0` |

ビルドするマシンと実行するマシンが違う場合は、**実行側の最も古い CPU** に
合わせて `FEX_ARCH` を明示してください。新しい命令でビルドしたイメージを
古い CPU で動かすと `Illegal instruction` で落ちます。

---

## データとバックアップ

| パス | 内容 |
| --- | --- |
| `./config/FactoryGame/Saved/SaveGames/server/` | セーブデータ（`shutdown` セーブを含む） |
| `./config/FactoryGame/Saved/SaveGames_backup/` | 自動バックアップ |
| `./config/FactoryGame/Saved/SaveGames/ServerSettings.7777.sav` | サーバー名、パスワード、API 証明書 |
| `./satisfactory/FactoryGame/Saved/Config/LinuxServer/` | `Engine.ini` などの設定 |
| `./satisfactory/FactoryGame/Saved/Logs/FactoryGame.log` | ゲームログ |
| `./fex-data/` | FEX rootfs とコードキャッシュ（削除しても再取得されます） |

`./config` と `./satisfactory/FactoryGame/Saved/Config` を定期的に
バックアップしてください。ゲーム本体は SteamCMD で再取得できます。

### 既存ワールドの移行

1. サーバーを停止
2. `.sav` を `./config/FactoryGame/Saved/SaveGames/server/` にコピー
3. サーバーを起動
4. Server Manager から一度ロードするか、自動ロードのセッション名を設定

正常停止時には `shutdown` という名前でセーブされ、再起動時にそのセーブから
再開します。`shutdown-*.sav` のバックアップは新しい 5 個だけ残します。

---

## 更新

`ALWAYS_UPDATE_ON_START=true` の場合、コンテナ再起動時に
`api.steamcmd.net` でビルド ID を確認し、変わっているときだけ SteamCMD を
実行します。

```bash
docker compose restart
docker compose logs -f
```

手動で更新する場合:

```bash
docker compose down
docker compose up -d
```

`docker compose build` が必要なのは、このリポジトリの Dockerfile や
スクリプトを変更したときだけです（ゲームの更新では不要）。

experimental ブランチを使う場合は `EXPERIMENTAL_BRANCH=true` にして再起動します。

---

## 安全な停止

`docker compose down` / `docker compose stop` は SIGTERM を送り、entrypoint が

1. ローカル HTTPS API の `SaveGame` で `shutdown` セーブを作成
2. `Shutdown` を呼び、最大 60 秒待つ
3. API が応答しない場合は SIGTERM にフォールバック

という順で停止します。`stop_grace_period` は 120 秒です。
`docker kill` はセーブされないため使わないでください。

この API 呼び出しはコンテナ内のループバック（127.0.0.1）だけで認証不要に
しています（`FG.DedicatedServer.AllowInsecureLocalAccess=1`）。
コンテナ外からの API アクセスには従来どおり認証が必要です。

Unreal のコンソールに入る場合:

```bash
docker attach satisfactory-server
# Ctrl-P Ctrl-Q でデタッチ
```

---

## パフォーマンスの目安

- **コア数よりシングルコア性能**が重要です。エミュレーションでは特にそうです。
- 小規模な工場と 1〜2 人なら 4 vCPU / 8 GB で足ります。
  ベルト・列車・パイプが多い終盤のワールドや 4 人以上なら 8 vCPU / 16 GB を推奨します。
- 検証時の新規ワールドはアイドルでも 4 vCPU のうち約 1 コアを使い、
  tick はフルの 30 を維持しました（4 vCPU Ampere）。
- entrypoint は初回起動時にチューニング済みの FEX 設定を `./fex-data` に書き込みます:
  - `DisableL2Cache=false` / `DynamicL1Cache=false` — メモリ内 JIT キャッシュを
    フルに使う設定（デフォルトはメモリ節約のためカクつきが増える側）。
  - `DisableTelemetry=true`。
  なお FEX のディスク JIT キャッシュ（`DiskCache` オプション）は
  `FEXOfflineCompiler` ツールが必要ですが、上流 PPA パッケージには含まれていないため
  効きません。変換済みコードは再起動をまたいで保存されず、
  4 vCPU 程度のマシンではワールドのロードにウォームアップの有無にかかわらず
  約 1 分かかります。
- `./fex-data` は消さないでください。FEX の rootfs と設定が入っています。
- `FG.AutosaveInterval`（デフォルト 300 秒）を延ばすと大規模セーブでの
  定期的なフリーズを減らせます（この構成では 600 秒に設定済み。
  クラッシュ時のロスが最大 10 分になるトレードオフがあります。
  正常停止時は必ずセーブされます）。
- CPU 制限を厳しくしすぎないでください。UE サーバーはワーカースレッドを
  使うため、スロットリングで停止することがあります。

---

## トラブルシューティング

### `Invalid or Unsupported elf file` / `RootFS path doesn't exist`

FEX rootfs がないか、`./fex-data` が空のボリュームです。

```bash
docker compose down
rm -rf ./fex-data
docker compose up -d
```

次回起動時に再ダウンロードされます。

### `/satisfactory` や `./config` の `Permission denied`

`PUID`/`PGID` がホストユーザーと一致していません。`id -u` / `id -g` に合わせてから:

```bash
docker compose down
sudo chown -R "$(id -u):$(id -g)" satisfactory config fex-data
docker compose up -d
```

### クライアントが接続できない

- **7777/TCP**、**7777/UDP**、**8888/TCP** を公開していますか？
  1.1 以降は 8888 がないと接続できません。
- クラウドのセキュリティリストでも同じポートを開放していますか？
- ログに `IpNetDriver listening on port 7777` が出ていますか？
- ポートを変更した場合は 1:1 で公開し、`-Port` / `-ReliablePort` を
  自動で渡す構成にしてください。
- 初回接続はワールドのダウンロードに時間がかかります。

### サーバーが落ちる / 再起動を繰り返す

```bash
docker compose logs --tail=200
tail -n 200 satisfactory/FactoryGame/Saved/Logs/FactoryGame.log
```

セーブ破損（バックアップから戻す）、ディスク不足（`df -h`）、
小さい VM での OOM（`dmesg | tail`）がよくある原因です。

### `Illegal instruction`

CPU がサポートしない `FEX_ARCH` でビルドされています。
`FEX_ARCH=armv8.0` で再ビルドするか、新しい ARM64 CPU で動かしてください。

### 起動直後に healthcheck が unhealthy

エミュレーションではマップロードに 1 分以上かかることがあります。
healthcheck の `start_period` は 15 分です。初回インストールが遅い場合は
それを超えることもあるので、`docker compose logs` を確認してください。

---

## 仕組み

```
Docker (Ubuntu 24.04 ARM64)
├── FEX-Emu（公式 PPA）            x86-64 → ARM64 変換
├── x86-64 FEX rootfs              ~/.fex/fex-emu/RootFS/Ubuntu_24_04
├── SteamCMD (x86)                 app 1690800 を /satisfactory に導入
└── FactoryServer.sh (x86-64)      FEXBash 経由で実行
```

- FEX はソースビルドせず公式 PPA から導入するため、ビルドが速く、
  以前のようなビルド破損が起きません。
- rootfs は `FEXRootFSFetcher` でボリュームに展開するため、
  `/dev/fuse` や `--privileged` は不要です。
- 最近の SteamCMD はエミュレーション下でプラットフォームを誤検出するため、
  `+@sSteamCmdForcePlatformType linux` を付けています。
- ローカルの `appmanifest_1690800.acf` のビルド ID が Steam と一致する場合は
  更新をスキップし、毎回 3 GB の validate をしないようにしています。

---

## クレジット

- 元の ARM64 Docker プロジェクト:
  [sa-shiro/Satisfactory-Dedicated-Server-ARM64-Docker](https://github.com/sa-shiro/Satisfactory-Dedicated-Server-ARM64-Docker)
- [FEX-Emu](https://github.com/FEX-Emu/FEX)
- [Satisfactory 専用サーバー公式ドキュメント](https://satisfactory.wiki.gg/wiki/Dedicated_servers)

ライセンス: MIT（[license.md](license.md)）

# 🐰 usakame (うさかめ) 🐢

**usakame** は、Ruby（mruby）でゲームロジックを記述し、グラフィックやサウンドなどの全アセットを**リソース込みのシングルスクリプト（単一ファイル）**で完結して表現できるレトロゲームエンジンです。

Rust（`macroquad` + `mrubyedge`）で構築されており、ネイティブデスクトップ（Windows / macOS / Linux）での軽快なホットリロード開発から、WebAssembly（ブラウザ実行）、配布用スタンドアロン単一バイナリ生成までを1つの CLI ツール `uk` でサポートします。

---

## ✨ 特徴

- **リソース込みシングルスクリプト完結**:
  - スクリプト末尾（`__END__` 以降）にドット絵スプライト、タイルマップ、効果音、BGM を直接テキストや Base64 で埋め込み可能。
  - 1つの `.rb` ファイルを共有・実行するだけでゲームがそのまま動作します。
- **レトロスペック**:
  - **仮想解像度**: 256x256 ピクセル（デフォルト 512x512 等倍整数スケーリング・レターボックス表示）
  - **パレット**: PICO-8 準拠 16色（パレット置換 `pal` / 透過色設定 `palt` 対応）
  - **日本語フォント & 絵文字**: 美咲ゴシック（8x8 漢字・かなフォント）および Twemoji 縮小ピクセル絵文字アトラス内蔵
- **レトロサウンドシステム（PICO-8 × Pyxel ハイブリッド）**:
  - **8-bit ソフトシンセ内蔵**: 矩形波・パルス波・三角波・ノコギリ波・ノイズ・オルガンなど8波形
  - **テキスト記法**: 音符列（`c3 e3 g3`）や MML（`T140 L8 O4 c e g > c`）による手書き編集
  - **プリセット効果音（サウンド絵文字）**: `sfx(:jump)` や `sfx(:coin)` など定番SEを1行で即座に再生
  - **パターンシーケンサ BGM**: `@MUSIC` によるマルチトラック（ch0〜ch3）同時演奏・自動ループ
  - **外部音声の埋め込み**: `@WAV` / `@OGG` による Base64 音声ファイルの埋め込み再生にも対応
- **超高速ホットリロード**:
  - `uk run` ではソース更新を即座に検知し、ゲームの進行状態（グローバル変数 `$x`, `$y`, `$hp` 等）を維持したままコードやグラフィック・サウンドを再読込
  - 再生中だった BGM も曲定義が変更されない限りシームレスに継続演奏
- **マルチターゲット**:
  - ネイティブ実行（`uk run`）
  - スタンドアロン単一実行バイナリ生成（`uk build`）
  - ブラウザ向けローカル Web サーバー & ライブリロード（`uk browser`）

---

## 🚀 クイックスタート

### 動作要件
- Rust 1.85+（2024 edition）
- （ブラウザ実行時）`rustup target add wasm32-unknown-unknown`

### ビルド & インストール
```bash
cargo build --release
# 生成された target/release/uk を PATH の通った場所に配置
```

### 実行
```bash
# サウンドデモの実行（上下キーでSE選択、Zで再生、XでBGM再生）
uk run examples/sound.rb

# サバイバルアクションゲーム「USAKAME SURVIVORS」の実行
uk run game.rb

# ブラウザで実行（Server-Sent Events による自動ライブリロード対応）
uk browser game.rb

# 配布用単一バイナリのビルド
uk build game.rb -o my_game.exe
```

---

## 🎵 サウンドシステム仕様

### 1. Ruby 再生 API
| メソッド | 説明 |
|---|---|
| `sfx(id_or_spec, channel = -1, volume = 1.0)` | 効果音を再生。整数ID（`@SFX` 番号）、シンボル（プリセット `:jump` 等）、文字列（インラインMML `"square c3 e3 g3"`）を指定可能。`channel` 省略時は空いているチャンネルで自動再生。 |
| `stop_sfx(channel = -1)` | 効果音を停止（`channel = -1` で全チャンネル停止）。 |
| `music(id, loop = true, volume = 1.0)` | `@MUSIC` で定義した BGM を再生（`id = -1` で停止）。 |
| `stop_music()` | 再生中の BGM を停止。 |

### 2. プリセット効果音（`:preset`）
効果音をゼロから組まなくても、スプライトの絵文字感覚ですぐに気持ちいいレトロSEが鳴らせます。
- `:jump` : ジャンプ上昇音
- `:coin` / `:pickup` : コイン・アイテム取得チャイム
- `:laser` / `:shoot` : レーザー・ショット発射音
- `:explosion` / `:boom` : 爆発・重低音ノイズ
- `:hit` / `:damage` / `:hurt` : 被ダメージ・打撃音
- `:powerup` : パワーアップ・アルペジオ
- `:select` / `:cursor` : UI選択・カーソル移動
- `:click` : 超短パーカッション
- `:gameover` / `:lose` : 敗北・ゲームオーバー下降和音

パラメータでピッチや速度の微調整も可能です：
```ruby
sfx("jump pitch=1.5")
```

### 3. リソース定義記法（`__END__` 以降）

#### ① `@SFX <id>`（効果音・フレーズ定義）
```ruby
__END__
# 複数行での定義
@SFX 0
wave square
speed 4
c3 e3 g3 c4 g3 e3 c3:fade

# 1行での定義
@SFX 1 wave=pulse speed=3 c2 c4:slide
@SFX 2 wave=noise speed=3 c4 r c2:fade

# プリセットを特定IDに割り当ててカスタマイズ
@SFX 3 :jump pitch=1.2 speed=1.0
```

- **波形 (`wave=`)**: `square` (矩形波), `pulse` (25%パルス), `pulse12` (12.5%パルス), `tri` (三角波), `saw` (ノコギリ波), `noise` (ノイズ), `organ` (オルガン), `phaser` (フェイザー)
- **速度 (`speed=`)**: 1ステップあたりの長さ（PICO-8基準: 60fps換算のフレーム数）
- **ノートエフェクト**: `:fade` (減衰), `:slide` (前の音からポルタメント), `:vib` (ビブラート), `:drop` (音程急降下), `:arp` (高速アルペジオ)

#### ② `@MUSIC <id>`（BGM・パターンシーケンサ定義）
**マルチトラック MML 記法**:
```ruby
@MUSIC 0
ch0 wave=square vol=4 T140 L8 O4 c e g > c < g e c e
ch1 wave=tri    vol=6 T140 L4 O3 c c g g
ch2 wave=noise  vol=2 T140 L8 O2 c r >>> c r <<<
```
- `T<bpm>`: テンポ指定
- `L<len>`: 基本音長（4: 4分音符, 8: 8分音符 等）
- `O<oct>` / `<` / `>`: オクターブ指定・上下移動

**PICO-8 パターン記法**:
各チャンネルで同時に鳴らす `@SFX` の ID を行ごとに並べて記述することもできます（`.` または `-` は休符）。
```ruby
@MUSIC 1
# ch0 ch1 ch2 ch3
10  11  12  .
13  11  14  .
```

#### ③ `@WAV <id>` / `@OGG <id>`（外部音声埋め込み）
`uk encode` コマンドで外部の `.wav` や `.ogg` を Base64 化してスクリプト内に直接埋め込めます。

---

## 🎨 グラフィック・描画リファレンス

### 描画プリミティブ
- `cls(col = 0)` : 画面クリア
- `pset(x, y, col = 7)` : 点描画
- `line(x0, y0, x1, y1, col = 7)` : 直線
- `rect(x, y, w, h, col = 7)` / `rectfill(x, y, w, h, col = 7)` : 矩形・塗りつぶし矩形
- `circ(x, y, r, col = 7)` / `circfill(x, y, r, col = 7)` : 円・塗りつぶし円
- `oval(x, y, rx, ry, col = 7)` / `ovalfill(x, y, rx, ry, col = 7)` : 楕円・塗りつぶし楕円
- `tri(x0, y0, x1, y1, x2, y2, col = 7)` / `trifill(...)` : 三角形・塗りつぶし三角形
- `spr(id_or_emoji, x, y, flip_x = false, flip_y = false, rotate = 0, scale = 1.0)` : スプライト描画
- `map(cel_x, cel_y, sx, sy, cel_w, cel_h)` : タイルマップ一括描画
- `mget(cel_x, cel_y)` / `mset(cel_x, cel_y, tile_id)` : タイルマップ取得・書換
- `print_text(str, x, y, col = 7)` : 日本語（美咲ゴシック）＋英数フォント＋インライン絵文字テキスト描画
- `camera(x = 0, y = 0)` : 仮想スクリーンのカメラ原点設定
- `clip(x, y, w, h)` : クリッピング領域設定（引数なしでリセット）
- `pal(c0, c1)` / `palt(col, transparent)` : パレット色置換 / 透過色設定

### 入力
- `btn(id_or_sym)` : 押し続け判定
  - キーボード: `0: :left`, `1: :right`, `2: :up`, `3: :down`, `4: :z / :space`, `5: :x / :enter`
  - マウス: `6: :mouse_l` (左クリック), `7: :mouse_r` (右クリック), `8: :mouse_m` (中クリック)
- `btnp(id_or_sym)` : このフレームで新たに押された瞬間判定（クリック検出や単発アクションに最適）
- `mouse_x` / `mouse_y` : 仮想画面（256x256）基準でのマウス座標（アスペクト比維持のレターボックス補正済み）
- `mouse_wheel` : マウスホイールのスクロール量（上: 正、下: 負）
- `show_mouse(visible = true)` : OS 標準マウスカーソルの表示 / 非表示切り替え

---

## 🛠️ CLI ツール (`uk`)

```bash
# スクリプトをネイティブ実行（ホットリロード付き）
uk run game.rb

# 配布用スタンドアロンバイナリ生成（外部アセット不要の1実行ファイル）
uk build game.rb -o my_game.exe

# ブラウザ向けローカル配信（ライブリロード付き）
uk browser game.rb

# 画像（PNG）や音声（WAV/OGG）を Base64 リソースブロックにエンコードして出力
uk encode my_icon.png --id 0
uk encode se.wav --id 10
```

---

## 📂 サンプルスクリプト

- **`game.rb`**: 本格ローグライト・サバイバルアクション「USAKAME SURVIVORS」（スプライト、アニメーション、敵AI、ボス戦、BGM・効果音、レベルアップモーダル等を含む完全なゲーム）
- **`examples/mouse.rb`**: マウス入力・ホイール・ドラッグ描画・絵文字＆スプライトカスタムカーソル対話型デモ
- **`examples/sound.rb`**: シンセ効果音・プリセットSE・BGMシーケンスの対話型プレビューデモ
- **`examples/tilemap.rb`**: タイルマップ描画と破壊・暗視パレット置換デモ
- **`examples/camera_clip.rb`**: カメラ追従と分割画面クリッピングデモ

---

## 📜 ライセンス

MIT License

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
  - **パレット**: 標準16色（パレット置換 `pal` / 透過色設定 `palt` 対応）
  - **日本語フォント & 絵文字**: 美咲ゴシック（8x8 漢字・かなフォント）および Twemoji 縮小ピクセル絵文字アトラス内蔵
- **レトロサウンドシステム**:
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

### バイナリのダウンロード（GitHub Releases）

Rust の開発環境をセットアップしなくても、GitHub Releases から各 OS 向けのビルド済みバイナリ（`uk`）をダウンロードしてすぐに利用できます。`main` ブランチへの push に連動して、常に最新（latest）のバイナリが自動ビルド・更新されます。

- 📦 **[GitHub Releases (latest) からダウンロード](https://github.com/ongaeshi/usakame/releases/latest)**
  - **Windows (x64)**: `uk-windows-x86_64.zip`
  - **macOS (Apple Silicon)**: `uk-macos-arm64.tar.gz`
  - **macOS (Intel)**: `uk-macos-x86_64.tar.gz`
  - **Linux (x64)**: `uk-linux-x86_64.tar.gz`

ダウンロードしたアーカイブを展開し、実行ファイル `uk`（Windows の場合は `uk.exe`）を PATH の通ったディレクトリに配置してください。

### ソースコードからのビルド & インストール
```bash
cargo build --release
# 生成された target/release/uk を PATH の通った場所に配置
```

### 新規プロジェクトの作成 (`uk new`) & 実行
```bash
# 1. 新規プロジェクトを作成（AIエージェント連携用の AGENTS.md & docs/ も自動生成）
uk new myapp
cd myapp

# 2. ゲームを実行（ホットリロード対応）
uk run

# 3. ゲームと内蔵エディタ（スプライト＆タイルマップ）を同時起動してリアルタイム編集
uk run_with_edit
# または単体でエディタを起動:
uk edit spr game.rb
uk edit map game.rb

# 4. オプション付きプロジェクト作成
uk new myapp --split          # game.rb と game.spr / game.map / game.sfx を分離して作成
uk new myapp --with-refs      # refs/examples/ に全サンプルコードを展開（AIのお手本にも最適）
uk new myapp --minimal        # AGENTS.md や docs/ を省略し最小構成で作成
uk new myapp -t platformer    # ジャンル別テンプレートから作成 (default, minimal, platformer, rpg, survivors, dungeon)

# 5. 🤖 初手 LLM プロトタイプ自動生成（自動コンパイル＆60フレーム実行検証・自己修復機能付き）
# 環境変数 GEMINI_API_KEY (または OPENAI_API_KEY / ANTHROPIC_API_KEY) を設定して実行:
uk new moon_rabbit -p "うさぎが月面で餅をつきながら隕石を避けるアクションゲーム"

# 6. 内蔵サンプル集を任意のフォルダに展開（Pyxel の copy_examples 相当）
uk examples ./examples

# 7. ブラウザで実行（Server-Sent Events による自動ライブリロード対応）
uk browser game.rb

# 8. 配布用単一バイナリのビルド
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
- **速度 (`speed=`)**: 1ステップあたりの長さ（60fps換算のフレーム数）
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

**トラッカー風パターン記法**:
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
- `spr(id_or_emoji_or_array, x, y, flip_x = false, flip_y = false, rotate = 0, scale = 1.0)` : スプライト描画（整数ID、絵文字文字列、またはメモリ上の256要素ピクセル配列をダイレクト描画）
- `draw_sprite_data(pixels, x, y, scale = 1.0, flip_x = false, flip_y = false)` : メモリ上のピクセル配列（256要素）から高速ダイレクトスプライト描画
- `map(cel_x, cel_y, sx, sy, cel_w, cel_h)` : タイルマップ一括描画
- `mget(cel_x, cel_y)` / `mset(cel_x, cel_y, tile_id)` : タイルマップ取得・書換
- `objects(filter_type = nil)` : マップ上に配置されたオブジェクト一覧を取得（`objects(:apple)` で特定種別のみ抽出も可能）
- `load_resource_objects(path, filter_type = nil)` : 外部ファイルやスクリプトからオブジェクト定義（`@OBJECTS`）を読込
- `print_text(str, x, y, col = 7)` : 日本語（美咲ゴシック）＋英数フォント＋インライン絵文字テキスト描画
- `camera(x = 0, y = 0)` : 仮想スクリーンのカメラ原点設定
- `clip(x, y, w, h)` : クリッピング領域設定（引数なしでリセット）
- `pal(c0, c1)` / `palt(col, transparent)` : パレット色置換 / 透過色設定

### 入力 & システム
- `btn(id_or_sym)` : 押し続け判定
  - 仮想パッド: `0: :left`, `1: :right`, `2: :up`, `3: :down`, `4: :z / :space / :btn_a`, `5: :x / :enter / :btn_b`
  - マウス: `6: :mouse_l` (左クリック), `7: :mouse_r` (右クリック), `8: :mouse_m` (中クリック)
  - フルキーボード: `:tab`, `:ctrl`, `:shift`, `:alt`, `:escape`, `:backspace`, `:del`, `:s`, `:c`, `:g`, `:key_1`..`:key_9`, `:f1`..`:f12` 等のシンボルに対応
- `btnp(id_or_sym)` : このフレームで新たに押された瞬間判定（クリック検出や単発アクションに最適）
- `mouse_x` / `mouse_y` : 仮想画面（256x256）基準でのマウス座標（アスペクト比維持のレターボックス補正済み）
- `mouse_wheel` : マウスホイールのスクロール量（上: 正、下: 負）
- `show_mouse(visible = true)` : OS 標準マウスカーソルの表示 / 非表示切り替え
- `fps` : 現在のフレームレート（FPS）を整数値で取得
- `restart` / `reset` : ゲームを先頭（初期状態）からリスタート

### デバッグ機能 & ショートカット
- **`F3` キー**: 実行中にいつでも画面右下に現在の **FPS 値（フレームレート）** を表示・非表示トグル可能。
- **`F5` または `Ctrl+R`（macOS: `Cmd+R`）**: ゲームを**先頭からリスタート**。普段スクリプト保存時のホットリロードでは変数の進行状態が維持されますが、このショートカットまたは `restart` API を呼ぶことで、いつでも最初からやり直すことができます。

---

## 🖥️ 画面解像度・倍率・フォント設定 (`config`)

ゲームの冒頭（トップレベル）で `config` を呼び出すことで、画面解像度やウィンドウ倍率、スプライトスケール、標準フォントサイズを柔軟にカスタマイズできます。

```ruby
config(
  width: 640,         # 仮想画面の横解像度（デフォルト: 256）
  height: 480,        # 仮想画面の縦解像度（デフォルト: 256）
  scale: 1.5,         # ウィンドウの表示倍率（デフォルト: 2.0）
  sprite_scale: 2.0,  # spr / map のグローバルスケーリング値（デフォルト: 1.0）
  text_size: 16,      # デフォルト文字サイズ（8 または 16、省略時は横256以下なら8、それ超なら16）
  title: "My Game",   # ウィンドウタイトル
  show_fps: true      # 画面右下に FPS を常時表示（F3キーでも切り替え可能）
)
```

### フォントシステム（美咲フォント & 東雲ゴシック 16 & Twemoji）
- **8x8 美咲フォント**: レトロ携帯機や 256x256 の低解像度画面に最適化された超小型漢字・かなフォント。
- **16x16 東雲ゴシック**: PC-98 / 90年代レトロPC風の高品位な 16x16 漢字・かな・英数フォント（Public Domain）。JIS第1・第2水準をバイナリ内蔵。
- **16x16 Twemoji 絵文字**: テキスト内の絵文字（🐰🐢⭐など）も自動的にテキストサイズに合わせてジャストサイズで埋め込み描画されます。
- **個別サイズ指定**: `print_text("STATUS", x, y, col, size: 8)` のように、16px 設定の画面でも部分的に 8px フォントを混在描画できます。

### `sprite_scale`
- `sprite_scale: 2.0` を指定すると、既存の 16x16 スプライトやタイルマップが自動的に 32x32px サイズ（Stardew Valley や Enter the Gungeon のような現代的レトロゲームの手法）で描画されます。個別 `spr` 呼び出しで倍率をオーバーライドすることも可能です。

---

## 🎨 外部リソース・ホットリロード & パックシステム

Usakame は **「1ファイルで配布・共有できる手軽さ」** と **「VSCode等のコードエディタと専用リソースツールの安全な並行編集」** を両立する「外部リソースオーバーレイ方式」を採用しています。

```
      [ VSCode ]                       [ Sprite Editor / Tilemap Editor ]
          │                                          │
    編集・保存 (Ctrl+S)                        編集・保存 (Ctrl+S)
          ▼                                          ▼
       game.rb                                game.spr / game.map
  (ロジック・基本リソース)                     (専用ツールの独立保存先)
          │                                          │
          └─────────────────┬────────────────────────┘
                            ▼
              【 自動マージ & ホットリロード 】
                    uk run game.rb
              (ゲーム画面が即座に最新反映！)
```

### 1. 安全な非破壊・並行開発
- VSCode 等で `game.rb` を開いたまま、スプライトエディタやタイルマップエディタを同時に起動して作業できます。
- エディタは `game.rb` のコードを直接書き換えるのではなく、`game.spr` や `game.map` に保存します。
- これにより、**コードエディタとリソースエディタが同一ファイルを上書きし合うバッティング（競合）が一切発生しません。**
- ゲーム側（`uk run game.rb`）は `game.rb` 本体だけでなく関連する `game.spr` や `game.map` の変更も常時監視しており、エディタで保存した瞬間に即座にホットリロードされます。

### 2. エディタ同士の相互同期
- スプライトエディタで保存した `game.spr` は、同時に起動しているタイルマップエディタにも自動検知・即座に反映されます。
- スプライトを描きながら、そのタイルのマップ上での見え方をリアルタイムに確認できます。

### 3. 1ファイル配布（Pack & Unpack）
開発時はファイルを分離して快適に作業し、配布時はいつでも単一ファイルに戻せます。
- **パック（Pack）**:
  ```bash
  uk pack game.rb -o my_game_packed.rb
  ```
  外部の `.spr` や `.map` などのリソースを `__END__` 以降にすべて統合した、配布用シングルスクリプトを出力します。
- **アンパック（Unpack）**:
  ```bash
  uk unpack my_game_packed.rb
  ```
  1ファイルにパックされたスクリプトからリソースを `.spr` や `.map` に安全に分離展開します。

---

## 🛠️ CLI ツール (`uk`)

```bash
# スクリプトをネイティブ実行（外部リソース含むマルチファイル・ホットリロード付き）
uk run game.rb

# ターゲットを指定してエディタを起動
uk run examples/sprite_editor.rb -- game.rb
uk run examples/tilemap_editor.rb -- game.rb

# 外部リソースをシングルスクリプトにパック（1ファイル配布用）
uk pack game.rb -o standalone_game.rb

# シングルスクリプトから外部リソースを分離展開
uk unpack standalone_game.rb

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
- **`examples/demo.rb`**: うさぎと亀の掛け合いによるエンジン機能紹介プレゼンテーションデモ（キャラクター歩行・正面向き、会話ウィンドウ、タイルマップスクロール、絵文字スプライト、パレット暗転フェードアウト等）
- **`examples/sprite_editor.rb`**: 480x270 高解像度 16x16 スプライトエディタ（16スロット、広大なキャンバス、パレット選択、ペン・塗りつぶし・スポイト、反転・シフト、アニメーションプレビュー、ターゲットスクリプトとの自動連携・`.spr` 保存）
- **`examples/tilemap_editor.rb`**: 480x270 高解像度 32x32 タイルマップエディタ（320x240 大画面キャンバス、16種タイルスプライト、ペン・矩形・バケツ・スポイト、ズーム切り替え、ミニマップ、スプライトエディタとの相互同期、ターゲットスクリプト連携・`.map` 保存）
- **`examples/mouse.rb`**: マウス入力・ホイール・ドラッグ描画・絵文字＆スプライトカスタムカーソル対話型デモ
- **`examples/sound.rb`**: シンセ効果音・プリセットSE・BGMシーケンスの対話型プレビューデモ
- **`examples/resolution.rb`**: 640x480 VGA / PC-98 風高解像度デモ（東雲ゴシック 16x16 フォント、16px Twemoji、`sprite_scale: 2` による 32x32 タイル・スプライト、8px 美咲フォントとの混在表示、会話ウィンドウ）
- **`examples/tilemap.rb`**: タイルマップ描画と破壊・暗視パレット置換デモ
- **`examples/split_game.rb`**: **コード・リソース完全分離サンプル**（`split_game.spr`, `split_game.map`, `split_game.sfx` の3つの外部ファイルと連携し、別ウィンドウのエディタで保存した瞬間リアルタイムに画面・音が変わるホットリロードの実験用ミニゲーム）
- **`examples/tiny_dungeon.rb`**: **Kenney「Tiny Dungeon」(CC0) を活用したダンジョン探索 & 全132タイルリファレンスデモ**（勇者の四方向歩行・壁衝突・宝箱オープン＆SE演出・モンスター巡回・Zキーによる「ゲーム」と「16x16全タイルID一覧ビューア」の相互切り替え機能付き）
- **`examples/camera_clip.rb`**: カメラ追従と分割画面クリッピングデモ

---

## 📜 ライセンス

- エンジン本体: MIT License
- コンパイラ・サードパーティ:
  - [mruby-compiler2](https://github.com/hasumikin/mruby-compiler2) (HASUMI Hitoshi 氏) - MIT License
  - [mruby-compiler2-sys](https://github.com/mruby/mruby-compiler2-sys) (Uchio Kondo 氏) - MIT License
  - [Prism](https://github.com/ruby/prism) (Ruby Core Team) - MIT License
- 内蔵フォント:
  - 美咲ゴシック (8x8): フリーフォント（門真 なほ 氏制作）
  - 東雲ゴシック (16x16 / 8x16): パブリックドメイン（古川 泰之 氏制作）
- 内蔵絵文字: Twemoji (CC-BY 4.0)

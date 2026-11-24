# Usakame Engine & mrubyedge 開発フィードバック・改善要望メモ

全30本のゲームを1ファイル完結（基本API + `bg()` + `@SPRITE` + キーボード/マウス）で連続制作する中で判明した、**実際に困った点・ハマりやすい仕様・改善してほしいポイント**をまとめました。

---

## 1. mrubyedge（Rubyランタイム）で実際に踏んだエラー・制約

### ① `Float - Integerリテラル` で VM がパニックする（最重要）【対応済み】
- **遭遇ゲーム**: `01_grapple_ascent.rb`
- **現象**: `@hook_y - 10` のように `Float` から `Integer` リテラルを引くコードを書くと、実行時に以下の Rust パニックが発生してクラッシュした。
  ```
  internal error: entered unreachable code: subi supports only integer
  ```
- **原因**: バイトコード最適化の `OP_SUBI`（即値整数減算）が左辺が `Float` のケースを想定していないため。
- **回避策**: 浮動小数座標のオフセット計算では必ず `@hook_y - 10.0` のように `.0` を付ける。
- **改善要望**: `OP_SUBI` / `OP_ADDI` 等で左辺が `Float` の場合に暗黙変換して計算できるようになると、ゲーム制作時の事故が激減します。
- **対応状況**: usakame コミット `23c52ea` にて、`mrubyedge` を最新（`a15a8e62`、PR #138 取り込み済み）へ更新し、パニックせず正常に計算・動作することを検証済み。

### ② `Array#each` 中の自己配列への `<<` で `RefCell already borrowed` パニック
- **遭遇ゲーム**: `21_pixel_aquarium.rb`
- **現象**: `@fishes.each do |f| ... @fishes << baby ... end` のようにイテレーション中に同じ配列へ要素を追加すると、`RefCell already borrowed` でパニックした。
- **回避策**: `new_babies = []` に一時退避し、`each` ループ終了後に追加する。
- **改善要望**: イテレーション中の配列変更時に分かりやすい `RuntimeError` を出すか、安全なイテレーションガードがあるとデバッグが容易になります。

### ③ 未実装の標準 Ruby メソッドによる `NoMethodError`
- **遭遇ゲーム**: `11_auto_chess_mini.rb`（`Array#index`）、`22_falling_sand_lab.rb`（`Array#fill`）
- **現象**: `docs/mrubyedge_api.md` の禁止リスト以外にも、`Array#index` や `Array#fill` などが未実装で実行時エラーになった（`Array.new(size, val)` は利用可能）。
- **改善要望**: `Array#index`, `Array#fill`, `Array#sample`, `Array#shuffle`, `Array#reverse`, `Hash#key?` など頻出メソッドが mrubyedge 側で実装されると、AI・人間ともに非常に書きやすくなります。

---

## 2. エンジン API / 描画仕様で困った点・欲しい機能

### ① 高解像度（`640x480`）時の `bg()` のデフォルトサイズ【対応済み】
- **遭遇ゲーム**: `23_dungeon_shopkeeper.rb`
- **現象**: `config(width: 640, height: 480)` のとき、通常の `bg(:city, dim: 0.55)` を呼ぶと 256×256 相当のサイズで左上にしか描画されず、右半分と下半分が単色背景になる（`fit: :screen` や `scale: 2.5` を明示する必要がある）。
- **改善要望**: 仮想解像度が `256x256` 以外のときは、デフォルトで画面全体を覆うスケーリング（または `fit: :screen` 相当）になるオプション挙動、あるいは `docs/api.md` での明記があると親切です。
- **対応状況**: usakame コミット `a60df1e` にて対応済み。仮想解像度が `256x256` 以外のとき、`scale`・`fit` 未指定（デフォルト `fit: :auto`）で画面全体を覆うよう自動スケーリングするように改善し、`fit: :screen` のループ非併用時挙動や `:cover` / `:contain` / `:height` / `:width` / `:none` オプションの拡充、および `docs/api.md` への明記を行った。

### ② 半透明（アルファブレンド）図形描画の不在【対応済み】
- **該当ゲーム**: `03_gravity_flip_run.rb`, `10_submarine_sonar.rb`, `26_fireworks_director.rb`, `27_kaleidoscope_bloom.rb`
- **困った点**: `rectfill` や `circfill` に透明度（alpha）指定がないため、ゴーストカー・残像・水中ライト・ソナーの視界マスク・花火のフェードアウトなどを「パレットスワップ（`@PALETTE 11`）」や「点滅（`frame % 2 == 0`）」や「サイズ縮小」で擬似表現する必要があった。
- **改善要望**: `alpha` 引数（または `blend(:add)`）が `rectfill` / `circfill` / `spr` に追加されると、光の演出や残像の表現力が一気に跳ね上がります。
- **対応状況**: usakame コミット `01cc652`（図形・テキスト・`spr` / `spr_ex` / `blt` 等への `alpha` 引数追加）および `3ca2214`（`blend(:normal / :add / :mul)` ステート API 追加）にて対応済み。サンプルとして `examples/alpha.rb` および `examples/blend.rb`（コミット `611c2e1`）を追加。

### ③ 太線（ライン幅）や塗りつぶし多角形（`polygonfill`）の不在【対応済み】
- **該当ゲーム**: `05_drift_circuit.rb`, `09_pinball_cyber.rb`, `29_retro_synth_visualizer.rb`
- **困った点**: 太さ1pxの `line` しかないため、ドリフトの太いコース路面は円を連続描画（`circfill`）して描き、フリッパーやビームは `line` を2〜3本ずらして重ね描きする必要があった。
- **改善要望**: `line(..., width: 3)` や `quadfill` があると、レースコース・ビーム・3Dポリゴン描画が大幅に高速・シンプルになります。
- **対応状況**: usakame コミット 2e71261 (feat(examples): add polygon and thick line demo (examples/polygon.rb)

---

## 3. 検証スクリプト・ツール面での気づき

### ① `scripts/verify_game.ps1` の禁止ワード正規表現が厳しめ【対応済み】
- **困った点**: `\b(map|...|play|...)\b` という正規表現でスキャンしているため、タイルマップAPIではなく Ruby の `Array#map` を使ったり、変数名に `map` や `play` を使っただけでも `[FORBIDDEN]` で弾かれる。
- **改善要望**: `Array#map`（`.map`）やローカル変数名と、トップレベル関数呼び出しの `map(...)` / `play(...)` を区別できるとさらに快適です。
- **対応状況**: 本体を `scripts/verify_game.py`（トークナイザによる字句解析ベース）へ刷新し、`scripts/verify_game.ps1` は互換ラッパー化。`Array#map`（`.map` / `&.map`）、ローカル変数（`map = ...` 等）、コメント、文字列リテラル、シンボルを誤爆せず、トップレベル呼び出し（`map(...)`, `play(...)`, `sfx(...)` 等）と未実装メソッド呼び出しのみを正確に検出するよう改善済み。

### ② `uk check -g`（ガチャ連打テスト）は非常に優秀だった
- **良かった点**: `11_auto_chess_mini.rb` の `Array#index` や `21_pixel_aquarium.rb` の `RefCell already borrowed`、`22_falling_sand_lab.rb` の `Array#fill` は、すべてタイトル画面の60フレームチェックでは見つからず、**`uk check -g`（480フレームのランダム入力テスト）によって即座に検出できた**。
- **要望**: 今後はマウス移動・クリックも含めたランダム入力モードが `uk check` にあると、マウス主体のゲーム（TDやサンドボックス等）の網羅テストがさらに強力になります。

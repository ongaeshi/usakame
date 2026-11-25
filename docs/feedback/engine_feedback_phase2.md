# Usakame Engine & mrubyedge 開発フィードバック・改善要望メモ（Phase 2: 31〜40）

Phase 1（`docs/engine_feedback.md`）で対応された新API（`alpha` 半透明、`blend(:add / :mul)`、太線 `line` / `polyline`、塗りつぶし多角形 `trifill` / `quadfill` / `polygonfill`、高解像度 `bg()` 自動フィット、`Float - Integer` 修正、`verify_game.py` 字句解析）を活用し、新作7本＋DX進化版3本の計10本（No.31〜40）を連続制作した振り返りです。

---

## 1. Phase 2 新APIで劇的に良くなった点

### ① `blend(:add / :mul)` ＋ `alpha` の表現力
- **`31_prism_laser.rb` / `40_fireworks_symphony.rb`**: `blend(:add)` により、レーザーのRGB加算混色や花火の重なり白熱発光が「光そのもの」として自然に表現できるようになった。
- **`33_shadow_thief.rb` / `34_drift_circuit_dx.rb` / `36_submarine_sonar_2.rb`**: `blend(:mul)` で画面全体を夜の暗闇や漆黒の深海へ沈め、その上から `blend(:add)` の視界コーン・ヘッドライト・サーチライトを重ねることで、擬似表現では不可能だった明暗コントラストが数行で実現できた。

### ② `polyline` / `trifill` / `quadfill` / `polygonfill`
- **`34_drift_circuit_dx.rb`**: 前作 `05` で `circfill` を大量スタンプして描いていた路面が、`polyline` 太線数本だけで滑らか・高速に描画できるようになった。
- **`32_star_trench.rb`**: `quadfill` / `trifill` により、Zソートされた面塗り3Dポリゴン渓谷・敵・戦艦をピュアRubyで違和感なく構築できた。
- **`33_shadow_thief.rb` / `39_vitrail_craft.rb`**: 任意多角形 `polygonfill(..., alpha)` により、壁遮蔽レイキャスト視界コーンやステンドグラスの多角形ガラス片が美しく描画できた。

### ③ 高解像度 `bg()` 自動フィット（`fit: :auto`）
- **`32`〜`34`, `36` (`320x240`) / `37`, `40` (`480x270`) / `38` (`640x480`)**: 仮想解像度を変更しても `bg(:mountain)` や `bg(:cave)` が自動で画面全体にフィットし、ワイド・高精細ゲームの制作コストが大幅に下がった。

### ④ `Float - Integer` 対応と `verify_game.py`
- `@px - 10` のような記述で VM パニックが一切起きなくなり、物理・座標計算の記述ストレスが解消された。
- `verify_game.py` の字句解析化により、`Array#map` やローカル変数名での誤検知がゼロになった。

---

## 2. Phase 2 で新たに踏んだ制約・ハマりやすい仕様

### ① 描画APIのキーワード引数 vs 位置引数 【対応済み (`1b09476`)】
- **遭遇ゲーム**: `31_prism_laser.rb`
- **現象**: `line(x0, y0, x1, y1, col, width: 6, alpha: 0.42)` のように `width:` / `alpha:` をキーワード引数で渡したところ、太さや透明度が反映されず 1px 不透明線で描画された。
- **回避策**: `line(x0, y0, x1, y1, col, 6, 0.42)` のように**位置引数**として渡すことで正常に太線・半透明が効くことを確認。`rect` / `tri` / `poly` / `print_text` 等でも位置引数を統一使用した。
- **改善要望**: `docs/api.md` 上の引数表と同じ感覚で `width:` / `alpha:` キーワード引数も全図形APIで受け取れるようにするか、位置引数推奨を明記すると親切。
- **対応内容**: 毎フレーム呼ばれる描画APIでのキーワード引数（Hash確保・GC Alloc）による実行時オーバーヘッドを避けるため、仕様として位置引数のみ対応とし、`docs/api.md` の「2.2 描画API」冒頭にキーワード引数非対応・位置引数指定のルールと具体例を明記した。

### ② `Array#each` ブロック引数の配列展開（Destructuring） 【対応済み (`719629f`)】
- **遭遇ゲーム**: `31_prism_laser.rb`（タイトル画面）
- **現象**: `[[y0, col0], [y1, col1]].each do |ty, c|` と書くと、mrubyedge では `ty` に配列 `[y0, col0]` がそのまま入り、`c` が `nil` になった。
- **回避策**: `each do |pair| ty = pair[0]; c = pair[1]` のようにインデックスアクセスする。
- **対応内容**: mrubyedge VM 側のブロック引数バインディング仕様のため、仕様として明文化する方針とし、`docs/mrubyedge_api.md`・`AGENTS.md`・`src/cli.rs`（`uk new` テンプレート）にブロック引数の配列展開非対応と代替パターンを追記した。

### ③ 高解像度時の `print_text` デフォルトサイズ 【対応済み (`720361a`)】
- **遭遇ゲーム**: `32_star_trench.rb`
- **現象**: `320x240` や `480x270` で `print_text(str, x, y, col)` をサイズ省略で呼ぶと、大きなフォント（16px相当）で描画され HUD が重なりやすかった。
- **回避策**: HUD や小ラベルには第5引数で明示的に `print_text(str, x, y, col, 8)`（8px美咲/6x8フォント）を指定する。
- **対応内容**: `AppConfig::resolved_text_size()` の解像度による自動 16px 切替を廃止し、仮想解像度によらずデフォルト `8`px に統一した（`16`px にしたい場合は `config(text_size: 16)` または第5引数 `16` を明示指定）。あわせて `docs/api.md` の `print_text` 仕様を更新した。

### ④ マウス入力API名（`btnp(:mouse_l)`） 【対応済み (`720361a`)】
- **遭遇ゲーム**: `31_prism_laser.rb`
- **現象**: `mouse_btn(0)` は未定義で `NoMethodError` となった。
- **回避策**: `btn(:mouse_l)` / `btnp(:mouse_l)` / `btnp(:mouse_r)` と `mouse_x` / `mouse_y` を使用する。
- **対応内容**: `docs/api.md` の「2.3 入力API」に `mouse_x`, `mouse_y`, `show_mouse` および `btn` / `btnp` のマウスボタン対応（`6`〜`8` / `:mouse_l`, `:mouse_r`, `:mouse_m`）を追記し、第6章の古い未実装候補（`mouse_btn`）の記述を削除した。

### ⑤ `Array#index` 未実装 【対応済み (`1e91107`)】
- **遭遇ゲーム**: `40_fireworks_symphony.rb`
- **現象**: Phase 1 の `docs/engine_feedback.md` にも記載がある通り `Array#index` は未実装。
- **回避策**: インデックス検索が必要な場合は手動ループまたはランダム選択で代替する。
- **対応内容**: `src/main.rs` に `register_array_extensions` を追加し、`Array#index(item)` および `Array#find_index(item)` を実装した（`docs/mrubyedge_api.md` にも追記）。

---

## 3. より深く満足できるゲームを作るための新機能提案（Phase 3 以降に向けて）

Phase 2 でビジュアル表現（光・影・多角形・高解像度）が大きく進化した次のステップとして、**「プレイヤーが何時間でも遊びたくなる深み・手触り・達成感」**を引き上げるために優先度の高いエンジン機能をまとめました。

### ① サウンド / チップチューン再生（`sfx` / `music` / `tone`）【最優先】
- **理由**: 現在は無音環境のためヒットストップ・シェイク・フラッシュで手触りを補っているが、居合斬り（`35`）・魚雷命中（`36`）・砲弾着弾（`37`）・花火の打ち上げと炸裂（`40`）・カード発動（`38`）に効果音とBGMが加わるだけで、ゲームの快感と没入感が段違いに跳ね上がる。
- **要望**: `docs/api.md` 第4章にある通り、外部ファイル不要で `__END__` 内に `@SFX` / `@MUSIC` を記述できる波形合成シンセ、または `tone(freq, dur, wave, vol)` の実装。

### ② 永続セーブデータ API（`dset` / `dget`、WASM `localStorage` 対応）【最優先】 【対応済み (`9f8e9fc`)】
- **理由**: 現状は `$dx_best_times` や `$abyss2_best` などのハイスコア・ベストゴースト・パズルのクリア状況が、ウィンドウを閉じる／ブラウザをリロードするとすべて消えてしまう。
- **要望**: PICO-8 の `dset(slot, val)` / `dget(slot)` やキーバリュー形式（`save_set(key, val)` / `save_get(key)`）で、デスクトップ版はローカルファイル、Web版は `localStorage` に永続保存できる仕組み。これにより「全12面スターコンプ」「ゴースト記録保持」「ローグライトのアンロック要素」など**長期的なやり込み動機**が作れる。
- **対応内容**: キーバリュー形式に一本化した永続セーブ API（`save_set`, `save_get`, `save_del`, `save_has?`, `save_keys`, `save_clear`）と `src/save.rs`（依存ゼロ JSON シリアライズ対応で `Array` / `Hash` もそのまま保存可能）を実装した。別ゲームとのデータ衝突・世代管理のため `config(save_id: "...", save_salt: "...")` の両指定を必須とし、補助コマンド `uk save-init` を追加した。デスクトップ版は OS 標準データディレクトリ配下の JSON ファイル、WASM 版は `web/mq_js_bundle.js` の `usakame_storage` プラグイン経由で `localStorage` に保存する（`uk check` 等のヘッドレス時はインメモリ動作）。また、`docs/api.md` の更新とサンプル `examples/save_data.rb` を追加した。

### ③ オフスクリーン描画サーフェス / ライトマップ（`surface` / `set_target`） 【対応済み (`6df233e`, `149c485`)】
- **理由**:
  - `34_drift_circuit_dx.rb` のタイヤ痕や `40_fireworks_symphony.rb` の花火の残光、`39_vitrail_craft.rb` のペイントなど、「消えずに残る軌跡・デカール」は現在すべて配列に溜めて毎フレーム再描画しているため、表現量に上限がある。
  - `33_shadow_thief.rb` や `36_submarine_sonar_2.rb` の闇と光の表現も、`blend(:mul)` の暗闇に「穴を開ける（くり抜く）」専用ライトマップが作れると、複数の光源が重なっても白飛びしない自然な2Dライティングが可能になる。
- **要望**: `create_surface(w, h)`、`render_to(surf) { ... }`、`draw_surface(surf, x, y, alpha:, blend:)` のようなシンプルなオフスクリーンバッファAPI。
- **対応内容**: `src/surface.rs` を新設し、`:gpu`（`RenderTarget` ベース）と `:pixel`（CPU バッファ＋Dirty Rect 部分転送）の 2 バックエンドを統一 API で扱うサーフェス機能（`create_surface`, `free_surface`, `clear_surface`, `surface_size`, `render_to`, `set_target`, `draw_surface`）を実装した。あわせて `blend(:erase)`（くり抜き合成）と `cls(nil)` / `cls(col, alpha)` の透明・半透明クリアを追加し、`docs/api.md` の更新とサンプル `examples/lightmap_decal.rb` を追加した。

### ④ テキスト計測＆装飾オプション（`text_width` / `align:` / `outline:`） 【対応済み】
- **理由**: 全作品を通じて「タイトルやポップアップの中央揃え」を手計算（`str.length * 3` 等）で行っており、特に `38_arcana_deck.rb` のような日本語（全角16px）と英数字（半角8px）が混在するUIでは正確なセンタリングや枠収めが難しい。また、明るい背景やエフェクト上での視認性を上げるための黒フチ文字（現在5回ずらし描きが必要）も頻繁に欲しくなる。
- **要望**: `text_width(str, size)`、`print_text(..., align: :center / :right, outline: 0)`（または `shadow: 0`）。
- **対応内容**: `BitmapFont`（`src/font.rs`）に描画と同一ロジックの計測関数を追加し、`text_width(text = "", size = nil)` および `text_height(text = "", size = nil)` を実装した（ASCII・全角・半角カナ・絵文字混在・`\n` 複数行・`config(text_size: ...)` 連動対応）。また、`print_text` については Hash 確保による GC Alloc オーバーヘッドを避けるためキーワード引数ではなく位置引数で拡張し、`print_text(text, x, y, col, size, alpha, align, outline, shadow)` として `:left` / `:center` / `:right`（複数行時は行単位整列）、4近傍フチ取り（`outline`）、右下ドロップシャドウ（`shadow`）を `:pixel` サーフェスを含めて実装した。あわせて `docs/api.md` の更新とサンプル `examples/text_style.rb` を追加した。

### ⑤ 入力の拡充（`mouse_wheel`・2P/ゲームパッド入力・`cursor` 表示制御） 【対応済み】
- **理由**:
  - `mouse_wheel` が取れると、パズルやショップ画面でのスクロール、花火や色ガラスの素早い切替が直感的になる。
  - `32_star_trench.rb` や `37_slingshot_fortress.rb` のような照準系ゲームでは、OS標準カーソルを隠してゲーム内レティクルを表示する `show_cursor(false)` があると没入感が増す。
  - `btn(id, player = 0)` の2P対応・ゲームパッド対応が入ると、対戦・協力アクションの幅が一気に広がる。
- **対応内容**: `mouse_wheel` と `show_mouse` は既存実装を確認し、`show_cursor` エイリアスを追加して `docs/api.md` に `mouse_wheel` / `show_cursor` を明記した。さらに `src/gamepad.rs`（Desktop 版 `gilrs` 0.11 / WASM 版 `web/index.html` の `usakame_gamepad` プラグインによる `navigator.getGamepads()` 連携）を新設し、`btn(id = 0, player = 0)` / `btnp(id = 0, player = 0)` および `gamepad_count()` を実装した（`player = 0` は 1P キーボード＋マウス＋ゲームパッド 1、`player = 1` は 2P キーボード `IJKL + U/O`＋ゲームパッド 2、`player = 2..3` はゲームパッド 3〜4 に対応）。あわせてサンプル `examples/input_2p_gamepad.rb` を追加した。

### ⑥ ピクセル取得・破壊可能地形向け API（`pget` / サーフェス直接書き換え） 【対応済み (`149c485`)】
- **理由**: `pget(x, y)` やサーフェス単位のピクセル操作があると、Worms風の「地形を爆破して穴を開ける」ゲームや、落下砂・流体シミュレーションの高速化が可能になり、物理アクションの遊びの幅が大きく広がる。
- メモ: ③ オフスクリーン描画サーフェス とセットで考えた方がいいかもしれない。
- **対応内容**: `create_surface(w, h, :pixel)` に対する図形スパン・`spr`・`blt`・`map`・`print_text`・`blend(:erase)` の CPU ブリッターと Dirty Rect GPU 部分転送を実装し、さらに `pget`, `surface_pget`, `surface_pset`, `surface_swap`, `surface_solid?`, `surface_circle_solid?`, `surface_raycast`, `surface_count` を追加した（透明ピクセルは `mget` と同じく `nil`、黒 `0` も真として判定可能）。`uk check` のヘッドレス環境でも同一の CPU 判定が動作し、サンプル `examples/destructible_terrain.rb` を追加した。

### ⑦ タイルマップの強化と描画パフォーマンス改善（`fget`・複数マップ・バッチング/チャンクキャッシュ）
- **理由**: 現状すでに `@MAP` / `map` / `mget` / `mset` が実装されているが、`usakame-games` の制約を外して探索型アクション・メトロイドヴァニア・見下ろしRPGなどの「長時間遊べるゲーム」を作る場合、タイルマップの活用が不可欠になる。
- **機能面の要望**:
  - **タイル属性フラグ（`fget` / `fset`）**: `mget` が返すスプライトIDに対して「壁」「ダメージ床」「ハシゴ」などの属性ビットを判定できる仕組み。
  - **名前付き複数マップ / マルチレイヤー**: `@MAP :stage1` のような複数マップ保持・切替や、背景レイヤー＋前景レイヤーの重ね描き、および `map()` での `alpha` / `blend` 対応。
- **パフォーマンス面の課題と要望（1セルずつの個別描画ボトルネック）**:
  - 現状、1タイルずつ個別に描画処理を行う実装では、Phase 2 で主流になった高解像度（`320x240` で約300タイル、`480x270` で約510タイル、`640x480` で最大1,200タイル、2レイヤーなら2,400回）や WASM 実行環境で CPU / ドローコール負荷が急増しやすい。
  - **改善案1（頂点バッチング）**: 同じスプライトバンク（アトラス）を参照するタイル群を1フレーム分の1つの頂点バッファ／メッシュにまとめて **1ドローコール** で描画する。
  - **改善案2（チャンク／オフスクリーンキャッシュ）**: 静的マップを一定単位（例: 16×16タイル）のオフスクリーンテクスチャにベイクしておき、`mset` / `mdel` が呼ばれたチャンクだけ再描画（Dirtyフラグ管理）する。
  - **改善案3（自動ビューポートカリング）**: `camera()` と仮想解像度から画面内のセル範囲だけを自動計算してスキップする。

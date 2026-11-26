# Usakame Engine & mrubyedge 開発フィードバック・改善要望メモ（Phase 3: 41〜50）

Phase 2（`docs/engine_feedback_phase2.md`）で対応された新API（永続セーブ `save_set`/`save_get`、オフスクリーン `:gpu` サーフェス＆`blend(:erase)`、`:pixel` サーフェス＆破壊可能地形クエリ `surface_*`、テキスト計測・整列・フチ取り `text_width`/`print_text`、2P/ゲームパッド入力・`mouse_wheel`・`show_cursor`、`Array#index`）を全面活用し、完全新作8本＋DX進化版2本の計10本（No.41〜50）を連続制作した振り返りです。

---

## 1. Phase 3 新API・設計方針で劇的に良くなった点

### ① 永続セーブデータ API（`save_set` / `save_get` / `save_has?`）
- **`42_lantern_survivors.rb` / `49_abyssal_driller.rb`**: ランで稼いだソウルや換金額を保存し、タイトル画面で恒久強化を購入できる「何度も遊びたくなるサイクル」が外部ファイル管理なしで数行で実装できた。
- **`44_micro_factory.rb` / `46_falling_sand_dx.rb` / `47_picross_atelier.rb`**: `Array` や `Hash` をそのまま JSON 永続化できるため、工場レイアウト・RLE 落ち砂作品・ピクロス途中経過＆16作品のギャラリー状態を丸ごと保存・復元できた。
- **`48_fishing_odyssey_dx.rb` / `50_titan_colosseum.rb`**: 全20種魚図鑑（最大寸・王冠）や全5体タイタンのSランク・最速タイムが残り、やり込み目標が明確になった。

### ② `:gpu` サーフェス ＋ `blend(:erase)` による 2D ライトマップ＆永続デカール
- **`42_lantern_survivors.rb` / `48_fishing_odyssey_dx.rb` / `49_abyssal_driller.rb` / `50_titan_colosseum.rb`**: `cls(0, alpha)` で闇を描き、`blend(:erase)` の `circfill` で複数光源をくり抜くことで、光源が重なっても白飛びしない自然な 2D ライティングが数行で実現できた。
- **`42` / `45` / `50`**: 別 `:gpu` サーフェスにスライム痕・コート焦げ跡・ボスのクレーター傷跡をスタンプすることで、毎フレームの再描画配列を肥大させずに「戦場の歴史が残る」演出が可能になった。

### ③ `:pixel` サーフェス ＆ 破壊可能地形クエリ API（`surface_*`）
- **`41_crater_artillery.rb` / `49_abyssal_driller.rb`**: `blend(:erase)` でピクセル地形にクレーターやトンネルを直接掘り、`surface_raycast` / `surface_solid?` / `surface_circle_solid?` で着弾・斜面移動・落石判定を CPU 側で正確に処理できた。
- **`43_ink_turf_arena.rb` / `46_falling_sand_dx.rb`**: `surface_pget` による足元インク判定や落ち砂判定、`surface_count` によるリアルタイム面積％集計やパズルビーカー充填判定が非常に高速かつ直感的に書けた。

### ④ `text_width` / `print_text` 位置引数整列・フチ取り（`:center`, `:right`, `outline`）
- **`47_picross_atelier.rb`** のヒント数字の右揃え・中央揃えや、全10作品の HUD・タイトルバナーで、従来の手計算センタリングや5回ずらし描きが不要になり、背景に負けない視認性が即座に得られた。

### ⑤ 入力拡充（`btn(..., 1)` / `gamepad_count` / `mouse_wheel` / `show_cursor(false)`）
- **`41` / `43` / `45` / `50`**: 1P＋CPU モードを基本としつつ、`btn(..., 1)` により 2P ローカル対戦・協力（`IJKL+U/O`・ゲームパッド2）へ自然に対応できた。
- **`41` / `44` / `46` / `47` / `48`**: `mouse_wheel` による兵器切替・設備回転・ブラシ調整・ツール切替・リール巻き操作が直感的で手触りを大きく向上させた。

### ⑥ 浅いハッシュテーブル（`$cfg` / `$weapons` 等）によるパラメータ集約
- 全10本で調整値とエンティティ仕様をスクリプト冒頭の浅いハッシュテーブルに集約したことで、バランス調整箇所が一目瞭然となり、`uk run` のホットリロード調整とも相性が良かった。

---

## 2. Phase 3 で新たに踏んだ制約・ハマりやすい仕様

### ① `draw_surface` の `scale:` オプションが期待通りに拡大されないケース
- **遭遇ゲーム**: `46_falling_sand_dx.rb`
- **現象**: `80x48` の `:pixel` サーフェスを `draw_surface(@surf, 0, @sy, scale: 4.0)`（および `1.0, nil, scale: 4.0`）で 4 倍拡大描画しようとしたところ、画面上では等倍（1x）サイズで描画された。
- **回避策**: `64x38` の `:pixel` サーフェスで物理・`surface_pget`・`surface_swap`・`surface_count` を処理し、描画ループで `rectfill(px * 5, sy + py * 5, 5, 5, c)` と 5x 拡大描画することで回避した。
- **改善要望**: `draw_surface(surf, x, y, scale: s)` および `scale_x:` / `scale_y:` のキーワード引数が `:pixel` / `:gpu` 両サーフェスで確実に拡大描画へ反映されるか確認・修正があると、低解像度ピクセルシミュレーションの拡大表示がさらに高速になる。

### ② 高解像度 `:pixel` サーフェスの純 Ruby 全セル走査負荷
- **遭遇ゲーム**: `46_falling_sand_dx.rb`
- **現象**: `160x96`（15,360ピクセル）を毎フレーム 2 パスで `surface_pget` / `surface_swap` する純 Ruby ループを書いたところ、480フレームのヘッドレス検証（`uk check -f 480`）が数分以上かかるほど重くなった。
- **回避策**: セル数を `64x38`（2,432セル）に抑え、2フレームに1回の更新＋最内側ループ直前でのローカル変数キャッシュを行うことで、十分な滑らかさと高速な検証時間を両立した。
- **改善要望**: セルオートマトンや大量粒子向けに、エンジン側で「矩形領域の簡易ステップ」や「`:pixel` サーフェスの整数倍率ニアレスト拡大転送」があると、より高精細な落ち砂ゲームが容易になる。

### ③ `verify_game.py` の `include?` 禁止チェックと `Array#index`
- **遭遇ゲーム**: `43_ink_turf_arena.rb`
- **現象**: `@unlocked.include?(w_str)` が `verify_game.py` の `strictForbidden` で検出された（`Hash#include?` 対策として `.include?` 全般が禁止されているため）。
- **回避策**: Phase 2 で追加された `Array#index` を使い、`!@unlocked.index(w_str).nil?` と書くことで安全かつ明快に判定できた。

---

## 3. 今後のさらなる進化に向けた提案（Phase 4 以降に向けて）

1. **サウンド / チップチューン再生（`sfx` / `music` / `tone`）**:
   - 全50本を達成した今、次の一歩として効果音・BGM の実装が加わるだけで、既存50本の快感（砲撃・斬撃・釣り上げ・ボス撃破）が劇的に跳ね上がる。
2. **`draw_surface` の `scale:` / `rot:` 動作確認とニアレスト補間指定**:
   - `:pixel` サーフェスを低解像度のまま `scale: 4.0` でくっきり拡大描画できるようになると、落ち砂・流体・ミニマップ表現の幅がさらに広がる。

---

## 4. サウンド機能（`sfx` / `music` / `tone`）実装に向けた具体提案

50本制作の実戦経験（1ファイル完結・AI生成との相性・`uk check` 検証・ホットリロード・WASM動作）から、サウンド機能の実装・拡充時にあらかじめ組み込んでおきたい仕様・改善点をまとめました。

### ① API 設計（位置引数統一・ピッチ可変・音量制御）
- **すべて位置引数で統一**（mrubyedge の Hash 確保オーバーヘッド回避・既存図形/`print_text` と統一）:
  - `tone(freq, dur = 0.1, wave = :square, vol = 0.5, slide = 0.0)`
  - `sfx(id, ch = -1, vol = 1.0, pitch = 1.0)`: `pitch` 引数があるとコイン連続取得やコンボ時の音階上昇演出が1行で書ける。
  - `music(id, loop = true, vol = 0.6)`（`nil` または `-1` で停止）。
- **全体音量 / ミュート API**: `master_vol(v)` / `sfx_vol(v)` / `music_vol(v)` があるとポーズ画面や設定に組み込みやすい。
- **`uk check` ヘッドレス無音スタブ**: `save_set` 同様、`uk check` 実行時は音声デバイスを開かずノーオペレーションで即返却し、CI・自動検証を確実に通す。
- **WASM（ブラウザ）Autoplay 対策**: 初回キー入力／クリック時に `AudioContext` を自動 `resume()` する仕組みをエンジン側で内包する。

### ② プリセット音源の内蔵 ＆ `__END__` テキスト定義
- **名前付きプリセット SFX の標準搭載（定義ゼロで即鳴る）**:
  - 絵文字スプライトが定義不要で使えるのと同様に、`:jump`, `:shoot`, `:hit`, `:explode`, `:coin`, `:powerup`, `:select`, `:confirm`, `:cancel`, `:laser`, `:slash`, `:splash`, `:clear`, `:gameover` 等の汎用プリセットを 15〜20 種内蔵する。
- **`@SFX :名前`（シンセレシピ記法）**:
  - `wave:square freq:440->880 dur:0.15 env:decay` のように AI・人間ともに直感的に読み書き・調整できるテキスト形式で定義可能にする。
- **`@MUSIC :名前`（MML 風マルチトラック記法）**:
  - `@SPRITE :hero` と同様にシンボル名で定義して `music(:boss_theme)` で呼び出せるようにし、Pulse1 / Pulse2 / Triangle(Bass) / Noise(Drums) の 3〜4 チャンネルを MML 風（例: `t140 o4 l8 c d e g`）で記述可能にする。

### ③ 発音制御・ホットリロード・ツール支援
- **SFX 多重発音ガード（クリッピング防止）**: 弾幕やサバイバーズ系で同フレームに複数ヒットが起きても音割れしないよう、同一 `sfx` ID の最小クールダウン（2〜3フレーム間引き）とボイススチール（上限超過時に古い音を切る）をエンジン側に備える。
- **ホットリロード時の音声同期**: `uk run` リロード時に鳴りっぱなしのループ音が残らず、同じ BGM ID なら途切れず継続・変更時のみ差し替える。
- **試聴 CLI / 静的検証**: `uk sfx` のような単体試聴プレビュー機能と、`uk check` 時の未定義 `@SFX` / `@MUSIC` シンボル・MML 構文エラー検知。

---

## 5. エディタレス高速確認 CLI（`uk spr` / `uk sfx`）の提案

リッチな GUI エディタを用意しなくても、**「1ファイル完結のままコマンド1つでアセットを即確認・即検証できる CLI」**があると、人間・AI エージェント双方の開発ループが劇的に高速化します。

### ① スプライト単体・一覧確認コマンド（`uk spr`）
- **課題**: 現状はスプライトを確認するために `uk run game.rb -s tmp/preview.png -f 60` でゲーム本編を起動・進行させる必要があり、後半のボスや `---` アニメーションの2フレーム目以降をピンポイントで確認しづらい。
- **提案**:
  - `uk spr game.rb -s tmp/sprites.png`（全スプライト＋全フレームを市松背景・4〜8倍拡大・ラベル付きで一覧出力）
  - `uk spr game.rb :golem -s tmp/golem.png`（指定スプライトのみを拡大出力）
  - ゲームループを回さず `__END__` の `@PALETTE` / `@SPRITE` / `@SHEET` を即レンダリングできるため、配色ミス・輪郭欠け・アニメフレームのピボットズレを一瞬で発見・修正できる。

### ② サウンド単体試聴 ＆ 数値・波形チェックコマンド（`uk sfx`）
- **課題**: サウンドはテキスト定義を読んでも鳴り方が分からず、スクリーンショットでも確認できないため、ゲーム本編を操作して該当イベントを起こさないと試聴できないと調整が重くなる。
- **提案**:
  - **人間向け即試聴**: `uk sfx game.rb :explode` や `uk sfx "wave:square freq:440->110 dur:0.2"` でゲーム起動なしに即再生（保存即再生のウォッチ対応があるとさらに快適）。
  - **エージェント向け検証**: 再生時間・Peak/RMS・クリッピング有無のテキストサマリ出力、および SFX 用の波形（エンベロープ）PNG 出力（`-s tmp/sfx_wave.png`）・BGM 用のチャンネル別サマリ／ピアノロール出力により、無音バグ・音割れ・ループ長ズレを自動検知できる。

### ③ 将来のエディタ統合を見据えた CLI サブコマンド体系（`uk edit` / `uk preview`）
- 将来的に GUI エディタをワンウィンドウ統合する見通しを踏まえ、CLI は「編集系」と「非対話プレビュー・ダンプ系」を動詞で分けてサブコマンド化しておくと綺麗に拡張できる：
  - **`uk edit <kind>`（インタラクティブ編集・将来ワンウィンドウ統合）**: `uk edit spr game.rb` / `uk edit map game.rb` / `uk edit sfx game.rb` を提供し、将来ワンウィンドウ統合後も `uk edit game.rb`（全体）および `uk edit spr game.rb`（スプライトタブを初期選択）として後方互換を維持できる。
  - **`uk preview <kind>`（または `uk view`：非対話プレビュー・画像/数値ダンプ）**: `uk preview spr game.rb [-s out.png]`、`uk preview sfx game.rb [:boom]`、`uk preview map game.rb [-s map.png]` のように、ゲームループを回さず人間・AI・CI が高速にアセットを確認・検証できる軽量コマンドとして独立させる。

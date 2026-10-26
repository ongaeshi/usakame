# AGENTS.md

このリポジトリ（Usakame）で AI エージェントがコードを生成・編集・リファクタリングする際のガイドラインです。

---

## 1. プロジェクト概要

* **Usakame** は、Rust（Macroquad）と軽量 Ruby VM **mrubyedge**（mruby-compiler2）で構築されたレトロゲームエンジンです。
* ゲーム本体やサンプルコード（`game.rb`, `examples/*.rb`）は Ruby で記述され、ネイティブおよび WebAssembly（WASM）環境で実行されます。

---

## 2. ⚠️ Ruby コード作成・編集時の絶対ルール（最重要）

Usakame で使用している Ruby 実行環境は **mrubyedge** であり、標準の CRuby と比べて**組み込みクラス・メソッドが軽量化（一部のみ実装）**されています。
存在しないメソッドを呼び出すと実行時に `NoMethodError` 等でクラッシュするため、以下のルールを必ず遵守してください。

### ① 必ず API 仕様書を確認すること
Ruby コードを生成・修正する前に、必ず以下のドキュメントを確認してください。
* **[docs/mrubyedge_api.md](file:///c:/Users/ongaeshi/Code/usakame/docs/mrubyedge_api.md)**: mrubyedge で利用可能な Ruby 標準クラス・メソッド一覧、および未実装メソッドと代替コード集。
* **[docs/api.md](file:///c:/Users/ongaeshi/Code/usakame/docs/api.md)**: Usakame エンジン固有の描画・入力・タイルマップ・サウンド API（`cls`, `spr`, `btn`, `map`, `sfx` 等）。

### ② 存在しない頻出メソッドと代替パターンの遵守
以下のメソッドは mrubyedge に存在しません。記載の代替パターンを必ず使用してください。

* ❌ `array.sample` → ⭕ **`array[rand(array.size)]`**
* ❌ `array.shuffle` → ⭕ ランダムスワップ処理を自前で実装する
* ❌ `array.reverse` → ⭕ インデックスを逆順に回す（`i = array.size - 1; while i >= 0 ...`）
* ❌ `array.delete(item)` → ⭕ **`array.reject! { |x| x == item }`** または `delete_at(idx)`
* ❌ `hash.key?(k)` / `include?` → ⭕ **`hash.has_key?(k)`**
* ❌ `hash.dig(...)` → ⭕ `hash[a] && hash[a][b]`
* ❌ `string.gsub` / `sub` → ⭕ `string.split(pat).join(rep)` 等で代替
* ❌ `n.upto(m)` / `downto` → ⭕ **`(n..m).each`** または `while` ループ
* ❌ `n.even?` / `odd?` → ⭕ **`n % 2 == 0`** / **`n % 2 != 0`**
* ❌ `sleep(sec)` → ⭕ ゲームループ（毎フレーム呼ばれる `update`）内のタイマー変数・フレームカウンタで制御
* ❌ `Time.now` → ⭕ フレームカウンタ（60FPS想定）から経過秒数を計算する

### ③ タイルマップ API（`mget` / `mset` / `mdel`）のルール
* **空マスの取得**: `mget(x, y)` は空マス・未設定セルに対して **`nil`** を返します（`-1` ではありません）。
  * ⭕ `if mget(x, y)` でタイルが存在するか判定できます（0番タイルも真になります）。
  * ❌ `if mget(x, y) > 0` や `if mget(x, y) != -1` と書かないこと。
* **タイルの消去**: 消去には **`mdel(x, y)`** または **`mset(x, y, nil)`** を使用してください。
  * ❌ `mset(x, y, -1)` などの負数を渡すと **`ArgumentError` 例外が発生** します。

### ④ 数学関数・乱数
* Usakame エンジンでは `Math.sin(x)`, `Math.cos(x)`, `Math.sqrt(x)` のほか、トップレベル関数 `sin(x)`, `cos(x)`, `sqrt(x)` も直接呼び出し可能です。
* 乱数は `rand()`（0.0...1.0）、`rand(max)`（0...max）、`rand(min..max)` が利用可能です。

---

## 3. テストと動作確認

* Rust コアのテスト:
  ```powershell
  cargo test
  ```
* スクリプトの実行確認:
  ```powershell
  cargo run --bin uk -- run game.rb
  # または
  cargo run --bin uk -- run examples/<sample>.rb
  ```

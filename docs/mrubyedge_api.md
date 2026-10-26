# mrubyedge & Usakame Ruby API リファレンス

本ドキュメントは、**Usakame** エンジンのスクリプト実行基盤である **mrubyedge**（および Usakame による拡張）で提供されている Ruby 組み込みクラス・メソッドの完全一覧と、CRuby（標準 Ruby）との違い・未実装メソッドの注意点をまとめたリファレンスです。

AI エージェントや開発者が Ruby コード（`game.rb` やスクリプト）を作成・編集する際は、**本ドキュメントに記載されているメソッドのみを使用**してください。

---

## 1. ⚠️ 最重要：よくある未定義メソッド（NoMethodError）と代替コード

mrubyedge は WASM や組み込み向けの軽量 Ruby 実行環境です。CRuby（標準 Ruby）で頻出する多くの便利メソッドが**未実装**となっています。
以下の表に、AI や開発者が最も踏みやすい「存在しないメソッド」と「代替パターン」をまとめました。

| 使えないメソッド (CRuby) | 理由 / 状態 | 推奨される代替パターン |
| :--- | :--- | :--- |
| `array.sample` | 未実装 | `array[rand(array.size)]` |
| `array.shuffle` / `shuffle!` | 未実装 | インデックスをランダムに入れ替える処理を自作する |
| `array.reverse` / `reverse!` | 未実装 | インデックスを逆順にループ（`i = array.size - 1; while i >= 0 ...`） |
| `array.delete(item)` | 未実装（`delete_at` のみ存在） | `array.reject! { \|x\| x == item }` または `array.delete_at(idx)` |
| `array.compact!` | 破壊的版は未実装 | `array = array.compact`（Enumerable#compact は利用可能） |
| `array.slice(idx, len)` | 未実装 | `array[idx, len]` またはループで取得 |
| `hash.key?(k)` | 未実装 | **`hash.has_key?(k)`** を使用する |
| `hash.include?(k)` | 未実装 | **`hash.has_key?(k)`** を使用する |
| `hash.fetch(k, default)` | 未実装 | `hash[k] \|\| default` または `hash.has_key?(k) ? hash[k] : default` |
| `hash.dig(...)` | 未実装 | `hash[a] && hash[a][b]` などの手動アクセス |
| `hash.select` / `reject` | 未実装 | 手動ループ（`res = {}; hash.each { \|k, v\| res[k] = v if ... }`） |
| `string.gsub` / `sub` | 未実装 | `string.split(pat).join(rep)` または手動文字列構築 |
| `string.reverse` | 未実装 | `chars` を逆順に連結 |
| `n.upto(m)` / `downto` | 未実装 | `(n..m).each { \|i\| ... }` または `i = n; while i <= m ...` |
| `n.even?` / `odd?` | 未実装 | `n % 2 == 0` / `n % 2 != 0` |
| `sleep(sec)` | 未実装 | ゲームループ内のフレームカウンタやタイマー変数で管理 |
| `Time.now` | 未実装 | フレーム数（毎フレーム `update` 呼び出しでカウント）で経過時間を計測 |
| `eval`, `require`, `load` | 未実装 | 単一ファイル構成、または Usakame の `read_file` ＋自前パース |

---

## 2. クラス・モジュール別 API リスト

### 2.1 Object / Kernel

すべてのオブジェクトやトップレベルで利用可能な基本メソッドです。

#### 利用可能なメソッド
* **出力・デバッグ**
  * `puts(*args)` : コンソールに改行付きで出力
  * `p(*args)` : オブジェクトを `inspect` 形式で出力
  * `debug(*args)` : デバッグ出力
* **オブジェクト比較・型判定**
  * `==`, `!=`, `===`, `<=>`
  * `nil?` : `nil` かどうか判定
  * `!` : 否定（Truthy / Falsy 判定）
  * `is_a?(klass)`, `kind_of?(klass)` : 型チェック
  * `class` : オブジェクトのクラスを返す
  * `respond_to?(sym)` : メソッドの存在チェック
  * `object_id`, `__id__` : オブジェクトID
* **文字列化**
  * `to_s`, `inspect`
* **フロー制御・手続き**
  * `initialize`
  * `raise(msg)` : 例外を発生
  * `block_given?` : ブロックが渡されたか判定
  * `proc`, `lambda` : Proc オブジェクトの生成
  * `loop { ... }` : 無限ループ
  * `public_send(name, *args)` : メソッドの動的呼び出し
  * `method_missing(sym, *args)` : 未定義メソッドフック
  * `extend(mod)` : モジュールの include
  * `wasm?` : WASM 環境かどうか判定
* **フォーマット（Usakame 拡張）**
  * `sprintf(fmt, *args)` / `format(fmt, *args)` : 書式付き文字列生成（`%d`, `%f`, `%s`, `%02d` 等に対応）
* **乱数（Usakame 拡張）**
  * `rand()` : `0.0 <= x < 1.0` の Float 乱数
  * `rand(max)` : `0 <= x < max` の Integer 乱数（整数引数）
  * `rand(range)` : `range.begin <= x <= range.end` の範囲乱数（例: `rand(1..6)`）

---

### 2.2 Array

配列クラス。`Enumerable` を include しています。

#### 利用可能なメソッド
* **構築・要素操作**
  * `Array.new`
  * `arr + other` : 配列の連結
  * `arr << item`, `arr.push(item)` : 末尾への追加
  * `arr[index]`, `arr.at(index)` : インデックスアクセス
  * `arr[index] = val` : 代入
  * `arr.first`, `arr.last` : 先頭／末尾要素
  * `arr.pop` : 末尾から取り出して削除
  * `arr.shift` : 先頭から取り出して削除
  * `arr.unshift(item)` : 先頭に追加
  * `arr.delete_at(index)` : 指定位置の要素を削除
  * `arr.clear` : 全要素をクリア
* **反復・検索**
  * `arr.each { |item| ... }`
  * `arr.empty?` : 空配列か判定
  * `arr.size`, `arr.length` : 配列の要素数
  * `arr.include?(item)` : 要素が含まれるか判定
* **集合演算・変換**
  * `arr & other` : 積集合
  * `arr | other` : 和集合
  * `arr.dup` : 浅いコピー
  * `arr.to_s`, `arr.inspect`
  * `arr.join(sep = "")` : 文字列連結
  * `arr.flatten`, `arr.flatten!` : 平坦化
  * `arr.pack(template)` : バイナリパック
* **破壊的走査・ソート**
  * `arr.map! { |x| ... }`
  * `arr.select! { |x| ... }`
  * `arr.reject! { |x| ... }`
  * `arr.sort!`
  * `arr.sort_by! { |x| ... }`
  * `arr.uniq!`
* **Enumerable 経由で利用可能なメソッド**
  * `map`, `select`, `find`, `all?`, `any?`, `count`, `compact`, `each_with_index`, `sort`, `sort_by`, `max`, `min`, `minmax`, `reduce`, `sum`, `to_a`, `uniq`, `delete_if`

> [!WARNING]
> `Array#sample`, `Array#shuffle`, `Array#reverse`, `Array#delete(val)` は**存在しません**。上記の「最重要：よくある未定義メソッド」を参照してください。

---

### 2.3 Enumerable

`Array`, `Hash`, `Range` に include されているコレクション用モジュールです。

#### 利用可能なメソッド
* `map { |x| ... }`
* `find { |x| ... }`
* `select { |x| ... }`
* `all? { |x| ... }`
* `any? { |x| ... }`
* `count` / `count { |x| ... }`
* `compact`
* `delete_if { |x| ... }`
* `each_with_index { |x, i| ... }`
* `sort` / `sort { |a, b| ... }`
* `sort_by { |x| ... }`
* `max`, `min`, `minmax`
* `reduce(init) { |acc, x| ... }`
* `sum`
* `to_a`
* `uniq`

---

### 2.4 Hash

ハッシュ（連想配列）クラス。`Enumerable` を include しています。

#### 利用可能なメソッド
* `Hash.new`
* `hash[key]`, `hash[key] = val`
* `hash.clear`
* `hash.dup`
* `hash.delete(key)` : キーを指定して削除
* `hash.empty?` : 空か判定
* `hash.has_key?(key)` : キーが存在するか判定（**※ `key?` は使えません**）
* `hash.has_value?(val)` : 値が存在するか判定
* `hash.key(val)` : 値からキーを逆引き
* `hash.keys` : キー一覧の配列
* `hash.values` : 値一覧の配列
* `hash.each { |k, v| ... }`
* `hash.size`, `hash.length`, `hash.count`
* `hash.merge(other)`, `hash.merge!(other)`
* `hash.to_h`
* `hash.flatten`
* `hash.to_s`, `hash.inspect`

> [!CAUTION]
> CRuby で一般的な `hash.key?(k)` は未定義です。必ず **`hash.has_key?(k)`** を使用してください。

---

### 2.5 String

文字列クラス。

#### 利用可能なメソッド
* `String.new`
* `str + other`, `str * n`, `str << other`
* `str[idx]`, `str[start, len]`, `str.slice(...)`
* `str.slice!(...)`
* `str.clear`
* `str.chomp`, `str.chomp!`
* `str.dup`
* `str.empty?`
* `str.getbyte(idx)`, `str.setbyte(idx, byte)`
* `str.index(sub)`
* `str.ord`
* `str.split(sep)` : 文字列分割
* `str.strip`, `str.strip!`, `str.lstrip`, `str.lstrip!`, `str.rstrip`, `str.rstrip!`
* `str.to_sym`, `str.intern`
* `str.start_with?(prefix)`, `str.end_with?(suffix)`
* `str.include?(sub)`
* `str.bytes`, `str.chars`
* `str.upcase`, `str.upcase!`, `str.downcase`, `str.downcase!`
* `str.to_i`, `str.to_f`
* `str.size`, `str.length`, `str.bytesize`
* `str.unpack(template)`
* `str.b`
* `str.to_s`, `str.inspect`
* `str % args` : フォーマット展開（Usakame 拡張）

> [!WARNING]
> `String#gsub`, `String#sub`, `String#reverse` は**存在しません**。

---

### 2.6 Integer

整数クラス。

#### 利用可能なメソッド
* 算術演算: `+`, `-`, `*`, `/`, `**`, `%`, `-@`
* ビット演算: `&`, `|`, `^`, `~`, `<<`, `>>`, `[idx]` (ビット参照)
* 変換・ユーティリティ:
  * `abs` : 絶対値
  * `to_i`, `to_f`
  * `chr` : ASCIIコードから文字へ変換
  * `times { |i| ... }` : 指定回数ループ
  * `clamp(min, max)` : 範囲制限
  * `to_s`, `inspect`
* **Usakame 拡張:**
  * `floor`, `ceil`, `round`, `modulo`

---

### 2.7 Float

浮動小数点数クラス。

#### 利用可能なメソッド
* 算術演算: `+`, `-`, `*`, `/`, `**`, `+@`, `-@`
* 変換・判定:
  * `to_i`, `to_f`
  * `abs`
  * `finite?`, `infinite?`, `nan?`
  * `clamp(min, max)`
  * `to_s`, `inspect`
* **定数:**
  * `Float::INFINITY`, `Float::NAN`, `Float::EPSILON`
* **Usakame 拡張:**
  * `%`, `modulo`
  * `floor`, `ceil`, `round`

---

### 2.8 Range

範囲クラス。`Enumerable` を include しています。

#### 利用可能なメソッド
* `(a..b).include?(val)` : 含まれているか判定
* `(a..b).each { |x| ... }` : 反復処理
* **Enumerable 経由:**
  * `to_a`, `map`, `select` など

> [!NOTE]
> `begin`, `end`, `cover?`, `step` は定義されていません。

---

### 2.9 Symbol

シンボルクラス。

#### 利用可能なメソッド
* `sym.to_s`
* `sym.to_proc`
* `sym.inspect`
* `sym.upcase`, `sym.downcase`（Usakame 拡張）

---

### 2.10 TrueClass / FalseClass / NilClass

* `TrueClass`: `&`, `|`, `^`, `!`, `to_s`, `inspect`
* `FalseClass`: `&`, `|`, `^`, `!`, `to_s`, `inspect`
* `NilClass`: `nil?` (常に true), `!`, `to_s`, `inspect`

---

### 2.11 Math モジュール（Usakame 拡張）

Usakame では、`Math` モジュール配下のメソッドが定義されており、同時にトップレベル（`Object`）にも同名関数がエクスポートされているため、`Math.sin(x)` でも `sin(x)` でも直接呼び出しが可能です。

#### 定数
* `Math::PI` (約 3.141592653589793)
* `Math::E` (約 2.718281828459045)

#### 関数一覧（`Math.xxx` およびトップレベル `xxx` 両対応）
* **三角関数:** `sin(x)`, `cos(x)`, `tan(x)`, `asin(x)`, `acos(x)`, `atan(x)`, `atan2(y, x)`
* **指数・対数・平方根:**
  * `sqrt(x)` : 平方根
  * `cbrt(x)` : 立方根
  * `exp(x)` : $e^x$
  * `log(x, [base])` : 自然対数（または指定底の対数）
  * `log2(x)` : 2を底とする対数
  * `log10(x)` : 10を底とする対数
  * `hypot(x, y)` : $\sqrt{x^2 + y^2}$

---

### 2.12 Class & Module

* `Class.new`
* `attr_reader(*syms)`
* `attr_writer(*syms)`
* `attr_accessor(*syms)` / `attr(*syms)`
* `include(mod)`
* `ancestors`
* `inspect`

---

### 2.13 Usakame ゲームエンジン API

グラフィックス描画（`cls`, `spr`, `rect`, `line`, `blt`, `print_text` 等）、キー・マウス入力（`btn`, `mouse_x` 等）、タイルマップ（`map`, `mget`, `mset`, `mdel`）、サウンド（`sfx`, `music`）などのエンジン固有 API については、[docs/api.md](file:///c:/Users/ongaeshi/Code/usakame/docs/api.md) を参照してください。

# Usakame Retro Engine — VSCode Extension (`vscode-usakame`)

Usakame (uk) レトロゲームエンジンのインラインリソース（`__END__` セクション内の `@SPRITE` / `@PALETTE` / `@MAP` / `@SFX` / `@MUSIC`）をフル活用するための VSCode 拡張機能です。

## 主な機能

1. **`@SPRITE` / `@PALETTE` / `@MAP` / `@SFX` のスマート展開**
   - `__END__` 内で `@SPRITE` と入力して Tab を押すと、次の空き ID を自動採番して `16×16` の `.` テンプレートを展開します。
   - `@SPRITE size32x32` や `@SPRITE 4 32x32`、`@SPRITE size16x32` 等を入力して Tab を押すと、指定されたサイズ（`32×32`, `16×32`, `24×24`, `48×48` 等）のドットブロックを自動展開します。
2. **エディタ上の `@SPRITE` 直接ピクセルカラー表示 & `@PALETTE` カラースウォッチ**
   - `@SPRITE` ブロック内の `0`〜`F` の文字背景に、指定された `pal:<id>`（または標準 PICO-8 パレット）の色を直接着色し、テキストエディタ上でそのままドット絵が浮かび上がります（コマンド `Usakame: Toggle Inline @SPRITE Pixel Coloring` で ON/OFF 切替可能）。
3. **`spr()` / `blt()` 入力時のカーソル右上リアルタイムプレビュー**
   - `spr(0, x, y)` や `blt(x, y, 0, u, v, w, h)` の引数を入力中、カーソル直上のシグネチャヘルプ内に**拡大スプライト画像**および **Bank 0 上の切り出し領域（赤枠ハイライト付き）**がリアルタイム表示されます。
   - コード行の末尾にもミニスプライトアイコンが常時インライン表示されます。
4. **その場で起動するインライン GUI エディタ (`Usakame Inline Studio`)**
   - `@SPRITE` / `@PALETTE` / `@MAP` / `@SFX` の上に表示される CodeLens（`🎨 ドット絵を編集` / `🌈 パレットを編集` / `🗺️ タイルマップを編集` / `🔊 サウンドを編集・試聴`）をクリックすると、エディタ横に GUI エディタが起動します。
   - キャンバス上でドットを打ったりパレット色を変更すると、即座に `game.rb` のテキストがリアルタイム書き換えされます。
5. **mrubyedge 互換性リンター & Bank 0 スロット重複チェック**
   - mrubyedge で未実装のメソッド（`.sample`, `.shuffle`, `.even?`, `.upto`, `mset(x, y, -1)` 等）や、大型スプライト配置時のタイルスロット重複をリアルタイムに警告します。

## 開発・動作確認方法

```bash
cd editors/vscode-usakame
npm install
npm run compile
npm test
```

VSCode でこのリポジトリを開き、**`F5` キー**（`Run Usakame VSCode Extension`）を押すと拡張機能開発ホストが起動し、`game.rb` や `examples/*.rb` で即座にすべての機能を試すことができます。

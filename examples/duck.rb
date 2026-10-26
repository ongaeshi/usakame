# 16bit風 元気なアヒルちゃん 泳ぎアニメーション サンプル
# Usakame Engine (16x16 Pixel Art, 16 Colors)

$frame = 0

# ぷかぷか揺れる波のオフセット（Floatの減算エラーを回避する安全な整数テーブル）
WAVE_Y = [0, 1, 2, 2, 1, 0, -1, -2, -2, -1]

def update
  $frame += 1
end

def draw
  cls(1) # 深い紺色（水底）でクリア

  # タイトル
  print_text("16bit DUCK - 16x16 PIXEL ART", 16, 12, 15)
  print_text("Water Swimming Demo", 16, 24, 4)

  # コマ切り替え（約15フレームごとにパタパタ）
  anim_id = ($frame / 15) % 2

  # 拡大プレビュー (x4)
  print_text("x4 Scale", 32, 54, 7)
  spr(anim_id, 48, 80, false, false, 0, 4.0)

  # 拡大プレビュー (x8 ディテール確認用)
  print_text("x8 Detail Preview", 136, 54, 7)
  spr(anim_id, 168, 120, false, false, 0, 8.0)

  # ゲーム内実寸デモ（1x スイミング）
  print_text("In-Game Demo (1x):", 16, 175, 7)

  # 水面ガイドライン
  line(0, 204, 255, 204, 2)

  # スイスイ泳ぐアヒルちゃん（整数演算でスイスイ前進）
  swim_x = (($frame * 2 / 3) % 280) + (-24)
  wave_offset = WAVE_Y[($frame / 4) % WAVE_Y.size]
  swim_y = 192 + wave_offset

  spr(anim_id, swim_x, swim_y)
end

__END__
@PALETTE 0
0: #181024
1: #10326E
2: #1868B8
3: #38B8E8
4: #9CF0FF
5: #208A7C
6: #703818
7: #A85000
8: #E88A00
9: #FFC400
A: #FFF068
B: #FF5A28
C: #FF9A48
D: #4A3854
E: #FFE4B0
F: #FFFFFF

# コマ0: スイスイ進む
@SPRITE 0 16x16 pal:0
................
......AAAA......
....AAFFAAA6....
...AAFF09AA6....
...AAAA99996BB6.
...A99B9988CBBB7
....9988886677..
..AA99998888....
.AA99AAAA99886..
6A99AAAAAA9986..
6999998888776...
.6777666666.....
443355553334433.
.2221111222211..
..11..........1.
................

# コマ1: ぷかぷか・尾羽と波の揺らめき
@SPRITE 1 16x16 pal:0
................
......AAAA......
....AAFFAAA6....
...AAFF09AA6....
...AAAA99996BB6.
...A99B9988CBBB7
..AA9988886677..
.AA9999AAAA886..
6A99AAAAAA9986..
.6999998888776..
..6777666666....
.4433555533344..
3322211112222114
.11..........11.
................
................

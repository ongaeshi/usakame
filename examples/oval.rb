# ==========================================
# Usakame Sample: oval & ovalfill Demo
# 実行コマンド: uk run examples/oval.rb
# ==========================================

$x = 96
$y = 176
$vy = 0.0
$jump_z = 0.0
$t = 0
$flip_x = false

def update
  $t += 1

  # 矢印キー / WASD で移動
  if btn(0)
    $x -= 2
    $flip_x = true
  end
  if btn(1)
    $x += 2
    $flip_x = false
  end
  if btn(2)
    $y -= 2
  end
  if btn(3)
    $y += 2
  end

  $x = 16 if $x < 16
  $x = 224 if $x > 224
  $y = 128 if $y < 128
  $y = 220 if $y > 220

  # Z / Space キーでハイジャンプ、通常時はリズミカルに小ジャンプ
  if $jump_z <= 0.0
    if btn(4)
      $vy = 4.2
    else
      $vy = 1.8
    end
  end

  $jump_z += $vy
  $vy -= 0.22
  if $jump_z < 0.0
    $jump_z = 0.0
    $vy = 0.0
  end
end

def draw
  cls(1)

  # 1. 夜空の星雲・オーロラ風グラデーション楕円 (ovalfill / oval)
  ovalfill(128, 52, 96, 26, 2)
  ovalfill(128, 52, 72, 16, 13)
  oval(128, 52, 104, 30, 14)

  # 土星風の惑星（本体 circfill + 楕円の輪 oval）
  oval(204, 52, 26, 7, 9)
  oval(204, 52, 22, 5, 10)
  circfill(204, 52, 9, 15)
  # 手前側のリング弧を上書き
  clip(176, 52, 56, 10)
  oval(204, 52, 26, 7, 9)
  oval(204, 52, 22, 5, 10)
  clip()

  # 2. 地面と池（塗りつぶし楕円 + 広がる波紋の楕円枠）
  rectfill(0, 112, 256, 144, 3)
  ovalfill(64, 108, 80, 18, 3)
  ovalfill(196, 112, 76, 20, 3)

  # 池の水面 (ovalfill)
  pond_cx = 188
  pond_cy = 184
  ovalfill(pond_cx, pond_cy, 46, 22, 5)
  ovalfill(pond_cx, pond_cy, 44, 20, 12)
  oval(pond_cx, pond_cy, 46, 22, 7)

  # 水面に広がる2重の楕円波紋アニメーション (oval)
  r1_rx = (($t / 2) % 36) + 4
  r1_ry = (r1_rx * 9) / 20
  oval(pond_cx - 6, pond_cy + 2, r1_rx, r1_ry, 7)

  r2_rx = ((($t + 36) / 2) % 36) + 4
  r2_ry = (r2_rx * 9) / 20
  oval(pond_cx + 8, pond_cy - 2, r2_rx, r2_ry, 6)

  # 池のほとりのカメ（足元に楕円の影）
  kame_x = 160 + (($t / 4) % 36)
  kame_y = 142
  ovalfill(kame_x + 8, kame_y + 15, 7, 3, 0)
  spr(1, kame_x, kame_y, false, false)

  # 3. 縦長・横長に脈動する魔法ポータル (oval / ovalfill)
  portal_rx = 8 + (($t / 4) % 6)
  portal_ry = 20 - (($t / 6) % 5)
  ovalfill(36, 168, portal_rx, portal_ry, 2)
  oval(36, 168, portal_rx + 2, portal_ry + 2, 14)
  oval(36, 168, portal_rx - 2, portal_ry - 2, 7)
  spr("✨", 28, 160)

  # 4. プレイヤー（ウサギ）：ジャンプ高さに応じて足元の楕円影 (ovalfill) のサイズ変化
  shadow_rx = 8 - ($jump_z / 6.0).to_i
  shadow_ry = 4 - ($jump_z / 12.0).to_i
  shadow_rx = 2 if shadow_rx < 2
  shadow_ry = 1 if shadow_ry < 1
  ovalfill($x + 8, $y + 15, shadow_rx, shadow_ry, 0)
  oval($x + 8, $y + 15, shadow_rx + 1, shadow_ry + 1, 5)

  # ウサギ本体と周囲のバリアリング
  uy = $y - $jump_z.to_i
  spr(0, $x, uy, $flip_x, false)
  if btn(4)
    oval($x + 8, uy + 8, 14, 9, 10)
    oval($x + 8, uy + 8, 9, 14, 11)
  end

  # 5. 上部UIヘッダ
  rectfill(0, 0, 256, 26, 0)
  line(0, 26, 255, 26, 12)
  print_text("OVAL & OVALFILL DEMO 🐰🐢", 8, 4, 10)
  print_text("Arrow:Move  Z:High Jump & Barrier", 8, 15, 7)
end

__END__
@SPRITE 0
....77....77....
...7887..7887...
...7887..7887...
...7887..7887...
...7777..7777...
...7777777777...
..777777777777..
.77788777788777.
.77788777788777.
.777777EE777777.
.77777777777777.
..777777777777..
...7777777777...
..777777777777..
...7777..7777...
................

@SPRITE 1
................
................
................
.....BBBBBB.....
....BBBBBBBB....
...BB33BBB33B...
..BBBB33333BBB..
.7BBB3BBBB3BBBB.
77B333BBBBB333B.
77BBB3333333BBB.
.7BBBBBBBBBBBBB.
..999999999999..
...999....999...
...999....999...
................
................

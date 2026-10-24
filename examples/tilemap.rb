# Tilemap Demo (map / mget / mset / @MAP)
# 矢印キー / WASD: プレイヤー移動（mget による壁判定・コイン/カギ取得・扉解錠）
# Z / Space: 向いている方向の目の前のマスを掘る / 土ブロック(2)を置く (mset)
# X / Enter: ダンジョン暗視パレット切替 (pal)

$px = 32
$py = 48
$dir_x = 1
$dir_y = 0
$flip_x = false
$coins = 0
$keys = 0
$cleared = false
$t = 0
$prev_act = false
$dark_mode = false
$prev_x_btn = false

# タイル番号が壁（通行不可）かどうかを判定
def solid_tile?(tile_id)
  tile_id == 1 || tile_id == 2 || tile_id == 4
end

# 矩形 (x, y, 12x12) の四隅のタイルを mget で調べて移動可能か判定
def can_move?(nx, ny)
  x0 = (nx + 2) / 16
  y0 = (ny + 2) / 16
  x1 = (nx + 13) / 16
  y1 = (ny + 13) / 16

  corners = [[x0, y0], [x1, y0], [x0, y1], [x1, y1]]
  i = 0
  while i < 4
    tx = corners[i][0]
    ty = corners[i][1]
    t = mget(tx, ty)
    # 施錠ドア(4)はカギを持っていれば自動で開く(msetで消す)
    if t == 4 && $keys > 0
      $keys -= 1
      mset(tx, ty, -1)
      t = -1
    end
    return false if solid_tile?(t)
    i += 1
  end
  true
end

def update
  $t += 1

  dx = 0
  dy = 0
  if btn(0)
    dx -= 2
    $dir_x = -1
    $dir_y = 0
    $flip_x = true
  end
  if btn(1)
    dx += 2
    $dir_x = 1
    $dir_y = 0
    $flip_x = false
  end
  if btn(2)
    dy -= 2
    $dir_x = 0
    $dir_y = -1
  end
  if btn(3)
    dy += 2
    $dir_x = 0
    $dir_y = 1
  end

  if dx != 0 && can_move?($px + dx, $py)
    $px += dx
  end
  if dy != 0 && can_move?($px, $py + dy)
    $py += dy
  end

  # プレイヤー中心のセル座標でアイテム回収判定 (mget -> mset)
  cx = ($px + 8) / 16
  cy = ($py + 8) / 16
  under = mget(cx, cy)
  if under == 3
    # コイン(3)を取得して空タイル(-1)に書き換え
    mset(cx, cy, -1)
    $coins += 1
  elsif under == 5
    # カギ(5)を取得
    mset(cx, cy, -1)
    $keys += 1
  elsif under == 6
    $cleared = true
  end

  # Z / Space: 目の前のタイルを掘る(2->-1) または 空マスに土ブロックを置く(-1->2)
  act = btn(4)
  if act && ($prev_act == false)
    tx = cx + $dir_x
    ty = cy + $dir_y
    front = mget(tx, ty)
    if front == 2
      mset(tx, ty, -1)
    elsif front < 0 && (tx != cx || ty != cy)
      mset(tx, ty, 2)
    end
  end
  $prev_act = act

  # X / Enter: パレット切替
  xb = btn(5)
  if xb && ($prev_x_btn == false)
    $dark_mode = ($dark_mode == false)
  end
  $prev_x_btn = xb
end

def draw
  pal()
  cls(1)

  # カメラをプレイヤー中心に追従 (32x16 タイル = 512x256 ピクセル空間)
  cam_x = $px - 120
  cam_x = 0 if cam_x < 0
  cam_x = 256 if cam_x > 256

  # メインゲーム画面領域 (上部 24px は HUD)
  clip(0, 24, 256, 232)
  if $dark_mode
    pal([0, 0, 1, 1, 2, 1, 13, 12, 2, 4, 9, 3, 1, 5, 13, 6])
  end
  camera(cam_x, 0)

  # 背景グリッド装飾
  rectfill(0, 24, 512, 232, 0)

  # タイルマップ一括描画 (32x16 セル)
  map(0, 0, 0, 0, 32, 16)

  # 向いている方向のターゲット枠（掘削・設置カーソル）
  cx = ($px + 8) / 16
  cy = ($py + 8) / 16
  tx = cx + $dir_x
  ty = cy + $dir_y
  front_id = mget(tx, ty)
  cursor_col = (front_id == 2) ? 10 : ((front_id < 0) ? 11 : 8)
  rect(tx * 16 + 1, ty * 16 + 1, 14, 14, cursor_col)

  # プレイヤー描画
  spr("🐰", $px, $py, $flip_x, false)

  # HUD 描画 (camera / clip / pal リセット)
  camera()
  clip()
  pal()

  rectfill(0, 0, 256, 24, 1)
  line(0, 23, 255, 23, 12)
  print_text("COIN:#{$coins} KEY:#{$keys}", 6, 4, 10)
  print_text("CELL:(#{cx},#{cy}) FRONT:#{front_id}", 6, 13, 7)

  # 右上にリアルタイム・ミニマップ (32x16 タイルを 2x1 px で表示)
  mx = 186
  my = 4
  rectfill(mx - 1, my - 1, 66, 18, 0)
  ry = 0
  while ry < 16
    rx = 0
    while rx < 32
      tid = mget(rx, ry)
      if tid >= 0
        mcol = (tid == 1) ? 5 : ((tid == 2) ? 4 : ((tid == 3) ? 10 : ((tid == 4) ? 8 : 11)))
        rectfill(mx + rx * 2, my + ry, 2, 1, mcol)
      end
      rx += 1
    end
    ry += 1
  end
  # ミニマップ上のプレイヤー位置
  rectfill(mx + cx * 2, my + cy, 2, 2, 7)

  if $cleared
    rectfill(44, 108, 168, 36, 1)
    rect(44, 108, 168, 36, 10)
    print_text("🎉 STAGE CLEAR! 🏆", 62, 116, 10)
    print_text("COINS COLLECTED: #{$coins}", 64, 128, 7)
  end

  rectfill(0, 246, 256, 10, 1)
  print_text("MOVE:ARROWS  Z:DIG/BUILD  X:PAL", 6, 247, 6)
end

__END__
# 1: レンガ壁 (破壊不可)
@SPRITE 1
5555555055555550
8888888088888880
8888888088888880
8844488088444880
8888888088888880
8888888088888880
8888888088888880
0000000000000000
5550555555505555
8880888888808888
8880888888808888
4880884448808844
8880888888808888
8880888888808888
8880888888808888
0000000000000000

# 2: ひび割れ土ブロック (Zボタンで掘削・再設置可能)
@SPRITE 2
.44444444444444.
4994499994499994
4944944449449944
4449444044444444
4494440444994494
4444404449444944
4994400444449444
4944044044444444
4440444404499444
4444499440494444
4944944444044994
4494440444449444
4444404499444444
4994044944944994
4444444444444444
.44444444444444.

# 3: コイン / ジェム (重なると回収)
@SPRITE 3
................
......AAAA......
....AA7777AA....
...A77AAAA77A...
..A7AA9999AA7A..
..A7A99AA99A7A..
..A7A9A77A9A7A..
..A7A9A77A9A7A..
..A7A99AA99A7A..
..A7AA9999AA7A..
...A77AAAA77A...
....AA9999AA....
......AAAA......
................
................
................

# 4: 施錠ドア (カギを持っていると開く)
@SPRITE 4
.55555555555555.
5666666666666665
5644444444444465
5649999449999465
5649449449449465
5644444444444465
564444AAAA444465
56444AA00AA44465
56444AA00AA44465
564444A00A444465
564444A00A444465
564444AAAA444465
5649449449449465
5649999449999465
5644444444444465
5555555555555555

# 5: カギ (絵文字スプライト)
@SPRITE 5 🔑

# 6: ゴールトロフィー (絵文字スプライト)
@SPRITE 6 🏆

# 7: 草むら装飾 (通行可能)
@SPRITE 7
................
................
................
................
................
.......B...B....
...B..BB..BB....
..BB..BB.BBB.B..
..BBB.BBBBBB.BB.
.BBBBBBBBBBBBBB.
.33BBBBBBBBBB33.
..3333BBBB3333..
....33333333....
................
................
................

# 32x16 タイルマップ (0/'.' は空タイル、1..7 は各スプライト番号)
@MAP 0 0
................................
................................
11111111111111111111111111111111
1....7..22..3...1......22..3...1
1.......22......1..5...22......1
1...7...22..3...111112211111...1
1.......22..........22.....1...1
111112221111111.....22..3..4...1
1...3222......1.....22.....1...1
1....222..7...1111..11111111...1
1..3..........223.......22.....1
1.......1111..223...7...22..6..1
1..7....15.1..1111......22.....1
1.......13.2............22..3..1
11111111111111111111111111111111
................................

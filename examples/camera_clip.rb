# ==========================================
# Usakame Sample: camera & clip Demo
# 実行コマンド: uk run examples/camera_clip.rb
# ==========================================

$x = 128
$y = 192
$cam_x = 0
$cam_y = 0
$t = 0
$flip_x = false
$shake = 0

WORLD_W = 512
WORLD_H = 320

def update
  $t += 1

  # 矢印キー / WASD でワールド内 (0..512, 0..320) を移動
  speed = btn(5) ? 4 : 2
  if btn(0)
    $x -= speed
    $flip_x = true
  end
  if btn(1)
    $x += speed
    $flip_x = false
  end
  if btn(2)
    $y -= speed
  end
  if btn(3)
    $y += speed
  end

  # Z / Space キーで画面シェイク演出
  if btn(4)
    $shake = 12
  elsif $shake > 0
    $shake -= 1
  end

  $x = 0 if $x < 0
  $x = WORLD_W - 16 if $x > WORLD_W - 16
  $y = 64 if $y < 64
  $y = 208 if $y > 208

  # プレイヤーを中心にカメラを追従させ、ワールド端にクランプ
  target_cx = $x - 120
  target_cy = $y - 144
  target_cx = 0 if target_cx < 0
  target_cx = WORLD_W - 256 if target_cx > WORLD_W - 256
  target_cy = 0 if target_cy < 0
  target_cy = WORLD_H - 256 if target_cy > WORLD_H - 256

  shake_dx = $shake > 0 ? (($t % 2 == 0) ? 3 : -3) : 0
  shake_dy = $shake > 0 ? ((($t / 2) % 2 == 0) ? 2 : -2) : 0

  $cam_x = target_cx + shake_dx
  $cam_y = target_cy + shake_dy
end

def draw_world
  # 遠景の山並み (trifill)
  trifill(40, 224, 140, 120, 240, 224, 2)
  trifill(180, 224, 290, 100, 400, 224, 5)
  trifill(340, 224, 430, 130, 510, 224, 2)

  # 太陽と雲
  circfill(420, 88, 18, 10)
  circ(420, 88, 22 + ($t / 15) % 3, 9)

  # 地面とグリッド目盛り (スクロール感がわかりやすいよう 32px ごとに配置)
  rectfill(0, 224, WORLD_W, 96, 3)
  rectfill(0, 224, WORLD_W, 4, 11)
  i = 0
  while i <= WORLD_W
    line(i, 224, i, 256, 11)
    print_text("#{i}", i + 2, 232, 7) if i % 64 == 0
    i += 32
  end

  # 背景オブジェクト (絵文字スプライト)
  spr("🏰", 32, 208)
  spr("🌲", 80, 208)
  spr("🌲", 160, 208)
  spr("🍎", 220, 208)
  spr("🌲", 280, 208)
  spr("🏠", 350, 208)
  spr("🌲", 410, 208)
  spr("🚩", 472, 208)

  # カメがワールドを往復
  kame_x = 120 + (($t / 2) % 260)
  spr(1, kame_x, 208, false, false)

  # プレイヤー (ウサギ)
  bounce = (($t / 8) % 2 == 0) ? 0 : -2
  spr(0, $x, $y + bounce, $flip_x, false)
end

def draw
  # 1. 画面全体をダークブルーでクリア
  cls(1)

  # 2. camera(cam_x, cam_y) でワールド座標系を描画
  camera($cam_x, $cam_y)
  draw_world

  # 3. camera() で画面固定座標系 (0, 0) に戻して上部HUDを描画
  camera()
  rectfill(0, 0, 256, 34, 0)
  line(0, 34, 255, 34, 12)
  print_text("CAMERA & CLIP DEMO 🐰🐢", 6, 4, 10)
  print_text("POS:(#{$x},#{$y}) CAM:(#{$cam_x},#{$cam_y})", 6, 14, 7)
  print_text("Arrow:Move  X:Dash  Z:Shake", 6, 24, 11)

  # 4. clip(x, y, w, h) のデモ1: 右上ミニスコープ窓 (ウサギ周辺をクリッピング表示)
  scope_x = 180
  scope_y = 40
  scope_w = 68
  scope_h = 52
  clip(scope_x, scope_y, scope_w, scope_h)
  cls(0)
  # スコープ窓の中央にウサギが来るようにカメラを設定
  camera($x - (scope_x + scope_w / 2 - 8), $y - (scope_y + scope_h / 2 - 8))
  draw_world
  # 回転する星エフェクト（スコープ枠でクリッピングされることを確認）
  spr("⭐", $x - 12, $y - 12, false, false, ($t * 4) % 360, 1.5)
  spr("⭐", $x + 16, $y - 8, false, false, ($t * 6) % 360, 1.5)
  camera()
  clip()
  # スコープ窓の白枠とラベル
  rect(scope_x - 1, scope_y - 1, scope_w + 2, scope_h + 2, 7)
  print_text("CLIP SCOPE", scope_x + 4, scope_y + 2, 14)

  # 5. clip(x, y, w, h) のデモ2: 下部の電光掲示板ウィンドウ（文字と図形のクリッピング）
  win_x = 16
  win_y = 228
  win_w = 224
  win_h = 22
  clip(win_x, win_y, win_w, win_h)
  cls(2)
  # ウィンドウ端で切れる大きな円とスクロールテキスト
  circfill(win_x + ($t * 2) % win_w, win_y + 11, 16, 8)
  marquee_x = win_x + win_w - (($t * 2) % (win_w + 220))
  print_text("✨clip()で指定した矩形の内側だけに図形・スプライト・文字が描画されます✨", marquee_x, win_y + 7, 7)
  clip()
  rect(win_x - 1, win_y - 1, win_w + 2, win_h + 2, 10)
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

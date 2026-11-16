# Background Prototype: High-res backdrop (:sky / :training / :mountain) + Pixel-art sprites
# Run: cargo run --bin uk -- run examples/bg_prototype.rb

config(
  width: 640,
  height: 360,
  scale: 1.5,
  sprite_scale: 2.0,
  title: "Usakame BG Prototype (:sky / :training / :mountain)"
)

BG_IDS = [300, 301, 302]
BG_NAMES = [":sky", ":training", ":mountain"]

TILE = 32 # 16px sprite * sprite_scale(2.0) = 32px on screen
GRAVITY = 0.45
JUMP_POWER = -9.2
MOVE_SPEED = 3.4

$bg_idx = 0
$px = 96.0
$py = 220.0
$vx = 0.0
$vy = 0.0
$facing_left = false
$on_ground = false
$cam_x = 0.0
$frame = 0
$score = 0
$coins = []

$player_id = 1
$ground_id = 2
$brick_id = 3
$coin_id = 4

def reset_coins
  $coins = []
  my = 0
  while my < 12
    mx = 0
    while mx < 40
      tile = mget(mx, my)
      if tile == $coin_id
        $coins << { x: mx * TILE, y: my * TILE, alive: true }
      end
      mx += 1
    end
    my += 1
  end
end

def solid_at?(wx, wy)
  tx = (wx / TILE).floor
  ty = (wy / TILE).floor
  return false if ty < 0 || tx < 0
  tile = mget(tx, ty)
  return false if tile.nil?
  tile == $ground_id || tile == $brick_id
end

def solid_box?(x, y, w, h)
  solid_at?(x, y) ||
    solid_at?(x + w - 1.0, y) ||
    solid_at?(x, y + h - 1.0) ||
    solid_at?(x + w - 1.0, y + h - 1.0)
end

def init
  $player_id = spr_id(:player)
  $ground_id = spr_id(:ground)
  $brick_id = spr_id(:brick)
  $coin_id = spr_id(:coin)
  reset_coins
end

def update
  $frame += 1

  # Switch background with X / Enter (btnp 5)
  if btnp(5)
    $bg_idx = ($bg_idx + 1) % BG_IDS.size
  end

  # Horizontal movement
  $vx = 0.0
  if btn(0)
    $vx = -MOVE_SPEED
    $facing_left = true
  elsif btn(1)
    $vx = MOVE_SPEED
    $facing_left = false
  end

  # Jump
  if $on_ground && (btnp(4) || btnp(2))
    $vy = JUMP_POWER
    $on_ground = false
  end

  # Apply gravity
  $vy += GRAVITY
  $vy = 10.0 if $vy > 10.0

  # Move X with tile collision (hitbox: 24x28 inside 32x32 sprite)
  nx = $px + $vx
  nx = 0.0 if nx < 0.0
  nx = 1252.0 if nx > 1252.0
  if !solid_box?(nx + 4.0, $py + 2.0, 24.0, 28.0)
    $px = nx
  end

  # Move Y with tile collision
  ny = $py + $vy
  if $vy >= 0.0
    if solid_box?($px + 4.0, ny + 2.0, 24.0, 28.0)
      ty = ((ny + 30.0) / TILE).floor.to_i
      $py = (ty * TILE - 30).to_f
      $vy = 0.0
      $on_ground = true
    else
      $py = ny
      $on_ground = false
    end
  else
    if solid_box?($px + 4.0, ny + 2.0, 24.0, 28.0)
      ty = ((ny + 2.0) / TILE).floor.to_i
      $py = ((ty + 1) * TILE - 2).to_f
      $vy = 0.0
    else
      $py = ny
    end
  end

  # Collect coins
  $coins.each do |c|
    next unless c[:alive]
    dx = ($px + 16) - (c[:x] + 16)
    dy = ($py + 16) - (c[:y] + 16)
    if dx * dx + dy * dy < 24 * 24
      c[:alive] = false
      $score += 100
    end
  end

  # Smooth camera follow
  target_cam = $px - 280.0
  target_cam = 0.0 if target_cam < 0.0
  max_cam = 640.0
  target_cam = max_cam if target_cam > max_cam
  $cam_x += (target_cam - $cam_x) * 0.15
end

def draw
  cls(0)

  # 1. Draw parallax looping background (scale: 1.0 to keep 640x360)
  camera(0, 0)
  bg_id = BG_IDS[$bg_idx]
  scroll_x = ($cam_x * 0.35).to_i % 640
  spr(bg_id, -scroll_x, 0, false, false, 0.0, 1.0)
  spr(bg_id, 640 - scroll_x, 0, false, false, 0.0, 1.0)

  # 2. Draw world tiles & sprites with camera
  camera($cam_x.to_i, 0)

  # Draw @MAP terrain (ground & bricks, skip coin marker tile)
  my = 0
  while my < 12
    mx = 0
    while mx < 40
      t = mget(mx, my)
      if t == $ground_id || t == $brick_id
        spr(t, mx * TILE, my * TILE)
      end
      mx += 1
    end
    my += 1
  end

  # Draw coins with gentle bobbing
  bob = (sin($frame * 0.1) * 3.0).to_i
  $coins.each do |c|
    next unless c[:alive]
    spr(:coin, c[:x], c[:y] + bob)
  end

  # Draw player sprite
  spr($player_id, $px, $py, $facing_left)

  # 3. HUD (fixed to screen)
  camera(0, 0)
  rectfill(8, 8, 560, 48, 1)
  print_text("BG: #{BG_NAMES[$bg_idx]}  SCORE: #{$score}", 16, 12, 7)
  print_text("[Arrow] Move  [Z/Up] Jump  [X/Enter] Switch BG", 16, 30, 6)
end

init

__END__

@SPRITE :player 16x16
......111..111..
.....1771.1771..
.....17A1.17A1..
.....177111771..
....17777777771.
...1777177717771
...177777A777771
....17777777771.
.....188888881..
....18887778881.
....17718881771.
.....11.888.11..
.......18.81....
.......17.71....
......11...11...
................

@SPRITE :ground 16x16
BBBBBBBBBBBBBBBB
33B333B333B333B3
3333333333333333
1111111111111111
5444454444544445
4454444544445444
4444544445444454
5444445444445444
4454444454444454
4444544444544444
5444445444445444
4454444454444454
4444544444544444
5444445444445444
4444444444444444
0000000000000000

@SPRITE :brick 16x16
1111111111111111
1999999199999991
19AA99919AA99991
1999999199999991
1111111111111111
1999199999991991
199919AA99991991
1999199999991991
1111111111111111
1999999199999991
19AA99919AA99991
1999999199999991
1111111111111111
1999199999991991
1999199999991991
1111111111111111

@SPRITE :coin 16x16
......1111......
....11AAAA11....
...1AA9999AA1...
..1A9A7777A9A1..
..1A9A7AA7A9A1..
.1A9A7AAAA7A9A1.
.1A9A7AAAA7A9A1.
.1A9A7AAAA7A9A1.
.1A9A7AAAA7A9A1.
.1A9A7AAAA7A9A1.
..1A9A7AA7A9A1..
..1A9A7777A9A1..
...1AA9999AA1...
....11AAAA11....
......1111......
................

@MAP 0 0
G = :ground
B = :brick
C = :coin
........................................
........................................
........................................
........................................
............C.C...........C.C...........
...........BBBBB.........BBBBB..........
......C.............................C...
.....BBB...........C.C.............BBB..
..................BBBBB.......C.........
..........C..................BBB........
GGGGGGGGGGGGGGGG.GGGGGGGGGGGGGGGG.GGGGGG
GGGGGGGGGGGGGGGG.GGGGGGGGGGGGGGGG.GGGGGG

@PNG 300 bg_sky.png
@PNG 301 bg_training.png
@PNG 302 bg_mountain.png

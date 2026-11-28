# Background Effect Verification Demo (256x256 default screen):
# - dim / tint / filter (:linear vs :nearest) / loop_x / parallax scroll
# Run: cargo run --bin uk -- run examples/bg_hd2d_demo.rb

config(
  title: "BG Effect Demo (dim / tint / filter)"
)

BG_IDS = [300, 301, 302]
BG_NAMES = [":sky", ":training", ":mountain"]

# Effect presets to compare dim / tint / filter side-by-side
EFFECT_PRESETS = [
  { label: "dim:0.0 (Raw)",             dim: 0.0,  tint: "#FFFFFF", filter: :linear,  scale: 1.0 },
  { label: "dim:0.45 (Pop Sprites!)",   dim: 0.45, tint: "#FFFFFF", filter: :linear,  scale: 1.0 },
  { label: "dim:0.35 + Cool Tint",      dim: 0.35, tint: "#88B8FF", filter: :linear,  scale: 1.0 },
  { label: "dim:0.30 + Warm Sunset",    dim: 0.30, tint: "#FFB078", filter: :linear,  scale: 1.0 },
  { label: "dim:0.20 + Linear (x1.25)", dim: 0.20, tint: "#FFFFFF", filter: :linear,  scale: 1.25 },
  { label: "dim:0.20 + Nearest(x1.25)", dim: 0.20, tint: "#FFFFFF", filter: :nearest, scale: 1.25 }
]

TILE = 16
MAP_W = 40
MAP_H = 16
GRAVITY = 0.25
JUMP_POWER = -5.4
MOVE_SPEED = 2.0

$player_id = 1
$ground_id = 2
$dirt_id = 3
$brick_id = 4
$coin_id = 5

$bg_idx = 2 # Start with :mountain
$fx_idx = 1 # Start with dim: 0.45
$px = 48.0
$py = 180.0
$vx = 0.0
$vy = 0.0
$facing_left = false
$on_ground = false
$coyote_timer = 0
$jump_buffer = 0
$cam_x = 0.0
$frame = 0
$score = 0
$coins = []

def reset_coins
  $coins = []
  my = 0
  while my < MAP_H
    mx = 0
    while mx < MAP_W
      if mget(mx, my) == $coin_id
        $coins << { x: mx * TILE, y: my * TILE, alive: true }
      end
      mx += 1
    end
    my += 1
  end
end

def solid_at?(wx, wy)
  tx = (wx / TILE).floor.to_i
  ty = (wy / TILE).floor.to_i
  return false if ty < 0 || tx < 0
  tile = mget(tx, ty)
  return false if tile.nil?
  tile == $ground_id || tile == $dirt_id || tile == $brick_id
end

def solid_box?(x, y, w, h)
  solid_at?(x, y) ||
    solid_at?(x + w - 0.01, y) ||
    solid_at?(x, y + h - 0.01) ||
    solid_at?(x + w - 0.01, y + h - 0.01)
end

def init
  $player_id = spr_id(:player)
  $ground_id = spr_id(:ground)
  $dirt_id = spr_id(:dirt)
  $brick_id = spr_id(:brick)
  $coin_id = spr_id(:coin)
  reset_coins
end

def update
  $frame += 1

  # Switch effect preset (X)
  if btnp(2)
    $fx_idx = ($fx_idx + 1) % EFFECT_PRESETS.size
  end

  # Switch backdrop image (Down)
  if btnp(:down)
    $bg_idx = ($bg_idx + 1) % BG_IDS.size
  end

  # Horizontal movement
  $vx = 0.0
  if btn(:left)
    $vx = -MOVE_SPEED
    $facing_left = true
  elsif btn(:right)
    $vx = MOVE_SPEED
    $facing_left = false
  end

  # Jump with buffer & coyote time
  if btnp(1) || btnp(:up)
    $jump_buffer = 6
  elsif $jump_buffer > 0
    $jump_buffer -= 1
  end

  if $on_ground
    $coyote_timer = 6
  elsif $coyote_timer > 0
    $coyote_timer -= 1
  end

  if $jump_buffer > 0 && $coyote_timer > 0
    $vy = JUMP_POWER
    $on_ground = false
    $coyote_timer = 0
    $jump_buffer = 0
  end

  $vy += GRAVITY
  $vy = 5.5 if $vy > 5.5

  # Move X (hitbox: 12x14 at +2,+2 inside 16x16 sprite)
  nx = $px + $vx
  nx = 0.0 if nx < 0.0
  max_px = (MAP_W * TILE - 14).to_f
  nx = max_px if nx > max_px
  if !solid_box?(nx + 2.0, $py + 2.0, 12.0, 14.0)
    $px = nx
  end

  # Move Y
  ny = $py + $vy
  if $vy >= 0.0
    if solid_box?($px + 2.0, ny + 2.0, 12.0, 14.0)
      ty = ((ny + 15.99) / TILE).floor.to_i
      $py = (ty * TILE - 16).to_f
      $vy = 0.0
      $on_ground = true
    else
      $py = ny
      $on_ground = false
    end
  else
    if solid_box?($px + 2.0, ny + 2.0, 12.0, 14.0)
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
    dx = ($px + 8.0) - (c[:x] + 8.0)
    dy = ($py + 8.0) - (c[:y] + 8.0)
    if dx * dx + dy * dy < 12.0 * 12.0
      c[:alive] = false
      $score += 100
    end
  end

  # Smooth camera follow
  target_cam = $px - 112.0
  target_cam = 0.0 if target_cam < 0.0
  max_cam = (MAP_W * TILE - 256).to_f
  target_cam = max_cam if target_cam > max_cam
  $cam_x += (target_cam - $cam_x) * 0.15
end

def draw
  cls(0)

  # 1. Backdrop with dim / tint / filter & seamless parallax loop
  fx = EFFECT_PRESETS[$fx_idx]
  y_off = fx[:scale] > 1.0 ? -32.0 : 0.0
  bg(
    BG_IDS[$bg_idx],
    0,
    y_off,
    {
      scale: fx[:scale],
      scroll_x: $cam_x * 0.4,
      loop_x: true,
      dim: fx[:dim],
      tint: fx[:tint],
      filter: fx[:filter]
    }
  )

  # 2. Crisp pixel-art terrain & sprites
  camera($cam_x.to_i, 0)

  start_mx = ($cam_x / TILE).floor.to_i
  start_mx = 0 if start_mx < 0
  end_mx = start_mx + 17
  end_mx = MAP_W - 1 if end_mx >= MAP_W

  my = 0
  while my < MAP_H
    mx = start_mx
    while mx <= end_mx
      t = mget(mx, my)
      if t == $ground_id || t == $dirt_id || t == $brick_id
        spr(t, mx * TILE, my * TILE)
      end
      mx += 1
    end
    my += 1
  end

  bob = (sin($frame * 0.1) * 2.0).to_i
  $coins.each do |c|
    next unless c[:alive]
    spr($coin_id, c[:x], c[:y] + bob)
  end

  spr($player_id, $px, $py, $facing_left)

  # 3. HUD
  camera(0, 0)
  rectfill(4, 4, 248, 32, 1)
  print_text("BG: #{BG_NAMES[$bg_idx]}", 8, 7, 7)
  print_text("FX: #{fx[:label]}", 8, 16, 10)
  print_text("[X]Next FX  [Down]Next BG", 8, 25, 6)
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
4454444454444454
4444544444544444

@SPRITE :dirt 16x16
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
4454444454444454
4444544444544444
5444445444445444
4454444454444454
4444544444544444
5444445444445444

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
D = :dirt
B = :brick
C = :coin
........................................
........................................
........................................
........................................
........................................
........................................
........................................
.......................G................
.......................D................
............C.C...........C.C...........
...........BBBBB.........BBBBB..........
......C................G............C...
.....BBB...........C.C.D...........BBB..
..................BBBBBD......C.........
..........C............D.....BBB........
GGGGGGGGGGGGGGGG.GGGGGGDGGGGGGGGG.GGGGGG

@PNG 300 bg_sky.png
@PNG 301 bg_training.png
@PNG 302 bg_mountain.png

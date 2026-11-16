# Preset Background Modes Demo (256x256)
# Run: cargo run --bin uk -- run examples/bg_presets.rb
#
# Controls:
#   [Z / Space] Switch Scroll Mode (Fixed / H-Scroll / H+V-Scroll / V-Scroll)
#   [X / Enter] Switch Preset BG (8 presets)
#   [Arrow]     Move foreground sprite

config(
  title: "Usakame Preset BG Modes"
)

PRESETS = [
  :sky,
  :mountain,
  :forest,
  :cave,
  :city,
  :space,
  :cyber,
  :training
]

MODES = [
  "1. FIXED",
  "2. H-SCROLL",
  "3. H+V-SCROLL",
  "4. V-SCROLL"
]

$preset_idx = 0
$mode_idx = 1
$sx = 0.0
$sy = 0.0
$px = 120.0
$py = 136.0
$facing_left = false
$frame = 0

def init
  $player_id = spr_id(:player)
end

def update
  $frame += 1

  # Switch mode with Z / Space (btnp 4)
  if btnp(4)
    $mode_idx = ($mode_idx + 1) % MODES.size
  end

  # Switch preset with X / Enter (btnp 5)
  if btnp(5)
    $preset_idx = ($preset_idx + 1) % PRESETS.size
  end

  # Auto scroll according to current mode
  if $mode_idx == 1
    $sx += 0.8
  elsif $mode_idx == 2
    $sx += 0.8
    $sy -= 0.6
  elsif $mode_idx == 3
    $sy -= 0.8
  end

  # Move foreground sprite with Arrow keys
  spd = 2.0
  if btn(0)
    $px -= spd
    $facing_left = true
  end
  if btn(1)
    $px += spd
    $facing_left = false
  end
  if btn(2)
    $py -= spd
  end
  if btn(3)
    $py += spd
  end
  $px = 8.0 if $px < 8.0
  $px = 232.0 if $px > 232.0
  $py = 44.0 if $py < 44.0
  $py = 232.0 if $py > 232.0
end

def draw
  cls(0)
  preset = PRESETS[$preset_idx]
  seamless_xy = (preset == :space || preset == :training)

  if $mode_idx == 0
    # 1. Fixed
    bg(preset, dim: 0.25)
  elsif $mode_idx == 1
    # 2. Horizontal Scroll
    if seamless_xy
      bg(preset, dim: 0.25, scroll_x: $sx, loop_x: true)
    else
      bg(preset, dim: 0.25, scroll_x: $sx, mirror_x: true)
    end
  elsif $mode_idx == 2
    # 3. Horizontal + Vertical Scroll
    if seamless_xy
      bg(preset, dim: 0.25, scroll_x: $sx, scroll_y: $sy, loop_x: true, loop_y: true)
    else
      bg(preset, dim: 0.25, scroll_x: $sx, scroll_y: $sy, mirror_x: true, mirror_y: true)
    end
  else
    # 4. Vertical Scroll
    if seamless_xy
      bg(preset, dim: 0.25, scroll_y: $sy, loop_y: true)
    else
      bg(preset, dim: 0.25, scroll_y: $sy, mirror_y: true)
    end
  end

  # Foreground sprite
  bob = sin($frame * 0.12) * 2.0
  spr($player_id, $px, $py + bob, $facing_left)

  # HUD
  rectfill(4, 4, 248, 34, 0)
  rect(4, 4, 248, 34, 7)
  print_text("MODE: #{MODES[$mode_idx]}", 10, 8, 10)
  print_text("BG: :#{preset}  (#{$preset_idx + 1}/#{PRESETS.size})", 10, 17, 7)
  print_text("[Z]Mode  [X]Preset  [Arrow]Move", 10, 26, 6)
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

# Mirror-Loop Background Demo (256x256):
# Demonstrates `mirror_x: true` for seamless background looping without editing images.
# Run: cargo run --bin uk -- run examples/bg_mirror_demo.rb

config(
  title: "Mirror Loop Demo (mirror_x: true)"
)

BG_IDS = [300, 301]
BG_NAMES = [":mountain", ":sky"]

$bg_idx = 0
$mirror_on = true
$auto_scroll = 0.0
$manual_offset = 0.0

def update
  # Toggle mirror_x with X
  if btnp(2)
    $mirror_on = !$mirror_on
  end

  # Switch backdrop with Down
  if btnp(:down)
    $bg_idx = ($bg_idx + 1) % BG_IDS.size
  end

  # Auto-scroll + manual control with Left / Right
  $auto_scroll += 1.0
  $manual_offset -= 2.5 if btn(:left)
  $manual_offset += 2.5 if btn(:right)
end

def draw
  cls(0)

  scroll = $auto_scroll + $manual_offset
  bg(BG_IDS[$bg_idx], 0, 0, {
    scroll_x: scroll,
    loop_x: true,
    mirror_x: $mirror_on,
    dim: 0.3,
    filter: :linear
  })

  # Foreground sprite
  spr(:player, 120, 192)

  # Ground strip
  x = 0
  while x < 256
    spr(:ground, x, 208)
    spr(:ground, x, 224)
    spr(:ground, x, 240)
    x += 16
  end

  # HUD
  rectfill(4, 4, 248, 32, 1)
  mode_label = $mirror_on ? "mirror_x: true (Seamless)" : "mirror_x: false (Seam visible)"
  print_text("BG: #{BG_NAMES[$bg_idx]}", 8, 7, 7)
  print_text(mode_label, 8, 16, $mirror_on ? 11 : 8)
  print_text("[X]Toggle Mirror [Down]BG [L/R]Scroll", 8, 25, 6)
end

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

@PNG 300 bg_mountain.png
@PNG 301 bg_sky.png

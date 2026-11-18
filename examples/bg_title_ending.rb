# Title & Ending Screen Demo using `bg` and Scene Classes (256x256)
# Run: cargo run --bin uk -- run examples/bg_title_ending.rb
#
# Demonstrates:
#   - Class-based scene management (`TitleScene`, `PlayScene`, `EndingScene` via `run`)
#   - Title screen with scrolling preset BG, fade-in (`alpha`), and dimmed backdrop (`dim`)
#   - In-game parallax BG (`scroll_x` + `mirror_x`)
#   - Ending credits with cross-fading BGs (sunset `:sky` -> starry `:space`)
#   - Note: Replace preset symbols (e.g. `:city`) with `@BG :title_bg path/to/img.png`
#           in `__END__` to use your own custom title/ending illustrations.

config(
  title: "Usakame BG Title & Ending"
)

def draw_shadow_text(text, x, y, col)
  print_text(text, x + 1, y + 1, 0)
  print_text(text, x, y, col)
end

class TitleScene
  def initialize
    @frame = 0
    @hero_id = spr_id(:hero)
  end

  def update
    @frame += 1

    if btnp(4)
      run PlayScene.new
    elsif btnp(5)
      # Shortcut to preview ending directly
      run EndingScene.new
    end
  end

  def draw
    cls(0)

    # Fade-in background over 45 frames
    alpha = @frame / 45.0
    alpha = 1.0 if alpha > 1.0

    # Custom @BG image can be used here instead of `:city`:
    #   bg(:title_bg, fit: :screen, dim: 0.25, alpha: alpha)
    bg(:city, dim: 0.35, scroll_x: @frame * 0.35, mirror_x: true, alpha: alpha)

    # Title logo panel
    rectfill(28, 42, 200, 56, 1)
    rect(28, 42, 200, 56, 7)
    rect(30, 44, 196, 52, 12)
    draw_shadow_text("USAKAME QUEST", 89, 58, 10)
    draw_shadow_text("BG TITLE & ENDING DEMO", 62, 74, 7)

    # Animated hero sprite
    bob = sin(@frame * 0.12) * 2.0
    spr(@hero_id, 120, 130 + bob, false)

    # Blinking prompt
    if (@frame / 24) % 2 == 0
      draw_shadow_text("PRESS [Z] TO START", 74, 186, 10)
    end
    draw_shadow_text("[X] PREVIEW ENDING", 74, 206, 6)
  end
end

class PlayScene
  def initialize
    @frame = 0
    @hero_id = spr_id(:hero)
    @star_id = spr_id(:star)
    @px = 40.0
    @py = 192.0
    @vy = 0.0
    @on_ground = true
    @facing_left = false
    @stars = [
      [96.0, 168.0, false],
      [152.0, 144.0, false],
      [208.0, 176.0, false]
    ]
    @collected = 0
  end

  def update
    @frame += 1

    spd = 2.0
    if btn(0)
      @px -= spd
      @facing_left = true
    end
    if btn(1)
      @px += spd
      @facing_left = false
    end

    @px = 8.0 if @px < 8.0
    @px = 232.0 if @px > 232.0

    # Jump with Z / Space / Up
    if (btnp(4) || btnp(2)) && @on_ground
      @vy = -4.2
      @on_ground = false
    end

    @vy += 0.22
    @py += @vy
    if @py >= 192.0
      @py = 192.0
      @vy = 0.0
      @on_ground = true
    end

    # Collect stars
    i = 0
    while i < @stars.size
      st = @stars[i]
      if !st[2]
        dx = (@px + 8.0) - (st[0] + 4.0)
        dy = (@py + 8.0) - (st[1] + 4.0)
        if dx * dx + dy * dy < 169.0
          st[2] = true
          @collected += 1
        end
      end
      i += 1
    end

    if @collected >= @stars.size || btnp(5)
      run EndingScene.new
    end
  end

  def draw
    cls(0)

    # Parallax background matching player position
    bg(:mountain, dim: 0.30, scroll_x: @px * 0.4, mirror_x: true)

    # Ground
    rectfill(0, 208, 256, 48, 3)
    rectfill(0, 208, 256, 3, 11)

    # Stars
    i = 0
    while i < @stars.size
      st = @stars[i]
      if !st[2]
        bob = sin(@frame * 0.15 + i) * 2.0
        spr(@star_id, st[0], st[1] + bob, false)
      end
      i += 1
    end

    # Hero
    spr(@hero_id, @px, @py, @facing_left)

    # HUD
    rectfill(4, 4, 248, 28, 0)
    rect(4, 4, 248, 28, 7)
    print_text("STARS: #{@collected}/#{@stars.size}  [ARROWS] MOVE  [Z] JUMP", 10, 10, 7)
    print_text("COLLECT ALL STARS OR PRESS [X] -> ENDING", 10, 20, 10)
  end
end

class EndingScene
  CREDITS = [
    "USAKAME QUEST",
    "",
    "- STAFF -",
    "DIRECTOR : YOU",
    "PROGRAM  : RUBY + MRUBYEDGE",
    "GRAPHICS : USAKAME BG & SPRITE",
    "MUSIC    : RETRO SFX",
    "",
    "SPECIAL THANKS",
    "ALL RETRO GAME FANS",
    "",
    "THANK YOU FOR PLAYING!"
  ]

  def initialize
    @end_timer = 0
    @hero_id = spr_id(:hero)
  end

  def update
    @end_timer += 1
    if btnp(4) && @end_timer > 30
      run TitleScene.new
    end
  end

  def draw
    cls(0)

    # Cross-fade from sunset sky (`:sky` + warm tint) to starry `:space`
    t = (@end_timer - 60) / 180.0
    t = 0.0 if t < 0.0
    t = 1.0 if t > 1.0

    if t < 1.0
      bg(:sky, dim: 0.25, tint: "#FF9966", scroll_x: @end_timer * 0.2, mirror_x: true, alpha: 1.0 - t)
    end
    if t > 0.0
      bg(:space, dim: 0.20, scroll_y: -@end_timer * 0.4, loop_y: true, alpha: t)
    end

    # Scrolling credits
    base_y = 240.0 - @end_timer * 0.45
    i = 0
    while i < CREDITS.size
      line = CREDITS[i]
      cy = base_y + i * 18
      if cy > -12 && cy < 260 && line.size > 0
        cx = 128 - line.size * 3
        col = (i == 0 || i == CREDITS.size - 1) ? 10 : 7
        draw_shadow_text(line, cx, cy, col)
      end
      i += 1
    end

    # Hero watching the sky at the bottom
    bob = sin(@end_timer * 0.08) * 1.5
    spr(@hero_id, 120, 208 + bob, false)

    if @end_timer > 90 && (@end_timer / 24) % 2 == 0
      draw_shadow_text("PRESS [Z] FOR TITLE", 71, 236, 12)
    end
  end
end

run TitleScene.new

__END__
# Optional custom high-res background example:
# @BG :title_bg assets/bg/city.jpg

@SPRITE :hero [16x16]
................
.....777777.....
....77777777....
....77077077....
....77777777....
.....778877.....
....CCCCCCCCC...
...CC7CCCCC7CC..
...CC7CCCCC7CC..
.....CCCCCC.....
.....CCCCCC.....
.....CC..CC.....
.....CC..CC.....
....444..444....
................
................

@SPRITE :star [8x8]
...AA...
...AA...
.AAAAAA.
AAAAAAAA
.AAAAAA.
..AAAA..
.AA..AA.
AA....AA

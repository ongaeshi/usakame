# ==============================================================================
# Usakame Resource & Live Play Viewer (Phase 1)
# - Resolution: 480x320 (scale: 2.0, text_size: 8)
# - Tabs: [1:PLAY] [2:SPRITE] [3:MAP] [4:SOUND]
# - Hot-Reload: Automatic monitoring via file_mtime
# ==============================================================================
config(
  width: 480,
  height: 320,
  scale: 2.0,
  text_size: 8,
  title: "Usakame Resource Viewer"
)
show_mouse(true)

HEX_DIGITS = "0123456789ABCDEF"
VIEWER_BANK = 3

def text(s, x, y, c = 7)
  print_text(s.to_s, x, y, c)
end

def to_hex2(n)
  v = n.to_i
  v = 0 if v < 0
  v = 255 if v > 255
  HEX_DIGITS[(v >> 4) & 15] + HEX_DIGITS[v & 15]
end

def pad3(n)
  v = n.to_i
  v = 0 if v < 0
  if v < 10
    "00#{v}"
  elsif v < 100
    "0#{v}"
  else
    v.to_s
  end
end

def truncate_str(s, max_len)
  str = s.to_s
  if str.length <= max_len
    str
  else
    str[0, max_len]
  end
end

def base_path_without_rb(path)
  if path.length > 3 && path[path.length - 3, 3] == ".rb"
    path[0, path.length - 3]
  else
    path
  end
end

def parse_hex_digit_char(ch)
  return nil if !ch || ch.length == 0
  b = ch.bytes[0]
  if b >= 48 && b <= 57
    b - 48
  elsif b >= 65 && b <= 70
    b - 55
  elsif b >= 97 && b <= 102
    b - 87
  else
    nil
  end
end

def is_ascii_integer_str(s)
  return false if !s || s.length == 0
  i = 0
  while i < s.length
    b = s.bytes[i]
    return false if b < 48 || b > 57
    i += 1
  end
  true
end

def parse_wxh_token(tok)
  parts = tok.split("x")
  return nil if parts.size != 2
  return nil if !is_ascii_integer_str(parts[0]) || !is_ascii_integer_str(parts[1])
  w = parts[0].to_i
  h = parts[1].to_i
  return nil if w <= 0 || h <= 0 || w > 128 || h > 128
  [w, h]
end

def extract_tail_section(content)
  return "" if !content
  lines = content.split("\n")
  has_end = false
  tail_lines = []
  i = 0
  while i < lines.size
    line = lines[i].split("\r").join("")
    if has_end
      tail_lines << line
    elsif line.strip == "__END__"
      has_end = true
    end
    i += 1
  end
  if has_end
    tail_lines.join("\n")
  else
    content
  end
end

# ==============================================================================
# Playable Embedded Demo Scene for [1:PLAY] Tab
# ==============================================================================
class PlayDemoScene
  attr_accessor :x, :y, :vx, :vy, :hp, :max_hp, :state, :dir, :anim_t, :atk_t, :inv_t, :enemies, :items

  def initialize
    reset_game
  end

  def reset_game
    @x = 120.0
    @y = 128.0
    @vx = 0.0
    @vy = 0.0
    @hp = 5
    @max_hp = 5
    @state = :idle
    @dir = 1
    @anim_t = 0
    @atk_t = 0
    @inv_t = 0
    $score = 0
    $coins = 0
    $wave = 1
    $kills = 0
    $cam_x = 0
    $cam_y = 0
    $t = 0
    @enemies = [
      { kind: :slime, x: 44.0, y: 56.0, vx: 0.6, vy: 0.4, hp: 2, pal: 2, w: 16 },
      { kind: :slime, x: 188.0, y: 68.0, vx: -0.5, vy: 0.5, hp: 2, pal: 2, w: 16 },
      { kind: :slime, x: 56.0, y: 188.0, vx: 0.5, vy: -0.6, hp: 2, pal: 2, w: 16 },
      { kind: :golem, x: 172.0, y: 164.0, vx: -0.35, vy: -0.3, hp: 6, pal: 3, w: 32 }
    ]
    @items = [
      { kind: :coin, x: 80.0, y: 64.0 },
      { kind: :coin, x: 168.0, y: 64.0 },
      { kind: :coin, x: 80.0, y: 184.0 },
      { kind: :chest, x: 120.0, y: 64.0 }
    ]
    @sparks = []
  end

  def spawn_wave
    $wave += 1
    count = 2 + ($wave % 3)
    i = 0
    while i < count
      ex = 32.0 + rand(176)
      ey = 40.0 + rand(160)
      if (ex - @x).abs + (ey - @y).abs < 48
        ex = 36.0
        ey = 44.0
      end
      is_boss = (i == 0 && $wave % 2 == 0)
      @enemies << {
        kind: is_boss ? :golem : :slime,
        x: ex,
        y: ey,
        vx: (rand(2) == 0 ? 0.6 : -0.6),
        vy: (rand(2) == 0 ? 0.5 : -0.5),
        hp: is_boss ? 6 : 2,
        pal: is_boss ? 3 : 2,
        w: is_boss ? 32 : 16
      }
      i += 1
    end
    @items << { kind: :coin, x: 48.0 + rand(152), y: 48.0 + rand(152) }
    @items << { kind: :coin, x: 48.0 + rand(152), y: 48.0 + rand(152) }
  end

  def add_sparks(px, py, col, cnt)
    i = 0
    while i < cnt
      ang = rand(628) * 0.01
      spd = 0.8 + rand(20) * 0.1
      @sparks << {
        x: px,
        y: py,
        vx: cos(ang) * spd,
        vy: sin(ang) * spd,
        life: 12 + rand(10),
        col: col
      }
      i += 1
    end
  end

  def update
    $t += 1
    @anim_t += 1
    @inv_t -= 1 if @inv_t > 0
    @atk_t -= 1 if @atk_t > 0

    if @hp <= 0
      @state = :dead
      if btnp(4) || btnp(5)
        sfx(:coin, -1, 0.35)
        reset_game
      end
      return
    end

    # Movement input (Pad 0..3)
    dx = 0.0
    dy = 0.0
    dx -= 1.0 if btn(0)
    dx += 1.0 if btn(1)
    dy -= 1.0 if btn(2)
    dy += 1.0 if btn(3)

    if dx != 0.0 && dy != 0.0
      dx *= 0.7071
      dy *= 0.7071
    end

    spd = 1.6
    @vx = dx * spd
    @vy = dy * spd
    @dir = -1 if dx < 0
    @dir = 1 if dx > 0

    @x += @vx
    @y += @vy
    @x = 18.0 if @x < 18.0
    @x = 222.0 if @x > 222.0
    @y = 34.0 if @y < 34.0
    @y = 222.0 if @y > 222.0

    # Attack on Button A (4) or Button B (5)
    if (btnp(4) || btnp(5)) && @atk_t == 0
      @atk_t = 12
      sfx(:hit, -1, 0.35)
      slash_x = @x + (@dir * 16)
      slash_y = @y
      add_sparks(slash_x + 8, slash_y + 8, 10, 6)

      i = 0
      while i < @enemies.size
        e = @enemies[i]
        ew = e[:w] * 0.5
        if (e[:x] + ew - (slash_x + 8)).abs < (16 + ew * 0.6) && (e[:y] + ew - (slash_y + 8)).abs < (16 + ew * 0.6)
          e[:hp] -= 1
          e[:vx] = @dir * 1.8
          add_sparks(e[:x] + ew, e[:y] + ew, 8, 8)
          if e[:hp] <= 0
            $score += (e[:kind] == :golem ? 250 : 100)
            $kills += 1
            sfx(:explosion, -1, 0.4)
            @items << { kind: :coin, x: e[:x] + 4, y: e[:y] + 4 }
          end
        end
        i += 1
      end
      @enemies.reject! { |e| e[:hp] <= 0 }
    end

    if @atk_t > 0
      @state = :attack
    elsif dx != 0.0 || dy != 0.0
      @state = :walk
    else
      @state = :idle
    end

    # Update enemies
    i = 0
    while i < @enemies.size
      e = @enemies[i]
      # Subtle homing + bounce inside arena
      tx = @x - e[:x]
      ty = @y - e[:y]
      dist = sqrt(tx * tx + ty * ty)
      if dist > 1.0
        espd = e[:kind] == :golem ? 0.45 : 0.72
        e[:vx] = e[:vx] * 0.92 + (tx / dist) * espd * 0.08
        e[:vy] = e[:vy] * 0.92 + (ty / dist) * espd * 0.08
      end
      e[:x] += e[:vx]
      e[:y] += e[:vy]
      max_pos = 238.0 - e[:w]
      if e[:x] < 18.0
        e[:x] = 18.0
        e[:vx] = -e[:vx]
      elsif e[:x] > max_pos
        e[:x] = max_pos
        e[:vx] = -e[:vx]
      end
      if e[:y] < 34.0
        e[:y] = 34.0
        e[:vy] = -e[:vy]
      elsif e[:y] > max_pos
        e[:y] = max_pos
        e[:vy] = -e[:vy]
      end

      # Player collision
      hr = e[:w] * 0.42
      if @inv_t == 0 && (e[:x] + hr - (@x + 8)).abs < (6 + hr) && (e[:y] + hr - (@y + 8)).abs < (6 + hr)
        @hp -= 1
        @inv_t = 40
        sfx(:damage, -1, 0.4)
        add_sparks(@x + 8, @y + 8, 8, 10)
      end
      i += 1
    end

    # Collect items
    i = 0
    while i < @items.size
      it = @items[i]
      if (it[:x] - (@x + 4)).abs < 12 && (it[:y] - (@y + 4)).abs < 12
        it[:collected] = true
        if it[:kind] == :chest
          $score += 150
          $coins += 5
          @hp = @max_hp if @hp < @max_hp
        else
          $score += 50
          $coins += 1
        end
        sfx(:coin, -1, 0.35)
        add_sparks(it[:x] + 4, it[:y] + 4, 10, 6)
      end
      i += 1
    end
    @items.reject! { |it| it[:collected] }

    # Update particles
    i = 0
    while i < @sparks.size
      sp = @sparks[i]
      sp[:x] += sp[:vx]
      sp[:y] += sp[:vy]
      sp[:life] -= 1
      i += 1
    end
    @sparks.reject! { |sp| sp[:life] <= 0 }

    spawn_wave if @enemies.size == 0
  end

  def draw
    rectfill(0, 0, 256, 256, 1)

    # Arena floor checkerboard tiles
    ty = 2
    while ty < 15
      tx = 1
      while tx < 15
        c = (tx + ty) % 2 == 0 ? 1 : 0
        rectfill(tx * 16, ty * 16, 16, 16, c)
        pset(tx * 16 + 8, ty * 16 + 8, 5) if (tx + ty) % 3 == 0
        tx += 1
      end
      ty += 1
    end

    # Border walls using :wall sprite (slot 1)
    i = 0
    while i < 16
      spr(:wall, i * 16, 16)
      spr(:wall, i * 16, 240)
      if i >= 2 && i < 15
        spr(:wall, 0, i * 16)
        spr(:wall, 240, i * 16)
      end
      i += 1
    end

    # Decorative torches
    t_frame = ($t / 8) % 3
    spr_ext(spr_id(:torch, t_frame), 20, 34, 0, 1.0, 1.0, false, false, 3)
    spr_ext(spr_id(:torch, t_frame), 220, 34, 0, 1.0, 1.0, false, false, 3)
    spr_ext(spr_id(:portal, ($t / 10) % 4), 120, 120, 0, 1.0, 1.0, false, false, 4)

    # Items
    i = 0
    while i < @items.size
      it = @items[i]
      if it[:kind] == :chest
        spr_ext(:chest, it[:x], it[:y], 0, 1.0, 1.0, false, false, 4)
      else
        spr_ext(spr_id(:coin, ($t / 6) % 4), it[:x], it[:y], 0, 1.0, 1.0, false, false, 4)
      end
      i += 1
    end

    # Enemies
    i = 0
    while i < @enemies.size
      e = @enemies[i]
      if e[:kind] == :golem
        f = ($t / 16) % 2
        spr_ext(spr_id(:golem, f), e[:x], e[:y], 0, 1.0, 1.0, e[:vx] < 0, false, 3)
      else
        f = ($t / 8) % 4
        spr_ext(spr_id(:slime, f), e[:x], e[:y], 0, 1.0, 1.0, e[:vx] < 0, false, 2)
      end
      i += 1
    end

    # Hero
    if @inv_t % 4 < 2
      h_frame = @state == :walk ? (($t / 6) % 4) : (($t / 18) % 2)
      spr_ext(spr_id(:hero, h_frame), @x, @y, 0, 1.0, 1.0, @dir < 0, false, 1)
    end

    # Sword slash effect
    if @atk_t > 0
      sx = @x + (@dir * 14)
      sy = @y
      spr_ext(:sword, sx, sy, 0, 1.0, 1.0, @dir < 0, false, 1)
      circ(sx + 8, sy + 8, 12 - @atk_t, 10)
    end

    # Sparks
    i = 0
    while i < @sparks.size
      sp = @sparks[i]
      rectfill(sp[:x], sp[:y], 2, 2, sp[:col])
      i += 1
    end

    # Top HUD bar inside 256x256 game screen
    rectfill(0, 0, 256, 16, 0)
    line(0, 15, 256, 15, 5)
    text("HP:", 4, 4, 7)
    h_idx = 0
    while h_idx < @max_hp
      col = h_idx < @hp ? 8 : 5
      rectfill(24 + h_idx * 8, 5, 6, 6, col)
      h_idx += 1
    end
    text("WAVE:#{$wave}", 72, 4, 11)
    text("COIN:#{$coins}", 124, 4, 10)
    text("SCORE:#{$score}", 180, 4, 7)

    if @hp <= 0
      rectfill(48, 104, 160, 44, 0)
      rect(48, 104, 160, 44, 8)
      text("GAME OVER", 96, 114, 8)
      text("Press Z / Space to Retry", 56, 130, 7)
    end
  end
end

# ==============================================================================
# Resource Metadata Parser & Hot-Reload Manager
# ==============================================================================
class ResourceViewer
  def initialize
    @tab = 2 # Start on [2:SPRITE] tab (1:PLAY, 2:SPRITE, 3:MAP, 4:SOUND)
    default_self = "examples/viewer.rb"
    @targets = [default_self, "game.rb"]
    ai = 0
    while ai < ARGV.size
      arg_str = ARGV[ai].to_s
      if arg_str.length > 6 && arg_str[0, 6] == "--tab="
        t_no = arg_str[6, arg_str.length - 6].to_i
        @tab = t_no if t_no >= 1 && t_no <= 4
      elsif arg_str.length > 0 && arg_str[0] != "-"
        if arg_str != default_self && arg_str != "game.rb"
          @targets = [arg_str, default_self, "game.rb"]
        else
          @targets = [arg_str, arg_str == default_self ? "game.rb" : default_self]
        end
      end
      ai += 1
    end
    @target_idx = 0
    @target_path = @targets[0]
    @use_internal_demo = (@target_path == default_self)

    # Hot-reload tracking
    @check_timer = 0
    @last_mtime_sig = ""
    @reload_flash = 0
    @has_spr_file = false
    @has_map_file = false
    @has_sfx_file = false

    # Sprite tab state
    @sprites = []
    @filtered_sprites = []
    @palettes = [0]
    @map_summary = { w: 0, h: 0, tiles: 0 }
    @sfx_names = []
    @music_names = []

    @sel_idx = 0
    @scroll_row = 0
    @filter_mode = :all # :all, :named, :anim, :s8, :s16, :s32
    @zoom_levels = [1, 2, 4, 8]
    @zoom_idx = 2 # Default 4x
    @bg_modes = [:chk, :c0, :c7, :c1]
    @bg_idx = 0 # Default CHK
    @flip_h = false
    @flip_v = false
    @anim_playing = true
    @anim_tick = 0
    @anim_frame_idx = 0
    @hover_col = nil
    @inspected_col = 8

    # Tweaker & editing state
    @draw_col = 8
    @prev_draw_col = 8
    @copied_toast_timer = 0
    @preview_hover_pos = nil

    # Play tab state
    @game_scene = PlayDemoScene.new
    @play_paused = false
    @play_step_once = false
    @play_speeds = [0.25, 0.5, 1.0]
    @play_speed_idx = 2 # Default 1.0x
    @play_frame_accum = 0.0

    # Map & Sound tab interactive preview state
    @sound_sel_idx = 0

    reload_target_resources(false)
    select_default_hero_sprite
  end

  def select_default_hero_sprite
    j = 0
    while j < @filtered_sprites.size
      if @filtered_sprites[j][:name] == ":hero"
        @sel_idx = j
        ensure_grid_scroll_visible
        update_default_inspected_color
        break
      end
      j += 1
    end
  end

  def compute_mtime_signature(path)
    base = base_path_without_rb(path)
    m_rb = file_mtime(path)
    m_spr = file_mtime(base + ".spr")
    m_map = file_mtime(base + ".map")
    m_sfx = file_mtime(base + ".sfx")
    "#{m_rb}:#{m_spr}:#{m_map}:#{m_sfx}"
  end

  def reload_target_resources(is_hot_reload)
    prev_sel_key = nil
    if @filtered_sprites.size > 0 && @sel_idx < @filtered_sprites.size
      prev_sel_key = @filtered_sprites[@sel_idx][:key]
    end

    path = @target_path
    base = base_path_without_rb(path)
    rb_text = read_file(path)
    spr_text = read_file(base + ".spr")
    map_text = read_file(base + ".map")
    sfx_text = read_file(base + ".sfx")

    @has_spr_file = spr_text != nil
    @has_map_file = map_text != nil
    @has_sfx_file = sfx_text != nil

    # Load palettes & bank pixels into VIEWER_BANK
    src_for_spr = @has_spr_file ? (base + ".spr") : path
    pals = load_resource_palettes(src_for_spr)
    if (!pals || pals.size <= 1) && @has_spr_file
      pals2 = load_resource_palettes(path)
      pals = pals2 if pals2 && pals2.size > pals.size
    end
    @palettes = pals && pals.size > 0 ? pals : [0]

    load_bank(VIEWER_BANK, src_for_spr)

    # Combine tail sections for metadata parsing
    combined_tail = extract_tail_section(rb_text || "")
    if spr_text
      combined_tail = combined_tail + "\n" + spr_text
    end
    if map_text
      combined_tail = combined_tail + "\n" + map_text
    end
    if sfx_text
      combined_tail = combined_tail + "\n" + sfx_text
    end

    parse_tail_metadata(combined_tail)
    apply_sprite_filter(prev_sel_key)

    if !@use_internal_demo
      if is_hot_reload
        sub_game_restart
      else
        sub_game_load(@target_path)
      end
    end

    @last_mtime_sig = compute_mtime_signature(path)
    if is_hot_reload
      @reload_flash = 36
      sfx(:coin, -1, 0.25)
    end
  end

  def parse_tail_metadata(tail_str)
    raw_defs = []
    @map_summary = { w: 0, h: 0, tiles: 0 }
    @sfx_names = []
    @music_names = []

    lines = tail_str.split("\n")
    mode = nil
    cur_def = nil
    cur_frame_lines = []

    i = 0
    while i <= lines.size
      raw_line = i < lines.size ? lines[i].split("\r").join("") : "@END_EOF"
      trimmed = raw_line.strip

      if trimmed.length > 0 && trimmed[0] == "@"
        # Flush any open @SPRITE definition
        if mode == :sprite && cur_def
          if cur_frame_lines.size > 0 || cur_def[:raw_frames].size == 0
            cur_def[:raw_frames] << cur_frame_lines
          end
          finalize_raw_sprite_def(cur_def)
          raw_defs << cur_def
          cur_def = nil
          cur_frame_lines = []
        end

        tokens = trimmed.split(" ")
        directive = tokens[0]

        if directive == "@SPRITE"
          mode = :sprite
          cur_def = parse_sprite_header_tokens(tokens)
          cur_frame_lines = []
        elsif directive == "@PNG" || directive == "@B64"
          mode = :other
          d = parse_png_or_sheet_tokens(tokens, directive)
          raw_defs << d if d
        elsif directive == "@SHEET"
          mode = :other
          d = parse_png_or_sheet_tokens(tokens, "@SHEET")
          raw_defs << d if d
        elsif directive == "@MAP"
          mode = :map
        elsif directive == "@SFX"
          mode = :sfx
          if tokens.size >= 2
            @sfx_names << tokens[1]
          end
        elsif directive == "@MUSIC"
          mode = :music
          if tokens.size >= 2
            @music_names << tokens[1]
          end
        else
          mode = :other
        end
      else
        if mode == :sprite && cur_def
          if trimmed == "---"
            cur_def[:raw_frames] << cur_frame_lines
            cur_frame_lines = []
          elsif trimmed.length > 0 && trimmed[0] != "#"
            cur_frame_lines << trimmed
          end
        elsif mode == :map
          if trimmed.length > 0 && trimmed[0] != "#"
            row_tokens = trimmed.split(" ")
            row_w = row_tokens.size > 1 ? row_tokens.size : trimmed.length
            @map_summary[:w] = row_w if row_w > @map_summary[:w]
            @map_summary[:h] += 1
            @map_summary[:tiles] += row_w
          end
        end
      end
      i += 1
    end

    allocate_sprite_slots(raw_defs)
  end

  def parse_sprite_header_tokens(tokens)
    explicit_id = nil
    name = nil
    w = nil
    h = nil
    pal = 0
    inline_tokens = []

    idx = 1
    while idx < tokens.size
      tok = tokens[idx]
      if idx == 1 && is_ascii_integer_str(tok)
        explicit_id = tok.to_i
      elsif tok[0] == ":" && !name
        name = tok
      elsif tok.length > 4 && tok[0, 4] == "pal:"
        pal_str = tok[4, tok.length - 4]
        pal = pal_str.to_i if is_ascii_integer_str(pal_str)
      else
        wh = parse_wxh_token(tok)
        if wh && !w
          w = wh[0]
          h = wh[1]
        else
          inline_tokens << tok
        end
      end
      idx += 1
    end

    {
      explicit_id: explicit_id,
      name: name,
      w: w,
      h: h,
      pal: pal,
      type: "@SPRITE",
      inline_tokens: inline_tokens,
      raw_frames: [],
      frame_count: 1
    }
  end

  def parse_png_or_sheet_tokens(tokens, dtype)
    return nil if tokens.size < 2
    explicit_id = nil
    name = nil
    w = 16
    h = 16
    frames = 1
    idx = 1
    while idx < tokens.size
      tok = tokens[idx]
      if idx == 1 && is_ascii_integer_str(tok)
        explicit_id = tok.to_i
      elsif tok[0] == ":" && !name
        name = tok
      else
        wh = parse_wxh_token(tok)
        if wh
          w = wh[0]
          h = wh[1]
        end
      end
      idx += 1
    end
    {
      explicit_id: explicit_id,
      name: name,
      w: w,
      h: h,
      pal: 0,
      type: dtype,
      inline_tokens: [],
      raw_frames: [],
      frame_count: frames
    }
  end

  def finalize_raw_sprite_def(d)
    # Check if inline emoji/tokens were used on header line
    if d[:inline_tokens].size > 0 && (d[:raw_frames].size == 0 || d[:raw_frames][0].size == 0)
      d[:type] = "EMOJI"
      d[:w] = 16 if !d[:w]
      d[:h] = 16 if !d[:h]
      d[:frame_count] = d[:inline_tokens].size
      return
    end

    # Filter out empty frames
    non_empty = []
    i = 0
    while i < d[:raw_frames].size
      fl = d[:raw_frames][i]
      non_empty << fl if fl.size > 0
      i += 1
    end

    if non_empty.size == 0
      d[:w] = 16 if !d[:w]
      d[:h] = 16 if !d[:h]
      d[:frame_count] = 1
      return
    end

    first_frame = non_empty[0]
    first_line = first_frame[0]
    # Check if first line is hex/dot pattern or emoji
    first_ch = first_line[0]
    is_pattern = (first_ch == "." || parse_hex_digit_char(first_ch) != nil)

    if !is_pattern
      # Emoji frame lines (e.g. "🧱 🍎" or single emoji)
      parts = first_line.split(" ")
      d[:type] = "EMOJI"
      d[:w] = 16 if !d[:w]
      d[:h] = 16 if !d[:h]
      d[:frame_count] = non_empty.size > 1 ? non_empty.size : parts.size
    else
      if !d[:w] || !d[:h]
        d[:h] = first_frame.size
        d[:w] = first_line.length
      end
      d[:frame_count] = non_empty.size
    end
  end

  # Matches Rust's exact 2-pass 16x16 slot allocator in parse_tail_resources_full
  def allocate_sprite_slots(raw_defs)
    used = Array.new(256, false)
    used[0] = true # Slot 0 is reserved for empty unless explicitly defined

    # Pass 1: Explicit integer slot IDs
    i = 0
    while i < raw_defs.size
      d = raw_defs[i]
      if d[:explicit_id]
        base_id = d[:explicit_id]
        fc = d[:frame_count]
        tw = (d[:w] + 15) / 16
        th = (d[:h] + 15) / 16
        fslots = []
        f = 0
        while f < fc
          sid = base_id + f
          fslots << sid
          mark_slot_used(used, sid, tw, th)
          f += 1
        end
        d[:slots] = fslots
      end
      i += 1
    end

    # Pass 2: Auto-packed slot IDs starting from candidate_id = 1
    i = 0
    while i < raw_defs.size
      d = raw_defs[i]
      if !d[:explicit_id]
        fc = d[:frame_count]
        tw = (d[:w] + 15) / 16
        th = (d[:h] + 15) / 16
        fslots = []
        f = 0
        while f < fc
          sid = find_free_slot(used, tw, th)
          fslots << sid
          mark_slot_used(used, sid, tw, th)
          f += 1
        end
        d[:slots] = fslots
      end
      i += 1
    end

    # Build final sprite metadata list and inspect pixel colors from VIEWER_BANK
    @sprites = []
    i = 0
    while i < raw_defs.size
      d = raw_defs[i]
      slots = d[:slots] || [0]
      first_slot = slots[0] || 0
      disp_name = d[:name] ? d[:name] : "##{pad3(first_slot)}"
      short_label = truncate_str(disp_name, 6)
      used_cols = scan_sprite_used_colors(slots, d[:w], d[:h])

      sp_entry = {
        key: d[:name] ? d[:name] : "id_#{first_slot}",
        name: disp_name,
        is_named: d[:name] != nil,
        slot_id: first_slot,
        slots: slots,
        frame_count: slots.size,
        w: d[:w],
        h: d[:h],
        cells_w: (d[:w] + 15) / 16,
        cells_h: (d[:h] + 15) / 16,
        type: d[:type],
        pal: d[:pal],
        short_label: short_label,
        used_cols: used_cols,
        modified: false,
        orig_frames: nil
      }
      backup_sprite_pixels(sp_entry)
      @sprites << sp_entry
      i += 1
    end
  end

  def can_fit_slot(used, cid, tw, th)
    sx = cid % 16
    sy = cid / 16
    return false if sx + tw > 16 || sy + th > 16
    dy = 0
    while dy < th
      dx = 0
      while dx < tw
        idx = (sy + dy) * 16 + (sx + dx)
        return false if used[idx]
        dx += 1
      end
      dy += 1
    end
    true
  end

  def mark_slot_used(used, cid, tw, th)
    sx = cid % 16
    sy = cid / 16
    dy = 0
    while dy < th
      dx = 0
      while dx < tw
        tx = sx + dx
        ty = sy + dy
        if tx < 16 && ty < 16
          used[ty * 16 + tx] = true
        end
        dx += 1
      end
      dy += 1
    end
  end

  def find_free_slot(used, tw, th)
    cid = 1
    while cid < 256
      return cid if can_fit_slot(used, cid, tw, th)
      cid += 1
    end
    1
  end

  def scan_sprite_used_colors(slots, w, h)
    used_map = Array.new(16, false)
    f = 0
    while f < slots.size
      sid = slots[f]
      u = (sid % 16) * 16
      v = (sid / 16) * 16
      pixels = get_bank_rect(VIEWER_BANK, u, v, w, h)
      if pixels
        pi = 0
        while pi < pixels.size
          c = pixels[pi]
          if c && c >= 0 && c <= 15
            used_map[c] = true
          end
          pi += 1
        end
      end
      f += 1
    end
    used_map
  end

  def apply_sprite_filter(prefer_key = nil)
    @filtered_sprites = []
    i = 0
    while i < @sprites.size
      sp = @sprites[i]
      keep = false
      if @filter_mode == :all
        keep = true
      elsif @filter_mode == :named
        keep = sp[:is_named]
      elsif @filter_mode == :anim
        keep = sp[:frame_count] > 1
      elsif @filter_mode == :s8
        keep = (sp[:w] == 8 && sp[:h] == 8)
      elsif @filter_mode == :s16
        keep = (sp[:w] == 16 && sp[:h] == 16)
      elsif @filter_mode == :s32
        keep = (sp[:w] >= 32 || sp[:h] >= 32)
      end
      @filtered_sprites << sp if keep
      i += 1
    end

    @sel_idx = 0
    if prefer_key
      j = 0
      while j < @filtered_sprites.size
        if @filtered_sprites[j][:key] == prefer_key
          @sel_idx = j
          break
        end
        j += 1
      end
    end
    ensure_grid_scroll_visible
    @anim_frame_idx = 0
    update_default_inspected_color
  end

  def backup_sprite_pixels(sp)
    return if !sp || sp[:orig_frames]
    orig = []
    f = 0
    while f < sp[:slots].size
      sid = sp[:slots][f]
      u = (sid % 16) * 16
      v = (sid / 16) * 16
      pixels = get_bank_rect(VIEWER_BANK, u, v, sp[:w], sp[:h])
      orig << (pixels ? pixels : [])
      f += 1
    end
    sp[:orig_frames] = orig
  end

  def revert_sprite_pixels(sp)
    return if !sp || !sp[:orig_frames] || !sp[:modified]
    f = 0
    while f < sp[:slots].size
      sid = sp[:slots][f]
      u = (sid % 16) * 16
      v = (sid / 16) * 16
      orig = sp[:orig_frames][f]
      if orig && orig.size > 0
        update_bank_rect(VIEWER_BANK, u, v, sp[:w], sp[:h], orig)
      end
      f += 1
    end
    sp[:modified] = false
    sp[:used_cols] = scan_sprite_used_colors(sp[:slots], sp[:w], sp[:h])
    sfx(:select, -1, 0.25)
  end

  def copy_sprite_definition_to_clipboard(sp)
    return if !sp

    header_parts = ["@SPRITE"]
    if sp[:is_named]
      header_parts << sp[:name]
    else
      header_parts << sp[:slot_id].to_s
    end

    if sp[:w] != 16 || sp[:h] != 16
      header_parts << "#{sp[:w]}x#{sp[:h]}"
    end

    if sp[:pal] && sp[:pal] > 0
      header_parts << "pal:#{sp[:pal]}"
    end

    lines = [header_parts.join(" ")]

    f = 0
    while f < sp[:slots].size
      if f > 0
        lines << "---"
      end
      sid = sp[:slots][f]
      u = (sid % 16) * 16
      v = (sid / 16) * 16
      pixels = get_bank_rect(VIEWER_BANK, u, v, sp[:w], sp[:h])

      y = 0
      while y < sp[:h]
        row_chars = []
        x = 0
        while x < sp[:w]
          c = pixels ? pixels[y * sp[:w] + x] : nil
          if c != nil && c >= 0 && c <= 15
            row_chars << HEX_DIGITS[c]
          else
            row_chars << "."
          end
          x += 1
        end
        lines << row_chars.join("")
        y += 1
      end
      f += 1
    end

    text = lines.join("\n") + "\n"
    set_clipboard(text)
    @copied_toast_timer = 90
    sfx(:coin, -1, 0.3)
  end

  def update_default_inspected_color
    sp = current_sprite
    return if !sp
    found = nil
    c = 8
    while c < 16
      if sp[:used_cols][c]
        found = c
        break
      end
      c += 1
    end
    if !found
      c = 1
      while c < 8
        if sp[:used_cols][c]
          found = c
          break
        end
        c += 1
      end
    end
    @inspected_col = found ? found : 0
    @draw_col = @inspected_col
    @prev_draw_col = @inspected_col
  end

  def current_sprite
    return nil if @filtered_sprites.size == 0
    if @sel_idx < 0
      @sel_idx = 0
    elsif @sel_idx >= @filtered_sprites.size
      @sel_idx = @filtered_sprites.size - 1
    end
    @filtered_sprites[@sel_idx]
  end

  def ensure_grid_scroll_visible
    row = @sel_idx / 12
    if row < @scroll_row
      @scroll_row = row
    elsif row >= @scroll_row + 3
      @scroll_row = row - 2
    end
    max_rows = (@filtered_sprites.size + 11) / 12
    max_scroll = max_rows > 3 ? max_rows - 3 : 0
    @scroll_row = max_scroll if @scroll_row > max_scroll
    @scroll_row = 0 if @scroll_row < 0
  end

  # ============================================================================
  # Update Loop
  # ============================================================================
  def update
    @reload_flash -= 1 if @reload_flash > 0

    # Periodic file_mtime hot-reload polling (every 20 frames)
    @check_timer += 1
    if @check_timer >= 20
      @check_timer = 0
      sig = compute_mtime_signature(@target_path)
      if sig != @last_mtime_sig
        reload_target_resources(true)
      end
    end

    mx = mouse_x
    my = mouse_y
    clicked = btnp(:mouse_l)

    # Global Header Tab Switching (Keys 1..4, Tab, or Mouse click on y: 0..15)
    new_tab = nil
    if btnp(:key_1)
      new_tab = 1
    elsif btnp(:key_2)
      new_tab = 2
    elsif btnp(:key_3)
      new_tab = 3
    elsif btnp(:key_4)
      new_tab = 4
    elsif btnp(:tab)
      new_tab = (@tab % 4) + 1
    end

    if clicked && my >= 0 && my < 16
      if mx >= 4 && mx < 58
        new_tab = 1
      elsif mx >= 60 && mx < 126
        new_tab = 2
      elsif mx >= 128 && mx < 176
        new_tab = 3
      elsif mx >= 178 && mx < 238
        new_tab = 4
      elsif mx >= 244 && mx < 388
        # Click on target filename to toggle between viewer.rb and game.rb
        cycle_target_file
      end
    end

    if new_tab && new_tab != @tab
      @tab = new_tab
      sfx(:select, -1, 0.3)
    end

    if @tab == 1
      update_play_tab(mx, my, clicked)
    elsif @tab == 2
      update_sprite_tab(mx, my, clicked)
    elsif @tab == 3
      update_map_tab(mx, my, clicked)
    elsif @tab == 4
      update_sound_tab(mx, my, clicked)
    end
  end

  def cycle_target_file
    return if @targets.size <= 1
    @target_idx = (@target_idx + 1) % @targets.size
    @target_path = @targets[@target_idx]
    @use_internal_demo = (@target_path == "examples/viewer.rb")
    sfx(:select, -1, 0.3)
    reload_target_resources(false)
  end

  # ============================================================================
  # [2:SPRITE] Tab Update
  # ============================================================================
  def update_sprite_tab(mx, my, clicked)
    sp = current_sprite

    # Animation frame counter (8 FPS = every 7.5 frames at 60fps -> 8 frames)
    if @anim_playing && sp && sp[:frame_count] > 1
      @anim_tick += 1
      if @anim_tick >= 8
        @anim_tick = 0
        @anim_frame_idx = (@anim_frame_idx + 1) % sp[:frame_count]
      end
    end

    # Distinguish Z key (:key_z) from Space key (:space / ButtonId::A)
    z_pressed = btnp(:key_z)
    space_pressed = !z_pressed && btnp(:space)

    if z_pressed
      @zoom_idx = (@zoom_idx + 1) % @zoom_levels.size
      sfx(:select, -1, 0.25)
    end

    if space_pressed
      @anim_playing = !@anim_playing
      sfx(:select, -1, 0.25)
    end

    if btnp(:key_g)
      @bg_idx = (@bg_idx + 1) % @bg_modes.size
      sfx(:select, -1, 0.25)
    end

    if btnp(:key_h)
      @flip_h = !@flip_h
      sfx(:select, -1, 0.25)
    end

    if btnp(:key_v)
      @flip_v = !@flip_v
      sfx(:select, -1, 0.25)
    end

    # Copy shortcut (C key)
    if btnp(:key_c) && sp
      copy_sprite_definition_to_clipboard(sp)
    end

    # Revert shortcut (R key or U key)
    if (btnp(:key_r) || btnp(:key_u)) && sp && sp[:modified]
      revert_sprite_pixels(sp)
    end

    # Toggle transparent / previous color pen (X key)
    if btnp(:key_x)
      if @draw_col == nil
        @draw_col = @prev_draw_col != nil ? @prev_draw_col : 8
      else
        @prev_draw_col = @draw_col
        @draw_col = nil
      end
      sfx(:select, -1, 0.2)
    end

    if @copied_toast_timer > 0
      @copied_toast_timer -= 1
    end

    # Preview hover & dot tweaker handling
    @preview_hover_pos = nil
    if sp
      zoom = @zoom_levels[@zoom_idx]
      draw_w = sp[:w] * zoom
      draw_h = sp[:h] * zoom
      px = 8
      py = 28
      pw = 96
      ph = 96
      dx = px + (pw - draw_w) / 2
      dy = py + (ph - draw_h) / 2

      if mx >= dx && mx < dx + draw_w && my >= dy && my < dy + draw_h
        raw_lx = (mx - dx) / zoom
        raw_ly = (my - dy) / zoom
        if raw_lx >= 0 && raw_lx < sp[:w] && raw_ly >= 0 && raw_ly < sp[:h]
          lx = @flip_h ? (sp[:w] - 1 - raw_lx) : raw_lx
          ly = @flip_v ? (sp[:h] - 1 - raw_ly) : raw_ly
          @preview_hover_pos = [lx, ly, raw_lx, raw_ly]

          # Dot editing: Left click / drag
          if btn(:mouse_left)
            cur_f = @anim_frame_idx % sp[:frame_count]
            sid = sp[:slots][cur_f]
            u = (sid % 16) * 16
            v = (sid / 16) * 16
            cur_col = get_bank_pixel(VIEWER_BANK, u + lx, v + ly)
            if cur_col != @draw_col
              backup_sprite_pixels(sp)
              set_bank_pixel(VIEWER_BANK, u + lx, v + ly, @draw_col)
              @anim_playing = false
              sp[:modified] = true
              sp[:used_cols] = scan_sprite_used_colors(sp[:slots], sp[:w], sp[:h])
            end
          end

          # Eyedropper: Right click
          if btnp(:mouse_right) || btn(:mouse_right)
            cur_f = @anim_frame_idx % sp[:frame_count]
            sid = sp[:slots][cur_f]
            u = (sid % 16) * 16
            v = (sid / 16) * 16
            c = get_bank_pixel(VIEWER_BANK, u + lx, v + ly)
            @draw_col = c
            if c != nil
              @inspected_col = c
              @prev_draw_col = c
            end
            sfx(:select, -1, 0.2) if btnp(:mouse_right)
          end
        end
      end
    end

    # Mouse wheel handling
    wheel = mouse_wheel
    if wheel != 0
      if mx < 180 && my >= 16 && my < 164
        # Zoom over preview panel
        if wheel > 0 && @zoom_idx < @zoom_levels.size - 1
          @zoom_idx += 1
        elsif wheel < 0 && @zoom_idx > 0
          @zoom_idx -= 1
        end
      elsif my >= 180 && my < 306
        # Scroll grid rows
        max_rows = (@filtered_sprites.size + 11) / 12
        max_scroll = max_rows > 3 ? max_rows - 3 : 0
        if wheel < 0 && @scroll_row < max_scroll
          @scroll_row += 1
        elsif wheel > 0 && @scroll_row > 0
          @scroll_row -= 1
        end
      end
    end

    # Keyboard arrow navigation in grid
    if @filtered_sprites.size > 0
      prev_sel = @sel_idx
      if btnp(:left)
        @sel_idx -= 1 if @sel_idx > 0
      elsif btnp(:right)
        @sel_idx += 1 if @sel_idx < @filtered_sprites.size - 1
      elsif btnp(:up)
        @sel_idx -= 12 if @sel_idx >= 12
      elsif btnp(:down)
        @sel_idx += 12 if @sel_idx + 12 < @filtered_sprites.size
      end
      if @sel_idx != prev_sel
        @anim_frame_idx = 0
        ensure_grid_scroll_visible
        update_default_inspected_color
        sfx(:select, -1, 0.2)
      end
    end

    # Palette & transparent chip hover detection
    @hover_col = nil
    if my >= 80 && my < 94
      if mx >= 188 && mx < 444
        c_idx = (mx - 188) / 16
        if c_idx >= 0 && c_idx <= 15
          @hover_col = c_idx
        end
      elsif mx >= 444 && mx < 458
        @hover_col = :trans
      end
    end

    return if !clicked

    # Copy & Revert buttons click: y: 18..30
    if sp && my >= 18 && my < 30
      if mx >= 326 && mx < 376
        revert_sprite_pixels(sp) if sp[:modified]
      elsif mx >= 382 && mx < 474
        copy_sprite_definition_to_clipboard(sp)
      end
    end

    # Palette & transparent chip click: y: 80..94
    if my >= 80 && my < 94
      if mx >= 188 && mx < 444
        c_idx = (mx - 188) / 16
        if c_idx >= 0 && c_idx <= 15
          @draw_col = c_idx
          @prev_draw_col = c_idx
          @inspected_col = c_idx
          sfx(:select, -1, 0.2)
        end
      elsif mx >= 444 && mx < 458
        @draw_col = nil
        sfx(:select, -1, 0.2)
      end
    end

    # Zoom buttons click: y: 132..144
    if my >= 132 && my < 144
      z_xs = [44, 68, 92, 116]
      zi = 0
      while zi < 4
        if mx >= z_xs[zi] && mx < z_xs[zi] + 22
          @zoom_idx = zi
          sfx(:select, -1, 0.25)
        end
        zi += 1
      end
    end

    # BG & Flip buttons click: y: 147..159
    if my >= 147 && my < 159
      bg_xs = [44, 74, 96, 118]
      bg_ws = [28, 20, 20, 20]
      bi = 0
      while bi < 4
        if mx >= bg_xs[bi] && mx < bg_xs[bi] + bg_ws[bi]
          @bg_idx = bi
          sfx(:select, -1, 0.25)
        end
        bi += 1
      end
      if mx >= 142 && mx < 158
        @flip_h = !@flip_h
        sfx(:select, -1, 0.25)
      elsif mx >= 160 && mx < 176
        @flip_v = !@flip_v
        sfx(:select, -1, 0.25)
      end
    end

    # Frame strip & animation buttons click: y: 130..158
    if sp && my >= 130 && my < 158
      fc = sp[:frame_count]
      max_strip = fc > 6 ? 6 : fc
      fi = 0
      while fi < max_strip
        fx = 188 + fi * 28
        if mx >= fx && mx < fx + 25 && my >= 132 && my < 156
          @anim_frame_idx = fi
          @anim_playing = false
          sfx(:select, -1, 0.25)
        end
        fi += 1
      end

      # Play/Pause & Step buttons on right of frame strip
      if mx >= 366 && mx < 418 && my >= 136 && my < 152
        @anim_playing = !@anim_playing
        sfx(:select, -1, 0.25)
      elsif mx >= 422 && mx < 444 && my >= 136 && my < 152
        @anim_playing = false
        @anim_frame_idx = (@anim_frame_idx - 1 + fc) % fc
        sfx(:select, -1, 0.25)
      elsif mx >= 446 && mx < 468 && my >= 136 && my < 152
        @anim_playing = false
        @anim_frame_idx = (@anim_frame_idx + 1) % fc
        sfx(:select, -1, 0.25)
      end
    end

    # Filter bar click: y: 164..179
    if my >= 164 && my < 179
      f_modes = [:all, :named, :anim, :s8, :s16, :s32]
      f_xs = [212, 246, 290, 328, 360, 402]
      f_ws = [32, 42, 36, 30, 40, 40]
      fi = 0
      while fi < f_modes.size
        if mx >= f_xs[fi] && mx < f_xs[fi] + f_ws[fi]
          if @filter_mode != f_modes[fi]
            @filter_mode = f_modes[fi]
            apply_sprite_filter
            sfx(:select, -1, 0.25)
          end
        end
        fi += 1
      end
    end

    # Sprite Grid click: y: 182..302
    if my >= 182 && my < 302 && mx >= 6 && mx < 471
      col = (mx - 6) / 39
      row = (my - 182) / 40
      if col >= 0 && col < 12 && row >= 0 && row < 3
        idx = (@scroll_row + row) * 12 + col
        if idx >= 0 && idx < @filtered_sprites.size
          @sel_idx = idx
          @anim_frame_idx = 0
          update_default_inspected_color
          sfx(:select, -1, 0.2)
        end
      end
    end
  end

  # ============================================================================
  # [1:PLAY] Tab Update
  # ============================================================================
  def update_play_tab(mx, my, clicked)
    if btnp(:key_p)
      @play_paused = !@play_paused
      sfx(:select, -1, 0.25)
    end
    if btnp(:key_s)
      @play_paused = true
      @play_step_once = true
      sfx(:select, -1, 0.25)
    end
    if btnp(:key_r)
      restart_current_game
    end

    if clicked && mx >= 280 && mx <= 472
      # Execution control buttons: Pause / Step / Restart (y: 40..54)
      if my >= 40 && my < 54
        if mx >= 286 && mx < 346
          @play_paused = !@play_paused
          sfx(:select, -1, 0.25)
        elsif mx >= 350 && mx < 404
          @play_paused = true
          @play_step_once = true
          sfx(:select, -1, 0.25)
        elsif mx >= 408 && mx < 466
          restart_current_game
        end
      end

      # Speed buttons: [0.25x] [0.5x] [1.0x] (y: 58..72)
      if my >= 58 && my < 72
        s_xs = [326, 374, 420]
        si = 0
        while si < 3
          if mx >= s_xs[si] && mx < s_xs[si] + 44
            @play_speed_idx = si
            sfx(:select, -1, 0.25)
          end
          si += 1
        end
      end
    end

    # Execute game scene update according to Pause / Step / Speed state
    if @play_step_once
      @play_step_once = false
      advance_game_frame
    elsif !@play_paused
      spd = @play_speeds[@play_speed_idx]
      @play_frame_accum += spd
      if @play_frame_accum >= 1.0
        @play_frame_accum -= 1.0
        advance_game_frame
      end
    end
  end

  def restart_current_game
    if @use_internal_demo
      @game_scene.reset_game
    else
      sub_game_restart
    end
    sfx(:coin, -1, 0.3)
  end

  def advance_game_frame
    if @use_internal_demo
      @game_scene.update
    else
      sub_game_update
    end
  end

  # ============================================================================
  # [3:MAP] & [4:SOUND] Placeholder Tab Updates
  # ============================================================================
  def update_map_tab(mx, my, clicked)
    # Placeholder tab: allows switching back with 1-4/Tab
  end

  def update_sound_tab(mx, my, clicked)
    total_snd = @sfx_names.size
    return if total_snd == 0
    if btnp(:up) && @sound_sel_idx > 0
      @sound_sel_idx -= 1
      sfx(:select, -1, 0.2)
    elsif btnp(:down) && @sound_sel_idx < total_snd - 1
      @sound_sel_idx += 1
      sfx(:select, -1, 0.2)
    elsif btnp(:space)
      sname = @sfx_names[@sound_sel_idx]
      if sname && sname.length > 1
        sym_str = sname[0] == ":" ? sname[1, sname.length - 1] : sname
        sfx(sym_str, -1, 0.4)
      end
    end
  end

  # ============================================================================
  # Master Draw Routine
  # ============================================================================
  def draw
    camera()
    clip()
    pal()
    palt()
    cls(0)

    if @tab == 1
      draw_play_tab
    elsif @tab == 2
      draw_sprite_tab
    elsif @tab == 3
      draw_map_tab
    elsif @tab == 4
      draw_sound_tab
    end

    # Always draw Header & Footer last so embedded game cannot overwrite them
    camera()
    clip()
    pal()
    palt()
    draw_global_header
    draw_global_footer
  end

  # ============================================================================
  # Global Header (y: 0..15) & Footer (y: 306..319)
  # ============================================================================
  def draw_global_header
    rectfill(0, 0, 480, 16, 1)
    line(0, 15, 480, 15, 5)

    tabs = [
      { id: 1, label: "1:PLAY", x: 4, w: 52 },
      { id: 2, label: "2:SPRITE", x: 58, w: 66 },
      { id: 3, label: "3:MAP", x: 126, w: 48 },
      { id: 4, label: "4:SOUND", x: 176, w: 60 }
    ]

    i = 0
    while i < tabs.size
      t = tabs[i]
      active = (@tab == t[:id])
      if active
        rectfill(t[:x], 2, t[:w], 13, 12)
        rect(t[:x], 2, t[:w], 13, 7)
        text("*#{t[:label]}*", t[:x] + 3, 5, 0)
      else
        rectfill(t[:x], 2, t[:w], 13, 0)
        rect(t[:x], 2, t[:w], 13, 5)
        text(" #{t[:label]} ", t[:x] + 3, 5, 6)
      end
      i += 1
    end

    # Target file display (clickable to switch target)
    ext_tags = []
    ext_tags << "spr" if @has_spr_file
    ext_tags << "map" if @has_map_file
    ext_tag_str = ext_tags.size > 0 ? " (+#{ext_tags.join(",")})" : ""
    target_str = "target: #{@target_path}#{ext_tag_str}"
    text(truncate_str(target_str, 24), 244, 4, 7)

    # Hot-reload [LIVE] indicator + FPS
    if @reload_flash > 0
      bg_c = (@reload_flash % 4 < 2) ? 10 : 11
      rectfill(390, 2, 48, 11, bg_c)
      text("*RELOAD", 393, 4, 0)
    else
      rectfill(390, 2, 46, 11, 0)
      rect(390, 2, 46, 11, 3)
      circfill(396, 7, 2, 11)
      text("LIVE", 402, 4, 11)
    end

    text("#{fps}fps", 442, 4, 6)
  end

  def draw_global_footer
    rectfill(0, 306, 480, 14, 1)
    line(0, 306, 480, 306, 5)

    guide = if @tab == 1
      "[P] Pause/Resume  [S] Step  [R] Restart  [Arrows/Z/X] Act  [1-4/Tab] Mode"
    elsif @tab == 2
      "[L-Clk] Draw  [R-Clk] Pick  [C] Copy @SPRITE  [R] Revert  [X] Trans  [Space] Pause  [Z] Zoom"
    elsif @tab == 3
      "[Click/Arrows] Pan Map  [Z] Zoom  [G] Grid  [Target] Switch  [1-4/Tab] Mode"
    else
      "[Up/Down] Select SFX  [Space] Play Test  [Target] Switch  [1-4/Tab] Mode"
    end
    text(guide, 6, 310, 7)
  end

  # ============================================================================
  # [2:SPRITE] Tab Rendering
  # ============================================================================
  def draw_sprite_tab
    sp = current_sprite
    draw_sprite_preview_panel(sp)
    draw_sprite_inspector_panel(sp)
    draw_sprite_filter_bar
    draw_sprite_grid
  end

  def draw_preview_bg(bx, by, bw, bh, bg_mode)
    if bg_mode == :chk
      cy = 0
      while cy < bh
        cx = 0
        while cx < bw
          col = (((cx / 8) + (cy / 8)) % 2 == 0) ? 5 : 13
          w = (cx + 8 <= bw) ? 8 : (bw - cx)
          h = (cy + 8 <= bh) ? 8 : (bh - cy)
          rectfill(bx + cx, by + cy, w, h, col)
          cx += 8
        end
        cy += 8
      end
    elsif bg_mode == :c0
      rectfill(bx, by, bw, bh, 0)
    elsif bg_mode == :c7
      rectfill(bx, by, bw, bh, 7)
    else
      rectfill(bx, by, bw, bh, 1)
    end
  end

  def draw_sprite_from_viewer_bank(sp, frame_idx, dx, dy, scale, flip_h, flip_v)
    return if !sp
    slots = sp[:slots]
    f = frame_idx % slots.size
    sid = slots[f]
    u = (sid % 16) * 16
    v = (sid / 16) * 16
    w = flip_h ? -sp[:w] : sp[:w]
    h = flip_v ? -sp[:h] : sp[:h]
    blt(dx, dy, VIEWER_BANK, u, v, w, h, 0, scale, sp[:pal])
  end

  def draw_sprite_preview_panel(sp)
    # Panel frame (x: 0..179, y: 16..163)
    rectfill(0, 16, 180, 148, 0)
    rect(0, 16, 180, 148, 5)
    text("PREVIEW", 6, 19, 12)
    if @preview_hover_pos
      text("(#{pad3(@preview_hover_pos[0])[1, 2]},#{pad3(@preview_hover_pos[1])[1, 2]})", 56, 19, 10)
    end
    if sp
      f_idx = @anim_frame_idx % sp[:frame_count]
      text("F:#{f_idx + 1}/#{sp[:frame_count]}", 126, 19, 6)
    end

    # Main 96x96 preview box at (8, 28)
    px = 8
    py = 28
    pw = 96
    ph = 96
    bg_mode = @bg_modes[@bg_idx]

    clip(px, py, pw, ph)
    draw_preview_bg(px, py, pw, ph, bg_mode)
    if sp
      zoom = @zoom_levels[@zoom_idx]
      draw_w = sp[:w] * zoom
      draw_h = sp[:h] * zoom
      dx = px + (pw - draw_w) / 2
      dy = py + (ph - draw_h) / 2
      draw_sprite_from_viewer_bank(sp, @anim_frame_idx, dx, dy, zoom, @flip_h, @flip_v)

      # 1px cursor frame over hovered dot
      if @preview_hover_pos
        rlx = @preview_hover_pos[2]
        rly = @preview_hover_pos[3]
        cx = dx + rlx * zoom
        cy = dy + rly * zoom
        rect(cx, cy, zoom, zoom, 10)
      end
    end
    clip()
    rect(px - 1, py - 1, pw + 2, ph + 2, 7)

    # Right side 1x and 2x mini-preview windows
    # 1x preview box (36x32 at x: 116, y: 28)
    m1x = 116
    m1y = 28
    m1w = 54
    m1h = 34
    clip(m1x, m1y, m1w, m1h)
    draw_preview_bg(m1x, m1y, m1w, m1h, bg_mode)
    if sp
      dx1 = m1x + (m1w - sp[:w]) / 2
      dy1 = m1y + (m1h - sp[:h]) / 2
      draw_sprite_from_viewer_bank(sp, @anim_frame_idx, dx1, dy1, 1.0, @flip_h, @flip_v)
    end
    clip()
    rect(m1x - 1, m1y - 1, m1w + 2, m1h + 2, 5)
    w_lbl = sp ? sp[:w] : 16
    text("1x(#{w_lbl})", m1x + 6, m1y + m1h + 3, 6)

    # 2x preview box (54x42 at x: 116, y: 74)
    m2x = 116
    m2y = 74
    m2w = 54
    m2h = 40
    clip(m2x, m2y, m2w, m2h)
    draw_preview_bg(m2x, m2y, m2w, m2h, bg_mode)
    if sp
      s2 = sp[:w] >= 32 ? 1.0 : 2.0
      dw2 = (sp[:w] * s2).to_i
      dh2 = (sp[:h] * s2).to_i
      dx2 = m2x + (m2w - dw2) / 2
      dy2 = m2y + (m2h - dh2) / 2
      draw_sprite_from_viewer_bank(sp, @anim_frame_idx, dx2, dy2, s2, @flip_h, @flip_v)
    end
    clip()
    rect(m2x - 1, m2y - 1, m2w + 2, m2h + 2, 5)
    text("2x(#{w_lbl * 2})", m2x + 4, m2y + m2h + 3, 6)

    # Zoom buttons row (y: 132)
    text("Zoom:", 6, 134, 6)
    z_labels = ["1x", "2x", "4x", "8x"]
    z_xs = [44, 68, 92, 116]
    zi = 0
    while zi < 4
      act = (@zoom_idx == zi)
      bx = z_xs[zi]
      rectfill(bx, 132, 22, 11, act ? 12 : 1)
      rect(bx, 132, 22, 11, act ? 7 : 5)
      text(z_labels[zi], bx + 5, 134, act ? 0 : 7)
      zi += 1
    end

    # BG & Flip buttons row (y: 147)
    text("BG  :", 6, 149, 6)
    bg_labels = ["CHK", "#0", "#7", "#1"]
    bg_xs = [44, 74, 96, 118]
    bg_ws = [28, 20, 20, 20]
    bi = 0
    while bi < 4
      act = (@bg_idx == bi)
      bx = bg_xs[bi]
      bw = bg_ws[bi]
      rectfill(bx, 147, bw, 11, act ? 10 : 1)
      rect(bx, 147, bw, 11, act ? 7 : 5)
      text(bg_labels[bi], bx + 4, 149, act ? 0 : 7)
      bi += 1
    end

    # Flip [H] [V]
    rectfill(142, 147, 16, 11, @flip_h ? 11 : 1)
    rect(142, 147, 16, 11, @flip_h ? 7 : 5)
    text("H", 147, 149, @flip_h ? 0 : 7)

    rectfill(160, 147, 16, 11, @flip_v ? 11 : 1)
    rect(160, 147, 16, 11, @flip_v ? 7 : 5)
    text("V", 165, 149, @flip_v ? 0 : 7)
  end

  def draw_sprite_inspector_panel(sp)
    # Panel frame (x: 180..479, y: 16..163)
    rectfill(180, 16, 300, 148, 0)
    rect(180, 16, 300, 148, 5)
    text("INSPECTOR", 188, 19, 12)

    if @copied_toast_timer > 0
      rectfill(326, 18, 148, 11, 11)
      rect(326, 18, 148, 11, 7)
      text("COPIED TO CLIPBOARD!", 336, 20, 0)
    else
      # Revert button: x: 326, y: 18, w: 50, h: 11
      rev_act = sp && sp[:modified]
      rectfill(326, 18, 50, 11, rev_act ? 8 : 1)
      rect(326, 18, 50, 11, rev_act ? 14 : 5)
      text(rev_act ? "*Revert*" : "Revert", 332, 20, rev_act ? 7 : 6)

      # Copy @SPRITE button: x: 382, y: 18, w: 92, h: 11
      rectfill(382, 18, 92, 11, 12)
      rect(382, 18, 92, 11, 7)
      text("Copy @SPRITE", 390, 20, 0)
    end

    if !sp
      text("No sprites match the selected filter.", 196, 68, 6)
      return
    end

    # Metadata rows
    slot_str = if sp[:frame_count] > 1
      "##{pad3(sp[:slot_id])}..##{pad3(sp[:slots][sp[:slots].size - 1])}"
    else
      "##{pad3(sp[:slot_id])}"
    end

    mod_tag = sp[:modified] ? " *MOD*" : ""
    text("NAME : #{truncate_str(sp[:name], 12)}#{mod_tag}", 188, 31, sp[:modified] ? 10 : 7)
    text("SLOT : #{slot_str}", 348, 31, 10)

    text("SIZE : #{sp[:w]}x#{sp[:h]}px (#{sp[:cells_w]}x#{sp[:cells_h]} cell)", 188, 42, 7)
    text("TYPE : #{sp[:type]}", 348, 42, 11)

    anim_str = sp[:frame_count] > 1 ? "#{sp[:frame_count]} frames (8 FPS)" : "1 frame (Static)"
    pal_str = sp[:pal] > 0 ? "Bank #{sp[:pal]} (@PAL)" : "Bank 0 (Std)"
    text("ANIM : #{anim_str}", 188, 53, 7)
    text("PAL  : #{pal_str}", 348, 53, 14)

    line(186, 64, 474, 64, 1)

    # Palette 16-color bar
    used_cnt = 0
    ci = 0
    while ci < 16
      used_cnt += 1 if sp[:used_cols][ci]
      ci += 1
    end
    pen_label = @draw_col == nil ? "TRANS" : HEX_DIGITS[@draw_col]
    text("PALETTE (Bank #{sp[:pal]} - 16 colors, #{used_cnt} used) [Pen: #{pen_label}]", 188, 68, 6)

    c = 0
    while c < 16
      cx = 188 + c * 16
      cy = 80
      rgba = get_palette_color(sp[:pal], c)
      r = rgba ? rgba[0] : 0
      g = rgba ? rgba[1] : 0
      b = rgba ? rgba[2] : 0
      rectfill_rgb(cx, cy, 14, 14, r, g, b)

      if sp[:used_cols][c]
        rect(cx, cy, 14, 14, 7)
        pset(cx + 7, cy - 2, 10)
      else
        rect(cx, cy, 14, 14, 5)
      end

      if @draw_col == c
        rect(cx - 1, cy - 1, 16, 16, 10)
      elsif @hover_col == c
        rect(cx - 1, cy - 1, 16, 16, 7)
      end

      lbl_col = (r + g + b > 380) ? 0 : 7
      text(HEX_DIGITS[c], cx + 4, cy + 3, lbl_col)
      c += 1
    end

    # 17th chip: Transparent color chip [.] at (444, 80)
    tcx = 444
    tcy = 80
    draw_preview_bg(tcx, tcy, 14, 14, :chk)
    is_trans_pen = (@draw_col == nil)
    rect(tcx, tcy, 14, 14, is_trans_pen ? 10 : 5)
    if is_trans_pen
      rect(tcx - 1, tcy - 1, 16, 16, 10)
    elsif @hover_col == :trans
      rect(tcx - 1, tcy - 1, 16, 16, 7)
    end
    text(".", tcx + 5, tcy + 3, 7)

    # Inspected / Hovered color RGB & HEX readout
    if @hover_col == :trans || (@hover_col == nil && @draw_col == nil)
      text("Col [TRANSPARENT] : . (Alpha/Nil) [PEN:TRANS] (Press X to toggle)", 188, 98, 7)
    else
      show_c = @hover_col ? @hover_col : (@inspected_col != nil ? @inspected_col : 0)
      rgba_s = get_palette_color(sp[:pal], show_c)
      sr = rgba_s ? rgba_s[0] : 0
      sg = rgba_s ? rgba_s[1] : 0
      sb = rgba_s ? rgba_s[2] : 0
      mod_tag = (rgba_s && rgba_s[3]) ? " *PAL" : ""
      used_tag = sp[:used_cols][show_c] ? "[USED]" : "[FREE]"
      pen_tag = (@draw_col == show_c) ? " [PEN]" : ""
      hex_code = "##{to_hex2(sr)}#{to_hex2(sg)}#{to_hex2(sb)}"
      text("Col ##{pad3(show_c)[1, 2]}: #{hex_code} (RGB:#{sr},#{sg},#{sb}) #{used_tag}#{mod_tag}#{pen_tag}", 188, 98, 7)
    end

    line(186, 110, 474, 110, 1)

    # Frame strip & playback controls
    text("FRAMES (Click or [Space] Play/Pause)", 188, 114, 6)
    fc = sp[:frame_count]
    max_strip = fc > 6 ? 6 : fc
    cur_f = @anim_frame_idx % fc

    fi = 0
    while fi < max_strip
      fx = 188 + fi * 28
      fy = 126
      is_cur = (fi == cur_f)
      rectfill(fx, fy, 25, 32, is_cur ? 1 : 0)
      rect(fx, fy, 25, 32, is_cur ? 10 : 5)

      # Mini frame thumbnail inside strip box
      thumb_scale = sp[:w] >= 32 ? 0.5 : (sp[:w] <= 8 ? 2.0 : 1.0)
      tw = (sp[:w] * thumb_scale).to_i
      th = (sp[:h] * thumb_scale).to_i
      tx = fx + (25 - tw) / 2
      ty = fy + 2 + (18 - th) / 2
      clip(fx + 1, fy + 1, 23, 20)
      draw_sprite_from_viewer_bank(sp, fi, tx, ty, thumb_scale, false, false)
      clip()

      flbl = is_cur ? "*#{fi}*" : " #{fi} "
      text(flbl, fx + 3, fy + 22, is_cur ? 10 : 6)
      fi += 1
    end

    # Playback controls: [PLAY/PAUSE] [|<] [>|]
    play_lbl = @anim_playing ? "PAUSE" : "PLAY "
    play_col = @anim_playing ? 11 : 10
    rectfill(366, 134, 52, 16, 1)
    rect(366, 134, 52, 16, play_col)
    text(play_lbl, 376, 138, play_col)

    rectfill(422, 134, 22, 16, 1)
    rect(422, 134, 22, 16, 6)
    text("|<", 427, 138, 7)

    rectfill(446, 134, 22, 16, 1)
    rect(446, 134, 22, 16, 6)
    text(">|", 451, 138, 7)
  end

  def draw_sprite_filter_bar
    rectfill(0, 164, 480, 16, 1)
    line(0, 179, 480, 179, 5)

    text("SPRITE LIST (#{@filtered_sprites.size}/#{@sprites.size} items)", 6, 168, 7)
    text("Filter:", 166, 168, 6)

    f_modes = [:all, :named, :anim, :s8, :s16, :s32]
    f_labels = ["ALL", "NAMED", "ANIM", "8x8", "16x16", "32x32"]
    f_xs = [212, 246, 290, 328, 360, 402]
    f_ws = [32, 42, 36, 30, 40, 40]

    fi = 0
    while fi < f_modes.size
      act = (@filter_mode == f_modes[fi])
      bx = f_xs[fi]
      bw = f_ws[fi]
      rectfill(bx, 166, bw, 12, act ? 12 : 0)
      rect(bx, 166, bw, 12, act ? 7 : 5)
      text(f_labels[fi], bx + 4, 168, act ? 0 : 6)
      fi += 1
    end
  end

  def draw_sprite_grid
    rectfill(0, 180, 480, 126, 0)

    row = 0
    while row < 3
      col = 0
      while col < 12
        idx = (@scroll_row + row) * 12 + col
        cx = 6 + col * 39
        cy = 182 + row * 40

        if idx < @filtered_sprites.size
          sp = @filtered_sprites[idx]
          is_sel = (idx == @sel_idx)

          rectfill(cx, cy, 36, 38, is_sel ? 1 : 0)
          rect(cx, cy, 36, 38, is_sel ? 10 : 5)
          rect(cx - 1, cy - 1, 38, 40, 7) if is_sel

          # Thumbnail box (cx+2, cy+2, 32x24)
          clip(cx + 2, cy + 2, 32, 24)
          g_scale = sp[:w] >= 32 ? 0.5 : (sp[:w] <= 8 ? 2.0 : 1.0)
          gw = (sp[:w] * g_scale).to_i
          gh = (sp[:h] * g_scale).to_i
          gx = cx + 18 - gw / 2
          gy = cy + 14 - gh / 2
          f_idx = (is_sel && @anim_playing) ? (@anim_frame_idx % sp[:frame_count]) : 0
          draw_sprite_from_viewer_bank(sp, f_idx, gx, gy, g_scale, false, false)
          clip()

          # Multi-frame animation indicator badge at top-right of cell
          if sp[:frame_count] > 1
            rectfill(cx + 27, cy + 2, 7, 8, 0)
            text("*", cx + 28, cy + 2, 10)
          end

          # Palette indicator dot at top-left if using custom palette
          if sp[:pal] > 0
            pset(cx + 3, cy + 3, 14)
            pset(cx + 4, cy + 3, 14)
          end

          # Bottom label (max 6 chars)
          lbl_col = is_sel ? 10 : (sp[:is_named] ? 7 : 6)
          text(sp[:short_label], cx + 1, cy + 28, lbl_col)
        else
          rect(cx, cy, 36, 38, 1)
        end
        col += 1
      end
      row += 1
    end

    # Scrollbar on right edge (x: 474..478)
    max_rows = (@filtered_sprites.size + 11) / 12
    if max_rows > 3
      rectfill(474, 182, 4, 118, 1)
      bar_h = (118 * 3) / max_rows
      bar_h = 12 if bar_h < 12
      bar_y = 182 + ((118 - bar_h) * @scroll_row) / (max_rows - 3)
      rectfill(474, bar_y, 4, bar_h, 12)
    end
  end

  # ============================================================================
  # [1:PLAY] Tab Rendering
  # ============================================================================
  def draw_play_tab
    rectfill(0, 16, 480, 290, 0)

    # 1. Draw Embedded 256x256 Game Screen at (x: 12, y: 26, w: 256, h: 256)
    if @use_internal_demo
      clip(12, 26, 256, 256)
      camera(-12, -26)
      @game_scene.draw
      camera()
      clip()
      pal()
      palt()
    else
      err = sub_game_error
      if err
        rectfill(12, 26, 256, 256, 0)
        rect(12, 26, 256, 256, 8)
        text("RUN ERROR:", 18, 34, 8)
        err_lines = err.split("\n")
        ey = 46
        ei = 0
        while ei < err_lines.size && ey < 270
          text(truncate_str(err_lines[ei], 38), 18, ey, 7)
          ey += 9
          ei += 1
        end
      else
        sub_game_draw(12, 26, 256, 256)
      end
    end

    # Game Viewport Frame & Caption
    rect(11, 25, 258, 258, @play_paused ? 10 : 12)
    rect(10, 24, 260, 260, 5)
    status_str = @play_paused ? "PAUSED (Step Ready)" : "RUNNING (#{@play_speeds[@play_speed_idx]}x)"
    text("VIEWPORT 256x256 - #{status_str}", 12, 287, @play_paused ? 10 : 11)

    # 2. Right Debug Panel (x: 280..472, y: 24..298)
    rectfill(280, 24, 192, 274, 0)
    rect(280, 24, 192, 274, 5)

    # Section A: EXECUTION CONTROL
    rectfill(281, 25, 190, 12, 1)
    text("EXECUTION CONTROL", 286, 27, 12)

    # Pause/Resume, Step, Restart buttons
    p_lbl = @play_paused ? "Resume" : "Pause "
    p_col = @play_paused ? 11 : 10
    rectfill(286, 40, 58, 13, 1)
    rect(286, 40, 58, 13, p_col)
    text(p_lbl, 296, 43, p_col)

    rectfill(350, 40, 52, 13, 1)
    rect(350, 40, 52, 13, 7)
    text(">| Step", 355, 43, 7)

    rectfill(408, 40, 58, 13, 1)
    rect(408, 40, 58, 13, 8)
    text("Restart", 416, 43, 8)

    # Speed selector
    text("Speed:", 286, 61, 6)
    s_labels = ["0.25x", "0.5x", "1.0x"]
    s_xs = [326, 374, 420]
    si = 0
    while si < 3
      act = (@play_speed_idx == si)
      bx = s_xs[si]
      rectfill(bx, 58, 44, 12, act ? 12 : 1)
      rect(bx, 58, 44, 12, act ? 7 : 5)
      text(s_labels[si], bx + 6, 60, act ? 0 : 7)
      si += 1
    end

    # Section B: WATCH VARIABLES
    rectfill(281, 75, 190, 12, 1)
    text("WATCH VARIABLES (Live)", 286, 77, 12)

    wy = 91
    if @use_internal_demo
      text("[Globals]", 286, wy, 10)
      wy += 10
      g_entries = collect_watched_globals
      gi = 0
      while gi < g_entries.size && wy < 164
        text(truncate_str(g_entries[gi], 29), 290, wy, 7)
        wy += 9
        gi += 1
      end

      wy += 3
      text("[Scene Instance (@game_scene)]", 286, wy, 11)
      wy += 10
      i_entries = collect_watched_ivars(@game_scene)
      ii = 0
      while ii < i_entries.size && wy < 236
        text(truncate_str(i_entries[ii], 29), 290, wy, 7)
        wy += 9
        ii += 1
      end
    else
      text("[Target Globals ($)]", 286, wy, 10)
      wy += 10
      g_pairs = sub_game_globals
      gi = 0
      while gi < g_pairs.size && wy < 164
        pair = g_pairs[gi]
        text(truncate_str("#{pair[0]}=#{pair[1]}", 29), 290, wy, 7)
        wy += 9
        gi += 1
      end
      if g_pairs.size == 0
        text("(No target globals)", 290, wy, 5)
        wy += 9
      end

      wy += 3
      text("[Target Scene Instance (@)]", 286, wy, 11)
      wy += 10
      i_pairs = sub_game_ivars
      ii = 0
      while ii < i_pairs.size && wy < 236
        pair = i_pairs[ii]
        text(truncate_str("#{pair[0]}=#{pair[1]}", 29), 290, wy, 7)
        wy += 9
        ii += 1
      end
      if i_pairs.size == 0
        text("(No scene ivars)", 290, wy, 5)
        wy += 9
      end
    end

    # Section C: INPUT MONITOR
    rectfill(281, 240, 190, 12, 1)
    text("INPUT MONITOR", 286, 242, 12)

    pad_names = ["L", "R", "U", "D", "A(Z)", "B(X)"]
    pad_xs = [286, 310, 334, 358, 384, 424]
    pad_ws = [20, 20, 20, 20, 36, 36]
    pi = 0
    while pi < 6
      pressed = btn(pi)
      bx = pad_xs[pi]
      bw = pad_ws[pi]
      rectfill(bx, 256, bw, 14, pressed ? 11 : 0)
      rect(bx, 256, bw, 14, pressed ? 7 : 5)
      text(pad_names[pi], bx + 4, 259, pressed ? 0 : 6)
      pi += 1
    end

    # Game-local mouse coordinates (relative to 12, 26)
    gmx = mouse_x - 12
    gmy = mouse_y - 26
    in_bounds = (gmx >= 0 && gmx < 256 && gmy >= 0 && gmy < 256)
    b_tag = in_bounds ? "IN" : "OUT"
    text("Mouse(Game): X=#{gmx} Y=#{gmy} [#{b_tag}]", 286, 276, in_bounds ? 7 : 6)

    if @use_internal_demo
      text("Frame: #{$t}  Enemies: #{@game_scene.enemies.size}", 286, 286, 6)
    else
      info = sub_game_info
      if info
        text("Target: #{@target_path} (#{info[0]}x#{info[1]})", 286, 286, 6)
      else
        text("Target: #{@target_path}", 286, 286, 6)
      end
    end
  end

  def format_watch_val(val)
    if val == nil
      "nil"
    elsif val.is_a?(Array)
      "Array(#{val.size})"
    elsif val.is_a?(Hash)
      "Hash(#{val.size})"
    elsif val.is_a?(Float)
      # Format float to 1 decimal place
      iv = (val * 10.0).to_i
      "#{iv / 10}.#{iv.abs % 10}"
    elsif val.is_a?(Symbol)
      ":#{val}"
    else
      val.to_s
    end
  end

  def collect_watched_globals
    out = []
    if respond_to?(:global_variables)
      gvars = global_variables
      i = 0
      while i < gvars.size
        gname = gvars[i].to_s
        if gname != "$SPRITES" && gname != "$MAP" && gname != "$SFX" && gname != "$MUSIC" && gname != "$OBJECTS" && gname != "$viewer" && gname != "$ARGV"
          val = global_variable_get(gname)
          out << "#{gname} = #{format_watch_val(val)}"
        end
        i += 1
      end
    else
      out << "$score = #{$score}  $coins = #{$coins}"
      out << "$wave = #{$wave}   $kills = #{$kills}"
      out << "$t = #{$t}"
    end

    # Pair up short global entries so more fit cleanly
    paired = []
    idx = 0
    while idx < out.size
      if idx + 1 < out.size && out[idx].length <= 13 && out[idx + 1].length <= 13
        paired << "#{out[idx]}  #{out[idx + 1]}"
        idx += 2
      else
        paired << out[idx]
        idx += 1
      end
    end
    paired
  end

  def collect_watched_ivars(scene_obj)
    out = []
    if scene_obj.respond_to?(:instance_variables)
      ivars = scene_obj.instance_variables
      i = 0
      while i < ivars.size
        iname = ivars[i].to_s
        val = scene_obj.instance_variable_get(iname)
        out << "#{iname} = #{format_watch_val(val)}"
        i += 1
      end
    else
      out << "@x=#{format_watch_val(scene_obj.x)} @y=#{format_watch_val(scene_obj.y)}"
      out << "@state=:#{scene_obj.state} @hp=#{scene_obj.hp}"
    end

    paired = []
    idx = 0
    while idx < out.size
      if idx + 1 < out.size && out[idx].length <= 13 && out[idx + 1].length <= 13
        paired << "#{out[idx]}  #{out[idx + 1]}"
        idx += 2
      else
        paired << out[idx]
        idx += 1
      end
    end
    paired
  end

  # ============================================================================
  # [3:MAP] & [4:SOUND] Placeholder Tabs (Phase 2 / Phase 3 Layout Frames)
  # ============================================================================
  def draw_map_tab
    rectfill(0, 16, 480, 290, 0)

    # Outer layout frame
    rect(12, 24, 310, 272, 5)
    rect(330, 24, 138, 272, 5)
    text("MAP VIEWPORT (Phase 2 Layout)", 20, 30, 12)
    text("TILE / OBJ INSPECTOR", 336, 30, 12)

    # Center placeholder card
    cx = 52
    cy = 84
    cw = 230
    ch = 140
    rectfill(cx, cy, cw, ch, 1)
    rect(cx, cy, cw, ch, 12)
    text("[3:MAP] TAB - PHASE 2 PLACEHOLDER", cx + 14, cy + 16, 10)
    text("Target: #{@target_path}", cx + 14, cy + 36, 7)
    text("Detected @MAP Size: #{@map_summary[:w]} x #{@map_summary[:h]}", cx + 14, cy + 50, 11)
    text("Total Map Cells   : #{@map_summary[:tiles]}", cx + 14, cy + 62, 11)
    text("Planned Features:", cx + 14, cy + 82, 6)
    text("- Full Tilemap Canvas & Zoom/Pan", cx + 14, cy + 94, 6)
    text("- Tile ID / Alias / Flag Overlay", cx + 14, cy + 106, 6)
    text("- @OBJECTS Spawn Marker Inspector", cx + 14, cy + 118, 6)

    text("Tile Palette Preview:", 338, 52, 6)
    i = 0
    while i < 16 && i < @sprites.size
      sp = @sprites[i]
      tx = 338 + (i % 4) * 30
      ty = 68 + (i / 4) * 30
      rect(tx, ty, 24, 24, 5)
      clip(tx + 2, ty + 2, 20, 20)
      draw_sprite_from_viewer_bank(sp, 0, tx + 4, ty + 4, 1.0, false, false)
      clip()
      i += 1
    end
  end

  def draw_sound_tab
    rectfill(0, 16, 480, 290, 0)

    rect(12, 24, 180, 272, 5)
    rect(200, 24, 268, 272, 5)
    text("SFX / MUSIC LIST", 20, 30, 12)
    text("WAVEFORM & MML MONITOR (Phase 2)", 208, 30, 12)

    # List detected @SFX and @MUSIC in left pane
    text("@SFX (#{@sfx_names.size} items):", 20, 48, 10)
    si = 0
    while si < @sfx_names.size && si < 12
      is_sel = (si == @sound_sel_idx)
      sy = 62 + si * 12
      rectfill(18, sy - 1, 166, 10, 1) if is_sel
      prefix = is_sel ? "> " : "  "
      text("#{prefix}#{@sfx_names[si]}", 20, sy, is_sel ? 11 : 7)
      si += 1
    end

    my_off = 68 + (@sfx_names.size * 12)
    my_off = 216 if my_off > 216
    text("@MUSIC (#{@music_names.size} tracks):", 20, my_off, 14)
    mi = 0
    while mi < @music_names.size && mi < 5
      text("  #{@music_names[mi]}", 20, my_off + 14 + mi * 12, 7)
      mi += 1
    end

    # Center placeholder card on right pane
    cx = 212
    cy = 72
    cw = 244
    ch = 150
    rectfill(cx, cy, cw, ch, 1)
    rect(cx, cy, cw, ch, 12)
    text("[4:SOUND] TAB - PHASE 2 PLACEHOLDER", cx + 10, cy + 16, 10)
    text("Detected @SFX  : #{@sfx_names.size} definitions", cx + 14, cy + 38, 11)
    text("Detected @MUSIC: #{@music_names.size} tracks", cx + 14, cy + 50, 14)
    text("Press [Up/Down] & [Space] to test SFX!", cx + 14, cy + 70, 7)
    text("Planned Features:", cx + 14, cy + 92, 6)
    text("- MML Note & Envelope Visualizer", cx + 14, cy + 104, 6)
    text("- 4-Channel Track Mute / Solo", cx + 14, cy + 116, 6)
    text("- Live Piano Roll & Preset Audition", cx + 14, cy + 128, 6)
  end
end

$viewer = ResourceViewer.new

def update
  $viewer.update
end

def draw
  $viewer.draw
end

__END__
# ==============================================================================
# Sample Resource Definitions for Usakame Resource Viewer
# - Custom Palettes (@PALETTE 1..4)
# - Animated Sprites (--- multi-frame & emoji)
# - Multiple Sizes (8x8, 16x16, 32x32)
# - Sample @MAP, @SFX, @MUSIC
# ==============================================================================
@PALETTE 1
# Hero Crimson & Gold Armor Palette
8: #FF1E56
9: #FF8C32
10: #FFE66D
12: #4ECDC4
14: #FF9F9F
15: #FFE5D9

@PALETTE 2
# Slime Aqua & Emerald Bioluminescence Palette
3: #0B4F6C
8: #FF5964
10: #B8F2E6
11: #00F5D4
12: #00BBF9
13: #4361EE

@PALETTE 3
# Magma Golem Obsidian & Lava Palette
1: #1A0F1F
2: #4A1525
4: #7A2021
5: #3B2D38
8: #FF2A00
9: #FF7B00
10: #FFD000

@PALETTE 4
# Royal Treasure Gold & Violet Palette
2: #4B1D70
8: #FF3366
9: #FF9900
10: #FFEE55
12: #9966FF
14: #FFBBFF

@SPRITE :wall 16x16
5555555055555550
5666665056666650
5655555056555550
0000000000000000
5550555555505555
6650566666505666
5550565555505655
0000000000000000
5555555055555550
5666665056666650
5655555056555550
0000000000000000
5550555555505555
6650566666505666
5550565555505655
0000000000000000

@SPRITE :hero 16x16 pal:1
....88888888....
...8888998888...
..888AAAAAA888..
..88FFFFFFFF88..
..88FF0FF0FF88..
..88FFFFFFFF88..
...88FFEFFF88...
....88888888....
...8899AA9988...
..88899AA99888..
..FF89999998FF..
..FF.889988.FF..
.....88..88.....
....88....88....
...44......44...
..444......444..
---
....88888888....
...8888998888...
..888AAAAAA888..
..88FFFFFFFF88..
..88FF0FF0FF88..
..88FFFFFFFF88..
...88FFEFFF88...
....88888888....
...8899AA9988...
..FF899AA99888..
..FF.8899998FF..
.....889988.FF..
....88...88.....
...44.....88....
..444......44...
...........444..
---
....88888888....
...8888998888...
..888AAAAAA888..
..88FFFFFFFF88..
..88FF0FF0FF88..
..88FFFFFFFF88..
...88FFEFFF88...
....88888888....
...8899AA9988...
..88899AA99888..
..FF89999998FF..
..FF.889988.FF..
.....88..88.....
....88....88....
...44......44...
..444......444..
---
....88888888....
...8888998888...
..888AAAAAA888..
..88FFFFFFFF88..
..88FF0FF0FF88..
..88FFFFFFFF88..
...88FFEFFF88...
....88888888....
...8899AA9988...
..88899AA998FF..
..FF8999988.FF..
..FF.889988.....
.....88...88....
....88.....44...
...44......444..
..444...........

@SPRITE :slime 16x16 pal:2
................
................
.....BBBBBB.....
...BBBBBBBBBB...
..BB77BBBBBBBB..
.BB77BBBBBBBBBB.
.BBBB00BBBB00BB.
.BBBB00BBBB00BB.
.BBBBBBBBBBBBBB.
.BBBBBB88BBBBBB.
.CCCBBBBBBBBCCC.
..CCCCCCCCCCCC..
...CCCCCCCCCC...
................
................
................
---
................
................
................
....BBBBBBBB....
..BBBBBBBBBBBB..
.BB77BBBBBBBBBB.
.BB7700BBBB00BB.
.BBBB00BBBB00BB.
.BBBBBBBBBBBBBB.
.BBBBBB8888BBBB.
.CCCBBBBBBBBCCC.
.CCCCCCCCCCCCCC.
..CCCCCCCCCCCC..
................
................
................
---
................
......BBBB......
....BBBBBBBB....
...BB77BBBBBB...
..BB77BBBBBBBB..
..BBB00BBBB00B..
..BBB00BBBB00B..
..BBBBBBBBBBBB..
..BBBBB88BBBBB..
..CCBBBBBBBBCC..
...CCCCCCCCCC...
....CCCCCCCC....
................
................
................
................
---
................
................
.....BBBBBB.....
...BBBBBBBBBB...
..BB77BBBBBBBB..
.BB77BBBBBBBBBB.
.BBBB00BBBB00BB.
.BBBB00BBBB00BB.
.BBBBBBBBBBBBBB.
.BBBBBB88BBBBBB.
.CCCBBBBBBBBCCC.
..CCCCCCCCCCCC..
...CCCCCCCCCC...
................
................
................

@SPRITE :sword 16x16 pal:1
..............77
.............7C7
............7CC7
...........7CC7.
..........7CC7..
.........7CC7...
........7CC7....
...99..7CC7.....
...9A97CC7......
....9A9C7.......
....99A9........
...449A99.......
..444.999.......
.444............
.A4.............
................

@SPRITE :shield 16x16 pal:1
..AAAAAAAAAAAA..
.A999999999999A.
.A91111AA11119A.
.A9111AAAA1119A.
.A911AA88AA119A.
.A91AA8888AA19A.
.A911AA88AA119A.
.A9111AAAA1119A.
..A9111AA1119A..
..A9111AA1119A..
...A911AA119A...
...A911AA119A...
....A91AA19A....
.....A9AA9A.....
......A99A......
.......AA.......

@SPRITE :chest 16x16 pal:4
................
..999999999999..
.9AAAAAAAAAAAA9.
.94444444444449.
.944444AA444449.
.999999AA999999.
.922222AA222229.
.922444AA444229.
.92244444444229.
.92244444444229.
.92222222222229.
.9AAAAAAAAAAAA9.
..999999999999..
................
................
................

@SPRITE :torch 16x16 pal:3
.......AA.......
......AAAA......
.....AA99AA.....
.....A9989A.....
....AA9889AA....
....A988889A....
.....988889.....
......9999......
......5555......
......5445......
.......44.......
.......44.......
.......44.......
.......44.......
......5445......
................
---
......AA........
.....AAAA.......
.....A99AA......
....AA989AA.....
....A98889A.....
....A988889A....
.....988889.....
......9999......
......5555......
......5445......
.......44.......
.......44.......
.......44.......
.......44.......
......5445......
................
---
........AA......
.......AAAA.....
......AA99A.....
.....AA989AA....
.....A98889A....
....A988889A....
.....988889.....
......9999......
......5555......
......5445......
.......44.......
.......44.......
.......44.......
.......44.......
......5445......
................

@SPRITE :portal 16x16 pal:4
....CCCCCCCC....
..CC22222222CC..
.C22EEEEEEEE22C.
.C2EE222222EE2C.
C2E22CCCCCC22E2C
C2E2CCAAAA222E2C
C2E2CA7777A22E2C
C2E2CA7AA7A22E2C
C2E2CA7AA7A22E2C
C2E2CA7777A22E2C
C2E222AAAACC2E2C
C2E22CCCCCC22E2C
.C2EE222222EE2C.
.C22EEEEEEEE22C.
..CC22222222CC..
....CCCCCCCC....
---
....EEEEEEEE....
..EECCCCCCCCEE..
.ECC22222222CCE.
.EC22EEEEEE22CE.
EC2EE222222EE2CE
EC2E22AAAA22E2CE
EC2E2A7777A2E2CE
EC2E2A7CC7A2E2CE
EC2E2A7CC7A2E2CE
EC2E2A7777A2E2CE
EC2E22AAAA22E2CE
EC2EE222222EE2CE
.EC22EEEEEE22CE.
.ECC22222222CCE.
..EECCCCCCCCEE..
....EEEEEEEE....
---
....22222222....
..22EEEEEEEE22..
.2EECCCCCCCCEE2.
.2EC22222222CE2.
2EC2EEEEEEEE2CE2
2EC2E2AAAA2E2CE2
2EC2EA7777AE2CE2
2EC2EA7EE7AE2CE2
2EC2EA7EE7AE2CE2
2EC2EA7777AE2CE2
2EC2E2AAAA2E2CE2
2EC2EEEEEEEE2CE2
.2EC22222222CE2.
.2EECCCCCCCCEE2.
..22EEEEEEEE22..
....22222222....
---
....CCCCCCCC....
..CC22222222CC..
.C22EEEEEEEE22C.
.C2EE222222EE2C.
C2E22CCCCCC22E2C
C2E222AAAACC2E2C
C2E2CA7777A22E2C
C2E2CA7AA7A22E2C
C2E2CA7AA7A22E2C
C2E2CA7777A22E2C
C2E2CCAAAA222E2C
C2E22CCCCCC22E2C
.C2EE222222EE2C.
.C22EEEEEEEE22C.
..CC22222222CC..
....CCCCCCCC....

@SPRITE :coin 8x8 pal:4
..AAAA..
.A9AA9A.
A9A77A9A
A9A77A9A
A9A77A9A
A9A77A9A
.A9AA9A.
..AAAA..
---
...AA...
..A99A..
.A9779A.
.A9779A.
.A9779A.
.A9779A.
..A99A..
...AA...
---
...AA...
...99...
...77...
...77...
...77...
...77...
...99...
...AA...
---
...AA...
..A99A..
.A9779A.
.A9779A.
.A9779A.
.A9779A.
..A99A..
...AA...

@SPRITE :spark 8x8 pal:1
...A....
...A....
..979...
AA777AA.
..979...
...A....
...A....
........
---
.9...9..
..A.A...
..979...
.A777A..
..979...
..A.A...
.9...9..
........
---
........
...9....
..9A9...
.9A7A9..
..9A9...
...9....
........
........
---
........
........
...8....
..898...
...8....
........
........
........

@SPRITE :heart_sm 8x8 pal:1
.88..88.
8AA88888
8A788888
88888888
.888888.
..8888..
...88...
........

@SPRITE :key_item 8x8 pal:4
..AAAA..
.A9..9A.
.A9..9A.
..AAAA..
...AA...
...AAA..
...AA...
...AAA..

@SPRITE :golem 32x32 pal:3
........5555555555555555........
......55554444444444445555......
.....5544449999999999444455.....
....55444999AAAAAAAA99944455....
....544499888888888888994445....
...55449888555555555588894455...
...54449855555555555555894445...
...54498855AA885588AA55889445...
..55449855AAA885588AAA55894455..
..5444985555555555555555894445..
..5444988555588998855558894445..
..5444498888899AA9988888944445..
.554422499999999999999994224455.
.544222244449988889944442222445.
.54225522244988AA88944222552245.
.5425555224498AAAA8944225555245.
.542588522449988889944225885245.
.542588522444999999444225885245.
.542255222444444444444222552245.
..5422222244222222224422222245..
..5544222442225555222442224455..
...554444422255..552224444455...
....5555552255....5522555555....
.........5225......5225.........
........55445......54455........
........54845......54845........
.......5549455....5549455.......
.......5444445....5444445.......
......55555555....55555555......
......55555555....55555555......
................................
................................
---
................................
........5555555555555555........
......55554444444444445555......
.....5544449999999999444455.....
....55444999AAAAAAAA99944455....
....544499888888888888994445....
...55449888555555555588894455...
...54449855555555555555894445...
...54498855AA885588AA55889445...
..55449855AAA885588AAA55894455..
..5444985555555555555555894445..
..5444988555588998855558894445..
..5444498888899AA9988888944445..
.554422499999999999999994224455.
.544222244449988889944442222445.
.54225522244988AA88944222552245.
.5425885224498AAAA8944225885245.
.5425AA522449988889944225AA5245.
.542588522444999999444225885245.
.542255222444444444444222552245.
..5422222244222222224422222245..
..5544222442225555222442224455..
...554444422255..552224444455...
....5555552255....5522555555....
........55225......52255........
.......554445......544455.......
.......5488455....5548845.......
......55499445....54499455......
......55555555....55555555......
......55555555....55555555......
................................
................................

@SPRITE :dragon 32x32 pal:2
...........BBBB..BBBB...........
..........BBCCBBBBCCBB..........
.........BBCCBBBBBBBBBB.........
........BBBB77BBBB77BBBB........
.......BBBB700BBBB007BBBB.......
.......BBBBBBBBBBBBBBBBBB.......
........BBBB88BBBB88BBBB........
...BBB...BBBBBBBBBBBBBB...BBB...
..BBCCB...BBBBAAAAABBBB..BCCBB..
.BBCCCBB.BBBBAAAAAAABBBB.BCCCBB.
.BCC33BBBBBBAAAAAAAAABBBBBB33CB.
BBCC333BBBBBBBBBBBBBBBBBB333CCBB
BCC33333BBBBBBBBBBBBBBBB33333CCB
BC333333BBBBAAABBBBAAABBBB3333CB
BC33333BBBBAAAABBBBAAAABBB3333CB
B33333BBBBBBBBBBBBBBBBBBBBB3333B
.B333BBBBBBBBBBBBBBBBBBBBBBB33B.
..BB..BBBBBBBBBBBBBBBBBBBB..BB..
.......BBBBBBBBBBBBBBBBBB.......
.......BBBBBB......BBBBBB.......
......BBBBBB........BBBBBB......
......BCCBB..........BBCCB......
.....BCCCBB..........BBCCCB.....
.....AAAAB............BAAAA.....
................................
................................
................................
................................
................................
................................
................................
................................

@SPRITE :apple 🍎
@SPRITE :gem 💎 ✨
@SPRITE :castle 🏰
@SPRITE :turtle 🐢
@SPRITE :crown 👑
@SPRITE :bomb 💣

@SPRITE 200 16x16
....77777777....
..77CCCCCCCC77..
.7CC77777777CC7.
.7C7CCCCCCCC7C7.
7C7CC111111CC7C7
7C7C11111111C7C7
7C7C11777711C7C7
7C7C117AA711C7C7
7C7C117AA711C7C7
7C7C11777711C7C7
7C7C11111111C7C7
7C7CC111111CC7C7
.7C7CCCCCCCC7C7.
.7CC77777777CC7.
..77CCCCCCCC77..
....77777777....

@MAP
1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
1 0 0 1 1 0 0 0 0 0 0 1 1 0 0 1
1 0 0 1 0 0 0 0 0 0 0 0 1 0 0 1
1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
1 0 0 0 0 0 1 1 1 1 0 0 0 0 0 1
1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1
1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1

@SFX :select
T180 @0 V12 O5 L32 C E G

@SFX :coin
T180 @0 V13 O5 L16 B > E4

@SFX :hit
T180 @3 V13 O4 L32 C < G C

@SFX :damage
T160 @1 V14 O3 L16 G F# F E

@SFX :explosion
T150 @3 V14 O3 L8 C < G E C

@MUSIC :dungeon_theme
CH0: T132 @1 V11 O4 L8 E G B > E D < B G B > C < A E A B4 R4
CH1: T132 @2 V10 O3 L4 E E A A F# F# B B

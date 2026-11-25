# Save Data API Sample: Star Catcher
#
# Demonstrates persistent save_set / save_get / save_clear across restarts
# (Desktop JSON file & WASM localStorage).
#
# Controls:
#   Left / Right : Move basket
#   Z / Space    : Start / Retry
#   Up (W)       : Cycle background theme (saved in Hash)
#   X / Enter    : Clear save data on Title/Result (press twice to confirm)

config(
  title: "Save Data Demo - Star Catcher",
  width: 256,
  height: 256,
  save_id: "save_data_demo",
  save_salt: "20260401"
)

THEMES = [
  { "name" => "NIGHT",  "bg" => 1, "accent" => 10 },
  { "name" => "FOREST", "bg" => 3, "accent" => 11 },
  { "name" => "PLUM",   "bg" => 2, "accent" => 14 }
]

class SaveDemoGame
  def initialize
    load_save_data
    @state = :title
    @px = 120.0
    @py = 220.0
    @score = 0
    @timer = 600
    @stars = []
    @spawn_cd = 0
    @clear_confirm = 0
    @notice = ""
    @notice_timer = 0
  end

  def load_save_data
    @high_score  = save_get(:high_score, 0)
    @total_stars = save_get(:total_stars, 0)
    @play_count  = save_get(:play_count, 0)
    @history     = save_get(:history, [])
    prefs        = save_get(:prefs, { "theme_idx" => 0 })
    @theme_idx   = (prefs["theme_idx"] || 0) % THEMES.size
  end

  def show_notice(msg)
    @notice = msg
    @notice_timer = 120
  end

  def start_round
    @state = :play
    @score = 0
    @timer = 600 # 10 seconds at 60 FPS
    @stars = []
    @spawn_cd = 10
    @play_count += 1
    save_set(:play_count, @play_count)
  end

  def finish_round
    @state = :result
    is_new_record = false
    if @score > @high_score
      @high_score = @score
      save_set(:high_score, @high_score)
      is_new_record = true
    end

    @total_stars += @score
    save_set(:total_stars, @total_stars)

    # Keep latest 5 scores (avoid Array#reverse / #last)
    new_hist = [@score]
    i = 0
    while i < @history.size && i < 4
      new_hist.push(@history[i])
      i += 1
    end
    @history = new_hist
    save_set(:history, @history)

    if is_new_record
      show_notice("NEW HIGH SCORE SAVED!")
    else
      show_notice("RECORD SAVED!")
    end
  end

  def update
    if @notice_timer > 0
      @notice_timer -= 1
    end
    if @clear_confirm > 0
      @clear_confirm -= 1
    end

    # Theme toggle (Up / W key / button 2) - saved immediately into Hash
    if btnp(2)
      @theme_idx = (@theme_idx + 1) % THEMES.size
      save_set(:prefs, { "theme_idx" => @theme_idx })
      show_notice("THEME SAVED: " + THEMES[@theme_idx]["name"])
    end

    # Clear save data (X / Enter on Title/Result) with 2-step confirmation
    if (@state == :title || @state == :result) && btnp(5)
      if @clear_confirm > 0
        save_clear
        load_save_data
        @clear_confirm = 0
        show_notice("SAVE DATA CLEARED!")
      else
        @clear_confirm = 120
        show_notice("PRESS [X] AGAIN TO CLEAR SAVE")
      end
    end

    if @state == :title || @state == :result
      if btnp(4) || btnp(:mouse_l)
        start_round
      end
      return
    end

    # Playing state
    @px -= 3.2 if btn(0)
    @px += 3.2 if btn(1)
    if btn(:mouse_l)
      @px = mouse_x - 8
    end
    @px = 8.0 if @px < 8.0
    @px = 232.0 if @px > 232.0

    @spawn_cd -= 1
    if @spawn_cd <= 0
      @stars.push({
        "x" => 12.0 + rand(232),
        "y" => 24.0,
        "vy" => 1.6 + rand() * 1.6
      })
      @spawn_cd = 14 + rand(12)
    end

    kept = []
    i = 0
    while i < @stars.size
      s = @stars[i]
      s["y"] += s["vy"]
      dx = (s["x"] - (@px + 8)).abs
      dy = (s["y"] - (@py + 4)).abs
      if dx < 14 && dy < 12
        @score += 1
      elsif s["y"] < 252
        kept.push(s)
      end
      i += 1
    end
    @stars = kept

    @timer -= 1
    if @timer <= 0
      finish_round
    end
  end

  def draw
    theme = THEMES[@theme_idx]
    cls(theme["bg"])

    # Header HUD
    rectfill(0, 0, 256, 22, 0)
    print_text("BEST:#{@high_score}", 6, 4, 10, 8)
    print_text("TOTAL:#{@total_stars}", 84, 4, 7, 8)
    print_text("PLAYS:#{@play_count}", 174, 4, 6, 8)
    line(0, 22, 255, 22, 5)

    # Stars
    i = 0
    while i < @stars.size
      s = @stars[i]
      circfill(s["x"], s["y"], 4, theme["accent"])
      pset(s["x"] - 1, s["y"] - 1, 7)
      i += 1
    end

    # Basket / Player
    rectfill(@px, @py, 16, 10, 9)
    rect(@px, @py, 16, 10, 7)

    if @state == :play
      secs = (@timer + 59) / 60
      print_text("SCORE:#{@score}", 8, 28, 7, 8)
      print_text("TIME:#{secs}", 186, 28, 10, 8)
    elsif @state == :title
      rectfill(24, 52, 208, 136, 0)
      rect(24, 52, 208, 136, theme["accent"])
      print_text("SAVE DATA DEMO", 72, 64, 10, 8)
      print_text("STAR CATCHER (10 SEC)", 56, 80, 7, 8)
      print_text("RECENT: #{format_history}", 40, 102, 12, 8)
      print_text("THEME: #{theme["name"]} ([UP] CHANGE)", 36, 118, 11, 8)
      print_text("[Z] START   [X] CLEAR SAVE", 40, 144, 7, 8)
      print_text("CLOSE & REOPEN TO VERIFY!", 48, 164, 6, 8)
    elsif @state == :result
      rectfill(24, 52, 208, 136, 0)
      rect(24, 52, 208, 136, theme["accent"])
      print_text("TIME UP!", 96, 66, 10, 8)
      print_text("SCORE: #{@score}", 88, 86, 7, 8)
      print_text("BEST:  #{@high_score}", 88, 100, 10, 8)
      print_text("RECENT: #{format_history}", 40, 120, 12, 8)
      print_text("[Z] RETRY   [UP] THEME", 48, 146, 7, 8)
      print_text("[X] CLEAR SAVE DATA", 60, 162, 8, 8)
    end

    if @notice_timer > 0
      rectfill(16, 236, 224, 16, 0)
      rect(16, 236, 224, 16, 10)
      print_text(@notice, 24, 240, 10, 8)
    end
  end

  def format_history
    return "-" if @history.empty?
    parts = []
    i = 0
    while i < @history.size
      parts.push(@history[i].to_s)
      i += 1
    end
    parts.join(", ")
  end
end

run SaveDemoGame.new

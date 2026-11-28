# 2P / Gamepad, Mouse Wheel & Cursor Control Demo
#
# Demonstrates:
#   - btn(id, player) / btnp(id, player) for 1P & 2P (Keyboard + Gamepad)
#   - gamepad_count()
#   - mouse_wheel() to cycle reticle color
#   - show_cursor(false) with a custom in-game reticle
#
# Controls:
#   1P : Arrows + Z(A) / X(B)  or Gamepad 1
#   2P : I/J/K/L       + U(A) / O(B)  or Gamepad 2
#   Mouse Wheel : Cycle reticle color
#   Right Click : Toggle OS cursor visibility (show_cursor)

config(
  title: "2P / Gamepad & Mouse Demo",
  width: 320,
  height: 240
)

class Input2PDemo
  def initialize
    @p1 = { "x" => 96.0, "y" => 120.0, "col" => 12, "flash" => 0 }
    @p2 = { "x" => 224.0, "y" => 120.0, "col" => 8, "flash" => 0 }
    @shots = []
    @reticle_cols = [7, 10, 11, 14]
    @reticle_idx = 0
    @cursor_visible = false
    show_cursor(false)
  end

  def move_player(p, player_id)
    spd = btn(:up, player_id) ? 3.0 : 1.8
    p["x"] -= spd if btn(:left, player_id)
    p["x"] += spd if btn(:right, player_id)
    p["y"] -= spd if btn(:up, player_id)
    p["y"] += spd if btn(:down, player_id)

    p["x"] = 16.0 if p["x"] < 16.0
    p["x"] = 304.0 if p["x"] > 304.0
    p["y"] = 44.0 if p["y"] < 44.0
    p["y"] = 224.0 if p["y"] > 224.0

    if p["flash"] > 0
      p["flash"] -= 1
    end

    if btnp(:right, player_id)
      p["flash"] = 10
      @shots.push({
        "x" => p["x"],
        "y" => p["y"],
        "r" => 2.0,
        "col" => p["col"],
        "life" => 20
      })
    end
  end

  def update
    move_player(@p1, 0)
    move_player(@p2, 1)

    wy = mouse_wheel
    if wy > 0.0
      @reticle_idx = (@reticle_idx + 1) % @reticle_cols.size
    elsif wy < 0.0
      @reticle_idx = (@reticle_idx + @reticle_cols.size - 1) % @reticle_cols.size
    end

    if btnp(:mouse_r)
      @cursor_visible = !@cursor_visible
      show_cursor(@cursor_visible)
    end

    if btnp(:mouse_l)
      @shots.push({
        "x" => mouse_x.to_f,
        "y" => mouse_y.to_f,
        "r" => 3.0,
        "col" => @reticle_cols[@reticle_idx],
        "life" => 24
      })
    end

    @shots.each do |s|
      s["r"] += 1.4
      s["life"] -= 1
    end
    @shots.reject! { |s| s["life"] <= 0 }
  end

  def draw
    cls(1)

    # Header
    print_text("2P / GAMEPAD & CURSOR DEMO", 160, 6, 7, 8, 1.0, :center, 0)
    gp_str = "GAMEPADS: " + gamepad_count.to_s + "  WHEEL COL: " + @reticle_cols[@reticle_idx].to_s
    print_text(gp_str, 160, 18, 10, 8, 1.0, :center, 0)

    # Expanding rings
    @shots.each do |s|
      alpha = s["life"] / 24.0
      circ(s["x"], s["y"], s["r"], s["col"], alpha)
    end

    # Players
    [@p1, @p2].each_with_index do |p, idx|
      c = p["flash"] > 0 ? 7 : p["col"]
      circfill(p["x"], p["y"], 8, c)
      circ(p["x"], p["y"], 8, 7)
      label = (idx == 0) ? "1P" : "2P"
      print_text(label, p["x"], p["y"] - 16, 7, 8, 1.0, :center, 0)
    end

    # Custom reticle at mouse position
    mx = mouse_x
    my = mouse_y
    rc = @reticle_cols[@reticle_idx]
    circ(mx, my, 7, rc)
    line(mx - 10, my, mx - 4, my, rc)
    line(mx + 4, my, mx + 10, my, rc)
    line(mx, my - 10, mx, my - 4, rc)
    line(mx, my + 4, mx, my + 10, rc)

    # Footer
    print_text("1P:WASD/ARROWS+Z/X  2P:IJKL+U/O", 160, 218, 7, 8, 1.0, :center, 0)
    cur_label = @cursor_visible ? "OS CURSOR: ON (R-CLICK)" : "OS CURSOR: OFF (R-CLICK)"
    print_text(cur_label, 160, 229, 11, 8, 1.0, :center, 0)
  end
end

run Input2PDemo.new

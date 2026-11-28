config(title: "Lightmap & Decal Demo", width: 320, height: 240)

class LightmapDecalDemo
  def initialize
    @decal = create_surface(320, 240, :gpu)
    @lightmap = create_surface(320, 240, :gpu)
    @fog = create_surface(320, 240, :gpu)

    @car_x = 160.0
    @car_y = 180.0
    @angle = 0.0
    @speed = 0.0
    @erase_mode = false
    @t = 0

    # 路面に初期ラインを焼き付け
    render_to(@decal) do
      cls(nil)
    end
  end

  def update
    @t += 1
    @erase_mode = !@erase_mode if btnp(:right) || btnp(:mouse_l)

    if btn(:left)
      @angle -= 0.06
    end
    if btn(:right)
      @angle += 0.06
    end
    if btn(:up)
      @speed = [@speed + 0.12, 2.4].min
    elsif btn(:down)
      @speed = [@speed - 0.12, -1.2].max
    else
      @speed *= 0.94
    end

    prev_x = @car_x
    prev_y = @car_y
    @car_x = (@car_x + cos(@angle) * @speed).clamp(16.0, 304.0)
    @car_y = (@car_y + sin(@angle) * @speed).clamp(16.0, 224.0)

    # 走行中はタイヤ痕を @decal へ永続焼き付け（配列不要）
    if @speed.abs > 0.4
      perp_x = -sin(@angle) * 4.0
      perp_y = cos(@angle) * 4.0
      render_to(@decal) do
        line(
          (prev_x + perp_x).to_i, (prev_y + perp_y).to_i,
          (@car_x + perp_x).to_i, (@car_y + perp_y).to_i,
          0, 2, 0.55
        )
        line(
          (prev_x - perp_x).to_i, (prev_y - perp_y).to_i,
          (@car_x - perp_x).to_i, (@car_y - perp_y).to_i,
          0, 2, 0.55
        )
      end
    end

    if btnp(:up)
      clear_surface(@decal)
    end
  end

  def draw
    cls(3)
    # サーキット風の背景路面
    rectfill(20, 20, 280, 200, 5)
    rectfill(64, 64, 192, 112, 3)

    # 永続デカール（タイヤ痕）を1ドローコールで合成
    draw_surface(@decal, 0, 0)

    # 自機（車）
    hx = @car_x + cos(@angle) * 7
    hy = @car_y + sin(@angle) * 7
    circfill(@car_x.to_i, @car_y.to_i, 6, 8)
    line(@car_x.to_i, @car_y.to_i, hx.to_i, hy.to_i, 7, 2)

    if @erase_mode
      # 方式B: :erase くり抜き視界マスク（中心は元の色を100%保持）
      render_to(@fog) do
        cls(0, 0.90)
        blend(:erase)
        circfill(@car_x.to_i, @car_y.to_i, 64, 7, 0.35)
        circfill(@car_x.to_i, @car_y.to_i, 40, 7, 1.0)
        circfill(160, 42, 30, 7, 0.85)
      end
      draw_surface(@fog, 0, 0)
    else
      # 方式A: 乗算ライトマップ（複数光源が重なっても白飛びしない）
      render_to(@lightmap) do
        cls(1)
        blend(:add)
        # 街灯
        circfill(160, 42, 42, 9, 0.55)
        circfill(160, 42, 22, 10, 0.75)
        # ヘッドライトコーン
        fx = @car_x + cos(@angle) * 8
        fy = @car_y + sin(@angle) * 8
        lx = @car_x + cos(@angle - 0.38) * 95
        ly = @car_y + sin(@angle - 0.38) * 95
        rx = @car_x + cos(@angle + 0.38) * 95
        ry = @car_y + sin(@angle + 0.38) * 95
        polyfill([[fx.to_i, fy.to_i], [lx.to_i, ly.to_i], [rx.to_i, ry.to_i]], 7, 0.85)
        circfill(@car_x.to_i, @car_y.to_i, 28, 10, 0.5)
      end
      draw_surface(@lightmap, 0, 0, 1.0, :mul)
    end

    print_text("ARROWS:DRIVE  Z:MODE  X:CLEAR", 6, 6, 7, 8)
    mode_label = @erase_mode ? "MODE: ERASE FOG" : "MODE: MUL LIGHTMAP"
    print_text(mode_label, 6, 16, 10, 8)
  end
end

run LightmapDecalDemo.new

config(title: "Destructible Terrain & Sand Demo", width: 320, height: 240)

class DestructibleTerrainDemo
  def initialize
    @terrain = create_surface(320, 240, :pixel)
    @shells = []
    @px = 60.0
    @py = 80.0
    @pvy = 0.0
    @t = 0
    build_terrain
  end

  def build_terrain
    render_to(@terrain) do
      cls(nil)
      # 破壊可能な丘陵地形 (色 4: 土, 色 11: 草)
      polyfill([[0, 160], [80, 130], [160, 170], [240, 120], [320, 150], [320, 240], [0, 240]], 4)
      polyline([[0, 160], [80, 130], [160, 170], [240, 120], [320, 150]], 11, 3)
      # 鉄骨足場 (色 6: 硬い素材)
      rectfill(120, 128, 72, 10, 6)
      # 落下砂の塊 (色 10: 黄色)
      rectfill(200, 30, 28, 20, 10)
    end
  end

  def explode(bx, by, radius)
    render_to(@terrain) do
      blend(:erase)
      circfill(bx, by, radius, 0, 1.0)
    end
  end

  def step_falling_sand
    # 砂領域 (x: 180..250) を下から上へ走査して色 10 (砂) を落下させる
    y = 238
    while y >= 25
      x = 180
      while x <= 250
        if surface_pget(@terrain, x, y) == 10
          if !surface_pget(@terrain, x, y + 1)
            surface_swap(@terrain, x, y, x, y + 1)
          elsif !surface_pget(@terrain, x - 1, y + 1)
            surface_swap(@terrain, x, y, x - 1, y + 1)
          elsif !surface_pget(@terrain, x + 1, y + 1)
            surface_swap(@terrain, x, y, x + 1, y + 1)
          end
        end
        x += 1
      end
      y -= 1
    end
  end

  def update
    @t += 1

    # キャラ移動＆地形 AABB 接地判定
    nx = @px
    nx -= 1.5 if btn(:left)
    nx += 1.5 if btn(:right)
    nx = nx.clamp(8.0, 312.0)

    if !surface_solid?(@terrain, (nx - 4).to_i, (@py - 8).to_i, 8, 7)
      @px = nx
    elsif !surface_solid?(@terrain, (nx - 4).to_i, (@py - 11).to_i, 8, 7)
      @px = nx
      @py -= 3.0
    end

    on_ground = surface_solid?(@terrain, (@px - 4).to_i, @py.to_i, 8, 2)
    if on_ground
      @pvy = 0.0
      if btnp(:up)
        @pvy = -3.8
      end
    else
      @pvy = [@pvy + 0.18, 4.0].min
    end

    ny = @py + @pvy
    if @pvy > 0 && surface_solid?(@terrain, (@px - 4).to_i, ny.to_i, 8, 1)
      while !surface_solid?(@terrain, (@px - 4).to_i, (@py + 1).to_i, 8, 1) && @py < 238
        @py += 1.0
      end
      @pvy = 0.0
    else
      @py = ny.clamp(8.0, 238.0)
    end

    # クリックまたは Z で照準方向へ砲弾発射
    if btnp(:mouse_l) || btnp(:z)
      tx = btnp(:mouse_l) ? mouse_x : (@px + 60)
      ty = btnp(:mouse_l) ? mouse_y : (@py - 30)
      dx = tx - @px
      dy = ty - (@py - 6)
      dist = sqrt(dx * dx + dy * dy)
      dist = 1.0 if dist < 1.0
      @shells << { x: @px, y: @py - 6.0, vx: (dx / dist) * 5.0, vy: (dy / dist) * 5.0 }
    end

    # X で地形リセット
    if btnp(:x)
      build_terrain
      @py = 80.0
      @pvy = 0.0
    end

    # 砲弾のレイキャスト衝突判定
    alive = []
    @shells.each do |sh|
      sh[:vy] += 0.12
      nx_s = sh[:x] + sh[:vx]
      ny_s = sh[:y] + sh[:vy]
      hit = surface_raycast(@terrain, sh[:x].to_i, sh[:y].to_i, nx_s.to_i, ny_s.to_i)
      if hit
        hx = hit[0]
        hy = hit[1]
        mat_col = hit[2]
        explode(hx, hy, (mat_col == 6) ? 8 : 22)
      elsif nx_s >= 0 && nx_s < 320 && ny_s < 240
        sh[:x] = nx_s
        sh[:y] = ny_s
        alive << sh
      end
    end
    @shells = alive

    step_falling_sand
  end

  def draw
    cls(1)
    draw_surface(@terrain, 0, 0)

    # プレイヤー
    rectfill((@px - 4).to_i, (@py - 9).to_i, 8, 9, 12)
    rect((@px - 4).to_i, (@py - 9).to_i, 8, 9, 7)

    # 砲弾
    @shells.each do |sh|
      circfill(sh[:x].to_i, sh[:y].to_i, 2, 9)
    end

    # 照準レティクル
    circ(mouse_x, mouse_y, 4, 8)
    print_text("ARROWS:MOVE  CLICK/Z:FIRE  X:RESET", 6, 6, 7, 8)
    print_text("TERRAIN PX: #{surface_count(@terrain)}", 6, 16, 10, 8)
  end
end

run DestructibleTerrainDemo.new

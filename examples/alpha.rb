# Alpha Blending Demo (spr / circfill / rectfill / line / oval / print_text)
# 矢印キー / WASD: うさぎを移動（半透明ゴースト残像つき）
# Z / Space: ダッシュ（残像が濃く・長くなります）
# X / Enter / クリック: 花火・光の波紋を発生

class AlphaDemoScene
  def initialize
    @t = 0
    @px = 128.0
    @py = 136.0
    @vx = 0.0
    @vy = 0.0
    @flip_x = false
    @trails = []      # [x, y, flip_x, life, max_life, rot]
    @fireworks = []   # [x, y, vx, vy, col, life, max_life, r]
    @ripples = []     # [x, y, rx, ry, col, life, max_life]
    @fireflies = []
    i = 0
    while i < 18
      @fireflies << {
        x: rand(240) + 8.0,
        y: rand(160) + 24.0,
        phase: rand * 6.28,
        speed: 0.03 + rand * 0.04,
        col: [10, 11, 12, 14][i % 4]
      }
      i += 1
    end
    spawn_firework(72.0, 74.0)
    spawn_firework(184.0, 64.0)
  end

  def spawn_firework(cx, cy)
    cols = [8, 9, 10, 11, 12, 14]
    base_col = cols[rand(cols.size)]
    count = 20
    i = 0
    while i < count
      ang = (6.28318 * i) / count + (rand - 0.5) * 0.15
      spd = 0.9 + rand * 1.4
      life = 36 + rand(22)
      @fireworks << {
        x: cx,
        y: cy,
        vx: cos(ang) * spd,
        vy: sin(ang) * spd,
        col: ((i % 3 == 0) ? 7 : base_col),
        life: life,
        max_life: life,
        r: 2 + rand(3)
      }
      i += 1
    end
    @ripples << { x: cx, y: cy, rx: 4.0, ry: 4.0, col: base_col, life: 30, max_life: 30 }
  end

  def spawn_ripple(x, y, col)
    @ripples << { x: x, y: y, rx: 3.0, ry: 1.5, col: col, life: 32, max_life: 32 }
  end

  def update
    @t += 1
    dash = btn(4)
    accel = dash ? 0.55 : 0.32
    moved = false

    if btn(0)
      @vx -= accel
      @flip_x = true
      moved = true
    end
    if btn(1)
      @vx += accel
      @flip_x = false
      moved = true
    end
    if btn(2)
      @vy -= accel
      moved = true
    end
    if btn(3)
      @vy += accel
      moved = true
    end

    # 操作していないときは緩やかに 8 の字浮遊
    if !moved && @t > 30
      target_x = 128.0 + cos(@t * 0.03) * 64.0
      target_y = 128.0 + sin(@t * 0.06) * 28.0
      @vx += (target_x - @px) * 0.015
      @vy += (target_y - @py) * 0.015
      @flip_x = @vx < -0.1
    end

    @vx *= 0.88
    @vy *= 0.88
    @px += @vx
    @py += @vy

    @px = 16.0 if @px < 16.0
    @px = 240.0 if @px > 240.0
    @py = 36.0 if @py < 36.0
    @py = 196.0 if @py > 196.0

    # ゴースト残像を追加
    if dash || (@t % 2 == 0)
      max_life = dash ? 22 : 14
      @trails << {
        x: @px,
        y: @py,
        flip_x: @flip_x,
        life: max_life,
        max_life: max_life,
        rot: @vx * 4.0
      }
    end

    @trails.each { |tr| tr[:life] -= 1 }
    @trails.reject! { |tr| tr[:life] <= 0 }

    # X / クリック / 定期打ち上げで花火
    if btnp(5) || btnp(6)
      fx = btnp(6) ? mouse_x.to_f : (40.0 + rand(176))
      fy = btnp(6) ? mouse_y.to_f : (44.0 + rand(68))
      spawn_firework(fx, fy)
    elsif @t % 95 == 0
      spawn_firework(48.0 + rand(160), 48.0 + rand(56))
    end

    # 水面の波紋
    if @py > 164.0 && (@t % 10 == 0)
      spawn_ripple(@px, 204.0 + (@py - 164.0) * 0.4, 12)
    end

    # 花火パーティクル更新
    @fireworks.each do |fw|
      fw[:x] += fw[:vx]
      fw[:y] += fw[:vy]
      fw[:vx] *= 0.96
      fw[:vy] = fw[:vy] * 0.96 + 0.025
      fw[:life] -= 1
    end
    @fireworks.reject! { |fw| fw[:life] <= 0 }

    # 波紋更新
    @ripples.each do |rp|
      rp[:rx] += 0.9
      rp[:ry] += (rp[:ry] < rp[:rx] * 0.5) ? 0.35 : 0.9
      rp[:life] -= 1
    end
    @ripples.reject! { |rp| rp[:life] <= 0 }

    # ホタル更新
    @fireflies.each do |ff|
      ff[:phase] += ff[:speed]
      ff[:x] += cos(ff[:phase] * 0.7) * 0.25
      ff[:y] += sin(ff[:phase] * 1.1) * 0.2
    end
  end

  def draw
    cls(0)

    # 1. 夜空背景と半透明グラデーション帯
    bg(:city, dim: 0.55)
    rectfill(0, 0, 256, 48, 1, 0.35)
    rectfill(0, 188, 256, 68, 1, 0.55)

    # 2. 水面の半透明反射（キャラ & 月）
    moon_x = 204
    moon_y = 52
    circfill(moon_x, moon_y, 26, 10, 0.08)
    circfill(moon_x, moon_y, 18, 10, 0.14)
    circfill(moon_x, moon_y, 11, 7, 0.85)

    # 水面の波紋（oval alpha）
    @ripples.each do |rp|
      a = rp[:life].to_f / rp[:max_life]
      oval(rp[:x].to_i, rp[:y].to_i, rp[:rx].to_i, rp[:ry].to_i, rp[:col], a * 0.65)
    end

    # 水面に映る反転うさぎ（spr_ex で flip_y = true & 半透明）
    reflect_y = 206 + (196 - @py) * 0.35
    spr_ex(:hero, @px.to_i - 8, reflect_y.to_i, 0.0, 1.0, 0.75, @flip_x, true, nil, 0.28)

    # 3. ホタルの柔らかい光（多重 circfill alpha）
    @fireflies.each do |ff|
      glow = 0.25 + 0.35 * (0.5 + 0.5 * sin(ff[:phase]))
      fx = ff[:x].to_i
      fy = ff[:y].to_i
      circfill(fx, fy, 7, ff[:col], glow * 0.25)
      circfill(fx, fy, 3, ff[:col], glow * 0.55)
      pset(fx, fy, 7, glow)
    end

    # 4. 花火の軌跡（line alpha）と光の粒（circfill alpha）
    @fireworks.each do |fw|
      a = fw[:life].to_f / fw[:max_life]
      x = fw[:x].to_i
      y = fw[:y].to_i
      tx = (fw[:x] - fw[:vx] * 3.5).to_i
      ty = (fw[:y] - fw[:vy] * 3.5).to_i
      line(tx, ty, x, y, fw[:col], 1, a * 0.6)
      circfill(x, y, fw[:r] + 2, fw[:col], a * 0.22)
      circfill(x, y, fw[:r], fw[:col], a * 0.85)
    end

    # 5. キャラのオーラライト（circfill alpha）
    aura_r = 16 + (sin(@t * 0.1) * 3.0).to_i
    circfill(@px.to_i, @py.to_i, aura_r + 8, 12, 0.08)
    circfill(@px.to_i, @py.to_i, aura_r, 12, 0.16)

    # 6. ゴースト残像トレイル（spr alpha）
    @trails.each do |tr|
      a = (tr[:life].to_f / tr[:max_life]) * 0.45
      spr(:hero, tr[:x].to_i - 8, tr[:y].to_i - 8, tr[:flip_x], 1, tr[:rot], 1.0, a)
    end

    # 本体
    spr(:hero, @px.to_i - 8, @py.to_i - 8, @flip_x, nil, @vx * 3.0, 1.0, 1.0)

    # 7. 半透明ガラス風 HUD とフェードテキスト（rectfill / rect / print_text alpha）
    rectfill(4, 4, 248, 22, 0, 0.55)
    rect(4, 4, 248, 22, 12, 1, 0.45)
    print_text("ALPHA BLENDING DEMO", 12, 8, 10, 8, 0.95)
    print_text("TRAIL:#{@trails.size} FW:#{@fireworks.size}", 156, 8, 6, 8, 0.8)

    rectfill(4, 232, 248, 20, 0, 0.55)
    rect(4, 232, 248, 20, 7, 1, 0.25)
    pulse = 0.45 + 0.55 * (0.5 + 0.5 * sin(@t * 0.07))
    print_text("ARROWS:MOVE  Z:DASH  X/CLICK:FIREWORK", 12, 238, 7, 8, pulse)
  end
end

run AlphaDemoScene.new

__END__
@PALETTE 1
# 残像用のクールな青系ゴーストパレット
7: #88E0FF
F: #55A8E8
E: #3377CC
8: #4499FF

@SPRITE :hero 16x16
......77..77....
.....7F7.7F7....
.....7F7.7F7....
.....7777777....
....777777777...
...77707770777..
...77777E77777..
....777777777...
.....7777777....
....777888777...
...77.78887.77..
......77777.....
.....77...77....
.....77...77....
....777...777...
................

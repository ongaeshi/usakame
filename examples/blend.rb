# Blend Mode Demo (blend :normal / :add / :mul)
# 矢印キー / WASD: ランタンを持ったうさぎを移動
# Z / Space: 夜の暗闇フィルター (:mul) の ON/OFF 切替
# X / Enter / クリック: 加算合成 (:add) の魔法弾・光の爆発を発射

class BlendDemoScene
  def initialize
    @t = 0
    @px = 128.0
    @py = 148.0
    @flip_x = false
    @night_mode = true
    @orbs = []
    @sparks = []
    @fireflies = []

    i = 0
    while i < 14
      @fireflies << {
        x: 20.0 + rand(216),
        y: 44.0 + rand(148),
        phase: rand * 6.28,
        spd: 0.03 + rand * 0.03,
        col: [10, 11, 12, 14][i % 4]
      }
      i += 1
    end
  end

  def spawn_magic(x, y, vx, vy)
    cols = [8, 9, 10, 11, 12, 14]
    col = cols[rand(cols.size)]
    @orbs << { x: x, y: y, vx: vx, vy: vy, col: col, life: 70, max_life: 70 }
  end

  def spawn_burst(cx, cy, base_col)
    i = 0
    while i < 16
      ang = (6.28318 * i) / 16.0 + (rand - 0.5) * 0.2
      spd = 0.7 + rand * 1.6
      life = 28 + rand(18)
      @sparks << {
        x: cx,
        y: cy,
        vx: cos(ang) * spd,
        vy: sin(ang) * spd,
        col: ((i % 3 == 0) ? 7 : base_col),
        life: life,
        max_life: life
      }
      i += 1
    end
  end

  def update
    @t += 1
    spd = 1.8
    moved = false
    if btn(0)
      @px -= spd
      @flip_x = true
      moved = true
    end
    if btn(1)
      @px += spd
      @flip_x = false
      moved = true
    end
    if btn(2)
      @py -= spd
      moved = true
    end
    if btn(3)
      @py += spd
      moved = true
    end

    if !moved && @t > 30
      @px = 128.0 + cos(@t * 0.025) * 56.0
      @py = 148.0 + sin(@t * 0.05) * 18.0
      @flip_x = sin(@t * 0.025) > 0.0
    end

    @px = 20.0 if @px < 20.0
    @px = 236.0 if @px > 236.0
    @py = 44.0 if @py < 44.0
    @py = 204.0 if @py > 204.0

    # Z / Space: 乗算暗闇フィルター (:mul) の ON/OFF
    if btnp(4)
      @night_mode = !@night_mode
    end

    # X / クリック / 自動デモ: 加算合成 (:add) の魔法弾を発射
    if btnp(5) || btnp(6)
      if btnp(6)
        dx = mouse_x.to_f - @px
        dy = mouse_y.to_f - @py
        len = sqrt(dx * dx + dy * dy)
        len = 1.0 if len < 1.0
        spawn_magic(@px, @py, (dx / len) * 2.6, (dy / len) * 2.6)
      else
        dir = @flip_x ? -1.0 : 1.0
        spawn_magic(@px + dir * 8.0, @py, dir * 2.4, -0.8 + (rand - 0.5) * 0.6)
      end
    elsif @t % 45 == 0
      ang = (@t * 0.07)
      spawn_magic(@px, @py - 4.0, cos(ang) * 1.8, sin(ang) * 1.2 - 0.6)
    end

    @orbs.each do |o|
      o[:x] += o[:vx]
      o[:y] += o[:vy]
      o[:life] -= 1
      if o[:life] == 1 || o[:x] < 12.0 || o[:x] > 244.0 || o[:y] < 32.0 || o[:y] > 214.0
        o[:life] = 0
        spawn_burst(o[:x], o[:y], o[:col])
      end
    end
    @orbs.reject! { |o| o[:life] <= 0 }

    @sparks.each do |sp|
      sp[:x] += sp[:vx]
      sp[:y] += sp[:vy]
      sp[:vx] *= 0.94
      sp[:vy] *= 0.94
      sp[:life] -= 1
    end
    @sparks.reject! { |sp| sp[:life] <= 0 }

    @fireflies.each do |ff|
      ff[:phase] += ff[:spd]
      ff[:x] += cos(ff[:phase] * 0.8) * 0.25
      ff[:y] += sin(ff[:phase] * 1.2) * 0.2
    end
  end

  def draw
    cls(0)

    # ==========================================================
    # 1. 通常描画 (:normal): 背景・森・宝石・キャラクター
    # ==========================================================
    blend(:normal)
    bg(:forest, dim: 0.15)

    # 地面と木・宝石
    rectfill(0, 208, 256, 48, 3)
    rectfill(0, 208, 256, 3, 11)
    spr(:tree, 28, 192)
    spr(:tree, 196, 192)
    spr(:gem, 64, 194)
    spr(:gem, 168, 194)

    # キャラクター本体
    spr(:hero, @px.to_i - 8, @py.to_i - 8, @flip_x)

    # ==========================================================
    # 2. 乗算合成 (:mul): 夜の空気感・暗闇フィルターを全体に掛ける
    # ==========================================================
    if @night_mode
      blend(:mul)
      # 濃い青紫を半透明で乗算すると、白飛びや濁りのない自然な夜の暗さに沈む
      rectfill(0, 0, 256, 256, 1, 0.78)
      # 画面下部の地面付近をさらに少し暗くする
      rectfill(0, 190, 256, 66, 0, 0.35)
    end

    # ==========================================================
    # 3. 加算合成 (:add): 重なるほど白く輝く光・魔法・ホタル
    # ==========================================================
    blend(:add)

    # キャラの持つランタンの温かい光（多重 circfill で柔らかい減衰光）
    lx = @px.to_i + (@flip_x ? -6 : 6)
    ly = @py.to_i - 2
    flicker = 1.0 + 0.08 * sin(@t * 0.25)
    circfill(lx, ly, (34 * flicker).to_i, 9, 0.14)
    circfill(lx, ly, (20 * flicker).to_i, 10, 0.22)
    circfill(lx, ly, (9 * flicker).to_i, 7, 0.35)

    # 宝石の淡い輝き
    circfill(72, 202, 12, 12, 0.22)
    circfill(176, 202, 12, 12, 0.22)

    # ホタルの光
    @fireflies.each do |ff|
      glow = 0.2 + 0.45 * (0.5 + 0.5 * sin(ff[:phase]))
      fx = ff[:x].to_i
      fy = ff[:y].to_i
      circfill(fx, fy, 7, ff[:col], glow * 0.25)
      circfill(fx, fy, 3, ff[:col], glow * 0.65)
      pset(fx, fy, 7, glow)
    end

    # 魔法弾（加算合成なので重なると中心が白く発光する）
    @orbs.each do |o|
      ox = o[:x].to_i
      oy = o[:y].to_i
      circfill(ox, oy, 11, o[:col], 0.25)
      circfill(ox, oy, 6, o[:col], 0.55)
      circfill(ox, oy, 2, 7, 0.85)
    end

    # 魔法爆発の火花
    @sparks.each do |sp|
      a = sp[:life].to_f / sp[:max_life]
      sx = sp[:x].to_i
      sy = sp[:y].to_i
      tx = (sp[:x] - sp[:vx] * 3.0).to_i
      ty = (sp[:y] - sp[:vy] * 3.0).to_i
      line(tx, ty, sx, sy, sp[:col], a * 0.7)
      circfill(sx, sy, 3, sp[:col], a * 0.45)
    end

    # ==========================================================
    # 4. 通常合成 (:normal) に戻して UI を描画
    # ==========================================================
    blend(:normal)
    rectfill(4, 4, 248, 22, 0, 0.6)
    rect(4, 4, 248, 22, 10, 0.5)
    mode_label = @night_mode ? "MUL NIGHT:ON" : "MUL NIGHT:OFF"
    print_text("BLEND DEMO (:add/:mul)", 10, 8, 10)
    print_text(mode_label, 174, 8, @night_mode ? 12 : 6)

    rectfill(4, 232, 248, 20, 0, 0.6)
    print_text("ARROWS:MOVE  Z:NIGHT  X:MAGIC", 10, 238, 7)
  end
end

run BlendDemoScene.new

__END__
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

@SPRITE :tree 🌲
@SPRITE :gem 💎

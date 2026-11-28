# ==============================================================================
# USAKAME DIORAMA: 5 MOVING PIXEL WORLDS
# ------------------------------------------------------------------------------
# 256x256 / 1ファイル完結 / 基本API + BG + スプライト専用 (タイルマップ・サウンド不使用)
# 実行: uk run examples/diorama.rb
#
# 【操作方法】
#   ← / → (A / D) : ジオラマ切替 (全5シーン)
#   ↑ / ↓ (W / S) : ムード / 時間帯切替 (各4バリエーション・滑らか色変化)
#   Z     : シーン固有のマジック演出を発火！
#   X     : UI表示切替 (PANEL → CINEMA黒帯 → CLEAN全画面)
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "USAKAME DIORAMA"
)

SCREEN_W = 256
SCREEN_H = 256

# ------------------------------------------------------------------------------
# 共通ヘルパー (mrubyedge互換)
# ------------------------------------------------------------------------------
def clamp_f(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

def lerp_f(a, b, t)
  a + (b - a) * t
end

def draw_shadow_text(text, x, y, col)
  print_text(text, x + 1, y + 1, 0)
  print_text(text, x, y, col)
end

def center_text_x(text)
  128 - (text.length * 6) / 2
end

def draw_spr_grounded(id, foot_cx, foot_y, w, h, sx, sy, flip_x, pal_id = nil)
  dx = foot_cx - (w * sx) * 0.5
  dy = foot_y - (h * sy)
  spr_ext(id, dx, dy, 0.0, sx, sy, flip_x, false, pal_id)
end

def draw_spr_centered(id, cx, cy, w, h, rot, sx, sy, flip_x, flip_y = false, pal_id = nil)
  if rot.abs < 0.001
    dx = cx - (w * sx) * 0.5
    dy = cy - (h * sy) * 0.5
    spr_ext(id, dx, dy, 0.0, sx, sy, flip_x, flip_y, pal_id)
  else
    dx = cx - w * 0.5
    dy = cy - h * 0.5
    spr_ext(id, dx, dy, rot, sx, sy, flip_x, flip_y, pal_id)
  end
end

# ------------------------------------------------------------------------------
# 1. FIREFLY CAMP WORLD (:forest)
# ------------------------------------------------------------------------------
class FireflyCampWorld
  attr_reader :title, :moods

  def initialize
    @title = "FIREFLY CAMP"
    @moods = [
      { name: "TWILIGHT", tint: [165, 195, 240], dim: 0.42, glow: 9,  sky_dot: 12 },
      { name: "MIDNIGHT", tint: [110, 145, 225], dim: 0.56, glow: 10, sky_dot: 7  },
      { name: "GOLDEN",   tint: [255, 195, 130], dim: 0.34, glow: 10, sky_dot: 9  },
      { name: "DAWN",     tint: [255, 175, 210], dim: 0.38, glow: 14, sky_dot: 7  }
    ]
    @t = 0
    @magic_t = 0
    @id_tent = spr_id(:tent)
    @fireflies = []
    i = 0
    while i < 28
      @fireflies << {
        bx: 18.0 + rand() * 220.0,
        by: 78.0 + rand() * 116.0,
        phase: rand() * 6.28318,
        spd: 0.02 + rand() * 0.03,
        rx: 6.0 + rand() * 14.0,
        ry: 4.0 + rand() * 10.0,
        x: 0.0,
        y: 0.0,
        col: (i % 3 == 0 ? 10 : 11)
      }
      i += 1
    end
    @embers = []
    @meteors = []
    @prev_mx = 0
    @prev_my = 0
    @mouse_active = 0
  end

  def magic_label
    "METEOR SHOWER!"
  end

  def trigger_magic
    @magic_t = 90
    i = 0
    while i < 3
      @meteors << {
        x: 36.0 + i * 64.0 + rand() * 24.0,
        y: 12.0 + rand() * 26.0,
        vx: 3.4 + rand() * 1.2,
        vy: 1.5 + rand() * 0.5,
        life: 32 + i * 6
      }
      i += 1
    end
    # 焚き火から黄金の火の粉バースト
    k = 0
    while k < 18
      @embers << {
        x: 128.0 + (rand() - 0.5) * 8.0,
        y: 196.0,
        vx: (rand() - 0.5) * 1.4,
        vy: -1.1 - rand() * 1.6,
        life: 38 + rand(22),
        col: (k % 2 == 0 ? 10 : 9)
      }
      k += 1
    end
  end

  def update
    @t += 1
    @magic_t -= 1 if @magic_t > 0

    mx = mouse_x
    my = mouse_y
    if mx > 2 && mx < 253 && my > 2 && my < 253 && (mx != @prev_mx || my != @prev_my)
      @mouse_active = 120
    elsif @mouse_active > 0
      @mouse_active -= 1
    end
    @prev_mx = mx
    @prev_my = my

    # ホタル浮遊
    i = 0
    while i < @fireflies.size
      f = @fireflies[i]
      f[:phase] += f[:spd] + (@magic_t > 0 ? 0.05 : 0.0)
      lift = (@magic_t > 0) ? -sin((@magic_t / 90.0) * 3.14159) * 26.0 : 0.0
      tx = f[:bx] + cos(f[:phase]) * f[:rx]
      ty = f[:by] + sin(f[:phase] * 1.4) * f[:ry] + lift
      if @mouse_active > 0
        tx = lerp_f(tx, mx.to_f, 0.14)
        ty = lerp_f(ty, my.to_f, 0.14)
      end
      f[:x] = tx
      f[:y] = ty
      i += 1
    end

    # 焚き火の火の粉
    if @t % 5 == 0
      @embers << {
        x: 128.0 + (rand() - 0.5) * 6.0,
        y: 197.0,
        vx: (rand() - 0.5) * 0.35,
        vy: -0.45 - rand() * 0.45,
        life: 36 + rand(18),
        col: (rand(3) == 0 ? 10 : 9)
      }
    end

    kept_e = []
    i = 0
    while i < @embers.size
      e = @embers[i]
      e[:x] += e[:vx] + sin(@t * 0.12 + i) * 0.15
      e[:y] += e[:vy]
      e[:life] -= 1
      kept_e << e if e[:life] > 0
      i += 1
    end
    @embers = kept_e

    kept_m = []
    i = 0
    while i < @meteors.size
      m = @meteors[i]
      m[:x] += m[:vx]
      m[:y] += m[:vy]
      m[:life] -= 1
      kept_m << m if m[:life] > 0
      i += 1
    end
    @meteors = kept_m
  end

  def draw(tint, dim)
    sway = sin(@t * 0.008) * 14.0
    bg(:forest, dim: dim, tint: tint, scale: 1.04, y: -3.0, scroll_x: sway, mirror_x: true)

    # 流れ星
    i = 0
    while i < @meteors.size
      m = @meteors[i]
      x1 = m[:x].round
      y1 = m[:y].round
      line(x1, y1, (x1 - m[:vx] * 4.5).round, (y1 - m[:vy] * 4.5).round, 12)
      line(x1, y1, (x1 - m[:vx] * 2.0).round, (y1 - m[:vy] * 2.0).round, 7)
      pset(x1, y1, 7)
      i += 1
    end

    # 夜空の控えめな瞬き星
    si = 0
    while si < 14
      sx = (si * 43 + 17) % 248 + 4
      sy = (si * 19 + 24) % 48 + 20
      pset(sx, sy, ((@t / 18 + si) % 3 == 0 ? 7 : 6))
      si += 1
    end

    # 遠景の丘 & 地面シルエット
    ovalfill(48, 224, 96, 36, 1)
    ovalfill(208, 226, 102, 34, 1)
    rectfill(0, 202, SCREEN_W, 54, 0)
    rectfill(0, 202, SCREEN_W, 4, 3)
    rectfill(0, 206, SCREEN_W, 8, 1)
    # 地面の小石・草テクスチャ
    px = 10
    while px < SCREEN_W
      rectfill(px, 211 + (px % 5), 2, 1, 5)
      pset((px + 11) % 250, 218 + (px % 7), 4) if px % 3 == 0
      px += 18
    end

    # 草のドット揺らぎ (不規則長)
    gx = 4
    while gx < SCREEN_W
      lean = (sin(@t * 0.05 + gx * 0.23) * 1.3).round
      h_blade = 2 + ((gx * 7) % 4)
      col_blade = (gx % 2 == 0) ? 3 : 11
      line(gx, 202, gx + lean, 202 - h_blade, col_blade)
      gx += 6 + (gx % 3)
    end

    # 焚き火の暖色グロウ輪
    pulse = sin(@t * 0.14) * 3.0 + ((@magic_t > 0) ? 8.0 : 0.0)
    circ(128, 198, (26.0 + pulse).round, 2)
    circ(128, 198, (18.0 + pulse * 0.7).round, 4)
    ovalfill(128, 205, (22.0 + pulse * 0.5).round, 4, 4)

    # スプライト配置：テント・焚き火・うさぎ・かめ
    draw_spr_grounded(@id_tent, 74.0, 208.0, 32, 24, 1.0, 1.0, false)
    fire_id = spr_id(:campfire, (@t / 6) % 3)
    draw_spr_grounded(fire_id, 128.0, 206.0, 16, 16, 1.0, 1.0, false)

    rab_id = spr_id(:camp_rabbit, (@t / 20) % 2)
    tur_id = spr_id(:camp_turtle, (@t / 24) % 2)
    draw_spr_grounded(rab_id, 164.0, 205.0, 16, 16, 1.0, 1.0, false)
    draw_spr_grounded(tur_id, 186.0, 205.0, 16, 16, 1.0, 1.0, false)

    # 火の粉
    i = 0
    while i < @embers.size
      e = @embers[i]
      pset(e[:x].round, e[:y].round, e[:col])
      i += 1
    end

    # ホタル明滅
    i = 0
    while i < @fireflies.size
      f = @fireflies[i]
      glow = sin(f[:phase] * 2.2)
      fx = f[:x].round
      fy = f[:y].round
      if glow > 0.35
        pset(fx - 1, fy, 3)
        pset(fx + 1, fy, 3)
        pset(fx, fy, 7)
      elsif glow > -0.35
        pset(fx, fy, f[:col])
      end
      i += 1
    end
  end
end

# ------------------------------------------------------------------------------
# 2. NEON HIGHWAY WORLD (:city)
# ------------------------------------------------------------------------------
class NeonHighwayWorld
  attr_reader :title, :moods

  def initialize
    @title = "NEON HIGHWAY"
    @moods = [
      { name: "CYBER NIGHT", tint: [145, 190, 255], dim: 0.36, road: 1, neon: 12, rain: false },
      { name: "SYNTHWAVE",   tint: [255, 130, 220], dim: 0.34, road: 2, neon: 14, rain: false },
      { name: "RAINY NOIR",  tint: [120, 175, 220], dim: 0.46, road: 1, neon: 12, rain: true  },
      { name: "SUNRISE",     tint: [255, 195, 145], dim: 0.30, road: 4, neon: 10, rain: false }
    ]
    @t = 0
    @scroll_far = 0.0
    @scroll_mid = 0.0
    @scroll_near = 0.0
    @speed = 1.0
    @boost_t = 0
    @sparks = []
    @rain = []
    i = 0
    while i < 36
      @rain << { x: rand() * 256.0, y: rand() * 210.0, spd: 3.4 + rand() * 1.4 }
      i += 1
    end
    @traffic = []
    i = 0
    while i < 5
      @traffic << { x: rand() * 256.0, y: 152.0 + (i % 3) * 8.0, spd: 1.6 + rand() * 1.4, col: (i % 2 == 0 ? 8 : 12) }
      i += 1
    end
  end

  def magic_label
    "NITRO OVERDRIVE!"
  end

  def trigger_magic
    @boost_t = 84
  end

  def update(mood)
    @t += 1
    if @boost_t > 0
      @boost_t -= 1
      @speed = lerp_f(@speed, 2.85, 0.16)
    else
      @speed = lerp_f(@speed, 1.0, 0.08)
    end

    @scroll_far += 0.35 * @speed
    @scroll_mid += 1.4 * @speed
    @scroll_near += 4.2 * @speed

    # 遠景の車・ドローンテールランプ
    i = 0
    while i < @traffic.size
      tr = @traffic[i]
      tr[:x] -= tr[:spd] * @speed
      if tr[:x] < -16.0
        tr[:x] = 268.0
        tr[:y] = 148.0 + rand(22).to_f
      end
      i += 1
    end

    # マフラー火花・排気粒
    if @t % 2 == 0 || @boost_t > 0
      count = (@boost_t > 0) ? 3 : 1
      k = 0
      while k < count
        @sparks << {
          x: 68.0,
          y: 211.0 + (rand() - 0.5) * 3.0,
          vx: -2.2 - rand() * 2.4 * @speed,
          vy: (rand() - 0.6) * 0.7,
          life: 10 + rand(8),
          col: (@boost_t > 0 ? (rand(2) == 0 ? 12 : 10) : (rand(2) == 0 ? 9 : 8))
        }
        k += 1
      end
    end

    kept_s = []
    i = 0
    while i < @sparks.size
      s = @sparks[i]
      s[:x] += s[:vx]
      s[:y] += s[:vy]
      s[:life] -= 1
      kept_s << s if s[:life] > 0
      i += 1
    end
    @sparks = kept_s

    # 雨モード（または常時少しの風筋）
    i = 0
    while i < @rain.size
      r = @rain[i]
      r[:x] -= 1.2 * @speed
      r[:y] += r[:spd]
      if r[:y] > 218.0 || r[:x] < -8.0
        r[:x] = rand() * 270.0
        r[:y] = -4.0
      end
      i += 1
    end
  end

  def draw(tint, dim, mood = nil)
    mood_data = mood || @moods[0]
    shake_y = (@boost_t > 0 && @t % 2 == 0) ? 1.0 : 0.0
    bg(:city, dim: dim, tint: tint, scale: 1.04, y: -3.0 - shake_y, scroll_x: @scroll_far, mirror_x: true)

    # 遠景高架光点
    i = 0
    while i < @traffic.size
      tr = @traffic[i]
      tx = tr[:x].round
      ty = tr[:y].round
      line(tx, ty, tx + 6, ty, tr[:col])
      pset(tx, ty, 7)
      i += 1
    end

    # 中景：高架橋とネオン街灯ポール (64px周期)
    rectfill(0, 178, SCREEN_W, 8, 0)
    line(0, 178, SCREEN_W, 178, mood_data[:neon])
    off_mid = (@scroll_mid.round) % 64
    px = -off_mid
    while px < SCREEN_W + 64
      # 街灯ポール
      rectfill(px + 20, 134, 2, 44, 5)
      rectfill(px + 20, 134, 9, 2, 6)
      pset(px + 28, 136, 7)
      circfill(px + 28, 137, 2, mood_data[:neon])
      # 橋脚柱
      rectfill(px + 48, 186, 6, 12, 1)
      px += 64
    end

    # 近景：ハイウェイ路面 (y: 186..256)
    rectfill(0, 186, SCREEN_W, 70, 0)
    rectfill(0, 186, SCREEN_W, 3, 5)
    line(0, 186, SCREEN_W, 186, 7)

    # 高速白破線 (40px周期)
    off_near = (@scroll_near.round) % 40
    dx = -off_near
    while dx < SCREEN_W + 40
      rectfill(dx, 208, 22, 2, 6)
      rectfill(dx + 12, 232, 18, 2, mood_data[:road])
      dx += 40
    end

    # 路肩ガードレール柱 (32px周期)
    off_rail = (@scroll_near.round) % 32
    rx = -off_rail
    while rx < SCREEN_W + 32
      rectfill(rx, 246, 3, 10, 5)
      pset(rx + 1, 247, 8)
      rx += 32
    end

    # ヘッドライト光錐 (車両前方ヘッドライト位置へぴったり合わせる)
    car_x = 96.0 + ((@boost_t > 0) ? sin(@t * 0.25) * 4.0 + 10.0 : sin(@t * 0.06) * 2.0)
    car_y = 217.0 + ((@t / 8) % 2 == 0 ? 0.0 : -0.5)
    hl_x = (car_x + 21.0).round
    hl_y = (car_y - 12.0).round
    trifill(hl_x, hl_y, 256, hl_y - 7, 256, hl_y + 11, 1)
    line(hl_x, hl_y, 256, hl_y + 2, 10)
    line(hl_x, hl_y + 1, 256, hl_y + 7, 12)

    # ニトロブースト時の極太スピード線 & アフターバーナー
    if @boost_t > 0
      line(10, 42, 74, 42, 12)
      line(160, 68, 248, 68, 7)
      line(30, 118, 110, 118, 14)
      line(180, 152, 254, 152, 12)
      # アフターバーナー三角炎
      ex = (car_x - 24.0).round
      ey = (car_y - 5.0).round
      trifill(ex, ey - 3, ex, ey + 3, ex - 22 - (@t % 8), ey, 12)
      trifill(ex, ey - 1, ex, ey + 1, ex - 13, ey, 7)
    end

    # 火花
    i = 0
    while i < @sparks.size
      s = @sparks[i]
      sx = s[:x].round
      sy = s[:y].round
      line(sx, sy, sx + 4, sy, s[:col])
      i += 1
    end

    # 主役：ネオンカー 48x24
    car_id = spr_id(:cyber_car, (@t / (@boost_t > 0 ? 2 : 5)) % 2)
    sx_c = (@boost_t > 0) ? 1.12 : 1.0
    sy_c = (@boost_t > 0) ? 0.92 : 1.0
    draw_spr_grounded(car_id, car_x, car_y + shake_y, 48, 24, sx_c, sy_c, false)

    # 雨 (RAINY NOIR)
    if mood_data[:rain]
      i = 0
      while i < @rain.size
        r = @rain[i]
        rx0 = r[:x].round
        ry0 = r[:y].round
        line(rx0, ry0, rx0 - 2, ry0 + 5, 12)
        i += 1
      end
    end
  end
end

# ------------------------------------------------------------------------------
# 3. STARLIGHT FLEET WORLD (:space)
# ------------------------------------------------------------------------------
class StarlightFleetWorld
  attr_reader :title, :moods

  def initialize
    @title = "STARLIGHT FLEET"
    @moods = [
      { name: "DEEP NEBULA",  tint: [200, 170, 255], dim: 0.25, planet_c: 13, ring_c: 12 },
      { name: "HYPER BLUE",   tint: [140, 220, 255], dim: 0.28, planet_c: 12, ring_c: 7  },
      { name: "EMERALD VOID", tint: [140, 255, 200], dim: 0.30, planet_c: 3,  ring_c: 11 },
      { name: "SOLAR FLARE",  tint: [255, 145, 110], dim: 0.28, planet_c: 2,  ring_c: 10 }
    ]
    @t = 0
    @scroll_x = 0.0
    @scroll_y = 0.0
    @warp_t = 0
    @stars = []
    i = 0
    while i < 60
      layer = i % 3
      @stars << {
        x: rand() * 256.0,
        y: rand() * 256.0,
        layer: layer,
        spd: (layer == 0 ? 0.35 : (layer == 1 ? 0.9 : 1.9)),
        col: (layer == 0 ? 5 : (layer == 1 ? 6 : 7))
      }
      i += 1
    end
    @trails = []
    @warp_rings = []
  end

  def magic_label
    "HYPER WARP!"
  end

  def trigger_magic
    @warp_t = 90
  end

  def update
    @t += 1
    warp_mul = 1.0
    if @warp_t > 0
      @warp_t -= 1
      warp_mul = 6.5
      if @warp_t % 10 == 0
        @warp_rings << { x: 184.0, r: 8.0, col: (@warp_t % 20 == 0 ? 12 : 7), life: 22 }
      end
    end

    @scroll_x += 0.25 * warp_mul
    @scroll_y += 0.08

    # スターフィールド更新
    i = 0
    while i < @stars.size
      st = @stars[i]
      st[:x] -= st[:spd] * warp_mul
      if st[:x] < -16.0
        st[:x] = 264.0
        st[:y] = rand() * 256.0
      end
      i += 1
    end

    # 艦隊イオントレイル
    if @t % 2 == 0
      fy = 128.0 + sin(@t * 0.04) * 5.0
      @trails << { x: 108.0, y: fy - 3.0, vx: -1.8 * warp_mul, life: 16, col: 12 }
      @trails << { x: 108.0, y: fy + 3.0, vx: -1.8 * warp_mul, life: 16, col: 7 }
      # 護衛機 3機の噴射
      offsets = [[-44.0, -40.0, 0.0], [-56.0, 42.0, 1.5], [-26.0, 56.0, 3.0]]
      k = 0
      while k < 3
        o = offsets[k]
        ey = 128.0 + o[1] + sin(@t * 0.06 + o[2]) * 6.0
        @trails << { x: 132.0 + o[0] - 8.0, y: ey, vx: -2.0 * warp_mul, life: 12, col: 12 }
        k += 1
      end
    end

    kept_t = []
    i = 0
    while i < @trails.size
      tr = @trails[i]
      tr[:x] += tr[:vx]
      tr[:life] -= 1
      kept_t << tr if tr[:life] > 0
      i += 1
    end
    @trails = kept_t

    kept_w = []
    i = 0
    while i < @warp_rings.size
      wr = @warp_rings[i]
      wr[:x] += 3.2
      wr[:r] += 1.8
      wr[:life] -= 1
      kept_w << wr if wr[:life] > 0
      i += 1
    end
    @warp_rings = kept_w
  end

  def draw(tint, dim, mood = nil)
    mood_data = mood || @moods[0]
    bg(:space, dim: dim, tint: tint, scroll_x: @scroll_x, scroll_y: @scroll_y, loop_x: true, loop_y: true)

    warping = @warp_t > 0

    # 奥層のスターフィールド (layer 0, 1: 惑星より奥)
    i = 0
    while i < @stars.size
      st = @stars[i]
      if st[:layer] < 2
        sx = st[:x].round
        sy = st[:y].round
        if warping
          len = (st[:spd] * 10.0).round
          line(sx, sy, sx + len, sy, st[:col])
        else
          pset(sx, sy, st[:col])
        end
      end
      i += 1
    end

    # 遠景のリング付き惑星
    px = 54
    py = 64
    circfill(px, py, 20, 1)
    circfill(px - 2, py - 2, 18, mood_data[:planet_c])
    oval(px, py, 34, 8, mood_data[:ring_c])
    # 惑星手前半分を上書き描画してリングが奥を回る立体感
    clip(px - 22, py - 22, 44, 22)
    circfill(px - 2, py - 2, 18, mood_data[:planet_c])
    clip()

    # 手前層のスターフィールド (layer 2: 惑星より手前)
    i = 0
    while i < @stars.size
      st = @stars[i]
      if st[:layer] == 2
        sx = st[:x].round
        sy = st[:y].round
        if warping
          len = (st[:spd] * 10.0).round
          line(sx, sy, sx + len, sy, st[:col])
        elsif i % 6 == 0
          pset(sx - 1, sy, 12)
          pset(sx + 1, sy, 12)
          pset(sx, sy - 1, 12)
          pset(sx, sy + 1, 12)
          pset(sx, sy, 7)
        else
          pset(sx, sy, st[:col])
        end
      end
      i += 1
    end

    # ワープリング
    i = 0
    while i < @warp_rings.size
      wr = @warp_rings[i]
      oval(wr[:x].round, 128, (wr[:r] * 0.35).round, wr[:r].round, wr[:col])
      i += 1
    end

    # イオン航跡
    i = 0
    while i < @trails.size
      tr = @trails[i]
      tx = tr[:x].round
      ty = tr[:y].round
      line(tx, ty, tx + 6, ty, tr[:col])
      i += 1
    end

    # 旗艦 48x32 & 護衛戦闘機 3機 16x16
    ship_x = 136.0 + ((@warp_t > 0) ? sin(@warp_t * 0.2) * 14.0 : 0.0)
    ship_y = 128.0 + sin(@t * 0.04) * 5.0
    sx_ship = (@warp_t > 0) ? 1.24 : 1.0
    sy_ship = (@warp_t > 0) ? 0.84 : 1.0
    flag_id = spr_id(:flagship, (@t / 6) % 2)
    draw_spr_centered(flag_id, ship_x, ship_y, 48, 32, 0.0, sx_ship, sy_ship, false)

    offsets = [[-44.0, -40.0, 0.0], [-56.0, 42.0, 1.5], [-26.0, 56.0, 3.0]]
    f_id = spr_id(:fighter, (@t / 5) % 2)
    k = 0
    while k < 3
      o = offsets[k]
      fx = 132.0 + o[0] + sin(@t * 0.03 + o[2]) * 4.0
      fy = 128.0 + o[1] + sin(@t * 0.06 + o[2]) * 6.0
      draw_spr_centered(f_id, fx, fy, 16, 16, 0.0, 1.0, 1.0, false)
      k += 1
    end
  end
end

# ------------------------------------------------------------------------------
# 4. CRYSTAL GROTTO WORLD (:cave) - リアルタイム水面鏡面反射
# ------------------------------------------------------------------------------
class CrystalGrottoWorld
  attr_reader :title, :moods

  def initialize
    @title = "CRYSTAL GROTTO"
    @moods = [
      { name: "AZURE CRYSTAL",  tint: [130, 215, 255], dim: 0.42, spore: 12, water: 1 },
      { name: "AMETHYST",       tint: [220, 145, 255], dim: 0.44, spore: 14, water: 2 },
      { name: "EMERALD SPRING", tint: [120, 240, 185], dim: 0.42, spore: 11, water: 1 },
      { name: "MAGMA CORE",     tint: [255, 130, 100], dim: 0.40, spore: 9,  water: 2 }
    ]
    @t = 0
    @resonate_t = 0
    @water_y = 168.0
    @spores = []
    i = 0
    while i < 24
      @spores << {
        x: 20.0 + rand() * 216.0,
        y: 36.0 + rand() * 124.0,
        vy: -0.15 - rand() * 0.25,
        phase: rand() * 6.28318,
        col: (i % 2 == 0 ? 12 : 7)
      }
      i += 1
    end
    @drops = []
    @ripples = []
  end

  def magic_label
    "CRYSTAL RESONANCE!"
  end

  def trigger_magic
    @resonate_t = 48
    @ripples << { x: 128.0, y: 186.0, rx: 6.0, ry: 2.0, col: 7, life: 36, max_life: 36 }
    @ripples << { x: 54.0,  y: 182.0, rx: 4.0, ry: 1.5, col: 12, life: 30, max_life: 30 }
    @ripples << { x: 202.0, y: 182.0, rx: 4.0, ry: 1.5, col: 12, life: 30, max_life: 30 }
  end

  def update
    @t += 1
    @resonate_t -= 1 if @resonate_t > 0

    # 光の胞子
    i = 0
    while i < @spores.size
      sp = @spores[i]
      sp[:y] += sp[:vy] - (@resonate_t > 0 ? 0.4 : 0.0)
      sp[:x] += sin(@t * 0.04 + sp[:phase]) * 0.2
      if sp[:y] < 24.0
        sp[:y] = 162.0
        sp[:x] = 20.0 + rand() * 216.0
      end
      i += 1
    end

    # 天井からの水滴
    if @t % 38 == 0
      @drops << { x: 28.0 + rand() * 200.0, y: 18.0, vy: 1.6 }
    end

    kept_d = []
    i = 0
    while i < @drops.size
      d = @drops[i]
      d[:y] += d[:vy]
      d[:vy] += 0.09
      if d[:y] >= @water_y + 8.0
        @ripples << { x: d[:x], y: d[:y], rx: 2.0, ry: 1.0, col: 12, life: 28, max_life: 28 }
      else
        kept_d << d
      end
      i += 1
    end
    @drops = kept_d

    kept_r = []
    i = 0
    while i < @ripples.size
      r = @ripples[i]
      r[:life] -= 1
      r[:rx] += 0.65
      r[:ry] += 0.22
      kept_r << r if r[:life] > 0
      i += 1
    end
    @ripples = kept_r
  end

  def draw(tint, dim, mood = nil)
    mood_data = mood || @moods[0]
    bg(:cave, dim: dim, tint: tint, scale: 1.04, y: -2.0, scroll_x: sin(@t * 0.006) * 8.0, mirror_x: true)

    crys_id = spr_id(:crystal, (@t / 14) % 2)
    spir_id = spr_id(:spirit, (@t / 12) % 2)
    res_pal = nil
    if @resonate_t > 34
      res_pal = 10
    elsif @resonate_t > 18
      res_pal = 11
    elsif @resonate_t > 0 && @resonate_t % 6 < 3
      res_pal = 12
    end

    spir_y = 136.0 + sin(@t * 0.06) * 5.0
    wy = @water_y.round

    # 1. 水面下の暗幕＆リアルタイム鏡面反射 (clip内で flip_y: true)
    rectfill(0, wy, SCREEN_W, SCREEN_H - wy, 0)
    rectfill(0, wy, SCREEN_W, 18, mood_data[:water])

    clip(0, wy, SCREEN_W, SCREEN_H - wy)
    wobble = sin(@t * 0.08) * 1.5
    # 鏡像 水晶群（上下反転して水面にピタリと接地）
    draw_spr_centered(crys_id, 46.0 + wobble,  wy + 14.4, 32, 32, 0.0, 1.0,  0.9,  false, true, res_pal)
    draw_spr_centered(crys_id, 210.0 - wobble, wy + 14.4, 32, 32, 0.0, 1.0,  0.9,  true,  true, res_pal)
    draw_spr_centered(crys_id, 84.0 - wobble,  wy + 9.4,  32, 32, 0.0, 0.65, 0.58, true,  true, res_pal)
    draw_spr_centered(crys_id, 174.0 + wobble, wy + 9.4,  32, 32, 0.0, 0.65, 0.58, false, true, res_pal)
    # 鏡像 精霊
    ref_sy = wy + (wy - spir_y) * 0.75
    draw_spr_centered(spir_id, 128.0 + wobble, ref_sy, 16, 16, 0.0, 1.0, 0.85, false, true, res_pal)

    # 水面反射横ラインの揺らぎディザ
    ry = wy + 4
    while ry < SCREEN_H
      rx_off = (sin(@t * 0.1 + ry * 0.4) * 6.0).round
      line(20 + rx_off, ry, 58 + rx_off, ry, 1) if ry % 6 == 0
      line(170 - rx_off, ry, 218 - rx_off, ry, 1) if ry % 6 == 2
      ry += 4
    end
    clip()

    # 水面境界線
    line(0, wy, SCREEN_W, wy, 12)
    shimmer_x = (@t * 2) % 256
    line(shimmer_x, wy, shimmer_x + 28, wy, 7)

    # 波紋
    i = 0
    while i < @ripples.size
      r = @ripples[i]
      oval(r[:x].round, r[:y].round, r[:rx].round, r[:ry].round, r[:col])
      i += 1
    end

    # 上部：岩棚 & 水晶群 & 精霊 (水晶土台を水面ラインに接地)
    ovalfill(128, wy + 2, 16, 3, 1)
    ovalfill(128, wy, 18, 4, 5)
    draw_spr_grounded(crys_id, 46.0,  wy + 1.0, 32, 32, 1.0,  1.0,  false, res_pal)
    draw_spr_grounded(crys_id, 210.0, wy + 1.0, 32, 32, 1.0,  1.0,  true,  res_pal)
    draw_spr_grounded(crys_id, 84.0,  wy + 1.0, 32, 32, 0.65, 0.65, true,  res_pal)
    draw_spr_grounded(crys_id, 174.0, wy + 1.0, 32, 32, 0.65, 0.65, false, res_pal)
    draw_spr_centered(spir_id, 128.0, spir_y, 16, 16, 0.0, 1.0, 1.0, false, false, res_pal)

    # 共鳴パルス輪
    if @resonate_t > 0
      rr = (48 - @resonate_t) * 2.8
      circ(128, spir_y.round, rr.round, 7)
      circ(128, spir_y.round, (rr * 0.7).round, 12)
    end

    # 天井水滴 & 光胞子
    i = 0
    while i < @drops.size
      d = @drops[i]
      line(d[:x].round, d[:y].round, d[:x].round, d[:y].round - 3, 7)
      i += 1
    end

    i = 0
    while i < @spores.size
      sp = @spores[i]
      pset(sp[:x].round, sp[:y].round, (@t / 8 + i) % 3 == 0 ? 7 : mood_data[:spore])
      i += 1
    end
  end
end

# ------------------------------------------------------------------------------
# 5. CYBER HORIZON WORLD (:cyber) - リアルタイム3Dワイヤーフレーム + Zソートドローン
# ------------------------------------------------------------------------------
class CyberHorizonWorld
  attr_reader :title, :moods

  OCT_VERTS = [
    [ 1.0,  0.0,  0.0], [-1.0,  0.0,  0.0],
    [ 0.0,  1.0,  0.0], [ 0.0, -1.0,  0.0],
    [ 0.0,  0.0,  1.0], [ 0.0,  0.0, -1.0]
  ]
  OCT_EDGES = [
    [0, 2], [0, 3], [0, 4], [0, 5],
    [1, 2], [1, 3], [1, 4], [1, 5],
    [2, 4], [4, 3], [3, 5], [5, 2]
  ]
  CUBE_VERTS = [
    [-0.46, -0.46, -0.46], [ 0.46, -0.46, -0.46],
    [ 0.46,  0.46, -0.46], [-0.46,  0.46, -0.46],
    [-0.46, -0.46,  0.46], [ 0.46, -0.46,  0.46],
    [ 0.46,  0.46,  0.46], [-0.46,  0.46,  0.46]
  ]
  CUBE_EDGES = [
    [0, 1], [1, 2], [2, 3], [3, 0],
    [4, 5], [5, 6], [6, 7], [7, 4],
    [0, 4], [1, 5], [2, 6], [3, 7]
  ]

  def initialize
    @title = "CYBER HORIZON"
    @moods = [
      { name: "TRON CYAN",    tint: [120, 230, 255], dim: 0.36, grid: 12, accent: 14, sun1: 10, sun2: 8  },
      { name: "VAPORWAVE",    tint: [255, 130, 215], dim: 0.34, grid: 14, accent: 12, sun1: 10, sun2: 14 },
      { name: "MATRIX GREEN", tint: [110, 255, 155], dim: 0.40, grid: 11, accent: 7,  sun1: 11, sun2: 3  },
      { name: "CRIMSON CORE", tint: [255, 80, 115],  dim: 0.38, grid: 8,  accent: 10, sun1: 9,  sun2: 8  }
    ]
    @t = 0
    @ax = 0.4
    @ay = 0.0
    @az = 0.2
    @pulse_t = 0
    @pulse_wave_y = 152.0
    @drones = []
    i = 0
    while i < 4
      @drones << { ang: i * 1.5708, x: 128.0, y: 108.0, z: 0.0, scale: 1.0 }
      i += 1
    end
  end

  def magic_label
    "SYSTEM PULSE!"
  end

  def trigger_magic
    @pulse_t = 52
    @pulse_wave_y = 152.0
  end

  def update
    @t += 1
    spin = (@pulse_t > 0) ? 3.5 : 1.0
    @pulse_t -= 1 if @pulse_t > 0
    @pulse_wave_y += 2.6 if @pulse_t > 0

    @ax += 0.018 * spin
    @ay += 0.026 * spin
    @az += 0.011 * spin

    i = 0
    while i < @drones.size
      d = @drones[i]
      d[:ang] += 0.028 * spin
      rad_x = 64.0 + ((@pulse_t > 0) ? 14.0 : 0.0)
      d[:x] = 128.0 + cos(d[:ang]) * rad_x
      d[:z] = sin(d[:ang])
      d[:y] = 104.0 + sin(d[:ang] * 2.0) * 10.0 + d[:z] * 12.0
      d[:scale] = 0.70 + (d[:z] + 1.0) * 0.25
      i += 1
    end
  end

  def project_vertex(v, ax, ay, az, fov)
    x = v[0]
    y = v[1]
    z = v[2]

    # Y回転
    cy = cos(ay)
    sy = sin(ay)
    x1 = x * cy + z * sy
    z1 = -x * sy + z * cy

    # X回転
    cx = cos(ax)
    sx = sin(ax)
    y2 = y * cx - z1 * sx
    z2 = y * sx + z1 * cx

    # Z回転
    cz = cos(az)
    sz = sin(az)
    x3 = x1 * cz - y2 * sz
    y3 = x1 * sz + y2 * cz

    depth = z2 + 3.1
    depth = 0.5 if depth < 0.5
    [
      128.0 + (x3 / depth) * fov,
      104.0 + (y3 / depth) * fov
    ]
  end

  def draw_wireframe(verts, edges, ax, ay, az, fov, col, draw_nodes)
    proj = []
    i = 0
    while i < verts.size
      proj << project_vertex(verts[i], ax, ay, az, fov)
      i += 1
    end

    i = 0
    while i < edges.size
      e = edges[i]
      p0 = proj[e[0]]
      p1 = proj[e[1]]
      line(p0[0].round, p0[1].round, p1[0].round, p1[1].round, col)
      i += 1
    end

    if draw_nodes
      i = 0
      while i < proj.size
        pt = proj[i]
        rectfill(pt[0].round - 1, pt[1].round - 1, 2, 2, 7)
        i += 1
      end
    end
  end

  def draw(tint, dim, mood = nil)
    mood_data = mood || @moods[0]
    bg(:cyber, dim: dim, tint: tint, scale: 1.04, y: -2.0, scroll_x: @t * 0.35, mirror_x: true)

    hy = 152

    # 水平線に沈むシンセサン (ストライプ抜き)
    sun_y = 136
    circfill(128, sun_y, 38, mood_data[:sun1])
    clip(86, sun_y - 6, 84, 46)
    circfill(128, sun_y, 38, mood_data[:sun2])
    clip()
    # スリット抜き (太陽の円弧幅にぴったり合わせる)
    sy = sun_y - 3
    slit_h = 1
    while sy < hy
      dy = (sy + slit_h * 0.5) - sun_y
      if dy.abs < 38.0
        hw = sqrt(38.0 * 38.0 - dy * dy).floor
        rectfill(128 - hw, sy, hw * 2, slit_h, 0) if hw > 0
      end
      sy += 5
      slit_h += 1 if slit_h < 3 && sy > sun_y + 4
    end

    # 遠近サイバーグリッド床 (y=152..256)
    rectfill(0, hy, SCREEN_W, SCREEN_H - hy, 0)
    line(0, hy, SCREEN_W, hy, 7)

    # 水平進行ライン (疑似パース)
    i = 0
    while i < 8
      phase = ((@t * 0.025 + i * 0.125) % 1.0)
      gy = hy + (phase * phase * 104.0).round
      line(0, gy, SCREEN_W, gy, mood_data[:grid])
      i += 1
    end

    # 放射ライン
    k = -6
    while k <= 6
      line(128 + k * 8, hy, 128 + k * 42, SCREEN_H, mood_data[:grid])
      k += 1
    end

    if @pulse_t > 0 && @pulse_wave_y <= 256.0
      line(0, @pulse_wave_y.round, SCREEN_W, @pulse_wave_y.round, 7)
      line(0, @pulse_wave_y.round + 1, SCREEN_W, @pulse_wave_y.round + 1, mood_data[:accent])
    end

    drone_id = spr_id(:holo_drone, (@t / 8) % 2)
    drone_pal = (@pulse_t > 32) ? 10 : nil

    # 奥のドローン (z < 0)
    i = 0
    while i < @drones.size
      d = @drones[i]
      if d[:z] < 0.0
        draw_spr_centered(drone_id, d[:x], d[:y], 16, 16, 0.0, d[:scale], d[:scale], false, false, drone_pal)
      end
      i += 1
    end

    # 3D ワイヤーフレーム (内殻キューブ + 外殻八面体)
    fov = 82.0 + ((@pulse_t > 0) ? sin((@pulse_t / 52.0) * 3.14159) * 26.0 : 0.0)
    draw_wireframe(CUBE_VERTS, CUBE_EDGES, -@ax * 1.3, -@ay * 1.5, @az, fov, mood_data[:accent], false)
    draw_wireframe(OCT_VERTS, OCT_EDGES, @ax, @ay, @az, fov, (@pulse_t > 38 ? 7 : mood_data[:grid]), true)

    # 手前のドローン (z >= 0)
    i = 0
    while i < @drones.size
      d = @drones[i]
      if d[:z] >= 0.0
        draw_spr_centered(drone_id, d[:x], d[:y], 16, 16, 0.0, d[:scale], d[:scale], false, false, drone_pal)
      end
      i += 1
    end
  end
end

# ------------------------------------------------------------------------------
# メインシーン: DioramaScene
# ------------------------------------------------------------------------------
class DioramaScene
  UI_MODES = [:panel, :cinema, :clean]

  def initialize(start_idx = 0, ui_mode_idx = 0)
    @worlds = [
      FireflyCampWorld.new,
      NeonHighwayWorld.new,
      StarlightFleetWorld.new,
      CrystalGrottoWorld.new,
      CyberHorizonWorld.new
    ]
    @idx = start_idx % @worlds.size
    @mood_indices = [0, 0, 0, 0, 0]
    @ui_mode = ui_mode_idx

    init_mood = current_mood
    @cur_tint = [init_mood[:tint][0].to_f, init_mood[:tint][1].to_f, init_mood[:tint][2].to_f]
    @cur_dim = init_mood[:dim].to_f

    @wipe_t = 0
    @toast_text = ""
    @toast_t = 0
    @frame = 0
  end

  def current_world
    @worlds[@idx]
  end

  def current_mood
    w = current_world
    m_idx = @mood_indices[@idx]
    w.moods[m_idx]
  end

  def show_toast(msg)
    @toast_text = msg
    @toast_t = 65
  end

  def switch_world(delta)
    @idx = (@idx + delta) % @worlds.size
    @wipe_t = 14
    m = current_mood
    @cur_tint = [m[:tint][0].to_f, m[:tint][1].to_f, m[:tint][2].to_f]
    @cur_dim = m[:dim].to_f
    show_toast("#{current_world.title} - #{m[:name]}")
  end

  def switch_mood(delta)
    w = current_world
    @mood_indices[@idx] = (@mood_indices[@idx] + delta) % w.moods.size
    show_toast("MOOD: #{current_mood[:name]}")
  end

  def update
    @frame += 1
    @wipe_t -= 1 if @wipe_t > 0
    @toast_t -= 1 if @toast_t > 0

    if btnp(:left)
      switch_world(-1)
    elsif btnp(:right)
      switch_world(1)
    end

    if btnp(:up)
      switch_mood(-1)
    elsif btnp(:down)
      switch_mood(1)
    end

    if btnp(1)
      current_world.trigger_magic
      show_toast(current_world.magic_label)
    end

    if btnp(2)
      @ui_mode = (@ui_mode + 1) % UI_MODES.size
      mode_names = ["PANEL UI", "CINEMA MODE", "CLEAN VIEW"]
      show_toast(mode_names[@ui_mode])
    end

    # ターゲットムードの tint / dim へ滑らか補間
    target = current_mood
    tt = target[:tint]
    @cur_tint[0] = lerp_f(@cur_tint[0], tt[0].to_f, 0.08)
    @cur_tint[1] = lerp_f(@cur_tint[1], tt[1].to_f, 0.08)
    @cur_tint[2] = lerp_f(@cur_tint[2], tt[2].to_f, 0.08)
    @cur_dim = lerp_f(@cur_dim, target[:dim].to_f, 0.08)

    # 各ワールド更新
    w = current_world
    if @idx == 1
      w.update(target)
    else
      w.update
    end
  end

  def draw
    cls(0)
    tint_rgb = [@cur_tint[0].round, @cur_tint[1].round, @cur_tint[2].round]
    w = current_world
    if @idx == 1 || @idx == 2 || @idx == 3 || @idx == 4
      w.draw(tint_rgb, @cur_dim, current_mood)
    else
      w.draw(tint_rgb, @cur_dim)
    end

    clip()
    camera()

    # ワイプ遷移演出
    if @wipe_t > 0
      h = ((@wipe_t.to_f / 14.0) * 128.0).round
      rectfill(0, 0, SCREEN_W, h, 0)
      rectfill(0, SCREEN_H - h, SCREEN_W, h, 0)
      line(0, h, SCREEN_W, h, 12)
      line(0, SCREEN_H - h, SCREEN_W, SCREEN_H - h, 12)
    end

    ui = UI_MODES[@ui_mode]
    if ui == :panel
      draw_panel_ui
    elsif ui == :cinema
      draw_cinema_ui
    end

    # トースト通知 (CLEANモード以外で表示)
    if @toast_t > 0 && ui != :clean
      ty = (ui == :panel) ? 26 : 28
      tw = @toast_text.length * 6 + 12
      tx = 128 - tw / 2
      rectfill(tx, ty, tw, 13, 0)
      rect(tx, ty, tw, 13, 12)
      draw_shadow_text(@toast_text, tx + 6, ty + 3, 7)
    end
  end

  def draw_panel_ui
    # 上部ヘッダー
    rectfill(0, 0, SCREEN_W, 18, 0)
    line(0, 18, SCREEN_W, 18, 5)
    left_txt = "#{@idx + 1}/5 #{current_world.title}"
    draw_shadow_text(left_txt, 6, 5, 10)
    m_txt = current_mood[:name]
    draw_shadow_text(m_txt, SCREEN_W - m_txt.length * 6 - 6, 5, 12)

    # 下部操作バー
    rectfill(0, 240, SCREEN_W, 16, 0)
    line(0, 240, SCREEN_W, 240, 5)
    guide = "<->:SCENE ^v:MOOD Z:MAGIC X:UI"
    draw_shadow_text(guide, center_text_x(guide), 244, 7)
  end

  def draw_cinema_ui
    rectfill(0, 0, SCREEN_W, 20, 0)
    rectfill(0, 236, SCREEN_W, 20, 0)
    line(0, 20, SCREEN_W, 20, 1)
    line(0, 236, SCREEN_W, 236, 1)
    cap = "#{current_world.title} / #{current_mood[:name]}"
    draw_shadow_text(cap, SCREEN_W - cap.length * 6 - 8, 242, 6)
  end
end

run DioramaScene.new

__END__
# ==============================================================================
# カスタムパレット (1..5: ジオラマ固有色, 10..12: 共鳴発光用)
# ==============================================================================
@PALETTE 1
0: #0E101E
1: #1D2B53
2: #7E2553
3: #1E6B43
4: #8B4530
5: #534A48
6: #A8B5C8
7: #FFF4E0
8: #FF3830
9: #FF9418
A: #FFE642
B: #38C858
C: #45B6FE
D: #9BE8FF
E: #FF77A8
F: #FFD4B8

@PALETTE 2
0: #090814
1: #191B3A
2: #581845
4: #7A1830
5: #363C66
6: #7082B8
7: #F4FBFF
8: #FF1E6E
9: #FF8822
A: #FFEE44
C: #00D8FF
D: #8CF2FF
E: #FF66CC
F: #B8C8FF

@PALETTE 3
0: #0B0D1C
1: #1B2848
2: #5B245C
5: #3D517A
6: #869BC2
7: #F5FAFF
8: #FF3366
9: #FF9933
A: #FFE44D
C: #29C8FF
D: #8EEBFF
F: #CEDCF2

@PALETTE 4
0: #0B1224
1: #1A2D56
2: #5A2875
3: #14526E
5: #394868
6: #7484A8
7: #F4FFFF
9: #4880D8
A: #80F0FF
B: #50C8B8
C: #29B8FF
D: #A880FF
E: #FF88E8
F: #D8F8FF

@PALETTE 5
0: #080A18
1: #161E42
5: #344474
6: #7088C4
7: #F0FFFF
8: #FF1E6E
A: #FFEC27
C: #00E0FF
D: #8CF5FF
E: #FF66CC

@PALETTE 10
#FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0
#FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0 #FFF8F0

@PALETTE 11
#1868A8 #1868A8 #2898D8 #2898D8 #2898D8 #40C8FF #80E8FF #F0FFFF
#2898D8 #40C8FF #80E8FF #40C8FF #80E8FF #F0FFFF #80E8FF #F0FFFF

@PALETTE 12
#A86000 #C87800 #C87800 #E09800 #E09800 #FFCC22 #FFE866 #FFFCE8
#FFB000 #FFCC22 #FFEC27 #FFCC22 #FFE866 #FFFCE8 #FFE866 #FFFCE8

# ==============================================================================
# スプライト定義 (全10種)
# ==============================================================================
@SPRITE :campfire 16x16 pal:1
.......8........
......89........
......9A8.......
.....89A9.......
....89AA79......
....9AA77A8.....
...89A777A9.....
...89AA7AA98....
....89AAA98.....
....04488440....
..044400004440..
.05654444445650.
.06505655650560.
..00.065560.00..
......0000......
................
---
........8.......
.......98.......
......8A9.......
.....9AA8.......
....89A798......
....9AA779......
...89A777A8.....
...9AAA7AA9.....
....89AAA98.....
....04488440....
..044400004440..
.05654444445650.
.06505655650560.
..00.065560.00..
......0000......
................
---
......8.........
.......98.......
......9A8.......
.....8AA98......
....9AA7A9......
...89A77798.....
...9AA777A9.....
...89AA7AA9.....
....89AAA98.....
....04488440....
..044400004440..
.05654444445650.
.06505655650560.
..00.065560.00..
......0000......
................

@SPRITE :tent 32x24 pal:1
...............00...............
..............0BB0..............
.............0BBBB0.............
............0BB77BB0............
...........0BBB77BBB0...........
..........0BBBB77BBBB0..........
.........0BBBB3333BBBB0.........
........0BBBB333333BBBB0........
.......0BBBB33999933BBBB0.......
......0BBBB339AAAA933BBBB0......
.....0BBBB339AA77AA933BBBB0.....
....0BBBB339AA7777AA933BBBB0....
...0BBBB339AAA7777AAA933BBBB0...
..0BBBB339AAAA7777AAAA933BBBB0..
.033BB33399AAA7777AAA99333BB330.
.03333333999AA7777AA99933333330.
040333333999AA7777AA999333333040
040033333099AA7777AA990333330040
.0..03330.09AA7777AA90.03330..0.
....0330...09A7777A90...0330....
....000.....00000000.....000....
................................
................................
................................

@SPRITE :camp_rabbit 16x16 pal:1
.....00..00.....
....07E00E70....
....07E00E70....
....07700770....
...0777777770...
...0707777770...
...07E7777770...
....00CCCCC00...
....0CC7777C0...
....077777770...
....077777770...
.....07777770...
....077777700...
...044000440....
...000...000....
................
---
................
.....00..00.....
....07E00E70....
....07E00E70....
....07700770....
...0777777770...
...0707777770...
...07E7777770...
....00CCCCC00...
....0CC7777C0...
....077777770...
....077777770...
.....07777770...
....077777700...
...044000440....
...000...000....

@SPRITE :camp_turtle 16x16 pal:1
................
................
................
..0000..........
.0BBBB0..00000..
0B0BBBB00BBBBB0.
0BBBBBB0BB333BB0
.0BBBB0BB3BBB3BB
..000B0B3BBBBB3B
....0BBBB33333B0
...0BBBBBBBBBB0.
...07777777770..
...0BB00000BB0..
...0330...0330..
...000.....000..
................
---
................
................
................
................
..0000..........
.0BBBB0..00000..
0B0BBBB00BBBBB0.
0BBBBBB0BB333BB0
.0BBBB0BB3BBB3BB
..000B0B3BBBBB3B
....0BBBB33333B0
...0BBBBBBBBBB0.
...07777777770..
...0BB00000BB0..
...0330...0330..
...000.....000..

@SPRITE :cyber_car 48x24 pal:2
................................................
................................................
................................................
................................................
.............000000000000000000.................
...........0066FFFFFFFFFFF666CC00...............
..........066FFCCCCDDDDDDCCFFFF6600.............
.........06FFCCDDDD77777DDDCCCCCC6600...........
........06FCCDD7777DDDDDDDDCCCCCCCC6600.........
...0000056FFFFFFFFFFFFFFFFFFFFFFFFF66660000.....
..0888055666666666666666666666666666666666A70...
.08E8055588888888888888888888888888888888AA770..
0488055511111111111111111111111111111111156770..
04405511CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC515660..
000551100000005555555555555555550000000115550...
..05510066F660055555555555555550066F66001550....
.....006F777F60000000000000000006F777F6000......
.....06F7C7C7F60................6F7C7C7F60......
.....06677C77660................6677C77660......
......0066F6600..................0066F6600......
........00000......................00000........
................................................
................................................
................................................
---
................................................
................................................
................................................
................................................
.............000000000000000000.................
...........0066FFFFFFFFFFF666CC00...............
..........066FFCCCCDDDDDDCCFFFF6600.............
.........06FFCCDDDD77777DDDCCCCCC6600...........
........06FCCDD7777DDDDDDDDCCCCCCCC6600.........
...0000056FFFFFFFFFFFFFFFFFFFFFFFFF66660000.....
..0888055666666666666666666666666666666666A70...
.08E80555EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEAA770..
0488055511111111111111111111111111111111156770..
04405511DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD515660..
000551100000005555555555555555550000000115550...
..05510066F660055555555555555550066F66001550....
.....006FC7CF60000000000000000006FC7CF6000......
.....06F77777F60................6F77777F60......
.....066C777C660................66C777C660......
......0066F6600..................0066F6600......
........00000......................00000........
................................................
................................................
................................................

@SPRITE :flagship 48x32 pal:3
................................................
................................................
....................00000000....................
...................06FFFFFF60...................
..................06FCCCCCCF60..................
.................056FCD77DCF60..................
...........0000005566FFFFFF650..................
..........06FFFF65555666666550000...............
.........06F888FF6655555555566FFF600............
........056888866FFFFFFFFFFFFFFFFFF600..........
......005666666FFFFFFFFFFFFFFFFFFFFFF600........
....00995566FFFFF6666666666666FFFFFFF77600......
..0CC99956FFFFFF6555CCCCCC55566FFFFFFFFF7600....
.0CD7D9556FFFF66555CD7777DC555566FFFFFFFFFF60...
0CD7779556666655555CCCCCCCC55555566666FFFFF760..
0CD7779555555555555111111115555555555566666660..
.0CD7D95566666555558888888855555566666FFFFFF60..
..0CC99956FFFF6655511111111555566FFFFFFFFFF60...
....00995566FFFF665555555555566FFFFFFF76600.....
......0056666666FFFFFFFFFFFFFFFFFFFF6600........
........056888866FFFFFFFFFFFFFFFF6600...........
.........06F888FF66555555555566600..............
..........06FFFF65555566666550..................
...........00000055566FFFF650...................
.................05566666650....................
..................011555510.....................
...................0011100......................
................................................
................................................
................................................
................................................
................................................
---
................................................
................................................
....................00000000....................
...................06FFFFFF60...................
..................06FDDDDDDF60..................
.................056FD7777DF60..................
...........0000005566FFFFFF650..................
..........06FFFF65555666666550000...............
.........06F888FF6655555555566FFF600............
........056888866FFFFFFFFFFFFFFFFFF600..........
......005666666FFFFFFFFFFFFFFFFFFFFFF600........
....00995566FFFFF6666666666666FFFFFFF77600......
..0DD99956FFFFFF6555DDDDDD55566FFFFFFFFF7600....
0CD77D9556FFFF66555D777777D555566FFFFFFFFFF60...
0D77779556666655555DDDDDDDD55555566666FFFFF760..
0D77779555555555555111111115555555555566666660..
0CD77D95566666555558888888855555566666FFFFFF60..
..0DD99956FFFF6655511111111555566FFFFFFFFFF60...
....00995566FFFF665555555555566FFFFFFF76600.....
......0056666666FFFFFFFFFFFFFFFFFFFF6600........
........056888866FFFFFFFFFFFFFFFF6600...........
.........06F888FF66555555555566600..............
..........06FFFF65555566666550..................
...........00000055566FFFF650...................
.................05566666650....................
..................011555510.....................
...................0011100......................
................................................
................................................
................................................
................................................
................................................

@SPRITE :fighter 16x16 pal:3
................
................
....000.........
...06F60........
...056FF00......
..09556FFF00....
.0C956FFCCFF00..
0D7956FCD7DCFF0.
0D7956FCCCCCFF0.
.0C956FFFFFF00..
..09556FFF00....
...056FF00......
...06F60........
....000.........
................
................
---
................
................
....000.........
...06F60........
...056FF00......
..09556FFF00....
0DC956FFDDFF00..
077956FD77DDFF0.
077956FDDDDDFF0.
0DC956FFFFFF00..
..09556FFF00....
...056FF00......
...06F60........
....000.........
................
................

@SPRITE :crystal 32x32 pal:4
................................
................................
................................
................................
................................
................................
................................
..............00................
.............07A0...............
............07CCA0..............
...........07CCAAA0.............
..........079CCAAFF0............
.........0799CCAAFFC0...........
.........0999CCAAFCC0...........
....00...0919CCAAFCC0...........
...07E0..0919CCA9FCC0...00......
..07DDA0.0919CCA9FC90..07A0.....
..07DD90.0919CC99FC90.07CCA0....
.072DD90.0919CC99F990.07CAA0....
.022DD90.0911C999999007CCAFF0...
.022DD90.01119999991009CCAFCC0..
.022DD10.01119999911009CCAFCC0..
..02DD10.011199991110099CA9CC0..
..022D100511199911110091C99C90..
...022105661119111150091C99990..
...055556FF6511115665091199910..
..056666FFF6655556FFF511199110..
.056FFF66665566656FF6651111150..
.056665555556FFF655555665556650.
05555511111566665111156665566650
01111100001155551000115551155510
.0000......000000....0000000000.
---
................................
................................
................................
................................
................................
................................
................................
..............00................
.............0AA0...............
............0A77A0..............
...........0ACCA7F0.............
..........09CCAAFFF0............
.........099CCCAAFFC0...........
.........0999CCAAFCC0...........
....00...0919CCAAFCC0...........
...0E70..0919CCA9FCC0...00......
..0ED7A0.0919CCA9FC90..0AA0.....
..0EDD90.0919CC99FC90.0A7FA0....
.0E2DD90.0919CC99F990.0ACAF0....
.022DD90.0911C999999009CCAFF0...
.022DD90.01119999991009CCAFCC0..
.022DD10.01119999911009CCAFCC0..
..02DD10.011199991110099CA9CC0..
..022D100511199911110091C99C90..
...022105661119111150091C99990..
...055556FF6511115665091199910..
..056666FFF6655556FFF511199110..
.056FFF66665566656FF6651111150..
.056665555556FFF655555665556650.
05555511111566665111156665566650
01111100001155551000115551155510
.0000......000000....0000000000.

@SPRITE :spirit 16x16 pal:4
.....000000.....
...00AAFFAA00...
..0AC77FFCCCA0..
.0AC7FCBBBBCCA0.
.0ACCCCCCCCCC90.
09CC17CCCC17CC90
09CC11CCCC11CC90
099CCCCCCCCCC990
.099CCEEEECC990.
..0999CCCC9990..
...0099999900...
...0A090090A0...
...0C0.00.0C0...
....0..00..0....
.......0........
................
---
.....000000.....
...00AAFFAA00...
..0AC77FFCCCA0..
.0AC7FCBBBBCCA0.
.0ACCCCCCCCCC90.
09CC17CCCC17CC90
09CC11CCCC11CC90
099CCCCCCCCCC990
.099CCEEEECC990.
..0999CCCC9990..
...0099999900...
..0A0.9009.0A0..
..0C0.0000.0C0..
...0...00...0...
.......0........
................

@SPRITE :holo_drone 16x16 pal:5
.......00.......
......0CC0......
.....0CDDC0.....
....0C5665C0....
...0C56FF65C0...
..0C56877865C0..
.0CD56888865DC0.
0CD7566AA6657DC0
.0CD56666665DC0.
..0C51555515C0..
...0C111111C0...
....0CEEEEC0....
.....0CEEC0.....
......0CC0......
.......00.......
................
---
.......00.......
......0EE0......
.....0EDDE0.....
....0E5665E0....
...0E56FF65E0...
..0E56877865E0..
.0ED56888865DE0.
0ED7566AA6657DE0
.0ED56666665DE0.
..0E51555515E0..
...0E111111E0...
....0ECCCCE0....
.....0ECCE0.....
......0EE0......
.......00.......
................

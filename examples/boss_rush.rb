# ==============================================================================
# USAKAME BOSS RUSH: 4 TRIALS OF THE BLADE
# ------------------------------------------------------------------------------
# 256x256 / 1ファイル完結 / 基本API + BG + スプライト専用 (タイルマップ・サウンド不使用)
# 実行: uk run examples/boss_rush.rb
#
# 【操作方法】
#   ← / → (A / D)   : 移動
#   ↑ (W)           : ジャンプ (2段ジャンプ可 / 離すと小ジャンプ)
#   ↓ (S)           : 足場すり抜け降り
#   Z       : 剣攻撃 (地上3段コンボ / 空中下突きポゴ: ↓+Z / ピンク弾パリィ)
#   X       : 無敵ステップ回避 (敵攻撃スレスレ回避で「JUST!」強化)
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "USAKAME BOSS RUSH"
)

# ------------------------------------------------------------------------------
# 定数 & ゲームフィール調整パラメータ
# ------------------------------------------------------------------------------
SCREEN_W = 256
SCREEN_H = 256
ARENA_LEFT = 8.0
ARENA_RIGHT = 248.0
GROUND_Y = 216.0

# プレイヤー移動・ジャンプ物理
P_ACCEL_GROUND     = 0.56
P_ACCEL_AIR        = 0.38
P_MAX_SPEED        = 2.45
P_FRICTION         = 0.72
P_GRAVITY          = 0.25
P_APEX_GRAVITY_MUL = 0.62
P_APEX_VY_THRESH   = 0.75
P_MAX_FALL         = 5.2
P_JUMP_VEL         = -5.15
P_DOUBLE_JUMP_VEL  = -4.65
P_JUMP_CUT_MUL     = 0.52
COYOTE_FRAMES      = 6
JUMP_BUFFER_FRAMES = 6
ATK_BUFFER_FRAMES  = 6

# 回避ダッシュ
DASH_SPEED         = 4.75
DASH_FRAMES        = 11
DASH_INV_FRAMES    = 13
DASH_CD_FRAMES     = 28

# パレットオーバーライド用定数 (10..13)
PAL_WHITE   = 10
PAL_CYAN    = 11
PAL_GOLD    = 12
PAL_CRIMSON = 13

# ステージ設定データ
BOSS_LIST = [
  {
    id: :golem,
    stage: 1,
    name: "MOSS GOLEM",
    subtitle: "ANCIENT FOREST GUARDIAN",
    bg: :forest,
    tint1: [220, 255, 220],
    tint2: [255, 165, 110],
    scroll_spd: 0.16,
    floor: :forest
  },
  {
    id: :phoenix,
    stage: 2,
    name: "SOLAR PHOENIX",
    subtitle: "BLAZING PEAK SOVEREIGN",
    bg: :mountain,
    tint1: [255, 190, 140],
    tint2: [255, 90, 75],
    scroll_spd: 0.35,
    floor: :volcano
  },
  {
    id: :mecha,
    stage: 3,
    name: "NEON MECHA",
    subtitle: "ORBITAL STEEL SENTINEL",
    bg: :city,
    tint1: [175, 210, 255],
    tint2: [215, 110, 255],
    scroll_spd: 0.45,
    floor: :city
  },
  {
    id: :dragon,
    stage: 4,
    name: "CYBER DRAGON",
    subtitle: "APEX CORE OVERLORD",
    bg: :cyber,
    tint1: [125, 235, 255],
    tint2: [255, 65, 105],
    scroll_spd: 0.65,
    floor: :cyber
  }
]

# セッション内ベスト記録 (ホットリロード維持)
$best_rush_frames ||= nil
$best_rush_rank ||= nil
$boss_best_frames ||= [nil, nil, nil, nil]

# ------------------------------------------------------------------------------
# 汎用ユーティリティ
# ------------------------------------------------------------------------------
def clamp_f(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

def lerp_f(a, b, t)
  a + (b - a) * t
end

def lerp_rgb(c1, c2, t)
  [
    lerp_f(c1[0].to_f, c2[0].to_f, t).round,
    lerp_f(c1[1].to_f, c2[1].to_f, t).round,
    lerp_f(c1[2].to_f, c2[2].to_f, t).round
  ]
end

def aabb_overlap?(ax, ay, aw, ah, bx, by, bw, bh)
  ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
end

# 点 (px, py) と線分 (x1, y1)-(x2, y2) の最短距離
def point_segment_dist(px, py, x1, y1, x2, y2)
  dx = x2 - x1
  dy = y2 - y1
  len_sq = dx * dx + dy * dy
  if len_sq < 0.0001
    return hypot(px - x1, py - y1)
  end
  t = ((px - x1) * dx + (py - y1) * dy) / len_sq
  t = clamp_f(t, 0.0, 1.0)
  nx = x1 + t * dx
  ny = y1 + t * dy
  hypot(px - nx, py - ny)
end

def draw_shadow_text(text, x, y, col)
  print_text(text, x + 1, y + 1, 0)
  print_text(text, x, y, col)
end

def center_text_x(text)
  128 - (text.length * 6) / 2
end

def format_time(frames)
  total_tenths = (frames / 6).to_i
  mins = total_tenths / 600
  secs = (total_tenths / 10) % 60
  tenths = total_tenths % 10
  sprintf("%02d:%02d.%d", mins, secs, tenths)
end

# rot=0 時の左上スケーリング仕様に合わせ、足元中央基準で接地描画
def draw_spr_grounded(id, foot_cx, foot_y, w, h, sx, sy, flip_x, pal_id = nil)
  dx = foot_cx - (w * sx) * 0.5
  dy = foot_y - (h * sy)
  spr_ext(id, dx, dy, 0.0, sx, sy, flip_x, false, pal_id)
end

# rot=0 / rot!=0 共通で幾何中心基準描画
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
# エフェクトシステム (ヒットストップ / スロー / シェイク / 粒子 / リング / 残像)
# ------------------------------------------------------------------------------
class EffectSystem
  attr_reader :hitstop, :slow_timer, :shake_mag

  def initialize
    @hitstop = 0
    @slow_timer = 0
    @shake_mag = 0.0
    @flash_timer = 0
    @flash_col = 7
    @particles = []
    @rings = []
    @afterimages = []
    @popups = []
    @shake_dx = 0
    @shake_dy = 0
  end

  def add_hitstop(frames)
    @hitstop = frames if frames > @hitstop
  end

  def add_slow(frames)
    @slow_timer = frames if frames > @slow_timer
  end

  def add_shake(mag)
    @shake_mag = mag if mag > @shake_mag
  end

  def add_flash(col, frames)
    @flash_col = col
    @flash_timer = frames
  end

  def spawn_burst(x, y, col, count = 8, spd = 2.4, grav = 0.08, life = 20)
    i = 0
    while i < count
      ang = rand() * 6.28318
      v = (0.4 + rand() * 0.8) * spd
      @particles << {
        x: x.to_f,
        y: y.to_f,
        vx: cos(ang) * v,
        vy: sin(ang) * v - 0.3,
        grav: grav,
        col: col,
        size: (rand(3) == 0 ? 2 : 1),
        life: life + rand(8),
        max_life: life + 8,
        kind: :dot
      }
      i += 1
    end
  end

  def spawn_slash_sparks(x, y, dir, col)
    i = 0
    while i < 7
      ang = (dir >= 0 ? -0.5 : 2.64) + (rand() - 0.5) * 1.4
      v = 1.6 + rand() * 2.8
      @particles << {
        x: x.to_f,
        y: y.to_f,
        vx: cos(ang) * v,
        vy: sin(ang) * v - 0.4,
        grav: 0.06,
        col: (i % 2 == 0 ? col : 7),
        size: 1,
        life: 12 + rand(8),
        max_life: 20,
        kind: :spark
      }
      i += 1
    end
  end

  def spawn_dust(x, y, count = 5)
    i = 0
    while i < count
      @particles << {
        x: x.to_f + (rand() - 0.5) * 8.0,
        y: y.to_f - 1.0,
        vx: (rand() - 0.5) * 1.4,
        vy: -0.3 - rand() * 0.7,
        grav: -0.01,
        col: (rand(2) == 0 ? 6 : 5),
        size: 2,
        life: 12 + rand(8),
        max_life: 20,
        kind: :dot
      }
      i += 1
    end
  end

  def spawn_ambient(x, y, vx, vy, col, life)
    @particles << {
      x: x.to_f,
      y: y.to_f,
      vx: vx.to_f,
      vy: vy.to_f,
      grav: 0.0,
      col: col,
      size: 1,
      life: life,
      max_life: life,
      kind: :dot
    }
  end

  def spawn_ring(x, y, max_r, col, life = 14)
    @rings << {
      x: x.to_f,
      y: y.to_f,
      r: 3.0,
      max_r: max_r.to_f,
      col: col,
      life: life,
      max_life: life
    }
  end

  def spawn_afterimage(spr_id, foot_cx, foot_y, w, h, sx, sy, flip_x, pal_id, life = 9)
    @afterimages << {
      id: spr_id,
      x: foot_cx.to_f,
      y: foot_y.to_f,
      w: w,
      h: h,
      sx: sx,
      sy: sy,
      flip_x: flip_x,
      pal: pal_id,
      life: life,
      max_life: life
    }
  end

  def spawn_popup(text, x, y, col = 7)
    @popups << {
      text: text.to_s,
      x: x.to_f,
      y: y.to_f,
      vy: -0.75,
      col: col,
      life: 32
    }
  end

  def tick_timers
    @hitstop -= 1 if @hitstop > 0
    @slow_timer -= 1 if @slow_timer > 0
    @flash_timer -= 1 if @flash_timer > 0
    if @shake_mag > 0.1
      ang = rand() * 6.28318
      @shake_dx = (cos(ang) * @shake_mag).round
      @shake_dy = (sin(ang) * @shake_mag).round
      @shake_mag *= 0.80
    else
      @shake_mag = 0.0
      @shake_dx = 0
      @shake_dy = 0
    end
  end

  def shake_x
    @shake_dx
  end

  def shake_y
    @shake_dy
  end

  def update_particles
    kept_p = []
    i = 0
    while i < @particles.size
      p = @particles[i]
      p[:x] += p[:vx]
      p[:y] += p[:vy]
      p[:vy] += p[:grav]
      p[:life] -= 1
      kept_p << p if p[:life] > 0
      i += 1
    end
    @particles = kept_p

    kept_r = []
    i = 0
    while i < @rings.size
      r = @rings[i]
      r[:life] -= 1
      if r[:life] > 0
        prog = 1.0 - (r[:life].to_f / r[:max_life].to_f)
        r[:r] = 3.0 + (r[:max_r] - 3.0) * prog
        kept_r << r
      end
      i += 1
    end
    @rings = kept_r

    kept_a = []
    i = 0
    while i < @afterimages.size
      a = @afterimages[i]
      a[:life] -= 1
      kept_a << a if a[:life] > 0
      i += 1
    end
    @afterimages = kept_a

    kept_pop = []
    i = 0
    while i < @popups.size
      pop = @popups[i]
      pop[:y] += pop[:vy]
      pop[:vy] *= 0.94
      pop[:life] -= 1
      kept_pop << pop if pop[:life] > 0
      i += 1
    end
    @popups = kept_pop
  end

  def draw_afterimages
    i = 0
    while i < @afterimages.size
      a = @afterimages[i]
      # 偶数フレームで点滅表現（透明度の代わり）
      if a[:life] > 3 || a[:life] % 2 == 0
        draw_spr_grounded(a[:id], a[:x], a[:y], a[:w], a[:h], a[:sx], a[:sy], a[:flip_x], a[:pal])
      end
      i += 1
    end
  end

  def draw_particles
    i = 0
    while i < @rings.size
      r = @rings[i]
      circ(r[:x].round, r[:y].round, r[:r].round, r[:col])
      i += 1
    end

    i = 0
    while i < @particles.size
      p = @particles[i]
      px = p[:x].round
      py = p[:y].round
      if p[:kind] == :spark
        line(px, py, (px - p[:vx] * 1.8).round, (py - p[:vy] * 1.8).round, p[:col])
      elsif p[:size] >= 2 && p[:life] > 4
        rectfill(px - 1, py - 1, 2, 2, p[:col])
      else
        pset(px, py, p[:col])
      end
      i += 1
    end
  end

  def draw_popups
    i = 0
    while i < @popups.size
      pop = @popups[i]
      tx = pop[:x].round - (pop[:text].length * 3)
      ty = pop[:y].round
      draw_shadow_text(pop[:text], tx, ty, pop[:col])
      i += 1
    end
  end

  def draw_screen_flash
    if @flash_timer > 0 && @flash_timer % 2 == 1
      rect(0, 0, SCREEN_W, SCREEN_H, @flash_col)
      rect(1, 1, SCREEN_W - 2, SCREEN_H - 2, @flash_col)
    end
  end
end

# ------------------------------------------------------------------------------
# 弾 / ビーム / 衝撃波ハザード
# ------------------------------------------------------------------------------
class Projectile
  attr_accessor :x, :y, :vx, :vy, :grav, :radius
  attr_accessor :col, :kind, :parryable, :destructible, :alive, :dmg
  attr_accessor :age, :homing_speed

  def initialize(opts)
    @x = opts[:x].to_f
    @y = opts[:y].to_f
    @vx = opts[:vx].to_f
    @vy = opts[:vy].to_f
    @grav = (opts[:grav] || 0.0).to_f
    @radius = (opts[:radius] || 4.0).to_f
    @col = opts[:col] || 9
    @kind = opts[:kind] || :normal
    @parryable = opts[:parryable] || false
    @destructible = opts[:destructible] || false
    @dmg = opts[:dmg] || 1
    @homing_speed = (opts[:homing_speed] || 0.0).to_f
    @alive = true
    @age = 0
    @trail = []
  end

  def update(player, boss, fx)
    @age += 1
    @trail << [@x, @y]
    @trail.shift if @trail.size > 5

    if @kind == :missile
      # 緩やか追尾ミサイル
      tx = player.foot_cx - @x
      ty = (player.foot_y - 8.0) - @y
      dist = hypot(tx, ty)
      if dist > 1.0 && @age < 95
        spd = hypot(@vx, @vy)
        spd = 2.1 if spd < 1.5
        want_vx = (tx / dist) * spd
        want_vy = (ty / dist) * spd
        @vx = lerp_f(@vx, want_vx, 0.06)
        @vy = lerp_f(@vy, want_vy, 0.06)
      end
      if @age % 3 == 0
        fx.spawn_ambient(@x, @y, -@vx * 0.2, -@vy * 0.2, (@age % 6 == 0 ? 9 : 6), 10)
      end
    elsif @kind == :reflected
      # パリィ反射弾：ボスへ高速追尾
      bx = boss.b.center_x
      by = boss.b.center_y
      dx = bx - @x
      dy = by - @y
      dist = hypot(dx, dy)
      if dist > 1.0
        spd = @homing_speed > 0.0 ? @homing_speed : 6.0
        @vx = (dx / dist) * spd
        @vy = (dy / dist) * spd
      end
      if @age % 2 == 0
        fx.spawn_ambient(@x, @y, 0.0, 0.0, 10, 8)
      end
    end

    @x += @vx
    @y += @vy
    @vy += @grav

    if @x < -20.0 || @x > 276.0 || @y < -28.0 || @y > GROUND_Y + 20.0 || @age > 320
      @alive = false
    end
  end

  def hitbox
    r = @radius
    [@x - r, @y - r, r * 2.0, r * 2.0]
  end

  def draw
    # トレイル描画
    i = 0
    while i < @trail.size
      pt = @trail[i]
      tcol = @parryable ? 14 : (@kind == :reflected ? 10 : @col)
      pset(pt[0].round, pt[1].round, tcol)
      i += 1
    end

    px = @x.round
    py = @y.round
    ri = @radius.round

    if @parryable
      # ピンクのパリィ可能弾（視認性抜群のキラキラ輪郭＋白芯）
      circfill(px, py, ri + 1, 2)
      circfill(px, py, ri, 14)
      circfill(px, py, (ri - 2).clamp(1, 8), 7)
      ang = @age * 0.18
      k = 0
      while k < 4
        a = ang + k * 1.5708
        kx = (px + cos(a) * (ri + 2)).round
        ky = (py + sin(a) * (ri + 2)).round
        pset(kx, ky, 7)
        k += 1
      end
    elsif @kind == :reflected
      circfill(px, py, ri + 1, 9)
      circfill(px, py, ri, 10)
      circfill(px, py, 2, 7)
    elsif @kind == :missile
      circfill(px, py, ri + 1, 0)
      circfill(px, py, ri, 8)
      circ(px, py, ri + 1, 10) if (@age / 3) % 2 == 0
      pset(px, py, 7)
    else
      circfill(px, py, ri + 1, 0)
      circfill(px, py, ri, @col)
      circfill(px, py, (ri - 2).clamp(1, 6), 7)
    end
  end
end

class BeamHazard
  attr_accessor :x1, :y1, :x2, :y2, :width, :col
  attr_accessor :telegraph_t, :active_t, :fade_t, :age, :alive

  def initialize(opts)
    @x1 = opts[:x1].to_f
    @y1 = opts[:y1].to_f
    @x2 = opts[:x2].to_f
    @y2 = opts[:y2].to_f
    @width = (opts[:width] || 12.0).to_f
    @col = opts[:col] || 8
    @telegraph_t = opts[:telegraph_t] || 36
    @active_t = opts[:active_t] || 18
    @fade_t = opts[:fade_t] || 8
    @age = 0
    @alive = true
  end

  def active?
    @age >= @telegraph_t && @age < @telegraph_t + @active_t
  end

  def update(fx)
    @age += 1
    if active? && @age % 2 == 0
      t = rand()
      sx = lerp_f(@x1, @x2, t)
      sy = lerp_f(@y1, @y2, t)
      fx.spawn_ambient(sx, sy, (rand() - 0.5) * 1.6, (rand() - 0.5) * 1.6, 7, 10)
    end
    if @age >= @telegraph_t + @active_t + @fade_t
      @alive = false
    end
  end

  def hits_box?(bx, by, bw, bh)
    return false unless active?
    cx = bx + bw * 0.5
    cy = by + bh * 0.5
    hr = ((bw < bh ? bw : bh) * 0.42)
    dist = point_segment_dist(cx, cy, @x1, @y1, @x2, @y2)
    dist <= (@width * 0.5 + hr)
  end

  def draw
    if @age < @telegraph_t
      # 予兆ライン（点滅）
      blink = (@age / 3) % 2 == 0
      tcol = blink ? 8 : 10
      line(@x1.round, @y1.round, @x2.round, @y2.round, tcol)
      if @age > @telegraph_t - 10
        # 発射直前に太め枠ヒント
        dx = @x2 - @x1
        dy = @y2 - @y1
        len = hypot(dx, dy)
        if len > 1.0
          nx = (-dy / len) * (@width * 0.45)
          ny = (dx / len) * (@width * 0.45)
          line((@x1 + nx).round, (@y1 + ny).round, (@x2 + nx).round, (@y2 + ny).round, 2)
          line((@x1 - nx).round, (@y1 - ny).round, (@x2 - nx).round, (@y2 - ny).round, 2)
        end
      end
    else
      # 本体ビーム / 収束フェード
      if active?
        half_w = @width * 0.5
      else
        rem = (@telegraph_t + @active_t + @fade_t) - @age
        ratio = rem.to_f / @fade_t.to_f
        half_w = @width * 0.5 * clamp_f(ratio, 0.1, 1.0)
      end
      draw_thick_beam(@x1, @y1, @x2, @y2, half_w, @col)
    end
  end

  def draw_thick_beam(x1, y1, x2, y2, hw, col)
    dx = x2 - x1
    dy = y2 - y1
    len = hypot(dx, dy)
    return if len < 0.5
    nx = -dy / len
    ny = dx / len
    # 外輪・本体・白芯をオフセット平行線群で描画（任意角度対応）
    steps = hw.round
    s = -steps
    while s <= steps
      ox = nx * s
      oy = ny * s
      c = s.abs <= (steps * 0.35).floor ? 7 : col
      line((x1 + ox).round, (y1 + oy).round, (x2 + ox).round, (y2 + oy).round, c)
      s += 1
    end
  end
end

class Shockwave
  attr_accessor :x, :y, :vx, :w, :h, :col, :alive, :age

  def initialize(x, vx, col = 11)
    @x = x.to_f
    @y = GROUND_Y
    @vx = vx.to_f
    @w = 10.0
    @h = 14.0
    @col = col
    @alive = true
    @age = 0
  end

  def update(fx)
    @age += 1
    @x += @vx
    if @age % 3 == 0
      fx.spawn_ambient(@x, @y - 2.0, -@vx * 0.2, -0.8, @col, 10)
    end
    if @x < -16.0 || @x > 272.0
      @alive = false
    end
  end

  def hitbox
    [@x - @w * 0.5, @y - @h, @w, @h]
  end

  def draw
    cx = @x.round
    by = @y.round
    peak = @h.round + ((@age % 4 < 2) ? 2 : 0)
    trifill(cx - 6, by, cx + 6, by, cx, by - peak, @col)
    trifill(cx - 3, by, cx + 3, by, cx, by - (peak - 4), 7)
  end
end

# ------------------------------------------------------------------------------
# プレイヤークラス
# ------------------------------------------------------------------------------
class Player
  attr_accessor :foot_cx, :foot_y, :vx, :vy, :facing, :on_ground
  attr_accessor :hp, :max_hp, :inv_timer, :empowered, :combo, :combo_timer
  attr_accessor :max_combo, :hits_taken, :just_count, :parry_count, :atk_hit_done
  attr_accessor :air_jumps, :atk_stage, :dash_cd

  def initialize
    @foot_cx = 56.0
    @foot_y = GROUND_Y
    @vx = 0.0
    @vy = 0.0
    @facing = 1
    @on_ground = true

    @coyote_t = 0
    @jump_buf_t = 0
    @air_jumps = 1
    @drop_through_t = 0

    @dash_timer = 0
    @dash_dir = 1
    @dash_cd = 0
    @dash_inv = 0
    @just_dodged_this_dash = false
    @just_cd = 0

    @atk_timer = 0
    @atk_total = 0
    @atk_stage = 0 # 1, 2, 3, :air, :pogo
    @atk_combo_win = 0
    @atk_buf_t = 0
    @atk_hit_done = false
    @empowered = false

    @hp = 5
    @max_hp = 5
    @inv_timer = 0
    @hurt_timer = 0

    @sx = 1.0
    @sy = 1.0
    @anim_t = 0.0

    @combo = 0
    @combo_timer = 0
    @max_combo = 0
    @hits_taken = 0
    @just_count = 0
    @parry_count = 0

    @id_idle = spr_id(:hero_idle)
    @id_run  = spr_id(:hero_run)
    @id_jump = spr_id(:hero_jump)
    @id_atk  = spr_id(:hero_atk)
    @id_dash = spr_id(:hero_dash)
    @id_slash = spr_id(:slash)
    @id_slash_down = spr_id(:slash_down)
  end

  def reset_for_stage(keep_hp = true)
    @foot_cx = 56.0
    @foot_y = GROUND_Y
    @vx = 0.0
    @vy = 0.0
    @facing = 1
    @on_ground = true
    @coyote_t = 0
    @jump_buf_t = 0
    @air_jumps = 1
    @drop_through_t = 0
    @dash_timer = 0
    @dash_cd = 0
    @dash_inv = 0
    @just_dodged_this_dash = false
    @just_cd = 0
    @atk_timer = 0
    @atk_combo_win = 0
    @atk_buf_t = 0
    @inv_timer = 0
    @hurt_timer = 0
    @sx = 1.0
    @sy = 1.0
    unless keep_hp
      @hp = @max_hp
    end
  end

  def hurtbox
    # 中心足元基準で当たり判定をやや小さめ (8x12) にしフェアに調整
    [@foot_cx - 4.0, @foot_y - 13.0, 8.0, 12.0]
  end

  def dashing_invuln?
    @dash_inv > 0
  end

  def invulnerable?
    @inv_timer > 0 || @dash_inv > 0
  end

  def can_just_dodge?
    @dash_inv > 0 && !@just_dodged_this_dash && @just_cd <= 0
  end

  def dash_cd_ratio
    return 1.0 if @dash_cd <= 0
    1.0 - (@dash_cd.to_f / DASH_CD_FRAMES.to_f)
  end

  def trigger_just_dodge(fx)
    @just_dodged_this_dash = true
    @just_cd = 20
    @dash_cd = 0
    @empowered = true
    @just_count += 1
    add_combo(2)
    fx.add_slow(10)
    fx.add_hitstop(4)
    fx.spawn_ring(@foot_cx, @foot_y - 8.0, 22.0, 12, 14)
    fx.spawn_burst(@foot_cx, @foot_y - 8.0, 12, 10, 2.5)
    fx.spawn_popup("JUST!", @foot_cx, @foot_y - 22.0, 12)
  end

  def add_combo(n)
    @combo += n
    @combo_timer = 150
    @max_combo = @combo if @combo > @max_combo
  end

  def take_damage(fx)
    return false if invulnerable?
    @hp -= 1
    @hp = 0 if @hp < 0
    @hits_taken += 1
    @combo = 0
    @combo_timer = 0
    @inv_timer = 55
    @hurt_timer = 14
    @dash_timer = 0
    @atk_timer = 0
    @vy = -2.8
    @vx = -@facing * 2.2
    @sx = 1.35
    @sy = 0.72
    fx.add_hitstop(7)
    fx.add_shake(4.5)
    fx.add_flash(8, 6)
    fx.spawn_burst(@foot_cx, @foot_y - 8.0, 8, 12, 2.8)
    fx.spawn_popup("-1", @foot_cx, @foot_y - 20.0, 8)
    true
  end

  def attack_active?
    return false if @atk_timer <= 0
    elapsed = @atk_total - @atk_timer
    if @atk_stage == 3
      elapsed >= 3 && elapsed < 10
    else
      elapsed >= 2 && elapsed < 7
    end
  end

  def attack_damage
    base = 10
    if @atk_stage == 2
      base = 12
    elsif @atk_stage == 3
      base = 18
    elsif @atk_stage == :air
      base = 11
    elsif @atk_stage == :pogo
      base = 12
    end
    @empowered ? base * 2 : base
  end

  def attack_hitbox
    return nil unless attack_active?
    if @atk_stage == :pogo
      return [@foot_cx - 10.0, @foot_y - 2.0, 20.0, 24.0]
    elsif @atk_stage == 3
      return [@foot_cx - 19.0 + @facing * 6.0, @foot_y - 20.0, 38.0, 22.0]
    else
      if @facing > 0
        return [@foot_cx + 2.0, @foot_y - 18.0, 26.0, 18.0]
      else
        return [@foot_cx - 28.0, @foot_y - 18.0, 26.0, 18.0]
      end
    end
  end

  def pogo_bounce(fx)
    @vy = -4.65
    @on_ground = false
    @air_jumps = 1
    @dash_cd = 0
    @sx = 0.78
    @sy = 1.26
    fx.spawn_ring(@foot_cx, @foot_y + 4.0, 12.0, 10, 10)
  end

  def update(platforms, fx)
    @anim_t += 1.0
    @inv_timer -= 1 if @inv_timer > 0
    @hurt_timer -= 1 if @hurt_timer > 0
    @dash_cd -= 1 if @dash_cd > 0
    @dash_inv -= 1 if @dash_inv > 0
    @just_cd -= 1 if @just_cd > 0
    @drop_through_t -= 1 if @drop_through_t > 0
    @atk_combo_win -= 1 if @atk_combo_win > 0
    if @combo_timer > 0
      @combo_timer -= 1
      @combo = 0 if @combo_timer == 0
    end

    # Squash & Stretch ばね復帰
    @sx = lerp_f(@sx, 1.0, 0.22)
    @sy = lerp_f(@sy, 1.0, 0.22)

    # 先行入力バッファ
    if btnp(:up)
      @jump_buf_t = JUMP_BUFFER_FRAMES
    elsif @jump_buf_t > 0
      @jump_buf_t -= 1
    end

    if btnp(1)
      @atk_buf_t = ATK_BUFFER_FRAMES
    elsif @atk_buf_t > 0
      @atk_buf_t -= 1
    end

    # 足場すり抜け
    if @on_ground && @foot_y < GROUND_Y - 1.0 && btnp(:down)
      @drop_through_t = 12
      @on_ground = false
      @foot_y += 1.5
    end

    # ダッシュ発動 (X)
    if btnp(2) && @dash_cd <= 0 && @dash_timer <= 0 && @hurt_timer <= 0
      dir = @facing
      dir = -1 if btn(:left)
      dir = 1 if btn(:right)
      @facing = dir
      @dash_dir = dir
      @dash_timer = DASH_FRAMES
      @dash_inv = DASH_INV_FRAMES
      @dash_cd = DASH_CD_FRAMES
      @just_dodged_this_dash = false
      @atk_timer = 0
      @vy = 0.0
      @vx = @dash_dir * DASH_SPEED
      @sx = 1.38
      @sy = 0.72
      fx.spawn_dust(@foot_cx, @foot_y, 5)
    end

    # 攻撃発動 (Z)
    if @atk_buf_t > 0 && @dash_timer <= 0 && @hurt_timer <= 0
      can_start = @atk_timer <= 0 || (@atk_timer <= 3 && @atk_stage != 3 && @on_ground)
      if can_start
        @atk_buf_t = 0
        @atk_hit_done = false
        if !@on_ground
          if btn(:down)
            @atk_stage = :pogo
            @atk_total = 13
          else
            @atk_stage = :air
            @atk_total = 12
          end
        else
          if @atk_combo_win > 0 && @atk_stage == 1
            @atk_stage = 2
            @atk_total = 13
            @vx = @facing * 2.2
          elsif @atk_combo_win > 0 && @atk_stage == 2
            @atk_stage = 3
            @atk_total = 18
            @vx = @facing * 2.8
          else
            @atk_stage = 1
            @atk_total = 12
            @vx = @facing * 1.1
          end
        end
        @atk_timer = @atk_total
        @atk_combo_win = 22
        @sx = 1.20
        @sy = 0.86
      end
    end

    if @atk_timer > 0
      @atk_timer -= 1
      # 攻撃終了の瞬間に次のコンボに備え、empoweredはヒット時に消費する
      if @atk_timer == 0 && @atk_hit_done
        @empowered = false
      end
    end

    # ダッシュ中の移動・残像
    if @dash_timer > 0
      @dash_timer -= 1
      @vx = @dash_dir * DASH_SPEED
      @vy = 0.0
      if @dash_timer % 2 == 0
        fx.spawn_afterimage(spr_id(:hero_dash), @foot_cx, @foot_y, 16, 16, @sx, @sy, @facing < 0, PAL_CYAN, 8)
      end
    else
      # 通常左右移動
      move_dir = 0
      move_dir -= 1 if btn(:left)
      move_dir += 1 if btn(:right)

      if @hurt_timer <= 0
        if move_dir != 0
          @facing = move_dir if @atk_timer <= 0
          acc = @on_ground ? P_ACCEL_GROUND : P_ACCEL_AIR
          @vx += move_dir * acc
          @vx = clamp_f(@vx, -P_MAX_SPEED, P_MAX_SPEED)
        else
          if @on_ground
            @vx *= P_FRICTION
            @vx = 0.0 if @vx.abs < 0.08
          else
            @vx *= 0.90
          end
        end
      else
        @vx *= 0.90
      end

      # コヨーテタイム
      if @on_ground
        @coyote_t = COYOTE_FRAMES
        @air_jumps = 1
      elsif @coyote_t > 0
        @coyote_t -= 1
      end

      # ジャンプ (地上・コヨーテ & 2段ジャンプ)
      if @jump_buf_t > 0 && @hurt_timer <= 0
        if @coyote_t > 0
          @vy = P_JUMP_VEL
          @on_ground = false
          @coyote_t = 0
          @jump_buf_t = 0
          @sx = 0.74
          @sy = 1.30
          fx.spawn_dust(@foot_cx, @foot_y, 4)
        elsif @air_jumps > 0
          @vy = P_DOUBLE_JUMP_VEL
          @air_jumps -= 1
          @jump_buf_t = 0
          @sx = 0.78
          @sy = 1.24
          fx.spawn_ring(@foot_cx, @foot_y - 2.0, 10.0, 7, 9)
        end
      end

      # 可変ジャンプ（ボタン離しで上昇抑制）
      if @vy < 0.0 && !btn(:up)
        @vy *= P_JUMP_CUT_MUL
      end

      # 重力（頂点滞空軽減）
      grav = (@vy.abs < P_APEX_VY_THRESH && !@on_ground) ? (P_GRAVITY * P_APEX_GRAVITY_MUL) : P_GRAVITY
      @vy += grav
      @vy = P_MAX_FALL if @vy > P_MAX_FALL
    end

    # 座標更新 & 着地判定
    prev_y = @foot_y
    @foot_cx += @vx
    @foot_y += @vy
    @foot_cx = clamp_f(@foot_cx, ARENA_LEFT, ARENA_RIGHT)

    landed = false
    if @vy >= 0.0
      # 地面
      if @foot_y >= GROUND_Y
        @foot_y = GROUND_Y
        landed = true
      elsif @drop_through_t <= 0
        # ワンウェイ足場
        i = 0
        while i < platforms.size
          pl = platforms[i]
          if prev_y <= pl[:y] + 2.0 && @foot_y >= pl[:y] &&
             @foot_cx >= pl[:x] - 4.0 && @foot_cx <= pl[:x] + pl[:w] + 4.0
            @foot_y = pl[:y].to_f
            landed = true
            break
          end
          i += 1
        end
      end
    end

    if landed
      if !@on_ground && @vy > 2.2
        @sx = 1.28
        @sy = 0.74
        fx.spawn_dust(@foot_cx, @foot_y, 4)
      end
      @vy = 0.0
      @on_ground = true
    else
      @on_ground = false
    end

    # EMPOWERED 時の常時オーラ粒
    if @empowered && (@anim_t.to_i % 4 == 0)
      fx.spawn_ambient(@foot_cx + (rand() - 0.5) * 10.0, @foot_y - rand() * 14.0, 0.0, -0.5, 10, 10)
    end
  end

  def draw
    # 無敵点滅
    if @inv_timer > 0 && (@inv_timer / 2) % 2 == 1
      # 半透明代わりの偶数フレームスキップ
    else
      flip = @facing < 0
      pal_id = nil
      pal_id = PAL_WHITE if @hurt_timer > 8
      pal_id = PAL_GOLD if @empowered && (@anim_t.to_i % 6 < 2) && pal_id.nil?

      if @dash_timer > 0
        sid = @id_dash
      elsif @atk_timer > 0
        sid = @id_atk
      elsif !@on_ground
        f_idx = @vy < 0.0 ? 0 : 1
        sid = spr_id(:hero_jump, f_idx)
      elsif @vx.abs > 0.35
        f_idx = (@anim_t / 6.0).to_i % 2
        sid = spr_id(:hero_run, f_idx)
      else
        f_idx = (@anim_t / 18.0).to_i % 2
        sid = spr_id(:hero_idle, f_idx)
      end

      draw_spr_grounded(sid, @foot_cx, @foot_y, 16, 16, @sx, @sy, flip, pal_id)
    end

    # 斬撃スプライト描画
    if attack_active?
      slash_pal = @empowered ? PAL_GOLD : nil
      if @atk_stage == :pogo
        draw_spr_centered(@id_slash_down, @foot_cx, @foot_y + 8.0, 16, 24, 0.0, 1.0, 1.0, @facing < 0, false, slash_pal)
      else
        elapsed = @atk_total - @atk_timer
        sf = elapsed < 4 ? 0 : 1
        sid = spr_id(:slash, sf)
        sx_scale = (@atk_stage == 3) ? 1.28 : 1.0
        sy_scale = (@atk_stage == 3) ? 1.28 : 1.0
        if @atk_stage == 3
          # 3段目は大回転振り抜き
          draw_spr_centered(sid, @foot_cx + @facing * 8.0, @foot_y - 10.0, 32, 16, 0.0, sx_scale, sy_scale, @facing < 0, false, slash_pal)
        else
          draw_spr_centered(sid, @foot_cx + @facing * 14.0, @foot_y - 9.0, 32, 16, 0.0, sx_scale, sy_scale, @facing < 0, @atk_stage == 2, slash_pal)
        end
      end
    end
  end
end

# ------------------------------------------------------------------------------
# ボス共通状態管理 (BossCore: コンポジション方式で継承/super依存を回避)
# ------------------------------------------------------------------------------
class BossCore
  attr_accessor :meta, :x, :y, :w, :h
  attr_accessor :hb_pad_x, :hb_pad_y, :hp, :max_hp, :display_hp
  attr_accessor :phase, :phase2_t, :state, :state_t, :hit_flash_t
  attr_accessor :sx, :sy, :facing, :touch_active, :stun_t
  attr_accessor :dying_t, :dead, :last_atk, :atk_count, :frame
  attr_accessor :platforms, :tint_blend

  def initialize(meta, platforms, x, y, w, h, max_hp, pad_x = 5.0, pad_y = 4.0)
    @meta = meta
    @platforms = platforms
    @x = x.to_f
    @y = y.to_f
    @w = w.to_f
    @h = h.to_f
    @hb_pad_x = pad_x.to_f
    @hb_pad_y = pad_y.to_f
    @hp = max_hp
    @max_hp = max_hp
    @display_hp = max_hp.to_f
    @phase = 1
    @phase2_t = 0
    @tint_blend = 0.0
    @state = :idle
    @state_t = 0
    @hit_flash_t = 0
    @sx = 1.0
    @sy = 1.0
    @facing = -1
    @touch_active = true
    @stun_t = 0
    @dying_t = 0
    @dead = false
    @last_atk = nil
    @atk_count = 0
    @frame = 0
  end

  def center_x
    @x
  end

  def center_y
    @y - @h * 0.5
  end

  # 足元基準(x, y)からの当たり判定矩形
  def hitbox
    [
      @x - @w * 0.5 + @hb_pad_x,
      @y - @h + @hb_pad_y,
      @w - @hb_pad_x * 2.0,
      @h - @hb_pad_y * 2.0
    ]
  end

  def hurt_or_roaring?
    @state == :phase2_roar || @state == :dying || @dead
  end

  def can_touch_damage?
    @touch_active && @state != :stun && @state != :phase2_roar && @state != :dying && !@dead
  end

  def tick_visuals
    @frame += 1
    @hit_flash_t -= 1 if @hit_flash_t > 0
    @sx = lerp_f(@sx, 1.0, 0.16)
    @sy = lerp_f(@sy, 1.0, 0.16)
    if @display_hp > @hp.to_f
      @display_hp = lerp_f(@display_hp, @hp.to_f, 0.08)
      @display_hp = @hp.to_f if (@display_hp - @hp.to_f).abs < 0.4
    end
    if @phase == 2 && @tint_blend < 1.0
      @tint_blend += 0.025
      @tint_blend = 1.0 if @tint_blend > 1.0
    end
  end

  def current_bg_tint
    lerp_rgb(@meta[:tint1], @meta[:tint2], @tint_blend)
  end

  def take_damage(amount, fx, player, is_crit = false, hit_x = nil, hit_y = nil)
    return false if @state == :dying || @dead
    actual = (@state == :phase2_roar) ? (amount / 3).clamp(1, 99) : amount
    @hp -= actual
    @hp = 0 if @hp < 0
    @hit_flash_t = 5
    @sx = 1.14
    @sy = 0.88

    hx = hit_x || center_x
    hy = hit_y || center_y
    pcol = is_crit ? 10 : 7
    fx.spawn_popup("#{actual}#{is_crit ? '!' : ''}", hx, hy - 8.0, pcol)
    fx.spawn_slash_sparks(hx, hy, player.facing, is_crit ? 10 : 12)
    fx.add_hitstop(is_crit ? 6 : 3)
    fx.add_shake(is_crit ? 3.5 : 1.6)
    player.add_combo(1)

    if @hp <= 0
      @state = :dying
      @dying_t = 62
      @touch_active = false
      fx.add_hitstop(10)
      fx.add_shake(6.0)
      fx.add_flash(7, 8)
      return true
    end

    if @phase == 1 && @hp <= (@max_hp / 2)
      @phase = 2
      @state = :phase2_roar
      @state_t = 44
      @touch_active = false
      @sx = 1.26
      @sy = 0.78
      fx.add_hitstop(8)
      fx.add_shake(5.5)
      fx.add_flash(8, 6)
      fx.spawn_ring(center_x, center_y, 52.0, 8, 22)
      fx.spawn_popup("PHASE 2!", center_x, @y - @h - 10.0, 8)
    end
    true
  end

  def update_dying(fx)
    @dying_t -= 1
    if @dying_t % 6 == 0
      ex = center_x + (rand() - 0.5) * @w * 0.85
      ey = center_y + (rand() - 0.5) * @h * 0.85
      fx.spawn_burst(ex, ey, (rand(2) == 0 ? 10 : 8), 10, 2.8)
      fx.spawn_ring(ex, ey, 16.0, 7, 10)
      fx.add_shake(2.5)
    end
    if @dying_t <= 0
      fx.spawn_burst(center_x, center_y, 7, 26, 4.0, 0.04, 28)
      fx.spawn_ring(center_x, center_y, 64.0, 10, 22)
      @dead = true
    end
  end

  def pick_next_attack(options)
    idx = rand(options.size)
    choice = options[idx]
    if choice == @last_atk && options.size > 1
      idx = (idx + 1) % options.size
      choice = options[idx]
    end
    @last_atk = choice
    @atk_count += 1
    choice
  end

  def pal_for_draw
    return PAL_WHITE if @hit_flash_t > 0
    if @state == :phase2_roar && (@state_t / 3) % 2 == 0
      return PAL_CRIMSON
    end
    nil
  end

  def draw_stun_stars
    return unless @state == :stun
    k = 0
    while k < 3
      ang = @frame * 0.16 + k * 2.094
      sx = (center_x + cos(ang) * 14.0).round
      sy = (@y - @h - 5.0 + sin(ang) * 3.0).round
      rectfill(sx - 1, sy - 1, 2, 2, 10)
      pset(sx, sy, 7)
      k += 1
    end
  end
end

# ------------------------------------------------------------------------------
# STAGE 1 BOSS: MOSS GOLEM
# ------------------------------------------------------------------------------
class MossGolem
  attr_reader :b

  def initialize
    plats = [
      { x: 20.0, y: 168.0, w: 48.0 },
      { x: 188.0, y: 168.0, w: 48.0 }
    ]
    @b = BossCore.new(BOSS_LIST[0], plats, 196.0, GROUND_Y, 32.0, 32.0, 240, 5.0, 4.0)
    @vx = 0.0
    @vy = 0.0
    @slam_hops = 0
    @charge_dir = -1
    @id_golem = spr_id(:boss_golem, 0)
    @id_golem_roar = spr_id(:boss_golem, 1)
  end

  def update(player, fx, projectiles, beams, shocks)
    @b.tick_visuals
    if @b.state == :dying
      @b.update_dying(fx)
      return
    end

    @b.state_t -= 1 if @b.state_t > 0

    case @b.state
    when :phase2_roar
      @b.y = GROUND_Y
      if @b.state_t % 8 == 0
        fx.spawn_ring(@b.center_x, @b.center_y, 38.0, 9, 14)
      end
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :idle
        @b.state_t = 16
      end

    when :idle
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      @b.y = GROUND_Y
      if @b.state_t <= 0
        nxt = @b.pick_next_attack([:slam, :charge, :spores])
        if nxt == :slam
          @b.state = :slam_windup
          @b.state_t = (@b.phase == 2 ? 18 : 24)
          @slam_hops = (@b.phase == 2 ? 2 : 1)
          @b.sx = 1.24
          @b.sy = 0.78
        elsif nxt == :charge
          @b.state = :charge_windup
          @b.state_t = (@b.phase == 2 ? 28 : 36)
          @charge_dir = (player.foot_cx < @b.x) ? -1 : 1
          @b.facing = @charge_dir
        else
          @b.state = :spores_windup
          @b.state_t = 22
        end
      end

    when :slam_windup
      @b.sx = 1.22
      @b.sy = 0.78
      if @b.state_t <= 0
        @b.state = :slam_air
        dx = player.foot_cx - @b.x
        @vx = clamp_f(dx / 32.0, -2.8, 2.8)
        @vy = -5.6
        @b.sx = 0.80
        @b.sy = 1.26
        fx.spawn_dust(@b.x, GROUND_Y, 6)
      end

    when :slam_air
      @b.x += @vx
      @b.y += @vy
      @vy += 0.28
      @b.x = clamp_f(@b.x, 26.0, 230.0)
      if @b.y >= GROUND_Y
        @b.y = GROUND_Y
        @vx = 0.0
        @vy = 0.0
        @b.sx = 1.35
        @b.sy = 0.68
        fx.add_shake(4.8)
        fx.spawn_dust(@b.x, GROUND_Y, 10)
        spd = (@b.phase == 2 ? 2.85 : 2.35)
        shocks << Shockwave.new(@b.x - 10.0, -spd, 11)
        shocks << Shockwave.new(@b.x + 10.0, spd, 11)
        @slam_hops -= 1
        if @slam_hops > 0
          @b.state = :slam_windup
          @b.state_t = 12
        else
          @b.state = :idle
          @b.state_t = (@b.phase == 2 ? 22 : 30)
        end
      end

    when :charge_windup
      # 足踏み予兆
      if @b.state_t % 6 == 0
        fx.spawn_dust(@b.x - @charge_dir * 10.0, GROUND_Y, 2)
      end
      if @b.state_t <= 0
        @b.state = :charge
        @b.state_t = 60
        @vx = @charge_dir * (@b.phase == 2 ? 4.8 : 4.0)
        @b.sx = 1.18
        @b.sy = 0.86
      end

    when :charge
      @b.x += @vx
      if @b.state_t % 3 == 0
        fx.spawn_dust(@b.x - @charge_dir * 12.0, GROUND_Y, 2)
      end
      if @b.x <= 24.0 || @b.x >= 232.0 || @b.state_t <= 0
        @b.x = clamp_f(@b.x, 24.0, 232.0)
        @vx = 0.0
        @b.state = :stun
        @b.state_t = (@b.phase == 2 ? 38 : 48)
        @b.touch_active = false
        @b.sx = 0.78
        @b.sy = 1.22
        fx.add_shake(5.0)
        fx.spawn_burst(@b.x, @b.center_y, 9, 10, 2.8)
        fx.spawn_popup("CRASH!", @b.x, @b.y - 38.0, 10)
      end

    when :stun
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :idle
        @b.state_t = 18
      end

    when :spores_windup
      @b.sx = 1.15
      @b.sy = 0.85
      if @b.state_t <= 0
        count = (@b.phase == 2 ? 6 : 4)
        i = 0
        while i < count
          frac = count == 1 ? 0.5 : (i.to_f / (count - 1).to_f)
          vx = lerp_f(-2.6, 2.6, frac) + (player.foot_cx - @b.x) * 0.008
          vy = -4.2 - (i % 2) * 0.7
          is_parry = (i == 1 || (count >= 5 && i == 4))
          projectiles << Projectile.new({
            x: @b.x,
            y: @b.y - 24.0,
            vx: vx,
            vy: vy,
            grav: 0.11,
            radius: is_parry ? 4.5 : 3.5,
            col: 11,
            parryable: is_parry
          })
          i += 1
        end
        @b.sx = 0.86
        @b.sy = 1.18
        fx.spawn_burst(@b.x, @b.y - 24.0, 11, 8, 2.2)
        @b.state = :idle
        @b.state_t = (@b.phase == 2 ? 22 : 30)
      end
    end
  end

  def on_parry_hit(fx)
    @b.sx = 0.82
    @b.sy = 1.22
  end

  def draw(fx)
    return if @b.dead
    # 突進予告の赤い危険ライン
    if @b.state == :charge_windup
      x_start = @b.x.round
      x_end = @charge_dir < 0 ? 12 : 244
      y_top = (GROUND_Y - 26.0).round
      blink = (@b.state_t / 3) % 2 == 0
      col = blink ? 8 : 10
      line(x_start, y_top, x_end, y_top, col)
      line(x_start, GROUND_Y.round - 2, x_end, GROUND_Y.round - 2, col)
      draw_shadow_text("!", @b.x.round - 2, (@b.y - @b.h - 12.0).round, col)
    end

    # 接地影
    shadow_w = clamp_f(14.0 - (GROUND_Y - @b.y) * 0.08, 6.0, 14.0).round
    ovalfill(@b.x.round, GROUND_Y.round + 1, shadow_w, 3, 0)

    roar = (@b.state == :charge_windup || @b.state == :charge || @b.state == :slam_windup || @b.state == :phase2_roar || @b.state == :spores_windup)
    sid = roar ? @id_golem_roar : @id_golem
    flip = @b.facing > 0
    if @b.state == :dying && @b.dying_t % 3 == 0
      pal = PAL_WHITE
    else
      pal = @b.pal_for_draw
    end
    draw_spr_grounded(sid, @b.x, @b.y, 32, 32, @b.sx, @b.sy, flip, pal)
    @b.draw_stun_stars
  end
end

# ------------------------------------------------------------------------------
# STAGE 2 BOSS: SOLAR PHOENIX
# ------------------------------------------------------------------------------
class SolarPhoenix
  attr_reader :b

  def initialize
    plats = [
      { x: 16.0,  y: 172.0, w: 44.0 },
      { x: 104.0, y: 138.0, w: 48.0 },
      { x: 196.0, y: 172.0, w: 44.0 }
    ]
    @b = BossCore.new(BOSS_LIST[1], plats, 192.0, 128.0, 32.0, 32.0, 260, 5.0, 5.0)
    @home_x = 192.0
    @home_y = 104.0
    @dive_vx = 0.0
    @dive_vy = 0.0
    @dive_tx = 64.0
    @dive_ty = 180.0
    @dive_left = 1
    @pillar_xs = []
    @id_phx0 = spr_id(:boss_phoenix, 0)
    @id_phx1 = spr_id(:boss_phoenix, 1)
  end

  def update(player, fx, projectiles, beams, shocks)
    @b.tick_visuals
    if @b.state == :dying
      @b.update_dying(fx)
      return
    end

    @b.state_t -= 1 if @b.state_t > 0

    # 炎尾パーティクル
    if @b.frame % 4 == 0
      fx.spawn_ambient(@b.x + (rand() - 0.5) * 16.0, @b.center_y + (rand() - 0.5) * 10.0,
                       0.0, -0.6 - rand() * 0.5, (rand(2) == 0 ? 9 : 10), 12)
    end

    case @b.state
    when :phase2_roar
      @b.x = lerp_f(@b.x, 128.0, 0.12)
      @b.y = lerp_f(@b.y, 118.0, 0.12)
      if @b.state_t % 7 == 0
        fx.spawn_ring(@b.center_x, @b.center_y, 40.0, 10, 14)
      end
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :hover
        @b.state_t = 18
      end

    when :hover, :idle
      target_x = (player.foot_cx < 128.0) ? 196.0 : 60.0
      target_y = 104.0 + sin(@b.frame * 0.07) * 14.0
      @b.x = lerp_f(@b.x, target_x, 0.08)
      @b.y = lerp_f(@b.y, target_y, 0.08)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        nxt = @b.pick_next_attack([:dive, :feathers, :pillars])
        if nxt == :dive
          @b.state = :dive_pos
          @b.state_t = 18
          @dive_left = (@b.phase == 2 ? 2 : 1)
          @home_x = (player.foot_cx < 128.0) ? 218.0 : 38.0
          @home_y = 92.0
        elsif nxt == :feathers
          @b.state = :feathers_pos
          @b.state_t = 22
        else
          @b.state = :pillars_aim
          @b.state_t = 40
          setup_pillars(player, beams)
        end
      end

    when :dive_pos
      @b.x = lerp_f(@b.x, @home_x, 0.18)
      @b.y = lerp_f(@b.y, @home_y, 0.18)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        @b.state = :dive_aim
        @b.state_t = (@b.phase == 2 ? 24 : 30)
        @dive_tx = clamp_f(player.foot_cx, 28.0, 228.0)
        @dive_ty = clamp_f(player.foot_y, 130.0, GROUND_Y)
      end

    when :dive_aim
      @b.facing = (@dive_tx < @b.x) ? -1 : 1
      @b.sx = 1.18
      @b.sy = 0.84
      if @b.state_t <= 0
        dx = @dive_tx - @b.x
        dy = @dive_ty - @b.y
        dist = hypot(dx, dy)
        dist = 1.0 if dist < 1.0
        spd = (@b.phase == 2 ? 5.8 : 4.9)
        @dive_vx = (dx / dist) * spd
        @dive_vy = (dy / dist) * spd
        @b.state = :dive
        @b.state_t = 34
        @b.sx = 1.28
        @b.sy = 0.78
        fx.spawn_burst(@b.center_x, @b.center_y, 9, 8, 2.4)
      end

    when :dive
      @b.x += @dive_vx
      @b.y += @dive_vy
      if @b.y > GROUND_Y - 2.0
        @b.y = GROUND_Y - 2.0
        @dive_vy = -@dive_vy.abs * 0.55
        fx.spawn_dust(@b.x, GROUND_Y, 5)
      end
      if @b.state_t % 3 == 0
        fx.spawn_ambient(@b.center_x, @b.center_y, 0.0, 0.0, 10, 12)
      end
      if @b.x <= 22.0 || @b.x >= 234.0 || @b.state_t <= 0
        @b.x = clamp_f(@b.x, 22.0, 234.0)
        @dive_left -= 1
        if @dive_left > 0
          @home_x = (@b.x < 128.0) ? 34.0 : 222.0
          @home_y = 92.0
          @b.state = :dive_pos
          @b.state_t = 14
        else
          @b.state = :perch
          @b.state_t = 30
        end
      end

    when :feathers_pos
      @b.x = lerp_f(@b.x, 128.0, 0.16)
      @b.y = lerp_f(@b.y, 94.0, 0.16)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        count = (@b.phase == 2 ? 7 : 5)
        i = 0
        while i < count
          ang = 1.5708 + (i - (count - 1) * 0.5) * 0.34
          spd = (@b.phase == 2 ? 2.55 : 2.15)
          is_parry = (i == 1 || i == count - 2)
          projectiles << Projectile.new({
            x: @b.x,
            y: @b.center_y + 6.0,
            vx: cos(ang) * spd,
            vy: sin(ang) * spd,
            radius: is_parry ? 4.5 : 3.5,
            col: 9,
            parryable: is_parry
          })
          i += 1
        end
        @b.sx = 1.24
        @b.sy = 0.78
        fx.spawn_burst(@b.center_x, @b.center_y, 10, 10, 2.4)
        @b.state = :hover
        @b.state_t = (@b.phase == 2 ? 24 : 32)
      end

    when :pillars_aim
      @b.x = lerp_f(@b.x, 128.0, 0.10)
      @b.y = lerp_f(@b.y, 76.0, 0.10)
      if @b.state_t <= 0
        @b.state = :perch
        @b.state_t = (@b.phase == 2 ? 34 : 42)
      end

    when :perch
      # 柱発射後またはダイブ後に低空で一息つく隙
      target_y = 176.0 + sin(@b.frame * 0.12) * 3.0
      @b.y = lerp_f(@b.y, target_y, 0.10)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        @b.state = :hover
        @b.state_t = 20
      end
    end
  end

  def setup_pillars(player, beams)
    px = clamp_f(player.foot_cx, 32.0, 224.0)
    xs = [px]
    xs << clamp_f(px - 68.0, 24.0, 232.0)
    xs << clamp_f(px + 68.0, 24.0, 232.0)
    if @b.phase == 2
      xs << (px < 128.0 ? 212.0 : 44.0)
    end
    i = 0
    while i < xs.size
      bx = xs[i]
      beams << BeamHazard.new({
        x1: bx, y1: GROUND_Y,
        x2: bx, y2: 34.0,
        width: 14.0,
        col: 9,
        telegraph_t: 40,
        active_t: 18,
        fade_t: 8
      })
      i += 1
    end
  end

  def on_parry_hit(fx)
    @b.sx = 0.80
    @b.sy = 1.22
  end

  def draw(fx)
    return if @b.dead
    # ダイブ予告赤ライン
    if @b.state == :dive_aim
      blink = (@b.state_t / 3) % 2 == 0
      col = blink ? 8 : 10
      line(@b.center_x.round, @b.center_y.round, @dive_tx.round, @dive_ty.round, col)
      circ(@dive_tx.round, @dive_ty.round, 5, col)
      draw_shadow_text("!", @b.x.round - 2, (@b.y - @b.h - 10.0).round, col)
    end

    # 影
    ovalfill(@b.x.round, GROUND_Y.round + 1, 10, 2, 0)

    flap = (@b.frame / 7) % 2
    sid = (flap == 0) ? @id_phx0 : @id_phx1
    flip = @b.facing > 0
    pal = (@b.state == :dying && @b.dying_t % 3 == 0) ? PAL_WHITE : @b.pal_for_draw
    draw_spr_grounded(sid, @b.x, @b.y, 32, 32, @b.sx, @b.sy, flip, pal)
  end
end

# ------------------------------------------------------------------------------
# STAGE 3 BOSS: NEON MECHA
# ------------------------------------------------------------------------------
class NeonMecha
  attr_reader :b

  def initialize
    plats = [
      { x: 24.0,  y: 162.0, w: 52.0 },
      { x: 180.0, y: 162.0, w: 52.0 }
    ]
    @b = BossCore.new(BOSS_LIST[2], plats, 198.0, GROUND_Y, 32.0, 32.0, 300, 5.0, 3.0)
    @id_mech0 = spr_id(:boss_mecha, 0)
    @id_mech1 = spr_id(:boss_mecha, 1)
    @id_bit   = spr_id(:mecha_bit)
    @bit_ang = 0.0
    @bit_timer = 50
    @bomb_dir = -1
    @rail_y = 198.0
    @target_y = GROUND_Y
  end

  def update(player, fx, projectiles, beams, shocks)
    @b.tick_visuals
    @bit_ang += 0.06
    if @b.state == :dying
      @b.update_dying(fx)
      return
    end

    @b.state_t -= 1 if @b.state_t > 0

    # 第2形態では浮遊ビットが定期援護弾を発射
    if @b.phase == 2 && @b.state != :phase2_roar && @b.state != :stun
      @bit_timer -= 1
      if @bit_timer <= 0
        @bit_timer = 76
        bx = @b.center_x + cos(@bit_ang) * 26.0
        by = @b.center_y + sin(@bit_ang * 1.3) * 14.0
        dx = player.foot_cx - bx
        dy = (player.foot_y - 8.0) - by
        d = hypot(dx, dy)
        d = 1.0 if d < 1.0
        projectiles << Projectile.new({
          x: bx, y: by,
          vx: (dx / d) * 1.9, vy: (dy / d) * 1.9,
          radius: 3.0, col: 12, parryable: false
        })
      end
    end

    case @b.state
    when :phase2_roar
      @b.y = lerp_f(@b.y, GROUND_Y, 0.15)
      if @b.state_t % 7 == 0
        fx.spawn_ring(@b.center_x, @b.center_y, 42.0, 12, 14)
      end
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :patrol
        @b.state_t = 18
      end

    when :patrol, :idle
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      @b.y = lerp_f(@b.y, GROUND_Y, 0.12)
      if @b.state_t <= 0
        nxt = @b.pick_next_attack([:railgun, :missiles, :bomb_run])
        if nxt == :railgun
          @b.state = :rail_pos
          @b.state_t = 18
          @b.x = clamp_f(@b.x, 30.0, 226.0)
          @target_y = (player.foot_y < 176.0) ? 162.0 : GROUND_Y
        elsif nxt == :missiles
          @b.state = :missiles_fire
          @b.state_t = 28
        else
          @b.state = :bomb_rise
          @b.state_t = 18
          @bomb_dir = (@b.x > 128.0) ? -1 : 1
        end
      end

    when :rail_pos
      @b.x = lerp_f(@b.x, (@b.x < 128.0 ? 32.0 : 224.0), 0.16)
      @b.y = lerp_f(@b.y, @target_y, 0.18)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        @b.state = :rail_fire
        @b.state_t = 40 + 22
        @rail_y = @b.y - 16.0
        x_end = (@b.facing > 0) ? 256.0 : 0.0
        beams << BeamHazard.new({
          x1: @b.x + @b.facing * 12.0, y1: @rail_y,
          x2: x_end, y2: @rail_y,
          width: 14.0, col: 12,
          telegraph_t: 38, active_t: 18, fade_t: 8
        })
      end

    when :rail_fire
      if @b.state_t == 24
        fx.add_shake(4.0)
        @b.sx = 0.85
        @b.sy = 1.15
      end
      if @b.state_t <= 0
        @b.state = :stun # 排熱ギャップ
        @b.state_t = (@b.phase == 2 ? 28 : 36)
        @b.touch_active = false
        fx.spawn_popup("HEAT VENT!", @b.x, @b.y - 38.0, 12)
      end

    when :stun
      @b.y = lerp_f(@b.y, GROUND_Y, 0.14)
      if @b.state_t % 6 == 0
        fx.spawn_ambient(@b.x + (rand() - 0.5) * 14.0, @b.y - 26.0, 0.0, -0.8, 7, 12)
      end
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :patrol
        @b.state_t = 18
      end

    when :missiles_fire
      if @b.state_t == 20 || @b.state_t == 10 || (@b.phase == 2 && @b.state_t == 2)
        projectiles << Projectile.new({
          x: @b.x + (rand() - 0.5) * 14.0,
          y: @b.y - 28.0,
          vx: (@b.facing * 0.8) + (rand() - 0.5) * 1.2,
          vy: -2.4,
          radius: 4.0,
          col: 8,
          kind: :missile,
          destructible: true
        })
        @b.sx = 1.15
        @b.sy = 0.88
      end
      if @b.state_t <= 0
        @b.state = :patrol
        @b.state_t = (@b.phase == 2 ? 26 : 36)
      end

    when :bomb_rise
      @b.y = lerp_f(@b.y, 102.0, 0.18)
      if @b.state_t <= 0
        @b.state = :bomb_sweep
        @b.state_t = 58
      end

    when :bomb_sweep
      spd = (@b.phase == 2 ? 3.2 : 2.6)
      @b.x += @bomb_dir * spd
      @b.facing = @bomb_dir
      if @b.x <= 26.0
        @b.x = 26.0
        @bomb_dir = 1
      elsif @b.x >= 230.0
        @b.x = 230.0
        @bomb_dir = -1
      end
      if @b.state_t % 14 == 0
        is_parry = (@b.state_t / 14) % 2 == 0
        projectiles << Projectile.new({
          x: @b.x,
          y: @b.y - 4.0,
          vx: @bomb_dir * 0.3,
          vy: 1.9,
          radius: is_parry ? 4.5 : 3.5,
          col: 12,
          parryable: is_parry
        })
      end
      if @b.state_t <= 0
        @b.state = :patrol
        @b.state_t = 24
      end
    end
  end

  def on_parry_hit(fx)
    @b.sx = 0.80
    @b.sy = 1.20
  end

  def draw(fx)
    return if @b.dead
    # 接地影
    ovalfill(@b.x.round, GROUND_Y.round + 1, 13, 2, 0)

    # 浮遊ビット描画
    b1x = @b.center_x + cos(@bit_ang) * 24.0
    b1y = @b.center_y + sin(@bit_ang * 1.3) * 12.0
    b2x = @b.center_x - cos(@bit_ang) * 24.0
    b2y = @b.center_y - sin(@bit_ang * 1.3) * 12.0
    draw_spr_centered(@id_bit, b1x, b1y, 16, 16, 0.0, 1.0, 1.0, false)
    draw_spr_centered(@id_bit, b2x, b2y, 16, 16, 0.0, 1.0, 1.0, true)

    overdrive = (@b.state == :rail_fire || @b.state == :phase2_roar || @b.phase == 2)
    sid = (overdrive && (@b.frame / 6) % 2 == 0) ? @id_mech1 : @id_mech0
    flip = @b.facing > 0
    pal = (@b.state == :dying && @b.dying_t % 3 == 0) ? PAL_WHITE : @b.pal_for_draw
    draw_spr_grounded(sid, @b.x, @b.y, 32, 32, @b.sx, @b.sy, flip, pal)
    @b.draw_stun_stars
  end
end

# ------------------------------------------------------------------------------
# STAGE 4 FINAL BOSS: CYBER DRAGON (48x48 + 6節首関節)
# ------------------------------------------------------------------------------
class CyberDragon
  attr_reader :b

  def initialize
    plats = [
      { x: 20.0,  y: 164.0, w: 52.0 },
      { x: 184.0, y: 164.0, w: 52.0 }
    ]
    @b = BossCore.new(BOSS_LIST[3], plats, 196.0, 152.0, 48.0, 48.0, 360, 8.0, 7.0)
    @id_head0 = spr_id(:boss_dragon, 0)
    @id_head1 = spr_id(:boss_dragon, 1)
    @id_seg   = spr_id(:dragon_seg)
    @sweep_dir = -1
    @sweep_base_y = 196.0
    @core_parried = false
  end

  def update(player, fx, projectiles, beams, shocks)
    @b.tick_visuals
    if @b.state == :dying
      @b.update_dying(fx)
      return
    end

    @b.state_t -= 1 if @b.state_t > 0

    case @b.state
    when :phase2_roar
      @b.x = lerp_f(@b.x, 192.0, 0.12)
      @b.y = lerp_f(@b.y, 138.0, 0.12)
      if @b.state_t % 6 == 0
        fx.spawn_ring(@b.center_x, @b.center_y, 50.0, 8, 14)
      end
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :float
        @b.state_t = 18
      end

    when :float, :idle
      side_x = (player.foot_cx < 128.0) ? 196.0 : 60.0
      target_y = 136.0 + sin(@b.frame * 0.06) * 14.0
      @b.x = lerp_f(@b.x, side_x, 0.08)
      @b.y = lerp_f(@b.y, target_y, 0.08)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        pool = (@b.phase == 2) ? [:bite, :cross_laser, :ring_core, :data_storm] : [:bite, :cross_laser, :ring_core]
        nxt = @b.pick_next_attack(pool)
        if nxt == :bite
          @b.state = :bite_pos
          @b.state_t = 18
          @sweep_dir = (player.foot_cx < 128.0) ? -1 : 1
          @sweep_base_y = (player.foot_y < 176.0) ? 164.0 : 204.0
        elsif nxt == :cross_laser
          @b.state = :laser_pos
          @b.state_t = 20
        elsif nxt == :ring_core
          @b.state = :ring_pos
          @b.state_t = 18
        else
          @b.state = :storm_pos
          @b.state_t = 16
        end
      end

    when :bite_pos
      edge_x = (@sweep_dir < 0) ? 218.0 : 38.0
      @b.x = lerp_f(@b.x, edge_x, 0.18)
      @b.y = lerp_f(@b.y, @sweep_base_y, 0.18)
      @b.facing = @sweep_dir
      if @b.state_t <= 0
        @b.state = :bite_aim
        @b.state_t = (@b.phase == 2 ? 26 : 34)
      end

    when :bite_aim
      @b.sx = 1.18
      @b.sy = 0.85
      if @b.state_t <= 0
        @b.state = :bite_sweep
        @b.state_t = 52
      end

    when :bite_sweep
      spd = (@b.phase == 2 ? 5.2 : 4.3)
      @b.x += @sweep_dir * spd
      @b.y = @sweep_base_y + sin(@b.state_t * 0.25) * 14.0
      if @b.state_t % 2 == 0
        fx.spawn_ambient(@b.center_x, @b.center_y, -@sweep_dir * 0.8, 0.0, 12, 10)
      end
      if @b.x <= 24.0 || @b.x >= 232.0 || @b.state_t <= 0
        @b.x = clamp_f(@b.x, 30.0, 226.0)
        @b.facing = (player.foot_cx < @b.x) ? -1 : 1
        @b.state = :float
        @b.state_t = 22
      end

    when :laser_pos
      @b.x = lerp_f(@b.x, 128.0, 0.16)
      @b.y = lerp_f(@b.y, 98.0, 0.16)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        @b.state = :laser_wait
        @b.state_t = 68
        # 交差データレーザー生成
        beams << BeamHazard.new({ x1: 128.0, y1: 70.0, x2: 128.0, y2: GROUND_Y, width: 12.0, col: 12, telegraph_t: 44, active_t: 18, fade_t: 8 })
        beams << BeamHazard.new({ x1: 128.0, y1: 72.0, x2: 18.0, y2: GROUND_Y, width: 10.0, col: 8, telegraph_t: 44, active_t: 18, fade_t: 8 })
        beams << BeamHazard.new({ x1: 128.0, y1: 72.0, x2: 238.0, y2: GROUND_Y, width: 10.0, col: 8, telegraph_t: 44, active_t: 18, fade_t: 8 })
        if @b.phase == 2
          beams << BeamHazard.new({ x1: 0.0, y1: 196.0, x2: 256.0, y2: 196.0, width: 10.0, col: 14, telegraph_t: 46, active_t: 16, fade_t: 8 })
        end
      end

    when :laser_wait
      if @b.state_t == 24
        fx.add_shake(4.5)
        @b.sx = 1.20
        @b.sy = 0.84
      end
      if @b.state_t <= 0
        @b.state = :float
        @b.state_t = 22
      end

    when :ring_pos
      @b.x = lerp_f(@b.x, 128.0, 0.16)
      @b.y = lerp_f(@b.y, 134.0, 0.16)
      @b.facing = (player.foot_cx < @b.x) ? -1 : 1
      if @b.state_t <= 0
        @b.state = :ring_fire
        @b.state_t = 40
        @core_parried = false
        count = (@b.phase == 2 ? 12 : 8)
        i = 0
        while i < count
          ang = (i.to_f / count.to_f) * 6.28318 + 0.2
          projectiles << Projectile.new({
            x: @b.center_x,
            y: @b.center_y,
            vx: cos(ang) * 2.1,
            vy: sin(ang) * 2.1,
            radius: 3.5,
            col: 12,
            parryable: false
          })
          i += 1
        end
        # パリィ返しでドラゴンを怯ませる大型ピンクコア！
        dx = player.foot_cx - @b.center_x
        dy = (player.foot_y - 8.0) - @b.center_y
        d = hypot(dx, dy)
        d = 1.0 if d < 1.0
        projectiles << Projectile.new({
          x: @b.center_x,
          y: @b.center_y,
          vx: (dx / d) * 2.3,
          vy: (dy / d) * 2.3,
          radius: 5.5,
          col: 14,
          parryable: true
        })
        fx.spawn_ring(@b.center_x, @b.center_y, 32.0, 14, 14)
      end

    when :ring_fire
      if @b.state_t <= 0
        @b.state = :float
        @b.state_t = 24
      end

    when :storm_pos
      @b.x = lerp_f(@b.x, 38.0, 0.16)
      @b.y = lerp_f(@b.y, 92.0, 0.16)
      @b.facing = 1
      if @b.state_t <= 0
        @b.state = :storm_sweep
        @b.state_t = 58
      end

    when :storm_sweep
      @b.x += 3.1
      if @b.state_t % 8 == 0
        is_p = (@b.state_t % 24 == 0)
        projectiles << Projectile.new({
          x: @b.center_x, y: @b.center_y + 10.0,
          vx: -0.6, vy: 2.5,
          radius: is_p ? 4.5 : 3.5, col: 8, parryable: is_p
        })
      end
      if @b.x >= 220.0 || @b.state_t <= 0
        @b.state = :float
        @b.state_t = 22
      end

    when :stun
      @b.y = lerp_f(@b.y, 184.0, 0.14)
      if @b.state_t <= 0
        @b.touch_active = true
        @b.state = :float
        @b.state_t = 20
      end
    end
  end

  def on_parry_hit(fx)
    @b.sx = 0.78
    @b.sy = 1.24
    if @b.state != :dying && @b.state != :phase2_roar
      @b.state = :stun
      @b.state_t = 44
      @b.touch_active = false
      fx.spawn_popup("STUN!", @b.center_x, @b.y - @b.h - 10.0, 10)
    end
  end

  def draw(fx)
    return if @b.dead
    # バイト突進の赤帯予告
    if @b.state == :bite_aim
      blink = (@b.state_t / 3) % 2 == 0
      col = blink ? 8 : 10
      yt = (@sweep_base_y - 36.0).round
      yb = (@sweep_base_y - 6.0).round
      line(10, yt, 246, yt, col)
      line(10, yb, 246, yb, col)
      draw_shadow_text("!", @b.center_x.round - 2, (@b.y - @b.h - 10.0).round, col)
    end

    # 接地影
    ovalfill(@b.x.round, GROUND_Y.round + 1, 18, 3, 0)

    # 6節首関節を背面から頭に向かってうねり描画
    hx = @b.center_x - @b.facing * 10.0
    hy = @b.center_y + 6.0
    anchor_x = (@b.facing > 0) ? (@b.x - 110.0) : (@b.x + 110.0)
    anchor_y = 148.0
    seg_pal = (@b.state == :dying && @b.dying_t % 3 == 0) ? PAL_WHITE : @b.pal_for_draw

    s = 6
    while s >= 1
      t = s.to_f / 7.0
      sx = lerp_f(hx, anchor_x, t)
      sy = lerp_f(hy, anchor_y, t) + sin(@b.frame * 0.14 + s * 0.7) * (6.0 * t + 2.0)
      draw_spr_centered(@id_seg, sx, sy, 16, 16, 0.0, 1.0, 1.0, @b.facing > 0, false, seg_pal)
      s -= 1
    end

    mouth_open = (@b.state == :bite_aim || @b.state == :bite_sweep || @b.state == :laser_wait ||
                  @b.state == :ring_fire || @b.state == :phase2_roar)
    sid = mouth_open ? @id_head1 : @id_head0
    flip = @b.facing > 0
    pal = (@b.state == :dying && @b.dying_t % 3 == 0) ? PAL_WHITE : @b.pal_for_draw
    draw_spr_grounded(sid, @b.x, @b.y, 48, 48, @b.sx, @b.sy, flip, pal)
    @b.draw_stun_stars
  end
end

def create_boss_for_stage(idx)
  return MossGolem.new if idx == 0
  return SolarPhoenix.new if idx == 1
  return NeonMecha.new if idx == 2
  CyberDragon.new
end

# ------------------------------------------------------------------------------
# 背景床 & ステージ足場描画ヘルパー（タイルマップ不使用）
# ------------------------------------------------------------------------------
def draw_arena_floor(style, frame)
  fy = GROUND_Y.round
  if style == :forest
    rectfill(0, fy, SCREEN_W, SCREEN_H - fy, 1)
    rectfill(0, fy, SCREEN_W, 4, 3)
    rectfill(0, fy, SCREEN_W, 2, 11)
    x = 0
    while x < SCREEN_W
      line(x, fy + 4, x, SCREEN_H, 0)
      rectfill(x + 4, fy + 8, 8, 4, 5)
      x += 24
    end
  elsif style == :volcano
    rectfill(0, fy, SCREEN_W, SCREEN_H - fy, 0)
    rectfill(0, fy, SCREEN_W, 3, 2)
    rectfill(0, fy, SCREEN_W, 1, 9)
    pulse = (frame / 10) % 2 == 0 ? 9 : 8
    x = 8
    while x < SCREEN_W
      line(x, fy + 5, x + 8, fy + 16, pulse)
      rectfill(x + 12, fy + 6, 10, 6, 4)
      x += 32
    end
  elsif style == :city
    rectfill(0, fy, SCREEN_W, SCREEN_H - fy, 1)
    rectfill(0, fy, SCREEN_W, 3, 6)
    rectfill(0, fy, SCREEN_W, 1, 12)
    # 警告ハザードストライプ
    x = 0
    while x < SCREEN_W
      col = ((x / 8) % 2 == 0) ? 10 : 0
      rectfill(x, fy + 4, 8, 3, col)
      line(x, fy + 8, x, SCREEN_H, 5)
      x += 8
    end
  else
    # :cyber スクロールデジタルグリッド
    rectfill(0, fy, SCREEN_W, SCREEN_H - fy, 0)
    rectfill(0, fy, SCREEN_W, 2, 12)
    line(0, fy + 2, SCREEN_W, fy + 2, 7)
    off = (frame * 2) % 24
    x = -off
    while x < SCREEN_W + 24
      line(x, fy + 2, x - 16, SCREEN_H, 1)
      line(x + 1, fy + 2, x - 15, SCREEN_H, 12) if ((x + off) / 24) % 2 == 0
      x += 24
    end
    line(0, fy + 12, SCREEN_W, fy + 12, 1)
  end
end

def draw_platforms(platforms, style)
  i = 0
  while i < platforms.size
    pl = platforms[i]
    px = pl[:x].round
    py = pl[:y].round
    pw = pl[:w].round
    if style == :forest
      rectfill(px, py, pw, 5, 4)
      rectfill(px, py, pw, 2, 11)
      rect(px, py, pw, 5, 0)
    elsif style == :volcano
      rectfill(px, py, pw, 5, 2)
      rectfill(px, py, pw, 2, 9)
      rect(px, py, pw, 5, 0)
    elsif style == :city
      rectfill(px, py, pw, 5, 5)
      rectfill(px, py, pw, 2, 12)
      rect(px, py, pw, 5, 7)
    else
      rectfill(px, py, pw, 4, 1)
      line(px, py, px + pw, py, 7)
      line(px, py + 1, px + pw, py + 1, 12)
      rect(px, py, pw, 4, 12)
    end
    i += 1
  end
end

# ------------------------------------------------------------------------------
# シーン 1: タイトル画面 (TitleScene)
# ------------------------------------------------------------------------------
class TitleScene
  def initialize
    @frame = 0
    @menu_idx = 0
    @practice_stage = 0
    @id_hero = spr_id(:hero_idle)
    @id_golem = spr_id(:boss_golem)
    @id_dragon = spr_id(:boss_dragon)
  end

  def update
    @frame += 1

    if btnp(:up) || btnp(:down)
      @menu_idx = 1 - @menu_idx
    end

    if @menu_idx == 1
      if btnp(:left)
        @practice_stage = (@practice_stage - 1) % 4
      elsif btnp(:right)
        @practice_stage = (@practice_stage + 1) % 4
      end
    end

    if btnp(1)
      player = Player.new
      if @menu_idx == 0
        run StageIntroScene.new(:rush, 0, player, 0)
      else
        run StageIntroScene.new(:practice, @practice_stage, player, 0)
      end
    end
  end

  def draw
    cls(0)
    bg(:cyber, dim: 0.48, tint: [140, 210, 255], scroll_x: @frame * 0.4, mirror_x: true)

    # 装飾床
    draw_arena_floor(:cyber, @frame)

    # ロゴパネル
    rectfill(20, 18, 216, 48, 1)
    rect(20, 18, 216, 48, 12)
    rect(22, 20, 212, 44, 7)
    t1 = "USAKAME BOSS RUSH"
    draw_shadow_text(t1, center_text_x(t1), 29, 10)
    t2 = "4 TRIALS OF THE BLADE"
    draw_shadow_text(t2, center_text_x(t2), 45, 7)

    # 対峙プレビュースプライト（左右にボス、中央下にうさ騎士）
    bob = sin(@frame * 0.1) * 2.0
    draw_spr_grounded(@id_golem, 40.0, GROUND_Y, 32, 32, 1.0, 1.0, true)
    draw_spr_grounded(@id_dragon, 218.0, 198.0 + bob, 48, 48, 1.0, 1.0, false)
    hero_f = spr_id(:hero_idle, (@frame / 18) % 2)
    draw_spr_grounded(hero_f, 128.0, GROUND_Y, 16, 16, 1.0, 1.0, false)

    # メニュー選択パネル
    rectfill(24, 74, 208, 74, 0)
    rect(24, 74, 208, 74, 6)

    c0 = (@menu_idx == 0) ? 10 : 7
    p0 = (@menu_idx == 0) ? "> BOSS RUSH (4 STAGES)" : "  BOSS RUSH (4 STAGES)"
    draw_shadow_text(p0, 42, 83, c0)

    bmeta = BOSS_LIST[@practice_stage]
    c1 = (@menu_idx == 1) ? 10 : 7
    p1 = (@menu_idx == 1) ? "> PRACTICE: < #{bmeta[:stage]}. #{bmeta[:name]} >" : "  PRACTICE:   #{bmeta[:stage]}. #{bmeta[:name]}"
    draw_shadow_text(p1, 32, 98, c1)

    if $best_rush_frames
      rec = "BEST RUSH: #{format_time($best_rush_frames)} [RANK #{$best_rush_rank}]"
      draw_shadow_text(rec, center_text_x(rec), 114, 11)
    else
      rec = "DEFEAT ALL 4 GUARDIANS!"
      draw_shadow_text(rec, center_text_x(rec), 114, 12)
    end

    if (@frame / 24) % 3 != 2
      st = "PRESS [Z] TO START"
      draw_shadow_text(st, center_text_x(st), 132, 10)
    end

    # 操作ガイド
    rectfill(14, 222, 228, 30, 0)
    rect(14, 222, 228, 30, 5)
    g1 = "MOVE:<-> JUMP:^ SLASH:Z DASH:X"
    g2 = "AIR DOWN+Z:POGO  SLASH PINK:PARRY"
    draw_shadow_text(g1, center_text_x(g1), 228, 7)
    draw_shadow_text(g2, center_text_x(g2), 240, 14)
  end
end

# ------------------------------------------------------------------------------
# シーン 2: ステージ導入カード (StageIntroScene)
# ------------------------------------------------------------------------------
class StageIntroScene
  def initialize(mode, stage_idx, player, total_frames, healed = false)
    @mode = mode
    @stage_idx = stage_idx
    @player = player
    @total_frames = total_frames
    @healed = healed
    @frame = 0
    @boss = create_boss_for_stage(stage_idx)
  end

  def update
    @frame += 1
    if @frame >= 65 || (@frame > 10 && btnp(1))
      run BattleScene.new(@mode, @stage_idx, @player, @total_frames, @boss)
    end
  end

  def draw
    cls(0)
    meta = @boss.b.meta
    bg(meta[:bg], dim: 0.45, tint: meta[:tint1], scroll_x: @frame * 0.5, mirror_x: true)

    draw_arena_floor(meta[:floor], @frame)
    draw_platforms(@boss.b.platforms, meta[:floor])

    # clip を使ったシネマスコープ開演演出
    open_h = (@frame * 10).clamp(16, 128)
    clip(0, 128 - open_h, SCREEN_W, open_h * 2)

    @player.draw
    @boss.draw(nil)

    rectfill(24, 58, 208, 52, 0)
    rect(24, 58, 208, 52, 10)
    st_lbl = "STAGE #{meta[:stage]} / 4"
    draw_shadow_text(st_lbl, center_text_x(st_lbl), 65, 12)
    draw_shadow_text(meta[:name], center_text_x(meta[:name]), 78, 10)
    draw_shadow_text(meta[:subtitle], center_text_x(meta[:subtitle]), 93, 7)

    if @healed
      ht = "HP +2 RECOVERED!"
      draw_shadow_text(ht, center_text_x(ht), 116, 11)
    end

    clip
  end
end

# ------------------------------------------------------------------------------
# シーン 3: バトル画面 (BattleScene)
# ------------------------------------------------------------------------------
class BattleScene
  def initialize(mode, stage_idx, player, total_frames, boss = nil)
    @mode = mode
    @stage_idx = stage_idx
    @player = player
    @player.reset_for_stage(true)
    @total_frames = total_frames
    @stage_frames = 0
    @boss = boss || create_boss_for_stage(stage_idx)
    @fx = EffectSystem.new
    @projectiles = []
    @beams = []
    @shocks = []
    @bg_scroll = 0.0
    @world_tick = 0
    @id_heart_full = spr_id(:heart, 0)
    @id_heart_empty = spr_id(:heart, 1)
  end

  def update
    @fx.tick_timers

    # ヒットストップ中は演出粒子の更新も止めて衝撃を強調
    if @fx.hitstop > 0
      return
    end

    # ジャスト回避スロー中はワールド進行を2フレームに1回に抑制
    @world_tick += 1
    if @fx.slow_timer > 0 && (@world_tick % 2 == 1)
      @fx.update_particles
      return
    end

    @stage_frames += 1
    @total_frames += 1
    meta = @boss.b.meta
    spd_mul = (@boss.b.phase == 2) ? 2.4 : 1.0
    @bg_scroll += meta[:scroll_spd] * spd_mul

    # 環境パーティクル
    spawn_env_particle(meta[:floor])

    # 1. プレイヤー更新
    @player.update(@boss.b.platforms, @fx)

    # 2. ボス更新
    @boss.update(@player, @fx, @projectiles, @beams, @shocks)

    # 3. 弾・ビーム・衝撃波更新
    i = 0
    while i < @projectiles.size
      @projectiles[i].update(@player, @boss, @fx)
      i += 1
    end

    i = 0
    while i < @beams.size
      @beams[i].update(@fx)
      i += 1
    end

    i = 0
    while i < @shocks.size
      @shocks[i].update(@fx)
      i += 1
    end

    # 4. プレイヤー斬撃 vs 弾（パリィ & ミサイル破壊） & 斬撃 vs ボス
    resolve_player_attacks

    # 5. 反射弾 vs ボス
    resolve_reflected_projectiles

    # 6. 敵攻撃 vs プレイヤー（ジャスト回避 or 被弾）
    resolve_player_hazards

    # 死んだオブジェクトの掃除
    @projectiles.reject! { |p| !p.alive }
    @beams.reject! { |bm| !bm.alive }
    @shocks.reject! { |sw| !sw.alive }

    @fx.update_particles

    # 7. 勝敗遷移
    if @player.hp <= 0
      run ResultScene.new(false, @mode, @stage_idx, @player, @total_frames, @boss.b)
      return
    end

    if @boss.b.dead
      prev_best = $boss_best_frames[@stage_idx]
      if prev_best.nil? || @stage_frames < prev_best
        $boss_best_frames[@stage_idx] = @stage_frames
      end

      if @mode == :rush && @stage_idx < 3
        old_hp = @player.hp
        @player.hp = (@player.hp + 2).clamp(0, @player.max_hp)
        healed = (@player.hp > old_hp)
        run StageIntroScene.new(:rush, @stage_idx + 1, @player, @total_frames, healed)
      else
        run ResultScene.new(true, @mode, @stage_idx, @player, @total_frames, @boss.b)
      end
    end
  end

  def spawn_env_particle(floor)
    return if @stage_frames % 5 != 0
    if floor == :forest
      @fx.spawn_ambient(rand(256).to_f, 40.0 + rand(165).to_f, (rand() - 0.5) * 0.3, -0.25, 11, 45)
    elsif floor == :volcano
      @fx.spawn_ambient(rand(256).to_f, GROUND_Y - 2.0, (rand() - 0.5) * 0.5, -0.8 - rand() * 0.6, (rand(2) == 0 ? 9 : 10), 40)
    elsif floor == :city
      @fx.spawn_ambient(rand(256).to_f, 16.0, -0.3, 3.2, 12, 32)
    else
      @fx.spawn_ambient(rand(256).to_f, 20.0 + rand(190).to_f, -1.2, 0.0, 12, 24)
    end
  end

  def resolve_player_attacks
    atk_box = @player.attack_hitbox
    return if atk_box.nil?
    ax, ay, aw, ah = atk_box[0], atk_box[1], atk_box[2], atk_box[3]

    # パリィ＆ミサイル破壊（1振り内でも複数弾OK）
    i = 0
    while i < @projectiles.size
      p = @projectiles[i]
      if p.alive && p.kind != :reflected
        pb = p.hitbox
        if aabb_overlap?(ax, ay, aw, ah, pb[0], pb[1], pb[2], pb[3])
          if p.parryable
            p.kind = :reflected
            p.parryable = false
            p.homing_speed = 6.2
            p.dmg = 24
            p.age = 0
            @player.parry_count += 1
            @player.add_combo(3)
            @player.dash_cd = 0
            @player.air_jumps = 1
            if @player.atk_stage == :pogo
              @player.pogo_bounce(@fx)
            elsif !@player.on_ground && @player.vy > -1.0
              @player.vy = -2.8
            end
            @fx.add_hitstop(6)
            @fx.add_shake(2.6)
            @fx.spawn_ring(p.x, p.y, 20.0, 10, 14)
            @fx.spawn_burst(p.x, p.y, 10, 10, 2.5)
            @fx.spawn_popup("PARRY!", p.x, p.y - 12.0, 10)
          elsif p.destructible
            p.alive = false
            @player.add_combo(1)
            @fx.spawn_burst(p.x, p.y, 9, 8, 2.2)
            @fx.spawn_ring(p.x, p.y, 12.0, 9, 10)
            if @player.atk_stage == :pogo
              @player.pogo_bounce(@fx)
            end
          end
        end
      end
      i += 1
    end

    # ボス本体へのヒット（1振りで1ヒット）
    return if @player.atk_hit_done || @boss.b.state == :dying || @boss.b.dead
    bh = @boss.b.hitbox
    if aabb_overlap?(ax, ay, aw, ah, bh[0], bh[1], bh[2], bh[3])
      @player.atk_hit_done = true
      is_crit = @player.empowered || (@player.atk_stage == 3)
      dmg = @player.attack_damage
      @player.empowered = false
      hx = clamp_f(ax + aw * 0.5, bh[0], bh[0] + bh[2])
      hy = clamp_f(ay + ah * 0.5, bh[1], bh[1] + bh[3])
      @boss.b.take_damage(dmg, @fx, @player, is_crit, hx, hy)
      if @player.atk_stage == :pogo
        @player.pogo_bounce(@fx)
      end
    end
  end

  def resolve_reflected_projectiles
    return if @boss.b.state == :dying || @boss.b.dead
    bh = @boss.b.hitbox
    i = 0
    while i < @projectiles.size
      p = @projectiles[i]
      if p.alive && p.kind == :reflected
        pb = p.hitbox
        if aabb_overlap?(pb[0], pb[1], pb[2], pb[3], bh[0], bh[1], bh[2], bh[3])
          p.alive = false
          @boss.b.take_damage(p.dmg, @fx, @player, true, p.x, p.y)
          @boss.on_parry_hit(@fx)
          @fx.spawn_ring(p.x, p.y, 24.0, 10, 14)
        end
      end
      i += 1
    end
  end

  def resolve_player_hazards
    hb = @player.hurtbox
    px, py, pw, ph = hb[0], hb[1], hb[2], hb[3]
    touched_hazard = false

    # 弾
    i = 0
    while i < @projectiles.size
      p = @projectiles[i]
      if p.alive && p.kind != :reflected
        pb = p.hitbox
        if aabb_overlap?(px, py, pw, ph, pb[0], pb[1], pb[2], pb[3])
          touched_hazard = true
          if @player.can_just_dodge?
            @player.trigger_just_dodge(@fx)
            return
          elsif !@player.invulnerable?
            p.alive = false
            @player.take_damage(@fx)
            return
          end
        end
      end
      i += 1
    end

    # ビーム
    i = 0
    while i < @beams.size
      bm = @beams[i]
      if bm.hits_box?(px, py, pw, ph)
        touched_hazard = true
        if @player.can_just_dodge?
          @player.trigger_just_dodge(@fx)
          return
        elsif !@player.invulnerable?
          @player.take_damage(@fx)
          return
        end
      end
      i += 1
    end

    # 衝撃波
    i = 0
    while i < @shocks.size
      sw = @shocks[i]
      if sw.alive
        sb = sw.hitbox
        if aabb_overlap?(px, py, pw, ph, sb[0], sb[1], sb[2], sb[3])
          touched_hazard = true
          if @player.can_just_dodge?
            @player.trigger_just_dodge(@fx)
            return
          elsif !@player.invulnerable?
            @player.take_damage(@fx)
            return
          end
        end
      end
      i += 1
    end

    # ボス体当たり
    if @boss.b.can_touch_damage?
      bh = @boss.b.hitbox
      if aabb_overlap?(px, py, pw, ph, bh[0], bh[1], bh[2], bh[3])
        if @player.can_just_dodge?
          @player.trigger_just_dodge(@fx)
          return
        elsif !@player.invulnerable?
          @player.take_damage(@fx)
          return
        end
      end
    end
  end

  def draw
    cls(0)
    meta = @boss.b.meta
    sx = @fx.shake_x
    sy = @fx.shake_y

    # 1. 背景描画 (bg は camera の影響を受けないため scale:1.04 と scroll_x でシェイク連動)
    bg(meta[:bg],
       dim: 0.42,
       tint: @boss.b.current_bg_tint,
       scale: 1.04,
       y: -4.0 - sy * 0.35,
       scroll_x: @bg_scroll + sx * 0.45,
       mirror_x: true)

    # 2. ワールド描画（カメラシェイク適用）
    camera(sx, sy)

    draw_arena_floor(meta[:floor], @stage_frames)
    draw_platforms(@boss.b.platforms, meta[:floor])

    # ビーム
    i = 0
    while i < @beams.size
      @beams[i].draw
      i += 1
    end

    # 残像
    @fx.draw_afterimages

    # プレイヤー接地影 & 本体
    ovalfill(@player.foot_cx.round, GROUND_Y.round + 1, 6, 2, 0) if @player.on_ground && @player.foot_y >= GROUND_Y - 1.0
    @boss.draw(@fx)
    @player.draw

    # 衝撃波・弾
    i = 0
    while i < @shocks.size
      @shocks[i].draw
      i += 1
    end

    i = 0
    while i < @projectiles.size
      @projectiles[i].draw
      i += 1
    end

    # パーティクル・ポップアップ
    @fx.draw_particles
    @fx.draw_popups

    # 3. HUD 描画（カメラを必ずリセット）
    camera()
    draw_hud
    @fx.draw_screen_flash
  end

  def draw_hud
    # 上部半透明風バー
    rectfill(0, 0, SCREEN_W, 20, 0)
    line(0, 20, SCREEN_W, 20, 5)

    # ハート 5個
    i = 0
    while i < @player.max_hp
      sid = (i < @player.hp) ? @id_heart_full : @id_heart_empty
      spr(sid, 6 + i * 10, 3)
      i += 1
    end

    # ダッシュゲージ & EMPOWERED インジケータ
    bar_x = 6
    bar_y = 13
    bar_w = 48
    rectfill(bar_x, bar_y, bar_w, 4, 1)
    fill_w = (bar_w * @player.dash_cd_ratio).round
    dash_col = @player.dash_cd_ratio >= 0.99 ? 12 : 6
    rectfill(bar_x, bar_y, fill_w, 4, dash_col) if fill_w > 0
    rect(bar_x, bar_y, bar_w, 4, 5)

    if @player.empowered
      draw_shadow_text("POWER!", 60, 5, 10)
    elsif @player.combo >= 2
      draw_shadow_text("#{@player.combo} HIT!", 60, 5, 12)
    end

    # ステージ & 経過時間
    st_lbl = (@mode == :rush) ? "STAGE #{@stage_idx + 1}/4" : "PRACTICE"
    t_str = format_time(@total_frames)
    draw_shadow_text(st_lbl, 134, 4, 7)
    draw_shadow_text(t_str, 198, 4, 10)

    # 下部 ボスHPゲージ (床エリア下部 y=224..252)
    meta = @boss.b.meta
    draw_shadow_text(meta[:name], 16, 224, 7)
    if @boss.b.phase == 2
      draw_shadow_text("PHASE 2", 198, 224, 8)
    end

    gx = 16
    gy = 235
    gw = 224
    gh = 9
    rectfill(gx, gy, gw, gh, 0)

    disp_w = ((@boss.b.display_hp / @boss.b.max_hp.to_f) * (gw - 2)).round.clamp(0, gw - 2)
    hp_w = ((@boss.b.hp.to_f / @boss.b.max_hp.to_f) * (gw - 2)).round.clamp(0, gw - 2)
    rectfill(gx + 1, gy + 1, disp_w, gh - 2, 10) if disp_w > 0
    hp_col = (@boss.b.phase == 2) ? 9 : 8
    rectfill(gx + 1, gy + 1, hp_w, gh - 2, hp_col) if hp_w > 0

    # フェーズ2ライン (50%)
    mid_x = gx + gw / 2
    line(mid_x, gy, mid_x, gy + gh - 1, 7)
    rect(gx, gy, gw, gh, 7)
  end
end

# ------------------------------------------------------------------------------
# シーン 4: リザルト画面 (ResultScene)
# ------------------------------------------------------------------------------
class ResultScene
  def initialize(victory, mode, stage_idx, player, total_frames, boss_core)
    @victory = victory
    @mode = mode
    @stage_idx = stage_idx
    @player = player
    @total_frames = total_frames
    @boss_core = boss_core
    @frame = 0
    @rank = compute_rank
    @new_record = false

    if @victory && @mode == :rush
      if $best_rush_frames.nil? || @total_frames < $best_rush_frames
        $best_rush_frames = @total_frames
        $best_rush_rank = @rank
        @new_record = true
      end
    end
  end

  def compute_rank
    return "C" unless @victory
    secs = @total_frames / 60.0
    hits = @player.hits_taken
    if @mode == :rush
      return "S+" if hits == 0 && secs <= 170.0
      return "S"  if hits <= 2 && secs <= 210.0
      return "A"  if hits <= 5 && secs <= 260.0
      return "B"  if hits <= 9
      "C"
    else
      return "S+" if hits == 0 && secs <= 45.0
      return "S"  if hits <= 1 && secs <= 65.0
      return "A"  if hits <= 3
      return "B"  if hits <= 6
      "C"
    end
  end

  def update
    @frame += 1
    return if @frame < 20

    if btnp(1)
      if @victory
        p = Player.new
        start_stage = (@mode == :rush) ? 0 : @stage_idx
        run StageIntroScene.new(@mode, start_stage, p, 0)
      else
        # 敗北時はそのボスへ即リトライ！
        p = Player.new
        run StageIntroScene.new(@mode, @stage_idx, p, 0)
      end
    elsif btnp(2)
      run TitleScene.new
    end
  end

  def draw
    cls(0)
    if @victory
      bg(:space, dim: 0.35, scroll_x: @frame * 0.25, scroll_y: -@frame * 0.2, loop_x: true, loop_y: true)
    else
      bg(:cave, dim: 0.58, tint: [220, 110, 120], scroll_x: @frame * 0.12, mirror_x: true)
    end

    rectfill(22, 24, 212, 206, 0)
    border = @victory ? 10 : 8
    rect(22, 24, 212, 206, border)
    rect(24, 26, 208, 202, 5)

    if @victory
      hdr = (@mode == :rush) ? "ALL GUARDIANS DEFEATED!" : "VICTORY!"
      draw_shadow_text(hdr, center_text_x(hdr), 36, 10)
      hero_f = spr_id(:hero_idle, (@frame / 14) % 2)
      draw_spr_grounded(hero_f, 128.0, 74.0, 16, 16, 1.5, 1.5, false)

      r_col = (@rank == "S+" || @rank == "S") ? 10 : 12
      r_txt = "CLEAR RANK : #{@rank}"
      draw_shadow_text(r_txt, center_text_x(r_txt), 86, r_col)
      if @new_record
        nr = "NEW RECORD!"
        draw_shadow_text(nr, center_text_x(nr), 98, 11)
      end
    else
      hdr = "DEFEATED..."
      draw_shadow_text(hdr, center_text_x(hdr), 38, 8)
      sub = "AT #{@boss_core.meta[:name]}"
      draw_shadow_text(sub, center_text_x(sub), 54, 7)
      rem_pct = ((@boss_core.hp.to_f / @boss_core.max_hp.to_f) * 100.0).ceil.to_i
      rem_txt = "BOSS HP LEFT : #{rem_pct}%"
      draw_shadow_text(rem_txt, center_text_x(rem_txt), 74, 9)
    end

    draw_shadow_text("CLEAR TIME  : #{format_time(@total_frames)}", 46, 118, 7)
    draw_shadow_text("HITS TAKEN  : #{@player.hits_taken}", 46, 132, 7)
    draw_shadow_text("JUST DODGES : #{@player.just_count}", 46, 146, 12)
    draw_shadow_text("PARRIES     : #{@player.parry_count}", 46, 160, 14)
    draw_shadow_text("MAX COMBO   : #{@player.max_combo}", 46, 174, 10)

    if (@frame / 24) % 3 != 2
      act = @victory ? "[Z] PLAY AGAIN" : "[Z] RETRY BOSS"
      draw_shadow_text(act, center_text_x(act), 198, 10)
    end
    t_btn = "[X] BACK TO TITLE"
    draw_shadow_text(t_btn, center_text_x(t_btn), 212, 6)
  end
end

# ------------------------------------------------------------------------------
# 初回シーン起動
# ------------------------------------------------------------------------------
run TitleScene.new

__END__
# ==============================================================================
# カスタムパレット (1..5: キャラ/ボス固有, 10..13: ヒットフラッシュ/残像/オーラ)
# ==============================================================================
@PALETTE 1
0: #121020
1: #1D2B53
2: #7E2553
4: #8B4530
5: #53586E
6: #A8B5C8
7: #FFF5EA
8: #FF1E56
9: #FFA300
A: #FFEC27
C: #38B6FF
D: #80D8FF
E: #FF77A8
F: #FFD4B8

@PALETTE 2
0: #0E1814
1: #23302A
3: #1E6B43
4: #5C4332
5: #4A545E
6: #86929C
7: #E8F4EC
8: #FF2E63
9: #FF9A2E
A: #FFE64D
B: #46B85C
C: #8BE872
D: #38443E
F: #B4C2BA

@PALETTE 3
0: #1F0B16
1: #4A1525
2: #8C1D2E
4: #6B2810
7: #FFF8E0
8: #FF2A3B
9: #FF7B1A
A: #FFD93D
B: #FF5522
C: #45D1FF
D: #B34030
E: #FF8870
F: #FFEAA0

@PALETTE 4
0: #0C0E1E
1: #1C2645
2: #5A1E5C
5: #364568
6: #7D92B8
7: #F0F8FF
8: #FF2470
9: #FF9933
A: #FFEE44
B: #00E896
C: #29C8FF
D: #90EAFF
E: #FF78B8
F: #B8CCE0

@PALETTE 5
0: #0A0816
1: #1A173B
2: #661448
5: #322F60
6: #6D6CA8
7: #F4FBFF
8: #FF1855
9: #FF8822
A: #FFE44D
C: #00D8FF
D: #8CF2FF
E: #FF66B2
F: #B5BCFF

@PALETTE 10
#FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8
#FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8

@PALETTE 11
#1870B8 #1870B8 #1870B8 #1870B8 #1870B8 #28C8FF #48D8FF #E8FFFF
#28C8FF #48D8FF #E8FFFF #28C8FF #48D8FF #E8FFFF #48D8FF #E8FFFF

@PALETTE 12
#B86400 #D07800 #D07800 #D07800 #D07800 #E89600 #FFCC22 #FFFCE0
#FFAA00 #FFCC22 #FFEC27 #FFCC22 #FFEC27 #FFFCE0 #FFCC22 #FFFCE0

@PALETTE 13
#680820 #680820 #981030 #981030 #981030 #C81840 #FF3355 #FFE8EC
#FF1E56 #FF4D79 #FF809E #FF3355 #FF6688 #FFE8EC #FF6688 #FFE8EC

# ==============================================================================
# スプライト定義 (全14種)
# ==============================================================================
@SPRITE :hero_idle 16x16 pal:1
....00....00....
...07E0..0E70...
...07E0..0E70...
...0770000770...
..077CC77CC770..
..077007700770..
...0777EE7770...
...0088888800...
..028889888070..
.0220166610670..
.020.01A10.0A0..
.....01110..0...
.....04040......
....0440440.....
....000.000.....
................
---
................
....00....00....
...07E0..0E70...
...07E0..0E70...
...0770000770...
..077CC77CC770..
..077007700770..
...0777EE7770...
..00088888800...
.0288889888070..
.020.0166610670.
.....01A10..0A0.
.....01110...0..
.....04040......
....0440440.....
....000.000.....

@SPRITE :hero_run 16x16 pal:1
.....00....00...
....07E0..0E70..
....07E0..0E70..
....0770000770..
...077CC77CC770.
...077007700770.
....0777EE7770..
.00.008888880...
0228888988070...
.0200166610670..
....011A10.0A0..
...040110...0...
..0440.040......
..000...0440....
.........000....
................
---
....00....00....
...07E0..0E70...
...07E0..0E70...
...0770000770...
..077CC77CC770..
..077007700770..
...0777EE7770...
00.008888880....
0228889888070...
.00.0166610670..
....01A110.0A0..
.....0110...0...
....04040.......
...0440.0440....
...000...000....
................

@SPRITE :hero_jump 16x16 pal:1
...00......00...
..07E0....0E70..
...07E0..0E70...
...0770000770...
..077CC77CC770..
..077007700770..
...0777EE7770...
..00088888800...
.028888988070...
.020.016610670..
.....01A10.0A0..
....0411140.0...
....0440440.....
.....00.00......
................
................
---
..00........00..
..07E0....0E70..
...07E0..0E70...
...0770000770...
..077CC77CC770..
..077007700770..
...0777EE7770...
00.0088888800...
0228889888070...
.00.0166610670..
....01A10..0A0..
....01110...0...
...040.040......
..0440.0440.....
...00...00......
................

@SPRITE :hero_atk 16x16 pal:1
.....00....00...
....07E0..0E70..
....07E0..0E70..
....0770000770..
...077CC77CC770.
...077007700770.
....0777EE7770..
.00.008888880...
022888898880....
.00..016661000..
....01A110A67770
....01110..0000.
...040.040......
..0440..0440....
..000....000....
................

@SPRITE :hero_dash 16x16 pal:1
................
................
..00....00......
.07E0..0E70.....
..0770000770....
..077CC77CC770..
..077007700770..
...0777EE7770...
0000088888800...
02228898880.....
.00.016661000...
...0401A10A6770.
..0440.0440000..
..000...000.....
................
................

@SPRITE :slash 32x16 pal:1
...........CCCCCCCCCCC..........
........CCCDDDDDDDDDDDCC........
......CCDDD77777777777DDDC......
....CCDD7777777777777777DDC.....
...CDD7777777777777777777DDC....
..CD7777777..........77777DDC...
.CD77777...............77777DC..
CD7777...................7777DC.
CD777.....................777DC.
.CD7.......................77DC.
..C.........................7C..
................................
................................
................................
................................
................................
---
..............CCCCCCC...........
..........CCCCDDDDDDDCCC........
.......CCCDDD77777777DDDC.......
.....CCDD7777........777DC......
....CD777................7C.....
...C77......................C...
................................
................................
................................
................................
................................
................................
................................
................................
................................
................................

@SPRITE :slash_down 16x24 pal:1
................
................
................
................
................
................
................
..C..........C..
.CD7........7DC.
.CD77......77DC.
.CD777....777DC.
.CD7777..7777DC.
..CD77777777DC..
..CCDD7777DDCC..
...CCDD77DDCC...
....CCDDDDCC....
.....CCCCCC.....
.......CC.......
................
................
................
................
................
................

@SPRITE :heart 8x8 pal:1
.00..00.
08800880
08788880
08888820
.088820.
..0820..
...00...
........
---
.00..00.
05500550
05155550
05555510
.055510.
..0510..
...00...
........

@SPRITE :boss_golem 32x32 pal:2
.........00000000000000.........
.......00BBCCCCCCCCCCBB00.......
.....00BBCB3333333333BCBB00.....
....0BCB333BBBBBBBBBB333BCB0....
...0BC33555666FFFF66655533CB0...
..0BC35566FFFFFFFFFFFF66553CB0..
..0B3566FFDDDDDDDDDDDDFF6653B0..
.0B356FFD11111111111111DFF653B0.
.0356FD110000000000000011DF6530.
0036FD10000009999990000001DF6300
0B36FD1000009AA77AA9000001DF63B0
0B56FD1000009A7777A9000001DF65B0
0556FD100000099AA990000001DF6550
056FFD11000000000000000011DFF650
056FD1111100000000000011111DF650
056FD1555511000000001155551DF650
0156F5666651110000111566665F6510
015656FFFF651111111156FFFF656510
015556F66F655511115556F66F655510
.015566556655511115556655665510.
.001555555555111111555555555100.
05501155555111444411155555110550
06F50111111144444444111111105F60
0FF65011111144111144111111056FF0
0F6550.001111111111111100.0556F0
065510..0115511111155110..015560
05510...0156651111566510...01550
0110....015FF51..15FF510....0110
.00.....0156651..1566510.....00.
........0115510..0155110........
........0011100..0011100........
.........00000....00000.........
---
.........00000000000000.........
.......00CC7777777777CC00.......
.....00CCBCBBBBBBBBBBBCBCC00....
....0CBCB33CCCCCCCCCC33BCBC0....
...0BC33555666FFFF66655533CB0...
..0BC35566FFFFFFFFFFFF66553CB0..
..0B3566FFDDDDDDDDDDDDFF6653B0..
.0B356FFD11111111111111DFF653B0.
.0356FD110000000000000011DF6530.
0036FD100000889AA988000001DF6300
0B36FD1000089AA77AA9800001DF63B0
0B56FD1000089A7777A9800001DF65B0
0556FD100000899AA998000001DF6550
056FFD11000000888800000011DFF650
056FD1111100000000000011111DF650
056FD1555511000000001155551DF650
0156F5666651110000111566665F6510
015656FFFF651111111156FFFF656510
015556F66F655511115556F66F655510
.015566556655511115556655665510.
.001555555555111111555555555100.
055011555551119AA911155555110550
06F501111111449AA944111111105F60
0FF65011111144111144111111056FF0
0F6550.001111111111111100.0556F0
065510..0115511111155110..015560
05510...0156651111566510...01550
0110....015FF51..15FF510....0110
.00.....0156651..1566510.....00.
........0115510..0155110........
........0011100..0011100........
.........00000....00000.........

@SPRITE :boss_phoenix 32x32 pal:3
...............00...............
..............0AF0..............
.............0A7F0....0000......
......000...0A9AA0..00AAFF0.....
.....0AAA0.0989AA0.0AA999AF0....
....0AC7AA098899900A988889AF0...
..00A7CAAA98888880A98822889AA0..
.0AA44AAAA982288898882112889AA0.
0440..00998822888988211112889A90
........088228889982111111289990
.........0828889AA98211112289980
..........08889AA7F9822222889880
...........089AA77F988888888880.
...........09AA7FFF999888888820.
..........099AAFFFFA9998888220..
.........0999AAFFFAA998882220...
........09889AAAAAA998822200....
.......09888999AA998822200......
......088228889998822200........
.....08821288888822000..........
....082111228882200.............
...08210.02282200...............
...020....02220..00.............
...00......020..0AA0............
...........00..0A990............
..............09890.............
.............09880..............
............08820...............
...........08210................
..........0210..................
..........00....................
................................
---
...............00...............
..............0AF0..............
.............0A7F0..............
......000...0A9AA0..............
.....0AAA0.0989AA0..............
....0AC7AA09889990..............
..00A7CAAA98888880..............
.0AA44AAAA982288890.............
0440..00998822888980............
........0882288899820...........
.........0828889AA98200.........
..........08889AA7F98220........
...........089AA77F988880.......
...........09AA7FFF99988800.....
..........099AAFFFFA99988890....
.........0999AAFFFAA998889AA0...
........09889AAAAAA9988899AAF0..
.......09888999AA998882289AAFF0.
......0882288899988221128899AA0.
.....08821288888822111128888990.
....082111228882211112288822880.
...08210.022822111222882211280..
...020....0222112228822110020...
...00......0211228822000...0....
...........0112282200...........
............0122200.............
.............0220...............
.............010................
..............0.................
................................
................................
................................

@SPRITE :boss_mecha 32x32 pal:4
.....0000.............0000......
....09AA90...000000...09AA90....
...099AA990.056FF650.099AA990...
...05566550056FFFF65005566550...
..056FFFF6556FCCCF65556FFFF650..
..056F66F655FC7DDC75556F66F650..
..0566556655FCDDDDF55566556650..
..01555555156FFFFFF65155555510..
...01155110566FFFF66501155110...
..0056666501566666651056666500..
.056FFFFF65015555551056FFFFF650.
056F6666F65501155110556F6666F650
05665511566556666665556655115660
056511CC15656FFFFFF6556511CC1560
05511CDDC156F688886F65511CDDC150
01511CCCC15668E77E8665111CCCC150
011511111156688EE886651111111110
.0115555555566288266555555555110
..00115566555662266555665511100.
...0566FFFF65566665556FFFF6650..
...056F666F65115511556F666F650..
...05565556510011001565556550...
....011555110.0550.011555110....
.....0011100..0660..0011100.....
.....056650...0550...056650.....
....056FF650..0110..056FF650....
....05666650...00...05666650....
....01555510........01555510....
.....0BBBB0..........0BBBB0.....
.....07BB70..........07BB70.....
......0BB0............0BB0......
.......00..............00.......
---
.....0000.............0000......
....0AA990...000000...0AA990....
...09AAA990.056FF650.09AAA990...
...05566550056FFFF65005566550...
..056FFFF6556FDDDD65556FFFF650..
..056F66F655FD7777D5556F66F650..
..0566556655FD7CC7D55566556650..
..01555555156FFFFFF65155555510..
...01155110566FFFF66501155110...
..0056666501566666651056666500..
.056FFFFF65015555551056FFFFF650.
056F6666F65501155110556F6666F650
05665511566556666665556655115660
056511DD15656FFFFFF6556511DD1560
05511D77D156F6EEEE6F65511D77D150
01511CDDC1566E7777E665111CDDC150
0115111111566E7777E6651111111110
.01155555555668EE866555555555110
..00115566555668866555665511100.
...0566FFFF65566665556FFFF6650..
...056F666F65115511556F666F650..
...05565556510011001565556550...
....011555110.0550.011555110....
.....0011100..0660..0011100.....
.....056650...0550...056650.....
....056FF650..0110..056FF650....
....05666650...00...05666650....
....01555510........01555510....
.....07BB70..........07BB70.....
.....0BBBB0..........0BBBB0.....
......0770............0770......
.......00..............00.......

@SPRITE :mecha_bit 16x16 pal:4
.....000000.....
...0056FF6500...
..056FFFFFF650..
.056F551155F650.
.05F51CCCC15F50.
05651CD77DC15650
05F11C7777C11F50
05F11CDDDDC11F50
05651CCCCCC15650
.05F511CC115F50.
.056F551155F650.
..056FFFFFF650..
...0056666500...
.....01BB10.....
......0770......
.......00.......

@SPRITE :boss_dragon 48x48 pal:5
.......................................0000.....
.....................................00AA7A0....
...................................00AA99AA0....
..................................0AA9900A0.....
..........................0000...0A990..00......
........................00AA7A0.0A90............
......................00AA99AA00AA0.............
.....................0AA9955AA0A90...0000.......
....................0A9905665AA90..00A77A0......
...................0A90.06FF65A0..0AA999A0......
..................0AA0.056CC650..0A99055A0......
.............000000A0..05CCCC50.0A90.05650......
..........00056FF65000056FCCF650AA0.056F650.....
........0056FFFFFF6555666FFFF65090.056FF650.....
......0056FF665566FFFFFFFFFFFF650.056F66F650....
.....056FF6551111556666FFFFFF6650056F6556650....
....056F6511CCDDCC115556666FF655056F51CC1550....
...056F511CD7777DDCC1155566FF65556F51CDDC150....
..056651CD788887DCCC1115566FF6556F51CCDDCC10....
.056651CC8877888DC11155566FFF656651CCCCCCC10....
056F511C8877888811555666FFFFF66F65111155110.....
05F65111888888115566FFFFFFFFF66FF6655555510.....
056655111111115566FFFF6666FFF656FFFF6666510.....
0156665555555666FFF66511115665156666555510......
0115666666666FFFF65511CCDD155111555511110.......
.00115566666FFFF6511CCDDDDCC111111110000........
..07701155566666511CCDDDDDDCC1111110............
..07600011155555111CCCCCCCCCC1115510............
...00.070001111111111111111111556510............
......0600700111111111111111556FF650............
.......0.060070000111111111566FFF650............
..........0.060.077011111556FF666510............
.............0..06600111556FF655510.............
.................00.011556FF651110..............
........00000.......01556FF65110................
......005666500.....0156FF65110.................
.....056FFFFF6500...0156F65110..................
....056FF666FF65500.015665110...................
...056F6511156FF655001565110....................
..0576511CC1156FFF655565110.....................
..077651CDDC1566FFFFF65110......................
...005511CC115566FFFF6510.......................
.....00111115566FFFF6510........................
.......00011566FFFF6510.........................
..........011556665510..........................
...........0011555110...........................
.............0011100............................
...............000..............................
---
.......................................0000.....
.....................................00AA7A0....
...................................00AA99AA0....
..................................0AA9900A0.....
..........................0000...0A990..00......
........................00AA7A0.0A90............
......................00AA99AA00AA0.............
.....................0AA9955AA0A90...0000.......
....................0A9905665AA90..00A77A0......
...................0A90.06FF65A0..0AA999A0......
..................0AA0.056CC650..0A99055A0......
.............000000A0..05CCCC50.0A90.05650......
..........00056FF65000056FCCF650AA0.056F650.....
........0056FFFFFF6555666FFFF65090.056FF650.....
......0056FF665566FFFFFFFFFFFF650.056F66F650....
.....056FF6551111556666FFFFFF6650056F6556650....
....056F6511CCDDCC115556666FF655056F51CC1550....
...056F511CD7777DDCC1155566FF65556F51CDDC150....
..056651CD788887DCCC1115566FF6556F51CCDDCC10....
.056651CC8877888DC11155566FFF656651CCCCCCC10....
056F511C8877888811555666FFFFF66F65111155110.....
05F65111888888115566FFFFFFFFF66FF6655555510.....
056655111111115566FFFF6666FFF656FFFF6666510.....
0156665555555666FFF66511115665156666555510......
0115666666666FFFF65511CCDD155111555511110.......
.00115566666FFFF6511CCDDDDCC111111110000........
..0770115556666651128EEEE82CC1111110............
..076000111555551128E7777E82C1115510............
...00.0700011111128E777777E821156510............
......0600700111128EE7777EE82156FF650...........
.......0.060070000288EEEE882116FFF650...........
..........0.060.070228888221156F666510..........
.............0..060.02222111556FF655510.........
.................0..011111556FF651110...........
........00000.......01556FF65110................
......005666500.....0156FF65110.................
.....056FFFFF6500...0156F65110..................
....056FF666FF65500.015665110...................
...056F6511156FF655001565110....................
..0576511CC1156FFF655565110.....................
..077651CDDC1566FFFFF65110......................
...005511CC115566FFFF6510.......................
.....00111115566FFFF6510........................
.......00011566FFFF6510.........................
..........011556665510..........................
...........0011555110...........................
.............0011100............................
...............000..............................

@SPRITE :dragon_seg 16x16 pal:5
.....000000.....
...0056FF6500...
..056FFFFFF650..
.056FF6666FF650.
.05F651CC156F50.
056F51CDDC15F650
056651CDDC156650
015651CCCC156510
0156551CC1556510
0156655115566510
.01566655666510.
.00155666655100.
..001155551100..
....00111100....
......0000......
................

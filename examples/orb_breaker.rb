# ==============================================================================
# ORB BREAKER - Slingshot Physics Bounce x Roguelite
# ------------------------------------------------------------------------------
# 256x256 / 1ファイル完結 / 基本API + BG + スプライト専用 (タイルマップ・サウンド不使用)
# 実行: uk run examples/orb_breaker.rb
#
# 【操作方法】
#   マウス移動 / ドラッグ : 発射角度を狙う
#   左クリック (離す)     : オーブ発射 / メニュー決定
#   ← / → (A / D)        : 角度調整 / カード選択
#   Z            : オーブ発射 / メニュー決定
#   X / 右クリック : 早送り (長押し3倍速) / 弾の強制回収
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "ORB BREAKER"
)

# ------------------------------------------------------------------------------
# 定数
# ------------------------------------------------------------------------------
SCREEN_W = 256
SCREEN_H = 256

ARENA_LEFT   = 12.0
ARENA_RIGHT  = 244.0
ARENA_TOP    = 24.0
DANGER_Y     = 196.0
LAUNCH_Y     = 214.0
BOTTOM_BAR_Y = 228

COLS       = 7
CELL_W     = 32.0
CELL_H     = 26.0
GRID_X0    = 16.0
GRID_Y0    = 34.0

SUBSTEPS      = 3
ORB_RADIUS    = 3.5
ORB_BASE_SPD  = 3.85
AIM_MIN_ANG   = -2.92  # 約 -167度 (左向き限界)
AIM_MAX_ANG   = -0.22  # 約 -13度  (右向き限界)

PAL_WHITE = 10

$best_score ||= 0
$best_wave  ||= 0

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

def draw_shadow_text(text, x, y, col)
  print_text(text, x + 1, y + 1, 0)
  print_text(text, x, y, col)
end

def center_text_x(text)
  128 - (text.length * 6) / 2
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

def rand_choice(arr)
  return nil if arr.empty?
  arr[rand(arr.size)]
end

def shuffle_copy(arr)
  res = arr.dup
  i = res.size - 1
  while i > 0
    j = rand(i + 1)
    tmp = res[i]
    res[i] = res[j]
    res[j] = tmp
    i -= 1
  end
  res
end

# ------------------------------------------------------------------------------
# アップグレード定義データ
# ------------------------------------------------------------------------------
UPGRADE_POOL = [
  {
    id: :add_orbs,
    kind: :passive,
    name: "+2 ORBS",
    tag: "ARSENAL",
    desc1: "ADD 2 ORBS",
    desc2: "TO VOLLEY",
    col: 12,
    spr: :orb_normal
  },
  {
    id: :pierce_orb,
    kind: :orb,
    orb_type: :pierce,
    name: "PIERCE ORB",
    tag: "ORB",
    desc1: "PIERCES",
    desc2: "ALL FOES",
    col: 11,
    spr: :orb_pierce
  },
  {
    id: :split_orb,
    kind: :orb,
    orb_type: :split,
    name: "SPLIT ORB",
    tag: "ORB",
    desc1: "SPLITS x2",
    desc2: "ON 1ST HIT",
    col: 14,
    spr: :orb_split
  },
  {
    id: :bomb_orb,
    kind: :orb,
    orb_type: :bomb,
    name: "BOMB ORB",
    tag: "ORB",
    desc1: "AOE BLAST",
    desc2: "EVERY 2 HIT",
    col: 9,
    spr: :orb_bomb
  },
  {
    id: :thunder_orb,
    kind: :orb,
    orb_type: :thunder,
    name: "THUNDER ORB",
    tag: "ORB",
    desc1: "CHAINS TO",
    desc2: "2 ENEMIES",
    col: 10,
    spr: :orb_thunder
  },
  {
    id: :spark_orb,
    kind: :orb,
    orb_type: :spark,
    name: "SPARK ORB",
    tag: "ORB",
    desc1: "BUMPER AOE",
    desc2: "+SPEED HIT",
    col: 8,
    spr: :orb_spark
  },
  {
    id: :power_core,
    kind: :passive,
    name: "POWER CORE",
    tag: "PASSIVE",
    desc1: "BASE DMG",
    desc2: "+1 ALL ORB",
    col: 8,
    spr: :orb_spark
  },
  {
    id: :crit_lens,
    kind: :passive,
    name: "CRIT LENS",
    tag: "PASSIVE",
    desc1: "+15% CRIT",
    desc2: "2X DAMAGE",
    col: 10,
    spr: :orb_thunder
  },
  {
    id: :combo_amp,
    kind: :passive,
    name: "COMBO AMP",
    tag: "PASSIVE",
    desc1: "COMBO DMG",
    desc2: "SCALING UP",
    col: 14,
    spr: :orb_split
  },
  {
    id: :bumper_forge,
    kind: :passive,
    name: "BUMPER +",
    tag: "PASSIVE",
    desc1: "+1 BUMPER",
    desc2: "+1 BMP DMG",
    col: 11,
    spr: :bumper
  },
  {
    id: :repair_kit,
    kind: :passive,
    name: "REPAIR KIT",
    tag: "HEAL",
    desc1: "HEAL +1 HP",
    desc2: "OR +1 MAX",
    col: 11,
    spr: :orb_pierce
  }
]

# ------------------------------------------------------------------------------
# ラン状態 (RunState) - ビルド・スコア・ステージ進行管理
# ------------------------------------------------------------------------------
class RunState
  attr_accessor :wave, :score, :hp, :max_hp, :max_combo, :total_hits
  attr_accessor :orb_list, :base_dmg, :crit_chance, :combo_tier, :bumper_bonus
  attr_accessor :kills

  def initialize
    @wave = 1
    @score = 0
    @hp = 5
    @max_hp = 5
    @max_combo = 0
    @total_hits = 0
    @kills = 0
    @base_dmg = 1
    @crit_chance = 8
    @combo_tier = 0
    @bumper_bonus = 0
    @orb_list = [:normal, :normal, :normal, :normal, :normal]
  end

  def stage_bg
    return :cave if @wave <= 3
    return :forest if @wave <= 6
    return :space if @wave <= 9
    :cyber
  end

  def stage_name
    return "CAVE" if @wave <= 3
    return "FOREST" if @wave <= 6
    return "SPACE" if @wave <= 9
    "CYBER"
  end

  def boss_wave?
    @wave % 4 == 0
  end

  def apply_upgrade(upg)
    uid = upg[:id]
    if uid == :add_orbs
      @orb_list << :normal
      @orb_list << :normal
    elsif upg[:kind] == :orb
      @orb_list << upg[:orb_type]
    elsif uid == :power_core
      @base_dmg += 1
    elsif uid == :crit_lens
      @crit_chance += 15
      @crit_chance = 75 if @crit_chance > 75
    elsif uid == :combo_amp
      @combo_tier += 1
    elsif uid == :bumper_forge
      @bumper_bonus += 1
    elsif uid == :repair_kit
      if @hp < @max_hp
        @hp += 1
      else
        @max_hp += 1
        @hp += 1
      end
    end
  end

  def orb_counts
    counts = {
      normal: 0,
      pierce: 0,
      split: 0,
      bomb: 0,
      thunder: 0,
      spark: 0
    }
    @orb_list.each do |t|
      if counts.has_key?(t)
        counts[t] += 1
      end
    end
    counts
  end
end

# ------------------------------------------------------------------------------
# エフェクトシステム (パーティクル / 爆発リング / 稲妻 / ポップアップ / シェイク)
# ------------------------------------------------------------------------------
class EffectSystem
  attr_reader :hitstop, :shake_dx, :shake_dy

  def initialize
    @hitstop = 0
    @shake_mag = 0.0
    @shake_dx = 0
    @shake_dy = 0
    @flash_timer = 0
    @flash_col = 7
    @particles = []
    @rings = []
    @bolts = []
    @popups = []
  end

  def add_hitstop(frames)
    @hitstop = frames if frames > @hitstop
  end

  def add_shake(mag)
    @shake_mag = mag if mag > @shake_mag
  end

  def add_flash(col, frames)
    @flash_col = col
    @flash_timer = frames
  end

  def spawn_sparks(x, y, col, count = 6, spd = 2.2)
    i = 0
    while i < count
      ang = rand() * 6.28318
      v = (0.4 + rand() * 0.8) * spd
      @particles << {
        x: x.to_f,
        y: y.to_f,
        vx: cos(ang) * v,
        vy: sin(ang) * v,
        grav: 0.05,
        col: (i % 3 == 0 ? 7 : col),
        size: (rand(3) == 0 ? 2 : 1),
        life: 12 + rand(8)
      }
      i += 1
    end
  end

  def spawn_ring(x, y, max_r, col, life = 14)
    @rings << {
      x: x.to_f,
      y: y.to_f,
      r: 2.0,
      max_r: max_r.to_f,
      col: col,
      life: life,
      max_life: life
    }
  end

  def spawn_lightning(x0, y0, x1, y1, col = 10)
    pts = []
    pts << [x0.to_f, y0.to_f]
    steps = 4
    i = 1
    while i < steps
      t = i.to_f / steps
      px = lerp_f(x0.to_f, x1.to_f, t) + (rand() - 0.5) * 12.0
      py = lerp_f(y0.to_f, y1.to_f, t) + (rand() - 0.5) * 12.0
      pts << [px, py]
      i += 1
    end
    pts << [x1.to_f, y1.to_f]
    @bolts << { pts: pts, col: col, life: 10 }
  end

  def spawn_popup(x, y, text, col = 7, big = false)
    @popups << {
      x: x.to_f,
      y: y.to_f,
      vy: -0.75,
      text: text,
      col: col,
      life: (big ? 28 : 20)
    }
  end

  def step_hitstop
    if @hitstop > 0
      @hitstop -= 1
      return true
    end
    false
  end

  def update
    if @shake_mag > 0.15
      @shake_dx = ((rand() * 2.0 - 1.0) * @shake_mag).round
      @shake_dy = ((rand() * 2.0 - 1.0) * @shake_mag).round
      @shake_mag *= 0.78
    else
      @shake_mag = 0.0
      @shake_dx = 0
      @shake_dy = 0
    end

    @flash_timer -= 1 if @flash_timer > 0

    @particles.each do |pt|
      pt[:x] += pt[:vx]
      pt[:y] += pt[:vy]
      pt[:vy] += pt[:grav]
      pt[:vx] *= 0.94
      pt[:life] -= 1
    end
    @particles.reject! { |pt| pt[:life] <= 0 }

    @rings.each do |rg|
      rg[:life] -= 1
      t = 1.0 - (rg[:life].to_f / rg[:max_life])
      rg[:r] = lerp_f(2.0, rg[:max_r], t)
    end
    @rings.reject! { |rg| rg[:life] <= 0 }

    @bolts.each { |b| b[:life] -= 1 }
    @bolts.reject! { |b| b[:life] <= 0 }

    @popups.each do |pp|
      pp[:y] += pp[:vy]
      pp[:vy] *= 0.93
      pp[:life] -= 1
    end
    @popups.reject! { |pp| pp[:life] <= 0 }
  end

  def draw
    @rings.each do |rg|
      circ(rg[:x].round, rg[:y].round, rg[:r].round, rg[:col])
    end

    @bolts.each do |b|
      pts = b[:pts]
      i = 0
      while i < pts.size - 1
        col = (b[:life] % 2 == 0 ? 7 : b[:col])
        line(pts[i][0].round, pts[i][1].round, pts[i + 1][0].round, pts[i + 1][1].round, col)
        i += 1
      end
    end

    @particles.each do |pt|
      if pt[:size] > 1
        rectfill(pt[:x].round, pt[:y].round, 2, 2, pt[:col])
      else
        pset(pt[:x].round, pt[:y].round, pt[:col])
      end
    end

    @popups.each do |pp|
      draw_shadow_text(pp[:text], pp[:x].round - (pp[:text].length * 3), pp[:y].round, pp[:col])
    end

    if @flash_timer > 0
      rect(0, 0, SCREEN_W, SCREEN_H, @flash_col)
      rect(1, 1, SCREEN_W - 2, SCREEN_H - 2, @flash_col)
    end
  end
end

# ------------------------------------------------------------------------------
# ターゲット (敵・ブロック・バンパー・ボス)
# ------------------------------------------------------------------------------
class Target
  attr_accessor :kind, :shape, :x, :y, :w, :h
  attr_accessor :r, :hw, :hh, :hp, :max_hp, :spr_name
  attr_accessor :flash_t, :sx, :sy, :col, :row, :hit_cd
  attr_accessor :is_boss, :score_val

  def initialize(opts)
    @kind = opts[:kind]
    @shape = opts[:shape] # :circle or :rect
    @x = opts[:x].to_f
    @y = opts[:y].to_f
    @w = (opts[:w] || 24).to_f
    @h = (opts[:h] || 20).to_f
    @hw = @w * 0.5
    @hh = @h * 0.5
    @r = (opts[:r] || 10.0).to_f
    @hp = opts[:hp] || 5
    @max_hp = @hp
    @spr_name = opts[:spr]
    @is_boss = opts[:boss] || false
    @score_val = opts[:score] || (@hp * 10)
    @flash_t = 0
    @sx = 1.0
    @sy = 1.0
    @col = opts[:col] || 7
    @row = opts[:row] || 0
    @hit_cd = 0
  end

  def alive?
    @kind == :bumper || @hp > 0
  end

  def on_hit(dmg)
    @flash_t = 4
    @sx = 1.24
    @sy = 0.78
    if @kind != :bumper
      @hp -= dmg
      @hp = 0 if @hp < 0
    end
  end

  def update_anim
    @flash_t -= 1 if @flash_t > 0
    @hit_cd -= 1 if @hit_cd > 0
    @sx = lerp_f(@sx, 1.0, 0.25)
    @sy = lerp_f(@sy, 1.0, 0.25)
  end

  def draw(frame)
    pal_id = (@flash_t > 0 ? PAL_WHITE : nil)
    if @kind == :bumper
      bob = sin(frame * 0.12 + @x * 0.1) * 0.06
      draw_spr_centered(@spr_name, @x, @y, 16, 16, 0.0, @sx + bob, @sy + bob, false, false, pal_id)
      circ(@x.round, @y.round, (@r + 2).round, (@flash_t > 0 ? 7 : 11))
      return
    end

    if @kind == :block || @kind == :crate
      bx = (@x - @w * 0.5).round
      by = (@y - @h * 0.5).round
      bw = @w.round
      bh = @h.round
      fill_col = (@flash_t > 0 ? 7 : @col)
      border_col = (@flash_t > 0 ? 7 : 6)
      rectfill(bx, by, bw, bh, 0)
      rectfill(bx + 1, by + 1, bw - 2, bh - 2, fill_col)
      rect(bx, by, bw, bh, border_col)
      if @kind == :crate
        draw_spr_centered(:crate, @x, @y, 16, 16, 0.0, @sx, @sy, false, false, pal_id)
      else
        line(bx + 2, by + 2, bx + bw - 3, by + 2, 7)
      end
      hp_str = @hp.to_s
      draw_shadow_text(hp_str, @x.round - hp_str.length * 3, @y.round - 4, 7)
      return
    end

    # 円形の敵・ボス
    spr_size = @is_boss ? 32 : 16
    bob_y = sin(frame * 0.1 + @x * 0.07) * 1.2
    draw_spr_centered(@spr_name, @x, @y + bob_y, spr_size, spr_size, 0.0, @sx, @sy, false, false, pal_id)

    # HP表示
    hp_str = @hp.to_s
    ty = @is_boss ? (@y + 18).round : (@y + 9).round
    draw_shadow_text(hp_str, @x.round - hp_str.length * 3, ty, (@hp <= 3 ? 10 : 7))
  end
end

# ------------------------------------------------------------------------------
# オーブ (弾丸)
# ------------------------------------------------------------------------------
class Orb
  attr_accessor :x, :y, :vx, :vy, :r, :type
  attr_accessor :active, :returning, :bounces, :split_done
  attr_accessor :boost_t, :pierce_hit_ids, :trail

  def initialize(x, y, vx, vy, orb_type, r = ORB_RADIUS)
    @x = x.to_f
    @y = y.to_f
    @vx = vx.to_f
    @vy = vy.to_f
    @r = r.to_f
    @type = orb_type
    @active = true
    @returning = false
    @bounces = 0
    @split_done = false
    @boost_t = 0
    @pierce_hit_ids = {}
    @trail = []
  end

  def spr_sym
    return :orb_pierce if @type == :pierce
    return :orb_split if @type == :split
    return :orb_bomb if @type == :bomb
    return :orb_thunder if @type == :thunder
    return :orb_spark if @type == :spark
    :orb_normal
  end

  def col_id
    return 11 if @type == :pierce
    return 14 if @type == :split
    return 9 if @type == :bomb
    return 10 if @type == :thunder
    return 8 if @type == :spark
    12
  end

  def draw
    # トレイル描画
    c = col_id
    i = 0
    while i < @trail.size
      pt = @trail[i]
      if i % 2 == 0
        pset(pt[0].round, pt[1].round, c)
      end
      i += 1
    end
    draw_spr_centered(spr_sym, @x, @y, 8, 8, 0.0, 1.0, 1.0, false)
  end
end

# ------------------------------------------------------------------------------
# 物理エンジン (固定サブステップ + 位置補正 + ゼロアロケーション判定 + 予測線)
# ------------------------------------------------------------------------------
class PhysicsWorld
  # オーブの壁衝突を直接更新 (アロケーションなし)
  def self.step_orb_walls(orb)
    r = orb.r
    hit_wall = false
    if orb.x - r < ARENA_LEFT
      orb.x = ARENA_LEFT + r
      orb.vx = orb.vx.abs
      hit_wall = true
    elsif orb.x + r > ARENA_RIGHT
      orb.x = ARENA_RIGHT - r
      orb.vx = -orb.vx.abs
      hit_wall = true
    end

    if orb.y - r < ARENA_TOP
      orb.y = ARENA_TOP + r
      orb.vy = orb.vy.abs
      hit_wall = true
    end

    if hit_wall
      prevent_horizontal_stuck_orb(orb)
    end
    hit_wall
  end

  def self.prevent_horizontal_stuck_orb(orb)
    vx = orb.vx
    vy = orb.vy
    spd_sq = vx * vx + vy * vy
    return if spd_sq < 0.0001
    if vy.abs < 0.25
      spd = sqrt(spd_sq)
      sign_y = (vy >= 0.0 ? 1.0 : -1.0)
      vy = sign_y * 0.32
      len = hypot(vx, vy)
      orb.vx = (vx / len) * spd
      orb.vy = (vy / len) * spd
    end
  end

  def self.reflect_orb(orb, nx, ny)
    dot = orb.vx * nx + orb.vy * ny
    return if dot >= 0.0
    orb.vx = orb.vx - 2.0 * dot * nx
    orb.vy = orb.vy - 2.0 * dot * ny
    prevent_horizontal_stuck_orb(orb)
  end

  # 円 vs 円 衝突判定 (非衝突時は nil を返しアロケーションゼロ)
  # 衝突時のみ [nx, ny, overlap] を返す
  def self.collide_circle_circle(cx1, cy1, r1, cx2, cy2, r2)
    r_sum = r1 + r2
    dx = cx1 - cx2
    return nil if dx >= r_sum || dx <= -r_sum
    dy = cy1 - cy2
    return nil if dy >= r_sum || dy <= -r_sum

    dist_sq = dx * dx + dy * dy
    return nil if dist_sq >= r_sum * r_sum

    if dist_sq < 0.0001
      return [0.0, -1.0, r_sum]
    end
    dist = sqrt(dist_sq)
    [dx / dist, dy / dist, r_sum - dist]
  end

  # 円 vs AABB矩形 衝突判定 (非衝突時は nil を返しアロケーションゼロ)
  # 衝突時のみ [nx, ny, overlap] を返す
  def self.collide_circle_rect(cx, cy, r, rx, ry, hw, hh)
    left = rx - hw
    return nil if cx + r <= left
    right = rx + hw
    return nil if cx - r >= right
    top = ry - hh
    return nil if cy + r <= top
    bottom = ry + hh
    return nil if cy - r >= bottom

    closest_x = clamp_f(cx, left, right)
    closest_y = clamp_f(cy, top, bottom)

    dx = cx - closest_x
    dy = cy - closest_y
    dist_sq = dx * dx + dy * dy
    return nil if dist_sq >= r * r

    if dist_sq < 0.0001
      d_left = (cx - left).abs
      d_right = (right - cx).abs
      d_top = (cy - top).abs
      d_bottom = (bottom - cy).abs
      m = d_left
      nx = -1.0
      ny = 0.0
      if d_right < m
        m = d_right
        nx = 1.0
        ny = 0.0
      end
      if d_top < m
        m = d_top
        nx = 0.0
        ny = -1.0
      end
      if d_bottom < m
        m = d_bottom
        nx = 0.0
        ny = 1.0
      end
      return [nx, ny, r + m]
    end

    dist = sqrt(dist_sq)
    [dx / dist, dy / dist, r - dist]
  end

  # 予測ガイド線シミュレーション (最初の1回反射 + 数ステップ先まで)
  def self.predict_trajectory(start_x, start_y, ang, targets)
    sim = Orb.new(start_x, start_y, cos(ang) * ORB_BASE_SPD, sin(ang) * ORB_BASE_SPD, :normal, ORB_RADIUS)
    sub_dt = 1.0 / SUBSTEPS

    pts = [[sim.x, sim.y]]
    bounces = 0
    post_bounce_steps = 0
    first_hit = nil

    step = 0
    while step < 48
      sub = 0
      while sub < SUBSTEPS
        sim.x += sim.vx * sub_dt
        sim.y += sim.vy * sub_dt

        if step_orb_walls(sim)
          first_hit = [sim.x, sim.y] if first_hit.nil?
          bounces += 1
        end

        sx = sim.x
        sy = sim.y
        i = 0
        t_len = targets.size
        while i < t_len
          tgt = targets[i]
          i += 1
          next unless tgt.alive?
          tx = tgt.x
          ty = tgt.y
          if tgt.shape == :circle
            rs = ORB_RADIUS + tgt.r
            dx = sx - tx
            next if dx >= rs || dx <= -rs
            dy = sy - ty
            next if dy >= rs || dy <= -rs
            hit = collide_circle_circle(sx, sy, ORB_RADIUS, tx, ty, tgt.r)
          else
            dx = sx - tx
            px = tgt.hw + ORB_RADIUS
            next if dx >= px || dx <= -px
            dy = sy - ty
            py = tgt.hh + ORB_RADIUS
            next if dy >= py || dy <= -py
            hit = collide_circle_rect(sx, sy, ORB_RADIUS, tx, ty, tgt.hw, tgt.hh)
          end
          if !hit.nil?
            sim.x += hit[0] * hit[2]
            sim.y += hit[1] * hit[2]
            reflect_orb(sim, hit[0], hit[1])
            first_hit = [sim.x, sim.y] if first_hit.nil?
            bounces += 1
            break
          end
        end

        break if bounces >= 2
        sub += 1
      end

      pts << [sim.x, sim.y] if step % 2 == 0
      if bounces >= 1
        post_bounce_steps += 1
        break if post_bounce_steps >= 10 || bounces >= 2
      end
      break if sim.y > LAUNCH_Y
      step += 1
    end

    [pts, first_hit]
  end
end

# ------------------------------------------------------------------------------
# タイトルシーン
# ------------------------------------------------------------------------------
class TitleScene
  def initialize
    @frame = 0
    @demo_orbs = []
    i = 0
    while i < 6
      ang = -0.4 - i * 0.42
      @demo_orbs << {
        x: 40.0 + i * 32.0,
        y: 80.0 + (i % 3) * 30.0,
        vx: cos(ang) * 1.6,
        vy: sin(ang) * 1.6,
        spr: (i % 2 == 0 ? :orb_normal : :orb_thunder)
      }
      i += 1
    end
  end

  def update
    @frame += 1
    @demo_orbs.each do |o|
      o[:x] += o[:vx]
      o[:y] += o[:vy]
      o[:vx] = o[:vx].abs if o[:x] < 16
      o[:vx] = -o[:vx].abs if o[:x] > 240
      o[:vy] = o[:vy].abs if o[:y] < 24
      o[:vy] = -o[:vy].abs if o[:y] > 200
    end

    if btnp(1) || btnp(:mouse_l)
      run BattleScene.new(RunState.new)
    end
  end

  def draw
    cls(0)
    bg(:space, dim: 0.45, scroll_x: @frame * 0.25, scroll_y: -@frame * 0.15, loop_x: true, loop_y: true)

    @demo_orbs.each do |o|
      draw_spr_centered(o[:spr], o[:x], o[:y], 8, 8, 0.0, 1.0, 1.0, false)
    end

    # タイトルパネル
    rectfill(24, 42, 208, 66, 1)
    rect(24, 42, 208, 66, 12)
    rect(26, 44, 204, 62, 1)

    draw_spr_centered(:boss_1, 52, 75, 32, 32, 0.0, 1.0, 1.0, false)
    draw_spr_centered(:launcher, 204, 78, 16, 16, 0.0, 1.2, 1.2, false)

    t1 = "ORB BREAKER"
    draw_shadow_text(t1, center_text_x(t1), 58, 10)
    t2 = "SLINGSHOT ROGUELITE"
    draw_shadow_text(t2, center_text_x(t2), 74, 7)
    t3 = "BOUNCE x BUILD x BREAK"
    draw_shadow_text(t3, center_text_x(t3), 88, 12)

    if $best_score > 0
      bs = sprintf("BEST: %d  (WAVE %d)", $best_score, $best_wave)
      draw_shadow_text(bs, center_text_x(bs), 122, 10)
    end

    # 操作ガイド
    rectfill(24, 140, 208, 62, 0)
    rect(24, 140, 208, 62, 5)
    draw_shadow_text("CONTROLS:", 34, 148, 11)
    draw_shadow_text("MOUSE / ARROWS : AIM", 34, 160, 7)
    draw_shadow_text("CLICK / Z/SPC  : FIRE ORBS", 34, 172, 7)
    draw_shadow_text("R-CLICK / X    : 3X / RECALL", 34, 184, 7)

    if (@frame / 20) % 2 == 0
      ps = "CLICK OR PRESS Z TO START"
      draw_shadow_text(ps, center_text_x(ps), 218, 10)
    end
  end
end

# ------------------------------------------------------------------------------
# 3択ローグライト強化シーン
# ------------------------------------------------------------------------------
class UpgradeScene
  def initialize(run_state)
    @run = run_state
    @frame = 0
    @selected = 1
    @choices = pick_three_upgrades
  end

  def pick_three_upgrades
    shuffled = shuffle_copy(UPGRADE_POOL)
    res = []
    i = 0
    while i < 3 && i < shuffled.size
      res << shuffled[i]
      i += 1
    end
    res
  end

  def card_rect(idx)
    w = 76
    h = 132
    x = 8 + idx * 82
    y = 64
    [x, y, w, h]
  end

  def update
    @frame += 1

    if btnp(:left)
      @selected = (@selected + 2) % 3
    elsif btnp(:right)
      @selected = (@selected + 1) % 3
    end

    mx = mouse_x
    my = mouse_y
    hovered = nil
    i = 0
    while i < 3
      cx, cy, cw, ch = card_rect(i)
      if mx >= cx && mx <= cx + cw && my >= cy && my <= cy + ch
        hovered = i
        @selected = i
      end
      i += 1
    end

    confirmed = btnp(1) || btnp(2) || (btnp(:mouse_l) && !hovered.nil?)
    if confirmed && @frame > 10
      chosen = @choices[@selected]
      @run.apply_upgrade(chosen)
      @run.wave += 1
      run BattleScene.new(@run)
    end
  end

  def draw
    cls(0)
    bg(@run.stage_bg, dim: 0.65, scroll_x: @frame * 0.2, mirror_x: true)

    title = sprintf("WAVE %d CLEARED!", @run.wave)
    draw_shadow_text(title, center_text_x(title), 18, 11)
    sub = "CHOOSE 1 UPGRADE"
    draw_shadow_text(sub, center_text_x(sub), 34, 7)

    hp_txt = sprintf("HP:%d/%d  ORBS:%d", @run.hp, @run.max_hp, @run.orb_list.size)
    draw_shadow_text(hp_txt, center_text_x(hp_txt), 48, 12)

    i = 0
    while i < 3
      upg = @choices[i]
      cx, cy, cw, ch = card_rect(i)
      sel = (i == @selected)
      bg_col = sel ? 1 : 0
      border_col = sel ? 10 : 5

      rectfill(cx, cy, cw, ch, bg_col)
      rect(cx, cy, cw, ch, border_col)
      if sel
        rect(cx - 1, cy - 1, cw + 2, ch + 2, 7)
      end

      # タグ
      draw_shadow_text(upg[:tag], cx + 4, cy + 8, upg[:col])

      # アイコン
      spr_size = (upg[:spr] == :bumper ? 16 : 8)
      draw_spr_centered(upg[:spr], cx + cw * 0.5, cy + 44, spr_size, spr_size, 0.0, 2.0, 2.0, false)

      # 名前
      draw_shadow_text(upg[:name], cx + 4, cy + 68, 7)

      # 説明 (2行)
      draw_shadow_text(upg[:desc1], cx + 4, cy + 88, 6)
      draw_shadow_text(upg[:desc2], cx + 4, cy + 100, 6)

      if sel
        draw_shadow_text("SELECT", cx + 18, cy + 118, 10)
      end
      i += 1
    end

    hint = "CLICK CARD OR ARROWS + Z"
    draw_shadow_text(hint, center_text_x(hint), 218, 6)
  end
end

# ------------------------------------------------------------------------------
# リザルトシーン
# ------------------------------------------------------------------------------
class ResultScene
  def initialize(run_state)
    @run = run_state
    @frame = 0
    $best_score = @run.score if @run.score > $best_score
    $best_wave = @run.wave if @run.wave > $best_wave
  end

  def update
    @frame += 1
    if @frame > 20 && (btnp(1) || btnp(:mouse_l))
      run BattleScene.new(RunState.new)
    elsif @frame > 20 && btnp(2)
      run TitleScene.new
    end
  end

  def draw
    cls(0)
    bg(:cave, dim: 0.72, tint: [220, 100, 120], scroll_x: @frame * 0.15, mirror_x: true)

    t = "GAME OVER"
    draw_shadow_text(t, center_text_x(t), 34, 8)

    rectfill(32, 56, 192, 120, 1)
    rect(32, 56, 192, 120, 6)

    s1 = sprintf("SCORE     : %d", @run.score)
    s2 = sprintf("WAVE      : %d (%s)", @run.wave, @run.stage_name)
    s3 = sprintf("MAX COMBO : %d", @run.max_combo)
    s4 = sprintf("TOTAL HITS: %d", @run.total_hits)
    s5 = sprintf("BEST SCORE: %d", $best_score)

    draw_shadow_text(s1, 46, 70, 10)
    draw_shadow_text(s2, 46, 88, 7)
    draw_shadow_text(s3, 46, 106, 12)
    draw_shadow_text(s4, 46, 124, 11)
    draw_shadow_text(s5, 46, 148, 14)

    if (@frame / 20) % 2 == 0
      r1 = "Z / CLICK : RETRY"
      draw_shadow_text(r1, center_text_x(r1), 198, 10)
    end
    r2 = "X : TITLE"
    draw_shadow_text(r2, center_text_x(r2), 214, 6)
  end
end

# ------------------------------------------------------------------------------
# バトルシーン (メインゲームループ)
# ------------------------------------------------------------------------------
class BattleScene
  def initialize(run_state)
    @run = run_state
    @fx = EffectSystem.new
    @frame = 0
    @state = :aim # :aim / :firing / :advance / :wave_clear
    @aim_ang = -1.5708
    @launch_x = 128.0
    @next_launch_x = nil
    @mouse_dragging = false
    @prev_mouse_x = mouse_x
    @prev_mouse_y = mouse_y

    @targets = []
    @orbs = []
    @fire_queue = []
    @fire_cd = 0
    @shot_timer = 0
    @combo = 0
    @turn_in_wave = 1
    @max_turns_in_wave = @run.boss_wave? ? 1 : 2
    @banner_text = @run.boss_wave? ? sprintf("BOSS WAVE %d!", @run.wave) : sprintf("WAVE %d - %s", @run.wave, @run.stage_name)
    @banner_timer = 75
    @hurt_flash = 0
    @preview_ang = nil
    @preview_pts = nil
    @preview_hit = nil

    setup_wave
  end

  def setup_wave
    @targets.clear
    if @run.boss_wave?
      spawn_boss
      spawn_bumpers(2 + @run.bumper_bonus)
    else
      spawn_row(0)
      spawn_row(1)
      spawn_bumpers(1 + @run.bumper_bonus)
    end
  end

  def spawn_boss
    boss_hp = 24 + @run.wave * 10
    boss_spr = (@run.wave % 8 == 0 ? :boss_2 : :boss_1)
    @targets << Target.new({
      kind: :enemy,
      shape: :circle,
      x: 128.0,
      y: GRID_Y0 + CELL_H,
      r: 20.0,
      hp: boss_hp,
      spr: boss_spr,
      boss: true,
      row: 1,
      score: boss_hp * 25
    })
    # ボスのお供ブロック
    [1, 5].each do |c|
      cx = GRID_X0 + 16.0 + c * CELL_W
      @targets << Target.new({
        kind: :block,
        shape: :rect,
        x: cx,
        y: GRID_Y0 + CELL_H * 2,
        w: 24.0,
        h: 18.0,
        hp: 4 + @run.wave,
        col: 2,
        row: 2
      })
    end
  end

  def spawn_bumpers(count)
    placed = 0
    attempts = 0
    while placed < count && attempts < 20
      attempts += 1
      bx = 44.0 + rand(5) * 42.0
      by = 128.0 + rand(2) * 34.0
      too_close = false
      @targets.each do |t|
        dx = t.x - bx
        dy = t.y - by
        if dx * dx + dy * dy < 30.0 * 30.0
          too_close = true
          break
        end
      end
      next if too_close
      @targets << Target.new({
        kind: :bumper,
        shape: :circle,
        x: bx,
        y: by,
        r: 9.0,
        hp: 999,
        spr: :bumper,
        row: -1
      })
      placed += 1
    end
  end

  def spawn_row(row_idx)
    base_hp = 2 + @run.wave * 2 + rand(3)
    c = 0
    while c < COLS
      roll = rand(100)
      cx = GRID_X0 + 16.0 + c * CELL_W
      cy = GRID_Y0 + row_idx * CELL_H

      if roll < 42
        # 敵スポーン
        pool = [:slime, :bat, :golem, :mage]
        etype = pool[rand([2 + (@run.wave / 3), 4].min)]
        hp_mul = (etype == :golem ? 1.5 : 1.0)
        @targets << Target.new({
          kind: :enemy,
          shape: :circle,
          x: cx,
          y: cy,
          r: 10.0,
          hp: (base_hp * hp_mul).round,
          spr: etype,
          row: row_idx
        })
      elsif roll < 64
        # ブロックまたはクレート
        is_crate = (rand(4) == 0)
        @targets << Target.new({
          kind: (is_crate ? :crate : :block),
          shape: :rect,
          x: cx,
          y: cy,
          w: 24.0,
          h: 18.0,
          hp: (is_crate ? [2, base_hp / 2].max : base_hp),
          col: (is_crate ? 4 : 1),
          row: row_idx
        })
      end
      c += 1
    end
  end

  def non_bumper_count
    cnt = 0
    @targets.each do |t|
      cnt += 1 if t.kind != :bumper && t.alive?
    end
    cnt
  end

  def update
    @frame += 1
    @banner_timer -= 1 if @banner_timer > 0
    @hurt_flash -= 1 if @hurt_flash > 0

    if @fx.step_hitstop
      @fx.update
      return
    end

    @targets.each { |t| t.update_anim }

    if @state == :aim
      update_aim
    elsif @state == :firing
      update_firing
    elsif @state == :advance
      update_advance
    elsif @state == :wave_clear
      update_wave_clear
    end

    @fx.update
  end

  def update_aim
    # キーボード操作
    if btn(:left)
      @aim_ang -= 0.035
    end
    if btn(:right)
      @aim_ang += 0.035
    end
    @aim_ang = clamp_f(@aim_ang, AIM_MIN_ANG, AIM_MAX_ANG)

    # マウス操作 (カーソル移動またはドラッグ)
    mx = mouse_x
    my = mouse_y
    mouse_moved = (mx != @prev_mouse_x || my != @prev_mouse_y)
    @prev_mouse_x = mx
    @prev_mouse_y = my

    if (mouse_moved || @mouse_dragging) && my < LAUNCH_Y - 4.0 && mx >= ARENA_LEFT && mx <= ARENA_RIGHT
      ang = atan2(my - LAUNCH_Y, mx - @launch_x)
      if ang < -0.05 && ang > -3.09
        @aim_ang = clamp_f(ang, AIM_MIN_ANG, AIM_MAX_ANG)
      end
    end

    if btnp(:mouse_l) && my < BOTTOM_BAR_Y
      @mouse_dragging = true
    end

    fire_now = btnp(1)
    if @mouse_dragging && !btn(:mouse_l)
      @mouse_dragging = false
      fire_now = true if my < BOTTOM_BAR_Y
    end

    if fire_now
      start_firing
    end
  end

  def start_firing
    @state = :firing
    @fire_queue = @run.orb_list.dup
    @fire_cd = 0
    @shot_timer = 0
    @combo = 0
    @next_launch_x = nil
  end

  def recall_rect
    [192, BOTTOM_BAR_Y + 4, 52, 18]
  end

  def update_firing
    @shot_timer += 1

    # 早送り倍率 (時間経過 or X / 右クリック)
    fast = btn(2) || btn(:mouse_r)
    speed_mult = 1
    if fast
      speed_mult = 3
    elsif @shot_timer > 600
      speed_mult = 3
    elsif @shot_timer > 360
      speed_mult = 2
    end

    # RECALL ボタンまたは 長時間経過後の右クリック/X で強制回収
    mx = mouse_x
    my = mouse_y
    rx, ry, rw, rh = recall_rect
    clicked_recall = btnp(:mouse_l) && mx >= rx && mx <= rx + rw && my >= ry && my <= ry + rh
    if clicked_recall || (@shot_timer > 180 && (btnp(2) || btnp(:mouse_r)))
      @fire_queue.clear
      @orbs.each { |o| o.returning = true }
    end

    tick = 0
    while tick < speed_mult
      step_firing_tick
      break if @fire_queue.empty? && @orbs.empty?
      tick += 1
    end

    if @fire_queue.empty? && @orbs.empty?
      @launch_x = @next_launch_x if !@next_launch_x.nil?
      @launch_x = clamp_f(@launch_x, ARENA_LEFT + 10.0, ARENA_RIGHT - 10.0)
      if non_bumper_count == 0
        @state = :wave_clear
        @banner_text = "WAVE CLEAR!"
        @banner_timer = 40
      else
        @state = :advance
      end
    end
  end

  def step_firing_tick
    if !@fire_queue.empty?
      if @fire_cd <= 0
        otype = @fire_queue.shift
        vx = cos(@aim_ang) * ORB_BASE_SPD
        vy = sin(@aim_ang) * ORB_BASE_SPD
        @orbs << Orb.new(@launch_x, LAUNCH_Y, vx, vy, otype)
        @fire_cd = 4
      else
        @fire_cd -= 1
      end
    end

    sub_dt = 1.0 / SUBSTEPS
    new_spawns = []

    @orbs.each do |orb|
      next unless orb.active

      if orb.returning
        dx = @launch_x - orb.x
        dy = LAUNCH_Y - orb.y
        dist_sq = dx * dx + dy * dy
        if dist_sq < 64.0
          orb.active = false
          next
        end
        dist = sqrt(dist_sq)
        orb.x += (dx / dist) * 7.5
        orb.y += (dy / dist) * 7.5
        next
      end

      orb.boost_t -= 1 if orb.boost_t > 0
      spd_scale = (orb.boost_t > 0 ? 1.28 : 1.0)

      t_len = @targets.size
      orb_r = orb.r
      step_x = orb.vx * sub_dt * spd_scale
      step_y = orb.vy * sub_dt * spd_scale

      sub = 0
      while sub < SUBSTEPS
        orb.x += step_x
        orb.y += step_y

        if PhysicsWorld.step_orb_walls(orb)
          @fx.spawn_sparks(orb.x, orb.y, orb.col_id, 3, 1.4)
          step_x = orb.vx * sub_dt * spd_scale
          step_y = orb.vy * sub_dt * spd_scale
        end

        ox = orb.x
        oy = orb.y
        ti = 0
        while ti < t_len
          tgt = @targets[ti]
          ti += 1
          next unless tgt.alive?
          tx = tgt.x
          ty = tgt.y
          if tgt.shape == :circle
            rs = orb_r + tgt.r
            dx = ox - tx
            next if dx >= rs || dx <= -rs
            dy = oy - ty
            next if dy >= rs || dy <= -rs
            hit = PhysicsWorld.collide_circle_circle(ox, oy, orb_r, tx, ty, tgt.r)
          else
            dx = ox - tx
            px = tgt.hw + orb_r
            next if dx >= px || dx <= -px
            dy = oy - ty
            py = tgt.hh + orb_r
            next if dy >= py || dy <= -py
            hit = PhysicsWorld.collide_circle_rect(ox, oy, orb_r, tx, ty, tgt.hw, tgt.hh)
          end

          next if hit.nil?

          is_pierce = (orb.type == :pierce && tgt.kind != :bumper)
          if is_pierce
            tid = tgt.object_id
            next if orb.pierce_hit_ids.has_key?(tid)
            orb.pierce_hit_ids[tid] = true
          else
            orb.x += hit[0] * hit[2]
            orb.y += hit[1] * hit[2]
            PhysicsWorld.reflect_orb(orb, hit[0], hit[1])
            ox = orb.x
            oy = orb.y
            step_x = orb.vx * sub_dt * spd_scale
            step_y = orb.vy * sub_dt * spd_scale
          end

          handle_orb_hit(orb, tgt, new_spawns)
          break unless is_pierce
        end

        if orb.y >= LAUNCH_Y && orb.vy > 0.0
          @next_launch_x = orb.x if @next_launch_x.nil?
          orb.active = false
          break
        end
        sub += 1
      end

      if orb.active
        orb.trail << [orb.x, orb.y]
        orb.trail.shift if orb.trail.size > 6
      end
    end

    new_spawns.each { |no| @orbs << no }
    @orbs.reject! { |o| !o.active }
    @targets.reject! { |t| !t.alive? }
  end

  def handle_orb_hit(orb, tgt, new_spawns)
    if tgt.kind == :bumper
      return if tgt.hit_cd > 0
      tgt.hit_cd = 4
      tgt.on_hit(0)
      orb.boost_t = 35
      @combo += 1
      @run.max_combo = @combo if @combo > @run.max_combo
      @run.score += 15 + @combo * 2
      @fx.spawn_ring(tgt.x, tgt.y, 18, 11, 10)
      @fx.spawn_sparks(tgt.x, tgt.y, 11, 6, 2.2)

      if orb.type == :spark
        dmg = @run.base_dmg + 1 + @run.bumper_bonus
        aoe_damage(tgt.x, tgt.y, 52.0, dmg, 8)
        @fx.spawn_ring(tgt.x, tgt.y, 52, 8, 14)
        @fx.add_shake(2.5)
      end
      return
    end

    @combo += 1
    @run.max_combo = @combo if @combo > @run.max_combo
    @run.total_hits += 1
    orb.bounces += 1

    # ダメージ計算 (基本 + コンボボーナス + クリティカル)
    combo_bonus = (@combo / (10 - [@run.combo_tier * 2, 6].min))
    dmg = @run.base_dmg + combo_bonus
    is_crit = (rand(100) < @run.crit_chance)
    dmg *= 2 if is_crit

    apply_damage_to_target(tgt, dmg, is_crit, orb.col_id)

    # 特殊オーブ効果
    if orb.type == :split && !orb.split_done
      orb.split_done = true
      ang = atan2(orb.vy, orb.vx)
      [-0.35, 0.35].each do |da|
        a2 = ang + da
        no = Orb.new(orb.x, orb.y, cos(a2) * ORB_BASE_SPD, sin(a2) * ORB_BASE_SPD, :normal, 3.0)
        no.split_done = true
        new_spawns << no
      end
      @fx.spawn_sparks(orb.x, orb.y, 14, 7, 2.4)
    elsif orb.type == :bomb && (orb.bounces % 2 == 0)
      aoe_damage(orb.x, orb.y, 38.0, @run.base_dmg + 1, 9)
      @fx.spawn_ring(orb.x, orb.y, 38, 9, 14)
      @fx.add_hitstop(1)
      @fx.add_shake(3.0)
    elsif orb.type == :thunder
      chain_lightning(tgt, @run.base_dmg)
    end
  end

  def apply_damage_to_target(tgt, dmg, is_crit, col)
    tgt.on_hit(dmg)
    @run.score += dmg * (10 + @combo)
    pop_txt = is_crit ? sprintf("%d!", dmg) : dmg.to_s
    pop_col = is_crit ? 10 : 7
    @fx.spawn_popup(tgt.x, tgt.y - 6.0, pop_txt, pop_col, is_crit)
    @fx.spawn_sparks(tgt.x, tgt.y, col, is_crit ? 8 : 5, 2.0)

    if is_crit || tgt.is_boss
      @fx.add_hitstop(1)
      @fx.add_shake(is_crit ? 2.2 : 1.5)
    end

    if !tgt.alive?
      @run.kills += 1
      @run.score += tgt.score_val
      @fx.spawn_ring(tgt.x, tgt.y, tgt.is_boss ? 34 : 16, 10, 14)
      @fx.spawn_sparks(tgt.x, tgt.y, 10, tgt.is_boss ? 16 : 8, 2.8)
      @fx.add_hitstop(2)
      @fx.add_shake(tgt.is_boss ? 5.0 : 2.5)
      if tgt.kind == :crate
        @run.score += 100
        @fx.spawn_popup(tgt.x, tgt.y - 12.0, "+100", 11, true)
      end
    end
  end

  def aoe_damage(cx, cy, radius, dmg, col)
    r_sq = radius * radius
    @targets.each do |t|
      next unless t.alive? && t.kind != :bumper
      dx = t.x - cx
      dy = t.y - cy
      if dx * dx + dy * dy <= r_sq
        apply_damage_to_target(t, dmg, false, col)
      end
    end
  end

  def chain_lightning(src_tgt, dmg)
    candidates = []
    @targets.each do |t|
      next unless t.alive? && t.kind != :bumper && t != src_tgt
      dx = t.x - src_tgt.x
      dy = t.y - src_tgt.y
      d_sq = dx * dx + dy * dy
      if d_sq <= 76.0 * 76.0
        candidates << [d_sq, t]
      end
    end
    candidates.sort_by! { |pair| pair[0] }
    cnt = 0
    while cnt < 2 && cnt < candidates.size
      target = candidates[cnt][1]
      @fx.spawn_lightning(src_tgt.x, src_tgt.y, target.x, target.y, 10)
      apply_damage_to_target(target, dmg, false, 10)
      cnt += 1
    end
  end

  def update_advance
    # 敵・ブロックを1段前進
    @targets.each do |t|
      next if t.kind == :bumper
      t.y += CELL_H
      t.row += 1
      if t.y + (t.shape == :circle ? t.r : t.h * 0.5) >= DANGER_Y
        t.hp = 0
        @run.hp -= 1
        @hurt_flash = 16
        @fx.add_flash(8, 6)
        @fx.add_shake(5.0)
        @fx.spawn_ring(t.x, DANGER_Y, 24, 8, 16)
      end
    end
    @targets.reject! { |t| !t.alive? }

    if @run.hp <= 0
      run ResultScene.new(@run)
      return
    end

    if @turn_in_wave < @max_turns_in_wave
      @turn_in_wave += 1
      spawn_row(0) unless @run.boss_wave?
    end

    if non_bumper_count == 0
      @state = :wave_clear
      @banner_text = "WAVE CLEAR!"
      @banner_timer = 40
    else
      @state = :aim
      @preview_pts = nil
    end
  end

  def update_wave_clear
    if @banner_timer <= 0
      run UpgradeScene.new(@run)
    end
  end

  def draw
    cls(0)

    # BG描画 (camera の影響を受けないため最初に描画)
    tint_col = @run.boss_wave? ? [255, 115, 120] : nil
    bg(@run.stage_bg, dim: 0.58, tint: tint_col, scroll_x: @frame * 0.15, mirror_x: true)

    camera(@fx.shake_dx, @fx.shake_dy)

    # アリーナ枠と危険ライン (背景を透過表示)
    draw_arena_backdrop

    # ターゲット描画
    @targets.each { |t| t.draw(@frame) }

    # 予測ガイド線 (Aim時)
    if @state == :aim
      draw_aim_preview
    end

    # 発射台
    rot = @aim_ang + 1.5708
    draw_spr_centered(:launcher, @launch_x, LAUNCH_Y, 16, 16, rot, 1.0, 1.0, false)

    # オーブ描画
    @orbs.each { |o| o.draw }

    # エフェクト描画
    @fx.draw

    camera()

    # 上部HUD & 下部ビルドバー
    draw_hud
    draw_bottom_bar

    if @banner_timer > 0
      rectfill(36, 108, 184, 22, 1)
      rect(36, 108, 184, 22, 10)
      draw_shadow_text(@banner_text, center_text_x(@banner_text), 115, 10)
    end
  end

  def draw_arena_backdrop
    # 危険ライン (点線)
    x = ARENA_LEFT.round + 2
    while x < ARENA_RIGHT.round - 4
      line(x, DANGER_Y.round, x + 4, DANGER_Y.round, 8)
      x += 10
    end
    # アリーナ境界線
    line(ARENA_LEFT.round, ARENA_TOP.round, ARENA_LEFT.round, LAUNCH_Y.round + 6, 6)
    line(ARENA_RIGHT.round, ARENA_TOP.round, ARENA_RIGHT.round, LAUNCH_Y.round + 6, 6)
    line(ARENA_LEFT.round, ARENA_TOP.round, ARENA_RIGHT.round, ARENA_TOP.round, 6)
  end

  def draw_aim_preview
    if @preview_pts.nil? || @preview_ang.nil? || (@aim_ang - @preview_ang).abs > 0.0005
      @preview_ang = @aim_ang
      @preview_pts, @preview_hit = PhysicsWorld.predict_trajectory(@launch_x, LAUNCH_Y, @aim_ang, @targets)
    end
    pts = @preview_pts
    first_hit = @preview_hit
    i = 0
    while i < pts.size
      pt = pts[i]
      col = (i % 2 == 0 ? 7 : 10)
      circfill(pt[0].round, pt[1].round, 1, col)
      i += 1
    end
    if !first_hit.nil?
      circ(first_hit[0].round, first_hit[1].round, 4, 10)
    end
  end

  def draw_hud
    rectfill(0, 0, SCREEN_W, 22, 1)
    line(0, 22, SCREEN_W, 22, 6)

    w_str = sprintf("W%d", @run.wave)
    draw_shadow_text(w_str, 6, 4, 10)

    sc_str = sprintf("SC:%d", @run.score)
    draw_shadow_text(sc_str, 40, 4, 7)

    if @combo > 1
      cb_str = sprintf("%d HIT!", @combo)
      draw_shadow_text(cb_str, 126, 4, (@combo >= 10 ? 10 : 11))
    end

    # HP ハート表示 (右寄せ)
    hp_col = (@hurt_flash > 0 && @hurt_flash % 4 < 2) ? 7 : 8
    hp_str = sprintf("HP:%d/%d", @run.hp, @run.max_hp)
    draw_shadow_text(hp_str, 200, 4, hp_col)

    # ボスHPバー
    boss = nil
    @targets.each { |t| boss = t if t.is_boss && t.alive? }
    if !boss.nil?
      bw = 160
      bx = 48
      by = 14
      rectfill(bx, by, bw, 5, 0)
      fill_w = ((boss.hp.to_f / boss.max_hp) * (bw - 2)).round
      rectfill(bx + 1, by + 1, fill_w, 3, 8)
      rect(bx, by, bw, 5, 7)
    else
      st_str = sprintf("%s  DMG:%d  CRIT:%d%%", @run.stage_name, @run.base_dmg, @run.crit_chance)
      draw_shadow_text(st_str, 6, 13, 6)
    end
  end

  def draw_bottom_bar
    rectfill(0, BOTTOM_BAR_Y, SCREEN_W, SCREEN_H - BOTTOM_BAR_Y, 1)
    line(0, BOTTOM_BAR_Y, SCREEN_W, BOTTOM_BAR_Y, 6)

    # ビルド内訳表示
    counts = @run.orb_counts
    items = [
      [:orb_normal, counts[:normal], 12],
      [:orb_pierce, counts[:pierce], 11],
      [:orb_split, counts[:split], 14],
      [:orb_bomb, counts[:bomb], 9],
      [:orb_thunder, counts[:thunder], 10],
      [:orb_spark, counts[:spark], 8]
    ]
    x = 8
    items.each do |it|
      next if it[1] <= 0
      draw_spr_centered(it[0], x + 4, BOTTOM_BAR_Y + 13, 8, 8, 0.0, 1.0, 1.0, false)
      draw_shadow_text(it[1].to_s, x + 10, BOTTOM_BAR_Y + 9, it[2])
      x += 26
    end

    if @state == :firing
      rx, ry, rw, rh = recall_rect
      rectfill(rx, ry, rw, rh, 2)
      rect(rx, ry, rw, rh, 10)
      draw_shadow_text("RECALL", rx + 8, ry + 5, 10)
    else
      tot = sprintf("x%d ORBS", @run.orb_list.size)
      draw_shadow_text(tot, 196, BOTTOM_BAR_Y + 9, 7)
    end
  end
end

# ------------------------------------------------------------------------------
# 初回シーン起動
# ------------------------------------------------------------------------------
run TitleScene.new

__END__
# ==============================================================================
# カスタムパレット定義
# ==============================================================================
@PALETTE 1
0: #0C0E18
1: #1D2B53
5: #4A546E
6: #A8B8D0
7: #FFF1E8
8: #FF2955
9: #FF8811
A: #FFEC27
B: #00E436
C: #29ADFF
D: #9068F0
E: #FF77A8

@PALETTE 2
0: #0C0E18
1: #1B3B2B
3: #008751
B: #38E878
A: #B8FF78
8: #FF244C
7: #FFF1E8

@PALETTE 3
0: #0C0E18
1: #2E1F47
2: #6B2E6B
D: #8A76B8
E: #FF77A8
C: #45C4FF
7: #FFF1E8

@PALETTE 10
#FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8
#FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8 #FFF1E8

# ==============================================================================
# スプライト定義
# ==============================================================================
@SPRITE :launcher 16x16 pal:1
.......77.......
......7CC7......
.....7CCCC7.....
....01CCCC10....
...01CCCCCC10...
...01C7CC7C10...
..016CCCCCC610..
..0166CCCC6610..
..0566CCCC6650..
..0556CCCC6550..
...055AAAA550...
...05AAAAAA50...
....01555510....
.....000000.....
................
................

@SPRITE :orb_normal 8x8 pal:1
..0000..
.07CCC0.
077CCCC0
0CCCCCC0
0CC1CCC0
0C1111C0
.011110.
..0000..

@SPRITE :orb_pierce 8x8 pal:1
..0000..
.07BBB0.
077BBBB0
0BBBBBB0
0BB3BBB0
0B3333B0
.033330.
..0000..

@SPRITE :orb_split 8x8 pal:1
..0000..
.07EEE0.
077EEEE0
0EEEEEE0
0EE2EEE0
0E2222E0
.022220.
..0000..

@SPRITE :orb_bomb 8x8 pal:1
..0000..
.079990.
07799990
09988990
09888890
09444490
.044440.
..0000..

@SPRITE :orb_thunder 8x8 pal:1
..0000..
.07AAA0.
077AAAA0
0AAAAAA0
0AA9AAA0
0A9999A0
.099990.
..0000..

@SPRITE :orb_spark 8x8 pal:1
..0000..
.078880.
07788880
088AA880
08AAAA80
08222280
.022220.
..0000..

@SPRITE :bumper 16x16 pal:1
....00000000....
..00BBBBBBBB00..
.0BB77777777BB0.
.0B7CCCCCCCC7B0.
0B7CC777777CC7B0
0B7C7CCCCCC7C7B0
0B7C7C7777C7C7B0
0B7C7C7AA7C7C7B0
0B7C7C7AA7C7C7B0
0B7C7C7777C7C7B0
0B7C7CCCCCC7C7B0
0B7CC777777CC7B0
.0B7CCCCCCCC7B0.
.0BB77777777BB0.
..00BBBBBBBB00..
....00000000....

@SPRITE :crate 16x16 pal:1
.00000000000000.
0999999999999990
0944444444444490
0949944444499490
0949A944449A9490
09449A9449A94490
094449A99A944490
0944449AA9444490
0944449AA9444490
094449A99A944490
09449A9449A94490
0949A944449A9490
0949944444499490
0944444444444490
0999999999999990
.00000000000000.

@SPRITE :slime 16x16 pal:2
................
.....000000.....
...00BBBBBB00...
..0BB77BBBBBB0..
..0B7ABBBBB3B0..
.0BBBBBBBBB33B0.
.0BBB0BBBB033B0.
.0BBB0BBBB033B0.
.0BBBB888BB33B0.
.0BBBB878BB33B0.
..0BBB333333B0..
..033333333330..
...0033333300...
.....000000.....
................
................

@SPRITE :bat 16x16 pal:3
................
.00..........00.
0220........0220
02D20..00..02D20
02DD200DD002DD20
.02DDDDDD22DD20.
.02DD0DDDD0DD20.
..0DD8DDDD8DD0..
..02DDDDDDDD20..
...02D7DD7D20...
....02DDDD20....
.....022220.....
....020..020....
................
................
................

@SPRITE :golem 16x16 pal:1
...0000000000...
..066666666660..
.06776666665560.
.06766666665560.
0665500660055660
0665587667855660
0665555665555660
0666666556666660
0566000000006650
0566055555506650
.05555555555550.
.05511555511550.
..001100001100..
...0110..0110...
................
................

@SPRITE :mage 16x16 pal:3
.....000000.....
....0DDDDDD0....
...0DDEEEEDD0...
..0DDD0000DDD0..
..0DD000000DD0..
..0D00A00A00D0..
..0D00000000D0..
...0022222200...
..022DDDDDD220..
.022DDEEEEDD220.
.02DDCCCCCCDD20.
..02DCCCCCCCD0..
...0222222220...
....020..020....
................
................

@SPRITE :boss_1 32x32 pal:2
..........000000000000..........
........00BBBBBBBBBBBB00........
......00BB777BBBBBBBBB3B00......
.....0BB77ABBBBBBBBBBB333B0.....
....0BB7ABBBBBBBBBBBBB3333B0....
...0BBBBBBBBBBBBBBBBBB33333B0...
..0BBBBBBBBBBBBBBBBBBB333333B0..
..0BBBB0000BBBBBBBB000033333B0..
.0BBBB077880BBBBBB08877033333B0.
.0BBBB078880BBBBBB08887033333B0.
.0BBBB00000BBBBBBBB0000333333B0.
.0BBBBBBBBBBBBBBBBBBBB3333333B0.
.0BBBBBBBBBB888888BBBB3333333B0.
.0BBBBBBBB8877777788BB3333333B0.
.0BBBBBBBB8778888778BB3333333B0.
.0BBBBBBBB8888888888BB3333333B0.
..0BBBBBBBB88888888BBB333333B0..
..0BBBBBBBBB333333BBBB333333B0..
...0BBBB3333333333333333333B0...
....0BB3333333333333333333B0....
.....0B333333333333333333B0.....
......00333333333333333300......
.......001133333333331100.......
........0111111111111110........
.......011001100001100110.......
......0110..010..010..0110......
......000....00..00....000......
................................
................................
................................
................................
................................

@SPRITE :boss_2 32x32 pal:1
.........00000000000000.........
.......00CCCCCCCCCCCCCC00.......
.....00CC777CCCCCCCCCCC1C00.....
....0CC77CCCCCCCCCCCCCC111C0....
...0CC7CCCCCCCCCCCCCCCC1111C0...
..0CCCCCCCCCCCCCCCCCCCC11111C0..
..0CCCC0000CCCCCCCC000011111C0..
.0CCCC0AAAA0CCCCCC0AAAA011111C0.
.0CCCC0A77A0CCCCCC0A77A011111C0.
.0CCCC00000CCCCCCCC0000111111C0.
.0CCCCCCC8888888888CCCC111111C0.
.0CCCCCC877777777778CCC111111C0.
.0CCCCCC878888888878CCC111111C0.
.0CCCCCC888888888888CCC111111C0.
.0CCCCCCC8888888888CCCC111111C0.
..0CCCCCCC11111111CCCCC11111C0..
..0CC11111111111111111111111C0..
...0C1111111111111111111111C0...
....001111111111111111111100....
.....0011111111111111111100.....
......01111001111110011110......
.....011100..001100..001110.....
.....0110......00......0110.....
......00................00......
................................
................................
................................
................................
................................
................................
................................
................................

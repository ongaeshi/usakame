# ==============================================================================
# CHRONO DUEL - PC-98 / HD-2D 風 タイミング介入コマンドバトル・ローグライト
# ------------------------------------------------------------------------------
# 640x480 / 1ファイル完結 / 基本API + BG + スプライト専用 (タイルマップ・サウンド不使用)
# 実行: cargo run --bin uk -- run examples/chrono_duel.rb
#
# 【操作方法】
#   ↑ / ↓ / ← / → : コマンド・スキル・報酬選択
#   Z              : 決定 / タイミング目押し / 連打 / ジャストガード
#   X              : キャンセル・戻る / ジャストガード
# ==============================================================================

config(
  width: 640,
  height: 480,
  scale: 2.0,
  sprite_scale: 2.0,
  text_size: 16,
  title: "CHRONO DUEL"
)

SCREEN_W = 640
SCREEN_H = 480
SPRITE_SCALE = 2.5

# ステージ上部・下部UI境界
TOP_WIN_H    = 96
STAGE_TOP    = 100
STAGE_BOTTOM = 324
BOT_WIN_Y    = 328
BOT_WIN_H    = 144

# 標準16色パレット定数
C_BLACK   = 0
C_DBLUE   = 1
C_DPURPLE = 2
C_DGREEN  = 3
C_BROWN   = 4
C_DGREY   = 5
C_LGREY   = 6
C_WHITE   = 7
C_RED     = 8
C_ORANGE  = 9
C_YELLOW  = 10
C_GREEN   = 11
C_CYAN    = 12
C_INDIGO  = 13
C_PINK    = 14
C_PEACH   = 15

# エフェクト用カスタムパレットID
PAL_FLASH_WHITE = 10
PAL_GUARD_CYAN  = 11
PAL_CRIT_GOLD   = 12
PAL_DANGER_RED  = 13

# ステージ定義 (全4戦)
STAGES = [
  {
    stage: 1,
    bg: :forest,
    tint: [215, 255, 225],
    floor_col1: 3,
    floor_col2: 1,
    area_name: "緑陰の古代森",
    boss_name: "シルヴァ・ゴーレム",
    boss_title: "森の守護者",
    boss_spr: :boss_golem,
    boss_w: 32,
    boss_h: 32,
    max_hp: 115,
    atk_base: 14,
    patterns: [
      { kind: :heavy,  name: "剛腕強撃",   dmg: 18, hits: 1, warn: "大振りの構え！" },
      { kind: :strike, name: "蔦の連撃",   dmg: 9,  hits: 2, warn: "2連続攻撃の気配！" },
      { kind: :charge, name: "大地の守り", dmg: 0,  hits: 0, shield: 14, atk_up: 4, warn: "装甲と力を蓄えている" }
    ]
  },
  {
    stage: 2,
    bg: :mountain,
    tint: [255, 175, 130],
    floor_col1: 4,
    floor_col2: 2,
    area_name: "黄昏の焦熱山脈",
    boss_name: "イグニス・ナイト",
    boss_title: "夕焼けの炎騎士",
    boss_spr: :boss_knight,
    boss_w: 32,
    boss_h: 32,
    max_hp: 165,
    atk_base: 17,
    patterns: [
      { kind: :strike, name: "紅蓮二連斬", dmg: 12, hits: 2, warn: "炎剣を二段に構えた！" },
      { kind: :heavy,  name: "業火の一閃", dmg: 24, hits: 1, cutin: true, warn: "凄まじい熱気が収束する！" },
      { kind: :charge, name: "炎帝の鼓動", dmg: 0,  hits: 0, shield: 12, atk_up: 6, warn: "炎を纏い攻撃力が上昇！" },
      { kind: :strike, name: "火の粉散華", dmg: 8,  hits: 3, warn: "3連撃が来る！" }
    ]
  },
  {
    stage: 3,
    bg: :city,
    tint: [175, 210, 255],
    floor_col1: 1,
    floor_col2: 5,
    area_name: "蒼夜の機甲都市",
    boss_name: "アーク・ジェネラル",
    boss_title: "夜景の機甲将軍",
    boss_spr: :boss_general,
    boss_w: 32,
    boss_h: 32,
    max_hp: 220,
    atk_base: 20,
    patterns: [
      { kind: :strike, name: "電磁パルス連射", dmg: 11, hits: 3, warn: "3連続射撃ロックオン！" },
      { kind: :charge, name: "重装甲展開",     dmg: 0,  hits: 0, shield: 22, atk_up: 5, warn: "高出力バリア展開中" },
      { kind: :heavy,  name: "レールキャノン", dmg: 30, hits: 1, cutin: true, warn: "主砲エネルギー臨界点！" },
      { kind: :heavy,  name: "対地制圧撃",     dmg: 21, hits: 1, warn: "高圧ブレード展開！" }
    ]
  },
  {
    stage: 4,
    bg: :cyber,
    tint: [165, 220, 255],
    floor_col1: 2,
    floor_col2: 1,
    area_name: "時空の狭間・零域",
    boss_name: "クロノス・ドラゴン",
    boss_title: "終焉の時空龍",
    boss_spr: :boss_dragon,
    boss_w: 48,
    boss_h: 48,
    max_hp: 300,
    atk_base: 24,
    patterns: [
      { kind: :strike, name: "次元裂断爪",   dmg: 14, hits: 3, warn: "空間が3度裂ける気配！" },
      { kind: :heavy,  name: "クロノ・ノヴァ", dmg: 36, hits: 1, cutin: true, warn: "時空崩壊級の魔力集中！" },
      { kind: :charge, name: "永劫の鱗",     dmg: 0,  hits: 0, shield: 24, atk_up: 7, warn: "時空障壁と龍気を解放！" },
      { kind: :heavy,  name: "星辰ブレス",   dmg: 27, hits: 1, warn: "蒼白の閃光が迫る！" }
    ]
  }
]

# スキルマスター定義
SKILLS_DB = {
  twin_slash: {
    id: :twin_slash,
    name: "ツインスラッシュ",
    cost: 2,
    kind: :timing,
    power: 16,
    hits: 2,
    desc: "2連撃。目押し成功で2撃目2倍",
    cutin: false
  },
  aegis_guard: {
    id: :aegis_guard,
    name: "イージスガード",
    cost: 2,
    kind: :shield,
    shield: 20,
    power: 10,
    desc: "シールド+20展開＋小ダメージ",
    cutin: false
  },
  break_smash: {
    id: :break_smash,
    name: "ブレイクスマッシュ",
    cost: 3,
    kind: :timing,
    power: 30,
    hits: 1,
    breaks: true,
    desc: "強撃＋敵の盾・強化を粉砕！",
    cutin: true
  },
  meteor_burst: {
    id: :meteor_burst,
    name: "メテオバースト",
    cost: 4,
    kind: :mash,
    power: 9,
    min_hits: 3,
    max_hits: 7,
    desc: "Z連打で最大7連撃の炎弾！",
    cutin: true
  },
  drain_edge: {
    id: :drain_edge,
    name: "ドレインエッジ",
    cost: 3,
    kind: :timing,
    power: 24,
    hits: 1,
    drain: true,
    desc: "与ダメの50%(会心75%)HP吸収",
    cutin: false
  },
  chrono_rush: {
    id: :chrono_rush,
    name: "クロノスラッシュ",
    cost: 5,
    kind: :timing,
    power: 20,
    hits: 3,
    desc: "時空を斬る奥義3連撃！",
    cutin: true
  }
}

# レリックマスター定義
RELICS_DB = {
  pocket_watch: {
    id: :pocket_watch,
    name: "黄金の懐中時計",
    short: "時計",
    desc: "PERFECT幅+25%＆会心倍率1.9倍"
  },
  azure_crest: {
    id: :azure_crest,
    name: "蒼穹の盾紋章",
    short: "盾紋",
    desc: "ジャストガード反撃+12＆盾+6"
  },
  mana_core: {
    id: :mana_core,
    name: "魔力循環コア",
    short: "魔核",
    desc: "毎ターン開始時にSP+1回復"
  },
  phoenix_feather: {
    id: :phoenix_feather,
    name: "不死鳥の羽根",
    short: "羽根",
    desc: "最大HP+20＆勝利時回復量+10"
  },
  combo_scroll: {
    id: :combo_scroll,
    name: "連撃の極意書",
    short: "極意",
    desc: "全スキルの与ダメージ+25%"
  },
  fury_ring: {
    id: :fury_ring,
    name: "逆境の闘志輪",
    short: "闘志",
    desc: "HP40%以下で全攻撃ダメ+35%"
  }
}

# 戦績ベスト（ホットリロード維持）
$best_rank ||= nil
$best_turns ||= nil

# ------------------------------------------------------------------------------
# 汎用ヘルパー（mrubyedge準拠）
# ------------------------------------------------------------------------------
def clamp_val(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

def lerp_val(a, b, t)
  a + (b - a) * t
end

def draw_shadow_text(txt, x, y, col, size = 16)
  print_text(txt, x + 1, y + 1, C_BLACK, { size: size })
  print_text(txt, x, y, col, { size: size })
end

def text_pixel_w(txt, size = 16)
  # 東雲16px: ASCII約8px, 全角16px / 美咲8px: ASCII約6px, 全角8px 概算
  w = 0
  chars = txt.chars
  i = 0
  while i < chars.size
    b = chars[i].bytesize
    if size == 8
      w += (b > 1 ? 8 : 6)
    else
      w += (b > 1 ? 16 : 8)
    end
    i += 1
  end
  w
end

def draw_centered_text(txt, cx, y, col, size = 16, shadow = true)
  x = cx - text_pixel_w(txt, size) / 2
  if shadow
    draw_shadow_text(txt, x, y, col, size)
  else
    print_text(txt, x, y, col, { size: size })
  end
end

# PC-98 / レトロRPG風 二重枠ウィンドウ描画
def draw_pc98_window(x, y, w, h, title = "", border_col = C_LGREY, title_col = C_CYAN)
  rectfill(x + 3, y + 3, w, h, C_BLACK)
  rectfill(x, y, w, h, C_BLACK)
  rect(x, y, w, h, border_col)
  rect(x + 2, y + 2, w - 4, h - 4, C_DBLUE)
  rect(x + 3, y + 3, w - 6, h - 6, border_col)
  if title != ""
    tw = text_pixel_w(title, 8) + 12
    rectfill(x + 14, y - 4, tw, 10, C_BLACK)
    print_text(title, x + 20, y - 3, title_col, { size: 8 })
  end
end

# spr_ext の倍率指定に対応した接地中央描画（rot == 0 専用）
def draw_spr_grounded(id, foot_cx, foot_y, w, h, sx, sy, flip_x, pal_id = nil)
  eff_sx = sx * SPRITE_SCALE
  eff_sy = sy * SPRITE_SCALE
  real_w = w * eff_sx
  real_h = h * eff_sy
  dx = foot_cx - real_w * 0.5
  dy = foot_y - real_h
  spr_ext(id, dx, dy, 0.0, eff_sx, eff_sy, flip_x, false, pal_id)
end

# rot != 0 時は中心基準、rot == 0 時は左上基準
def draw_spr_centered(id, cx, cy, w, h, rot, sx, sy, flip_x, pal_id = nil)
  eff_sx = sx * SPRITE_SCALE
  eff_sy = sy * SPRITE_SCALE
  if rot.abs < 0.001
    dx = cx - (w * eff_sx) * 0.5
    dy = cy - (h * eff_sy) * 0.5
    spr_ext(id, dx, dy, 0.0, eff_sx, eff_sy, flip_x, false, pal_id)
  else
    dx = cx - (w * eff_sx) * 0.5
    dy = cy - (h * eff_sy) * 0.5
    spr_ext(id, dx, dy, rot, eff_sx, eff_sy, flip_x, false, pal_id)
  end
end

# 配列からランダムにN個重複なしで選ぶ（shuffle未実装のため手動）
def pick_random_items(arr, count)
  pool = arr.dup
  res = []
  while res.size < count && pool.size > 0
    idx = rand(pool.size)
    res << pool[idx]
    pool.delete_at(idx)
  end
  res
end

# ------------------------------------------------------------------------------
# エフェクトシステム（粒子・斬撃・リング・ポップアップ・シェイク・ヒットストップ）
# ------------------------------------------------------------------------------
class EffectManager
  attr_reader :hitstop, :shake_x, :shake_y

  def initialize
    @hitstop = 0
    @shake_mag = 0.0
    @shake_x = 0
    @shake_y = 0
    @flash_timer = 0
    @flash_col = C_WHITE
    @particles = []
    @rings = []
    @slashes = []
    @popups = []
    @ambient = []
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

  def spawn_burst(x, y, col, count = 12, spd = 3.5, grav = 0.12, life = 24)
    i = 0
    while i < count
      ang = rand() * 6.28318
      v = (0.4 + rand() * 0.8) * spd
      @particles << {
        x: x.to_f,
        y: y.to_f,
        vx: cos(ang) * v,
        vy: sin(ang) * v - 0.6,
        grav: grav,
        col: col,
        size: (rand(3) == 0 ? 4 : 2),
        life: life + rand(10),
        max_life: life + 10
      }
      i += 1
    end
  end

  def spawn_ring(x, y, col, max_r = 56, life = 18)
    @rings << {
      x: x.to_f,
      y: y.to_f,
      r: 6.0,
      max_r: max_r.to_f,
      col: col,
      life: life,
      max_life: life
    }
  end

  def spawn_slash(x, y, pal_id = nil, flip_x = false)
    @slashes << {
      x: x.to_f,
      y: y.to_f,
      pal: pal_id,
      flip_x: flip_x,
      frame: 0,
      max_frame: 14
    }
  end

  def spawn_popup(text, x, y, col, size = 16)
    @popups << {
      text: text,
      x: x.to_f,
      y: y.to_f,
      vy: -2.6,
      col: col,
      size: size,
      life: 44,
      max_life: 44
    }
  end

  def update_ambient(stage_idx)
    if rand(4) == 0 && @ambient.size < 28
      col = C_GREEN
      col = C_ORANGE if stage_idx == 1
      col = C_CYAN if stage_idx == 2
      col = C_PINK if stage_idx == 3
      @ambient << {
        x: rand(SCREEN_W).to_f,
        y: (STAGE_BOTTOM - rand(20)).to_f,
        vx: (rand() - 0.5) * 0.6,
        vy: -0.4 - rand() * 0.7,
        col: col,
        life: 90 + rand(60)
      }
    end
    @ambient.each do |p|
      p[:x] += p[:vx]
      p[:y] += p[:vy]
      p[:life] -= 1
    end
    @ambient.reject! { |p| p[:life] <= 0 || p[:y] < STAGE_TOP }
  end

  def update
    if @hitstop > 0
      @hitstop -= 1
    end

    if @shake_mag > 0.2
      @shake_x = ((rand() * 2.0 - 1.0) * @shake_mag).round
      @shake_y = ((rand() * 2.0 - 1.0) * @shake_mag).round
      @shake_mag *= 0.80
    else
      @shake_mag = 0.0
      @shake_x = 0
      @shake_y = 0
    end

    @flash_timer -= 1 if @flash_timer > 0

    @particles.each do |p|
      p[:x] += p[:vx]
      p[:y] += p[:vy]
      p[:vy] += p[:grav]
      p[:life] -= 1
    end
    @particles.reject! { |p| p[:life] <= 0 }

    @rings.each do |r|
      t = 1.0 - (r[:life].to_f / r[:max_life])
      r[:r] = lerp_val(6.0, r[:max_r], t)
      r[:life] -= 1
    end
    @rings.reject! { |r| r[:life] <= 0 }

    @slashes.each do |s|
      s[:frame] += 1
    end
    @slashes.reject! { |s| s[:frame] >= s[:max_frame] }

    @popups.each do |pop|
      pop[:y] += pop[:vy]
      pop[:vy] *= 0.90
      pop[:life] -= 1
    end
    @popups.reject! { |pop| pop[:life] <= 0 }
  end

  def draw_ambient
    @ambient.each do |p|
      rectfill(p[:x], p[:y], 2, 2, p[:col])
    end
  end

  def draw_foreground
    @rings.each do |r|
      circ(r[:x], r[:y], r[:r], r[:col])
      circ(r[:x], r[:y], r[:r] - 2.0, C_WHITE) if r[:r] > 8.0
    end

    @slashes.each do |s|
      idx = s[:frame] < 7 ? 0 : 1
      draw_spr_centered(spr_id(:slash_fx, idx), s[:x], s[:y], 24, 24, 0.0, 1.3, 1.3, s[:flip_x], s[:pal])
    end

    @particles.each do |p|
      rectfill(p[:x], p[:y], p[:size], p[:size], p[:col])
    end

    @popups.each do |pop|
      draw_centered_text(pop[:text], pop[:x], pop[:y], pop[:col], pop[:size], true)
    end

    if @flash_timer > 0
      # 画面全体の薄いフラッシュ枠演出
      rect(0, 0, SCREEN_W, SCREEN_H, @flash_col)
      rect(2, 2, SCREEN_W - 4, SCREEN_H - 4, @flash_col)
      rect(4, 4, SCREEN_W - 8, SCREEN_H - 8, @flash_col)
    end
  end
end

# ------------------------------------------------------------------------------
# プレイヤーラン状態（連戦引き継ぎ用データコンテナ）
# ------------------------------------------------------------------------------
class PlayerRun
  attr_accessor :hp, :max_hp, :sp, :max_sp, :potions, :ethers
  attr_accessor :elixirs, :skills, :relics, :stage_idx, :total_turns
  attr_accessor :perfect_count, :timing_attempts, :just_guard_count

  def initialize
    @max_hp = 90
    @hp = 90
    @max_sp = 6
    @sp = 2
    @potions = 2
    @ethers = 1
    @elixirs = 1
    @skills = [:twin_slash, :aegis_guard]
    @relics = []
    @stage_idx = 0
    @total_turns = 0
    @perfect_count = 0
    @timing_attempts = 0
    @just_guard_count = 0
  end

  def has_relic?(id)
    @relics.include?(id)
  end

  def add_relic(id)
    return if has_relic?(id)
    @relics << id
    if id == :phoenix_feather
      @max_hp += 20
      @hp += 20
      @hp = @max_hp if @hp > @max_hp
    end
  end

  def add_skill(id)
    return if @skills.include?(id)
    @skills << id
  end

  def perfect_rate
    return 0 if @timing_attempts == 0
    (@perfect_count * 100 / @timing_attempts).to_i
  end

  def calc_rank
    score = 0
    score += 40 if @hp >= (@max_hp * 0.6)
    score += 25 if @hp >= (@max_hp * 0.3)
    score += 35 if perfect_rate >= 65
    score += 20 if perfect_rate >= 40
    score += 30 if @just_guard_count >= 4
    score += 15 if @just_guard_count >= 2
    score += 25 if @total_turns <= 22
    return "S+" if score >= 120
    return "S" if score >= 95
    return "A" if score >= 70
    return "B" if score >= 45
    "C"
  end
end

# ------------------------------------------------------------------------------
# タイトルシーン
# ------------------------------------------------------------------------------
class TitleScene
  def initialize
    @frame = 0
    @cursor = 0
  end

  def update
    @frame += 1
    if btnp(:up) || btnp(:down)
      @cursor = (@cursor + 1) % 2
    end
    if btnp(1) || btnp(2) || btnp(:mouse_l)
      if @cursor == 0
        run BattleScene.new(PlayerRun.new)
      else
        @cursor = 0
      end
    end
  end

  def draw
    cls(C_BLACK)
    bg(:cyber, { fit: :screen, dim: 0.58, scroll_x: @frame * 0.4, loop_x: true })

    # 装飾ライン
    rect(16, 16, SCREEN_W - 32, SCREEN_H - 32, C_DBLUE)
    rect(20, 20, SCREEN_W - 40, SCREEN_H - 40, C_CYAN)

    # ヒーロー＆クロノスドラゴンの対峙シルエット演出
    bob = sin(@frame * 0.06) * 4.0
    draw_spr_grounded(spr_id(:hero, (@frame / 18) % 2), 156, 268 + bob * 0.5, 24, 24, 1.0, 1.0, false)
    draw_spr_grounded(spr_id(:boss_dragon, (@frame / 22) % 2), 470, 276 - bob, 48, 48, 1.0, 1.0, false)

    # タイトルロゴウィンドウ
    draw_pc98_window(110, 42, 420, 96, "PC-98 / HD-2D ROGUELITE BATTLE", C_CYAN, C_YELLOW)
    draw_centered_text("CHRONO DUEL", 320, 62, C_YELLOW, 16, true)
    draw_centered_text("刻を斬り裂くタイミング介入コマンドRPG", 320, 92, C_WHITE, 16, true)
    draw_centered_text("TIMING INTERVENTION ROGUELITE", 320, 118, C_CYAN, 8, true)

    # コマンド＆操作ガイドウィンドウ
    draw_pc98_window(140, 294, 360, 140, "SYSTEM MENU", C_LGREY, C_CYAN)
    c0 = @cursor == 0 ? C_YELLOW : C_WHITE
    c1 = @cursor == 1 ? C_YELLOW : C_LGREY
    p0 = @cursor == 0 ? "▶ 新規ラン開始 (全4ステージ)" : "  新規ラン開始 (全4ステージ)"
    p1 = @cursor == 1 ? "▶ 操作：Zで目押し会心＆ジャストガード" : "  操作：Zで目押し会心＆ジャストガード"
    draw_shadow_text(p0, 176, 320, c0, 16)
    draw_shadow_text(p1, 176, 348, c1, 16)

    draw_shadow_text("・自ターン: 黄金ゾーンで [Z] 目押し → PERFECT! 1.6倍撃", 160, 382, C_PEACH, 8)
    draw_shadow_text("・敵ターン: 攻撃直前に [Z/X] → JUST GUARD! 反撃＆SP回復", 160, 396, C_CYAN, 8)

    if $best_rank
      draw_centered_text("BEST RECORD: RANK #{$best_rank} (#{$best_turns} TURNS)", 320, 416, C_GREEN, 8, true)
    else
      if (@frame / 25) % 2 == 0
        draw_centered_text("PRESS [Z] TO START", 320, 416, C_YELLOW, 8, true)
      end
    end
  end
end

# ------------------------------------------------------------------------------
# バトルシーン
# ------------------------------------------------------------------------------
class BattleScene
  def initialize(run_data)
    @run = run_data
    @stage = STAGES[@run.stage_idx]
    @fx = EffectManager.new
    @frame = 0

    # プレイヤー戦闘ステータス
    @p_disp_hp = @run.hp.to_f
    @p_trail_hp = @run.hp.to_f
    @p_shield = 0
    @p_charge_turns = 0
    @p_elixir_turns = 0
    @p_x = 156.0
    @p_y = 268.0
    @p_sx = 1.0
    @p_sy = 1.0
    @p_pal = nil
    @p_pal_timer = 0
    @p_pose = :idle

    # 敵戦闘ステータス
    @e_max_hp = @stage[:max_hp]
    @e_hp = @e_max_hp
    @e_disp_hp = @e_max_hp.to_f
    @e_trail_hp = @e_max_hp.to_f
    @e_shield = 0
    @e_atk_bonus = 0
    @e_x = 474.0
    @e_y = 276.0
    @e_sx = 1.0
    @e_sy = 1.0
    @e_pal = nil
    @e_pal_timer = 0
    @e_pat_idx = 0
    @e_intent = @stage[:patterns][0]

    # フェーズ管理
    # :intro -> :menu -> :skill_menu -> :item_menu -> :player_timing -> :player_mash
    # -> :cutin -> :player_resolve -> :enemy_windup -> :enemy_strike -> :turn_end -> :victory / :defeat
    @phase = :intro
    @phase_timer = 36
    @menu_idx = 0
    @sub_idx = 0
    @logs = ["#{@stage[:boss_name]} が立ちはだかる！"]

    # タイミングバー変数
    @timing_pos = 0.0
    @timing_dir = 1.0
    @timing_speed = 0.026
    @timing_result = :none
    @timing_action = nil
    @mash_count = 0
    @mash_timer = 0

    # 敵攻撃タイミング変数
    @enemy_hit_idx = 0
    @enemy_total_hits = 1
    @enemy_windup_len = 52
    @enemy_guard_window = 12
    @enemy_guard_pressed = false
    @enemy_guard_grade = :none

    # カットイン演出変数
    @cutin_timer = 0
    @cutin_title = ""
    @cutin_sub = ""
    @cutin_col = C_YELLOW
    @cutin_is_enemy = false
    @cutin_next_phase = :player_resolve
  end

  def push_log(msg)
    @logs << msg
    @logs.shift if @logs.size > 4
  end

  def perfect_half_width
    base = 0.085
    base *= 1.25 if @run.has_relic?(:pocket_watch)
    base
  end

  def good_half_width
    0.22
  end

  def calc_player_attack_mult
    mult = 1.0
    if @p_charge_turns > 0
      mult *= 1.5
    end
    if @p_elixir_turns > 0
      mult *= 1.4
    end
    if @run.has_relic?(:fury_ring) && @run.hp <= (@run.max_hp * 0.4)
      mult *= 1.35
    end
    mult
  end

  def calc_crit_mult
    @run.has_relic?(:pocket_watch) ? 1.9 : 1.6
  end

  def damage_enemy(raw_dmg, is_crit = false, breaks_shield = false)
    dmg = raw_dmg.to_i
    dmg = 1 if dmg < 1

    if breaks_shield && (@e_shield > 0 || @e_atk_bonus > 0)
      @e_shield = 0
      @e_atk_bonus = 0
      @fx.spawn_popup("BREAK!", @e_x, @e_y - 96.0, C_CYAN, 16)
      push_log("敵の装甲と強化を粉砕した！")
    end

    if @e_shield > 0
      absorbed = dmg < @e_shield ? dmg : @e_shield
      @e_shield -= absorbed
      dmg -= absorbed
      @fx.spawn_popup("SHIELD -#{absorbed}", @e_x, @e_y - 78.0, C_LGREY, 8) if absorbed > 0
    end

    @e_hp -= dmg
    @e_hp = 0 if @e_hp < 0

    @e_sx = 1.28
    @e_sy = 0.74
    @e_pal = is_crit ? PAL_CRIT_GOLD : PAL_FLASH_WHITE
    @e_pal_timer = is_crit ? 10 : 6

    ey = @e_y - (@stage[:boss_h] * SPRITE_SCALE * 0.5)
    @fx.spawn_slash(@e_x, ey, is_crit ? PAL_CRIT_GOLD : nil, false)
    @fx.spawn_burst(@e_x, ey, is_crit ? C_YELLOW : C_WHITE, is_crit ? 18 : 10, is_crit ? 4.4 : 2.8)
    if is_crit
      @fx.spawn_ring(@e_x, ey, C_YELLOW, 64, 16)
      @fx.add_hitstop(7)
      @fx.add_shake(7.0)
      @fx.add_flash(C_YELLOW, 3)
      @fx.spawn_popup("CRITICAL #{dmg}!", @e_x, @e_y - 86.0, C_YELLOW, 16)
    else
      @fx.add_hitstop(4)
      @fx.add_shake(3.5)
      @fx.spawn_popup("#{dmg}", @e_x, @e_y - 78.0, C_WHITE, 16)
    end
    dmg
  end

  def damage_player(raw_dmg, grade)
    dmg = raw_dmg.to_i
    if grade == :just
      dmg = (dmg * 0.25).round
      dmg = 1 if dmg < 1 && raw_dmg > 0
    elsif grade == :guard
      dmg = (dmg * 0.65).round
    end

    if @p_shield > 0
      absorbed = dmg < @p_shield ? dmg : @p_shield
      @p_shield -= absorbed
      dmg -= absorbed
    end

    @run.hp -= dmg
    @run.hp = 0 if @run.hp < 0

    @p_sx = 1.25
    @p_sy = 0.78
    if grade == :just
      @p_pal = PAL_GUARD_CYAN
      @p_pal_timer = 12
      @fx.spawn_ring(@p_x, @p_y - 26.0, C_CYAN, 58, 16)
      @fx.spawn_burst(@p_x, @p_y - 26.0, C_CYAN, 16, 4.0)
      @fx.add_hitstop(8)
      @fx.add_shake(6.0)
      @fx.add_flash(C_CYAN, 3)
      @fx.spawn_popup("JUST GUARD! -#{dmg}", @p_x, @p_y - 68.0, C_CYAN, 16)
    elsif grade == :guard
      @p_pal = PAL_GUARD_CYAN
      @p_pal_timer = 6
      @fx.spawn_burst(@p_x, @p_y - 26.0, C_LGREY, 8, 2.5)
      @fx.add_hitstop(3)
      @fx.spawn_popup("GUARD -#{dmg}", @p_x, @p_y - 60.0, C_LGREY, 16)
    else
      @p_pal = PAL_DANGER_RED
      @p_pal_timer = 8
      @fx.spawn_burst(@p_x, @p_y - 26.0, C_RED, 12, 3.2)
      @fx.add_hitstop(5)
      @fx.add_shake(6.0)
      @fx.add_flash(C_RED, 3)
      @fx.spawn_popup("-#{dmg}", @p_x, @p_y - 60.0, C_RED, 16)
    end
    dmg
  end

  def start_cutin(title, sub, col, is_enemy, next_phase)
    @cutin_title = title
    @cutin_sub = sub
    @cutin_col = col
    @cutin_is_enemy = is_enemy
    @cutin_timer = 38
    @cutin_next_phase = next_phase
    @phase = :cutin
  end

  def update
    @frame += 1
    @fx.update_ambient(@run.stage_idx)
    @fx.update

    # 遅延追従HPバー更新
    @p_disp_hp = lerp_val(@p_disp_hp, @run.hp.to_f, 0.22)
    if @p_trail_hp > @p_disp_hp
      @p_trail_hp = lerp_val(@p_trail_hp, @p_disp_hp, 0.06)
    else
      @p_trail_hp = @p_disp_hp
    end

    @e_disp_hp = lerp_val(@e_disp_hp, @e_hp.to_f, 0.22)
    if @e_trail_hp > @e_disp_hp
      @e_trail_hp = lerp_val(@e_trail_hp, @e_disp_hp, 0.06)
    else
      @e_trail_hp = @e_disp_hp
    end

    # スクワッシュ＆ストレッチ復元
    @p_sx = lerp_val(@p_sx, 1.0, 0.18)
    @p_sy = lerp_val(@p_sy, 1.0, 0.18)
    @e_sx = lerp_val(@e_sx, 1.0, 0.18)
    @e_sy = lerp_val(@e_sy, 1.0, 0.18)
    @p_x  = lerp_val(@p_x, 156.0, 0.16)
    @e_x  = lerp_val(@e_x, 474.0, 0.16)

    if @p_pal_timer > 0
      @p_pal_timer -= 1
      @p_pal = nil if @p_pal_timer == 0
    end
    if @e_pal_timer > 0
      @e_pal_timer -= 1
      @e_pal = nil if @e_pal_timer == 0
    end

    return if @fx.hitstop > 0

    case @phase
    when :intro
      @phase_timer -= 1
      if @phase_timer <= 0
        @phase = :menu
      end

    when :menu
      @p_pose = :idle
      if btnp(:up)
        @menu_idx = (@menu_idx - 1) % 4
      elsif btnp(:down)
        @menu_idx = (@menu_idx + 1) % 4
      end

      if btnp(1)
        execute_main_menu(@menu_idx)
      end

    when :skill_menu
      skills = @run.skills
      if btnp(:up)
        @sub_idx = (@sub_idx - 1) % skills.size
      elsif btnp(:down)
        @sub_idx = (@sub_idx + 1) % skills.size
      elsif btnp(2)
        @phase = :menu
      elsif btnp(1)
        sk = SKILLS_DB[skills[@sub_idx]]
        if @run.sp >= sk[:cost]
          @run.sp -= sk[:cost]
          @timing_action = sk
          if sk[:kind] == :shield
            @p_shield += sk[:shield]
            @p_pose = :guard
            @fx.spawn_ring(@p_x, @p_y - 24.0, C_CYAN, 48, 16)
            @fx.spawn_popup("SHIELD +#{sk[:shield]}", @p_x, @p_y - 60.0, C_CYAN, 16)
            dmg = (sk[:power] * calc_player_attack_mult * (@run.has_relic?(:combo_scroll) ? 1.25 : 1.0)).round
            damage_enemy(dmg, false, false)
            push_log("#{sk[:name]}！盾+#{sk[:shield]}＆#{dmg}ダメージ")
            @phase = :player_resolve
            @phase_timer = 26
          elsif sk[:kind] == :mash
            @mash_count = 0
            @mash_timer = 85
            if sk[:cutin]
              start_cutin(sk[:name], "Z連打で炎弾を叩き込め！", C_ORANGE, false, :player_mash)
            else
              @phase = :player_mash
            end
          else
            @timing_pos = 0.0
            @timing_dir = 1.0
            @timing_speed = 0.029
            @timing_result = :none
            if sk[:cutin]
              start_cutin(sk[:name], "黄金ゾーンで [Z] 目押し！", C_YELLOW, false, :player_timing)
            else
              @phase = :player_timing
            end
          end
        else
          push_log("SPが足りない！（必要:#{sk[:cost]}）")
        end
      end

    when :item_menu
      items = available_items
      if items.empty?
        @phase = :menu
        return
      end
      if btnp(:up)
        @sub_idx = (@sub_idx - 1) % items.size
      elsif btnp(:down)
        @sub_idx = (@sub_idx + 1) % items.size
      elsif btnp(2)
        @phase = :menu
      elsif btnp(1)
        use_item(items[@sub_idx][:id])
      end

    when :player_timing
      @timing_pos += @timing_dir * @timing_speed
      if @timing_pos >= 1.0
        @timing_pos = 1.0
        @timing_dir = -1.0
      elsif @timing_pos <= 0.0
        @timing_pos = 0.0
        @timing_dir = 1.0
      end

      if btnp(1)
        dist = (@timing_pos - 0.5).abs
        @run.timing_attempts += 1
        if dist <= perfect_half_width
          @timing_result = :perfect
          @run.perfect_count += 1
        elsif dist <= good_half_width
          @timing_result = :good
        else
          @timing_result = :normal
        end
        resolve_player_timing
      end

    when :player_mash
      @mash_timer -= 1
      if btnp(1)
        @mash_count += 1
        @fx.spawn_burst(@p_x + 24.0, @p_y - 36.0, C_ORANGE, 4, 2.5, 0.05, 12)
      end
      if @mash_timer <= 0
        resolve_player_mash
      end

    when :cutin
      @cutin_timer -= 1
      if @cutin_timer <= 0
        @phase = @cutin_next_phase
      end

    when :player_resolve
      @phase_timer -= 1
      if @phase_timer <= 0
        if @e_hp <= 0
          on_victory
        else
          start_enemy_turn
        end
      end

    when :enemy_windup
      @phase_timer -= 1
      # ジャストガード受付判定
      if !@enemy_guard_pressed && (btnp(1) || btnp(2))
        @enemy_guard_pressed = true
        if @phase_timer <= @enemy_guard_window
          @enemy_guard_grade = :just
          @run.just_guard_count += 1
        elsif @phase_timer <= @enemy_guard_window + 16
          @enemy_guard_grade = :guard
        else
          @enemy_guard_grade = :miss
        end
      end

      if @phase_timer <= 0
        execute_enemy_hit
      end

    when :enemy_strike
      @phase_timer -= 1
      if @phase_timer <= 0
        if @run.hp <= 0
          @phase = :defeat
          @phase_timer = 55
        elsif @e_hp <= 0
          on_victory
        elsif @enemy_hit_idx < @enemy_total_hits
          prepare_next_enemy_hit
        else
          end_turn_cleanup
        end
      end

    when :victory
      @phase_timer -= 1
      if @phase_timer <= 0
        if @run.stage_idx >= STAGES.size - 1
          run ResultScene.new(@run, true)
        else
          run RewardScene.new(@run)
        end
      end

    when :defeat
      @phase_timer -= 1
      if @phase_timer <= 0
        run ResultScene.new(@run, false)
      end
    end
  end

  def execute_main_menu(idx)
    case idx
    when 0
      # こうげき
      @timing_action = { id: :basic_attack, name: "通常斬撃", kind: :basic, power: 18 }
      @timing_pos = 0.0
      @timing_dir = 1.0
      @timing_speed = 0.027
      @timing_result = :none
      @phase = :player_timing
    when 1
      # スキル
      @sub_idx = 0
      @phase = :skill_menu
    when 2
      # チャージ
      sp_gain = 2
      @run.sp += sp_gain
      @run.sp = @run.max_sp if @run.sp > @run.max_sp
      @p_shield += 8
      @p_charge_turns = 1
      @p_pose = :guard
      @fx.spawn_ring(@p_x, @p_y - 24.0, C_YELLOW, 46, 16)
      @fx.spawn_popup("CHARGE! SP+2", @p_x, @p_y - 64.0, C_YELLOW, 16)
      push_log("精神統一！SP+2・盾+8・次撃1.5倍")
      @phase = :player_resolve
      @phase_timer = 26
    when 3
      # アイテム
      if available_items.empty?
        push_log("使えるアイテムがない！")
      else
        @sub_idx = 0
        @phase = :item_menu
      end
    end
  end

  def available_items
    list = []
    list << { id: :potion, name: "ハイポーション", count: @run.potions, desc: "HPを35回復する" } if @run.potions > 0
    list << { id: :ether,  name: "エーテル結晶",   count: @run.ethers,  desc: "SPを+3回復する" } if @run.ethers > 0
    list << { id: :elixir, name: "剛力の秘薬",     count: @run.elixirs, desc: "2ターン与ダメ1.4倍" } if @run.elixirs > 0
    list
  end

  def use_item(item_id)
    case item_id
    when :potion
      @run.potions -= 1
      heal = 35
      @run.hp += heal
      @run.hp = @run.max_hp if @run.hp > @run.max_hp
      @fx.spawn_burst(@p_x, @p_y - 28.0, C_GREEN, 14, 2.8)
      @fx.spawn_popup("HP +#{heal}", @p_x, @p_y - 62.0, C_GREEN, 16)
      push_log("ハイポーションでHPが#{heal}回復！")
    when :ether
      @run.ethers -= 1
      @run.sp += 3
      @run.sp = @run.max_sp if @run.sp > @run.max_sp
      @fx.spawn_burst(@p_x, @p_y - 28.0, C_CYAN, 14, 2.8)
      @fx.spawn_popup("SP +3", @p_x, @p_y - 62.0, C_CYAN, 16)
      push_log("エーテル結晶でSPが3回復！")
    when :elixir
      @run.elixirs -= 1
      @p_elixir_turns = 2
      @fx.spawn_burst(@p_x, @p_y - 28.0, C_ORANGE, 14, 2.8)
      @fx.spawn_popup("ATK UP!", @p_x, @p_y - 62.0, C_ORANGE, 16)
      push_log("剛力の秘薬！2ターン与ダメ1.4倍！")
    end
    @phase = :player_resolve
    @phase_timer = 26
  end

  def resolve_player_timing
    @p_x = 220.0
    @p_pose = :atk
    @p_sx = 1.24
    @p_sy = 0.84

    mult = calc_player_attack_mult
    is_crit = (@timing_result == :perfect)
    crit_mul = is_crit ? calc_crit_mult : (@timing_result == :good ? 1.2 : 1.0)
    act = @timing_action

    if act[:kind] == :basic
      dmg = (act[:power] * mult * crit_mul).round
      if is_crit
        @run.sp += 1
        @run.sp = @run.max_sp if @run.sp > @run.max_sp
        @fx.spawn_popup("PERFECT! SP+1", @p_x, @p_y - 68.0, C_YELLOW, 16)
        push_log("PERFECT会心！#{dmg}ダメージ＆SP+1")
      elsif @timing_result == :good
        push_log("GOOD斬撃！#{dmg}ダメージ")
      else
        push_log("通常攻撃！#{dmg}ダメージ")
      end
      damage_enemy(dmg, is_crit, false)
    else
      skill_mul = @run.has_relic?(:combo_scroll) ? 1.25 : 1.0
      total = 0
      hits = act[:hits] || 1
      i = 0
      while i < hits
        h_mul = crit_mul
        if act[:id] == :twin_slash && i == 1 && is_crit
          h_mul = calc_crit_mult * 1.25
        end
        d = (act[:power] * mult * skill_mul * h_mul).round
        total += damage_enemy(d, is_crit, act[:breaks] && i == 0)
        i += 1
      end
      if act[:drain]
        ratio = is_crit ? 0.75 : 0.5
        heal = (total * ratio).round
        @run.hp += heal
        @run.hp = @run.max_hp if @run.hp > @run.max_hp
        @fx.spawn_popup("HP +#{heal}", @p_x, @p_y - 64.0, C_GREEN, 16)
      end
      tag = is_crit ? "PERFECT!" : (@timing_result == :good ? "GOOD!" : "")
      push_log("#{act[:name]} #{tag} 計#{total}ダメージ！")
    end

    @p_charge_turns = 0 if @p_charge_turns > 0
    @phase = :player_resolve
    @phase_timer = 32
  end

  def resolve_player_mash
    @p_x = 220.0
    @p_pose = :atk
    act = @timing_action
    hits = clamp_val(act[:min_hits] + (@mash_count / 3), act[:min_hits], act[:max_hits])
    mult = calc_player_attack_mult * (@run.has_relic?(:combo_scroll) ? 1.25 : 1.0)
    total = 0
    i = 0
    while i < hits
      d = (act[:power] * mult).round
      total += damage_enemy(d, i == hits - 1, false)
      i += 1
    end
    push_log("#{act[:name]} #{hits}連撃！計#{total}ダメージ！")
    @p_charge_turns = 0 if @p_charge_turns > 0
    @phase = :player_resolve
    @phase_timer = 34
  end

  def start_enemy_turn
    pat = @e_intent
    if pat[:kind] == :charge
      @e_shield += pat[:shield]
      @e_atk_bonus += pat[:atk_up]
      @e_sx = 0.85
      @e_sy = 1.22
      @fx.spawn_ring(@e_x, @e_y - 48.0, C_ORANGE, 56, 18)
      @fx.spawn_popup("CHARGE!", @e_x, @e_y - 84.0, C_ORANGE, 16)
      push_log("敵は#{pat[:name]}！盾+#{pat[:shield]} 攻撃+#{pat[:atk_up]}")
      @phase = :enemy_strike
      @enemy_hit_idx = 1
      @enemy_total_hits = 1
      @phase_timer = 28
    else
      @enemy_hit_idx = 0
      @enemy_total_hits = pat[:hits]
      if pat[:cutin]
        start_cutin(pat[:name], "インパクト直前に [Z/X] でジャストガード！", C_RED, true, :enemy_windup)
        prepare_next_enemy_hit_data
      else
        prepare_next_enemy_hit
      end
    end
  end

  def prepare_next_enemy_hit_data
    @enemy_hit_idx += 1
    @enemy_windup_len = 46 - (@run.stage_idx * 3)
    @phase_timer = @enemy_windup_len
    @enemy_guard_pressed = false
    @enemy_guard_grade = :none
  end

  def prepare_next_enemy_hit
    prepare_next_enemy_hit_data
    @phase = :enemy_windup
  end

  def execute_enemy_hit
    @e_x = 390.0
    @e_sx = 1.22
    @e_sy = 0.82
    raw = @e_intent[:dmg] + @e_atk_bonus
    grade = @enemy_guard_grade
    grade = :miss if grade == :none
    dmg = damage_player(raw, grade)

    if grade == :just
      @p_pose = :guard
      # ジャストガード報酬: SP+1 & カウンター反撃
      @run.sp += 1
      @run.sp = @run.max_sp if @run.sp > @run.max_sp
      counter = 14 + (@run.has_relic?(:azure_crest) ? 12 : 0)
      @p_shield += 6 if @run.has_relic?(:azure_crest)
      damage_enemy(counter, false, false)
      @fx.spawn_popup("COUNTER #{counter}!", @e_x, @e_y - 104.0, C_CYAN, 16)
      push_log("JUST GUARD! 被ダメ#{dmg} 反撃#{counter}＆SP+1")
    elsif grade == :guard
      @p_pose = :guard
      push_log("ガード成功！#{dmg}ダメージに軽減")
    else
      push_log("#{@e_intent[:name]}！#{dmg}ダメージを受けた")
    end

    @phase = :enemy_strike
    @phase_timer = 24
  end

  def end_turn_cleanup
    @run.total_turns += 1
    @p_elixir_turns -= 1 if @p_elixir_turns > 0
    if @run.has_relic?(:mana_core)
      @run.sp += 1
      @run.sp = @run.max_sp if @run.sp > @run.max_sp
    end
    # 次ターンの敵行動予兆を決定
    pats = @stage[:patterns]
    @e_pat_idx = (@e_pat_idx + 1 + rand(2)) % pats.size
    @e_intent = pats[@e_pat_idx]
    @phase = :menu
  end

  def on_victory
    @run.total_turns += 1
    heal = 18 + (@run.has_relic?(:phoenix_feather) ? 10 : 0)
    @run.hp += heal
    @run.hp = @run.max_hp if @run.hp > @run.max_hp
    @fx.spawn_burst(@e_x, @e_y - 48.0, C_YELLOW, 24, 4.5)
    @fx.spawn_ring(@e_x, @e_y - 48.0, C_WHITE, 72, 20)
    push_log("#{@stage[:boss_name]} を撃破！HP+#{heal}回復")
    @phase = :victory
    @phase_timer = 46
  end

  def draw
    cls(C_BLACK)
    bg(@stage[:bg], { fit: :screen, dim: 0.48, tint: @stage[:tint] })

    # カメラシェイク適用（bgには影響しない）
    camera(@fx.shake_x, @fx.shake_y)

    # HD-2D 風バトルステージ床（遠近グリッド）
    draw_stage_floor
    @fx.draw_ambient

    # キャラクター影
    ovalfill(@p_x, @p_y - 6.0, 32, 8, C_BLACK)
    ovalfill(@e_x, @e_y, @stage[:boss_w] * 1.25, 10, C_BLACK)

    # プレイヤー描画
    p_bob = sin(@frame * 0.08) * 2.0
    p_spr = spr_id(:hero, (@frame / 20) % 2)
    p_spr = spr_id(:hero_atk) if @p_pose == :atk
    p_spr = spr_id(:hero_guard) if @p_pose == :guard
    draw_spr_grounded(p_spr, @p_x, @p_y + p_bob, 24, 24, @p_sx, @p_sy, false, @p_pal)

    # 敵・ボス描画（撃破時は消滅演出）
    if @e_hp > 0 || (@phase == :victory && (@phase_timer % 4) < 2)
      e_bob = sin(@frame * 0.06 + 1.2) * 3.0
      e_spr = spr_id(@stage[:boss_spr], (@frame / 24) % 2)
      draw_spr_grounded(e_spr, @e_x, @e_y + e_bob, @stage[:boss_w], @stage[:boss_h], @e_sx, @e_sy, false, @e_pal)
    end

    # ジャストガード収束リング
    if @phase == :enemy_windup
      t = 1.0 - (@phase_timer.to_f / @enemy_windup_len)
      ring_r = lerp_val(84.0, 18.0, t)
      in_just = @phase_timer <= @enemy_guard_window
      r_col = in_just ? C_CYAN : (@phase_timer <= @enemy_guard_window + 16 ? C_YELLOW : C_RED)
      circ(@p_x, @p_y - 34.0, ring_r, r_col)
      circ(@p_x, @p_y - 34.0, 18, C_WHITE)
      if in_just
        draw_centered_text("NOW! [Z/X]", @p_x, @p_y - 94.0, C_CYAN, 16, true)
      else
        draw_centered_text("GUARD TIMING", @p_x, @p_y - 88.0, C_YELLOW, 8, true)
      end
    end

    @fx.draw_foreground

    # カットイン演出（clip使用）
    draw_cutin if @phase == :cutin

    # UIはシェイクさせず固定
    camera(0, 0)
    draw_top_ui
    draw_timing_bar if @phase == :player_timing
    draw_mash_bar if @phase == :player_mash
    draw_bottom_ui
  end

  def draw_stage_floor
    rectfill(0, 258, SCREEN_W, 70, C_BLACK)
    line(0, 258, SCREEN_W, 258, @stage[:floor_col1])
    y = 266
    step = 10
    while y < 328
      line(0, y, SCREEN_W, y, @stage[:floor_col2])
      y += step
      step += 4
    end
    # 遠近パースライン
    i = -4
    while i <= 4
      x_top = 320 + i * 52
      x_bot = 320 + i * 110
      line(x_top, 258, x_bot, 328, @stage[:floor_col2])
      i += 1
    end
  end

  def draw_cutin
    # 上下から帯が開くシネマティッククリップ演出
    open_t = clamp_val((38 - @cutin_timer) / 8.0, 0.0, 1.0)
    open_t = clamp_val(@cutin_timer / 8.0, 0.0, 1.0) if @cutin_timer < 8
    band_h = (92 * open_t).round
    return if band_h <= 2

    cy = 205
    by = cy - band_h / 2
    clip(0, by, SCREEN_W, band_h)
    rectfill(0, by, SCREEN_W, band_h, C_BLACK)

    # 高速スピードライン
    i = 0
    while i < 8
      ly = by + 6 + i * 11
      lx = ((@frame * 28 + i * 97) % (SCREEN_W + 180)) - 180
      rectfill(lx, ly, 160, 2, @cutin_col)
      i += 1
    end

    if @cutin_is_enemy
      e_spr = spr_id(@stage[:boss_spr], 0)
      draw_spr_centered(e_spr, 510, cy, @stage[:boss_w], @stage[:boss_h], 0.0, 1.6, 1.6, false, nil)
    else
      p_spr = spr_id(:hero_atk)
      draw_spr_centered(p_spr, 130, cy, 24, 24, 0.0, 1.8, 1.8, false, nil)
    end

    draw_centered_text(@cutin_title, 320, cy - 16, @cutin_col, 16, true)
    draw_centered_text(@cutin_sub, 320, cy + 12, C_WHITE, 8, true)
    clip()

    line(0, by, SCREEN_W, by, @cutin_col)
    line(0, by + band_h, SCREEN_W, by + band_h, @cutin_col)
  end

  def draw_timing_bar
    bx = 160
    by = 282
    bw = 320
    bh = 28
    rectfill(bx - 6, by - 20, bw + 12, bh + 26, C_BLACK)
    rect(bx - 6, by - 20, bw + 12, bh + 26, C_YELLOW)
    draw_centered_text("黄金ゾーンで [Z] 目押し！", 320, by - 14, C_WHITE, 8, true)

    rectfill(bx, by, bw, bh, C_DBLUE)
    # GOODゾーン
    gw = (bw * good_half_width * 2).round
    gx = 320 - gw / 2
    rectfill(gx, by + 2, gw, bh - 4, C_GREEN)
    # PERFECTゾーン
    pw = (bw * perfect_half_width * 2).round
    px = 320 - pw / 2
    rectfill(px, by + 2, pw, bh - 4, C_YELLOW)
    line(320, by, 320, by + bh, C_WHITE)

    # カーソル
    cx = bx + (bw * @timing_pos).round
    rectfill(cx - 3, by - 3, 6, bh + 6, C_WHITE)
    rect(cx - 3, by - 3, 6, bh + 6, C_RED)
  end

  def draw_mash_bar
    bx = 180
    by = 282
    bw = 280
    bh = 26
    rectfill(bx - 6, by - 20, bw + 12, bh + 26, C_BLACK)
    rect(bx - 6, by - 20, bw + 12, bh + 26, C_ORANGE)
    draw_centered_text("[Z] 連打！ (#{@mash_count} HIT)", 320, by - 14, C_YELLOW, 8, true)
    rectfill(bx, by, bw, bh, C_DBLUE)
    fill_w = clamp_val((bw * (@mash_count / 12.0)).round, 0, bw)
    rectfill(bx, by + 2, fill_w, bh - 4, C_ORANGE)
  end

  def draw_top_ui
    # 左：ステージ＆ビルド情報
    draw_pc98_window(12, 8, 282, 86, "STAGE #{@stage[:stage]}/4", C_LGREY, C_CYAN)
    draw_shadow_text(@stage[:area_name], 24, 24, C_YELLOW, 16)
    draw_shadow_text("TURN #{@run.total_turns + 1} | PERF #{@run.perfect_rate}% | JG #{@run.just_guard_count}", 24, 48, C_WHITE, 8)
    if @run.relics.empty?
      draw_shadow_text("RELIC: なし", 24, 66, C_LGREY, 8)
    else
      names = @run.relics.map { |id| RELICS_DB[id][:short] }.join(" / ")
      draw_shadow_text("RELIC: #{names}", 24, 66, C_CYAN, 8)
    end

    # 右：敵ステータス＆行動予兆
    draw_pc98_window(302, 8, 326, 86, "TARGET / INTENT", C_LGREY, C_PINK)
    draw_shadow_text(@stage[:boss_name], 314, 22, C_WHITE, 16)

    # 敵HPバー
    hp_x = 314
    hp_y = 44
    hp_w = 210
    hp_h = 10
    rectfill(hp_x, hp_y, hp_w, hp_h, C_DBLUE)
    trail_w = (hp_w * (@e_trail_hp / @e_max_hp)).round
    fill_w  = (hp_w * (@e_disp_hp / @e_max_hp)).round
    rectfill(hp_x, hp_y, trail_w, hp_h, C_WHITE) if trail_w > 0
    rectfill(hp_x, hp_y, fill_w, hp_h, C_RED) if fill_w > 0
    rect(hp_x, hp_y, hp_w, hp_h, C_LGREY)
    draw_shadow_text("#{@e_hp}/#{@e_max_hp}", hp_x + hp_w + 8, hp_y + 1, C_WHITE, 8)

    # シールド・バフ表示
    buff_str = ""
    buff_str += "盾:#{@e_shield} " if @e_shield > 0
    buff_str += "攻+#{@e_atk_bonus}" if @e_atk_bonus > 0
    draw_shadow_text(buff_str, 530, 24, C_ORANGE, 8) if buff_str != ""

    # 行動予兆 (INTENT)
    intent = @e_intent
    if intent[:kind] == :charge
      i_txt = "【予兆】#{intent[:name]} (盾+#{intent[:shield]}/強化)"
      i_col = C_ORANGE
    else
      dmg_val = intent[:dmg] + @e_atk_bonus
      hit_str = intent[:hits] > 1 ? "#{dmg_val}x#{intent[:hits]}" : "#{dmg_val}"
      i_txt = "【予兆】#{intent[:name]} (DMG #{hit_str})"
      i_col = intent[:cutin] ? C_RED : C_YELLOW
    end
    draw_shadow_text(i_txt, 314, 62, i_col, 8)
    draw_shadow_text(intent[:warn], 314, 74, C_LGREY, 8)
  end

  def draw_bottom_ui
    # 1. 左：プレイヤーHP・SP・バフ
    draw_pc98_window(12, BOT_WIN_Y, 196, BOT_WIN_H, "PLAYER", C_LGREY, C_CYAN)
    draw_shadow_text("クロノスブレイド", 24, BOT_WIN_Y + 14, C_WHITE, 16)

    # プレイヤーHPバー
    bx = 24
    by = BOT_WIN_Y + 38
    bw = 170
    bh = 10
    rectfill(bx, by, bw, bh, C_DBLUE)
    tw = (bw * (@p_trail_hp / @run.max_hp)).round
    fw = (bw * (@p_disp_hp / @run.max_hp)).round
    rectfill(bx, by, tw, bh, C_WHITE) if tw > 0
    rectfill(bx, by, fw, bh, C_GREEN) if fw > 0
    rect(bx, by, bw, bh, C_LGREY)
    draw_shadow_text("HP #{@run.hp}/#{@run.max_hp}", 24, BOT_WIN_Y + 52, C_GREEN, 8)

    # SP セルゲージ
    draw_shadow_text("SP #{@run.sp}/#{@run.max_sp}", 24, BOT_WIN_Y + 70, C_CYAN, 8)
    i = 0
    while i < @run.max_sp
      sx = 82 + i * 16
      sy = BOT_WIN_Y + 68
      col = i < @run.sp ? C_CYAN : C_DBLUE
      rectfill(sx, sy, 12, 10, col)
      rect(sx, sy, 12, 10, C_WHITE)
      i += 1
    end

    # バフ表示
    b_txt = ""
    b_txt += "盾:#{@p_shield} " if @p_shield > 0
    b_txt += "溜め " if @p_charge_turns > 0
    b_txt += "秘薬#{@p_elixir_turns}T" if @p_elixir_turns > 0
    draw_shadow_text(b_txt == "" ? "状態: 通常" : b_txt, 24, BOT_WIN_Y + 90, C_YELLOW, 8)
    draw_shadow_text("薬:#{@run.potions}  エ:#{@run.ethers}  秘:#{@run.elixirs}", 24, BOT_WIN_Y + 108, C_PEACH, 8)

    # 2. 中央：コマンドウィンドウ
    if @phase == :skill_menu
      draw_pc98_window(214, BOT_WIN_Y, 196, BOT_WIN_H, "SKILL (X:戻る)", C_CYAN, C_YELLOW)
      @run.skills.each_with_index do |sid, idx|
        sk = SKILLS_DB[sid]
        sel = idx == @sub_idx
        can_use = @run.sp >= sk[:cost]
        col = sel ? (can_use ? C_YELLOW : C_RED) : (can_use ? C_WHITE : C_DGREY)
        pre = sel ? "▶" : " "
        draw_shadow_text("#{pre}#{sk[:name]}", 224, BOT_WIN_Y + 16 + idx * 20, col, 8)
        draw_shadow_text("SP#{sk[:cost]}", 374, BOT_WIN_Y + 16 + idx * 20, C_CYAN, 8)
      end
    elsif @phase == :item_menu
      draw_pc98_window(214, BOT_WIN_Y, 196, BOT_WIN_H, "ITEM (X:戻る)", C_GREEN, C_YELLOW)
      items = available_items
      items.each_with_index do |it, idx|
        sel = idx == @sub_idx
        col = sel ? C_YELLOW : C_WHITE
        pre = sel ? "▶" : " "
        draw_shadow_text("#{pre}#{it[:name]} x#{it[:count]}", 224, BOT_WIN_Y + 20 + idx * 24, col, 8)
      end
    else
      draw_pc98_window(214, BOT_WIN_Y, 196, BOT_WIN_H, "COMMAND", C_LGREY, C_CYAN)
      cmds = ["こうげき", "スキル", "チャージ", "アイテム"]
      cmds.each_with_index do |label, idx|
        sel = (@phase == :menu && idx == @menu_idx)
        col = sel ? C_YELLOW : C_WHITE
        pre = sel ? "▶ " : "  "
        draw_shadow_text(pre + label, 232, BOT_WIN_Y + 18 + idx * 26, col, 16)
      end
    end

    # 3. 右：ログ＆コマンドガイド
    draw_pc98_window(416, BOT_WIN_Y, 212, BOT_WIN_H, "LOG / GUIDE", C_LGREY, C_CYAN)
    guide = "↑↓:選択  Z:決定  X:戻る"
    if @phase == :menu
      case @menu_idx
      when 0 then guide = "通常斬撃 (PERFECTでSP+1)"
      when 1 then guide = "SPを消費して強力スキル"
      when 2 then guide = "SP+2 / 盾+8 / 次撃1.5倍"
      when 3 then guide = "回復・強化アイテム使用"
      end
    elsif @phase == :skill_menu
      sk = SKILLS_DB[@run.skills[@sub_idx]]
      guide = sk[:desc]
    elsif @phase == :item_menu
      items = available_items
      guide = items[@sub_idx][:desc] if items[@sub_idx]
    end
    draw_shadow_text(guide, 426, BOT_WIN_Y + 16, C_YELLOW, 8)
    line(424, BOT_WIN_Y + 30, 618, BOT_WIN_Y + 30, C_DBLUE)

    @logs.each_with_index do |msg, idx|
      col = (idx == @logs.size - 1) ? C_WHITE : C_LGREY
      draw_shadow_text(msg, 426, BOT_WIN_Y + 38 + idx * 20, col, 8)
    end
  end
end

# ------------------------------------------------------------------------------
# 3択報酬シーン (RewardScene)
# ------------------------------------------------------------------------------
class RewardScene
  def initialize(run_data)
    @run = run_data
    @frame = 0
    @cursor = 0
    @choices = build_choices
  end

  def build_choices
    list = []

    # 1. 未習得スキル
    avail_skills = []
    SKILLS_DB.each do |k, v|
      avail_skills << v unless @run.skills.include?(k)
    end
    if avail_skills.size > 0 && @run.skills.size < 5
      sk = pick_random_items(avail_skills, 1)[0]
      list << {
        kind: :skill,
        data: sk,
        tag: "NEW SKILL",
        title: sk[:name],
        sub: "SP #{sk[:cost]}",
        desc1: sk[:desc],
        desc2: "戦術の幅が大きく広がる",
        col: C_YELLOW
      }
    end

    # 2. 未所持レリック
    avail_relics = []
    RELICS_DB.each do |k, v|
      avail_relics << v unless @run.has_relic?(k)
    end
    if avail_relics.size > 0
      rel = pick_random_items(avail_relics, 1)[0]
      list << {
        kind: :relic,
        data: rel,
        tag: "RELIC",
        title: rel[:name],
        sub: "パッシブ効果",
        desc1: rel[:desc],
        desc2: "永続的に能力を強化する",
        col: C_CYAN
      }
    end

    # 3. 補給＆最大HP強化パック（必ず1つ以上）
    while list.size < 3
      if list.size == 1
        list << {
          kind: :supply_atk,
          tag: "SUPPLY",
          title: "秘薬＆エーテル",
          sub: "補給パック",
          desc1: "剛力の秘薬+1 / エーテル+1",
          desc2: "さらにHPを30回復する",
          col: C_ORANGE
        }
      else
        list << {
          kind: :vitality,
          tag: "VITALITY",
          title: "生命の聖杯",
          sub: "HP強化＆回復",
          desc1: "最大HP+15 / HP全回復",
          desc2: "ハイポーション+1補充",
          col: C_GREEN
        }
      end
    end
    list
  end

  def update
    @frame += 1
    if btnp(:left)
      @cursor = (@cursor - 1) % @choices.size
    elsif btnp(:right)
      @cursor = (@cursor + 1) % @choices.size
    elsif btnp(1)
      apply_choice(@choices[@cursor])
      @run.stage_idx += 1
      @run.sp = 2 if @run.sp < 2
      run BattleScene.new(@run)
    end
  end

  def apply_choice(ch)
    case ch[:kind]
    when :skill
      @run.add_skill(ch[:data][:id])
    when :relic
      @run.add_relic(ch[:data][:id])
    when :supply_atk
      @run.elixirs += 1
      @run.ethers += 1
      @run.hp += 30
      @run.hp = @run.max_hp if @run.hp > @run.max_hp
    when :vitality
      @run.max_hp += 15
      @run.hp = @run.max_hp
      @run.potions += 1
    end
  end

  def draw
    cls(C_BLACK)
    bg(:space, { fit: :screen, dim: 0.55, scroll_x: @frame * 0.25, loop_x: true })

    draw_pc98_window(80, 24, 480, 74, "STAGE CLEAR!", C_YELLOW, C_CYAN)
    draw_centered_text("戦利品を選択してください", 320, 42, C_YELLOW, 16, true)
    draw_centered_text("← / → で選択   [Z] で決定して次のステージへ", 320, 70, C_WHITE, 8, true)

    @choices.each_with_index do |ch, idx|
      cx = 28 + idx * 198
      cy = 128
      cw = 188
      ch_h = 240
      sel = idx == @cursor
      b_col = sel ? ch[:col] : C_LGREY
      draw_pc98_window(cx, cy, cw, ch_h, ch[:tag], b_col, ch[:col])

      if sel
        rect(cx - 2, cy - 2, cw + 4, ch_h + 4, ch[:col])
        draw_centered_text("▼ SELECTED ▼", cx + cw / 2, cy - 18, ch[:col], 8, true)
      end

      draw_centered_text(ch[:title], cx + cw / 2, cy + 36, ch[:col], 16, true)
      draw_centered_text(ch[:sub], cx + cw / 2, cy + 72, C_WHITE, 8, true)
      line(cx + 16, cy + 94, cx + cw - 16, cy + 94, C_DBLUE)
      draw_centered_text(ch[:desc1], cx + cw / 2, cy + 124, C_WHITE, 8, true)
      draw_centered_text(ch[:desc2], cx + cw / 2, cy + 148, C_LGREY, 8, true)
    end

    draw_pc98_window(80, 396, 480, 58, "STATUS", C_LGREY, C_CYAN)
    draw_centered_text("HP: #{@run.hp}/#{@run.max_hp}   SP: #{@run.sp}/#{@run.max_sp}   スキル数: #{@run.skills.size}   レリック数: #{@run.relics.size}", 320, 420, C_WHITE, 8, true)
  end
end

# ------------------------------------------------------------------------------
# リザルトシーン (ResultScene)
# ------------------------------------------------------------------------------
class ResultScene
  def initialize(run_data, cleared)
    @run = run_data
    @cleared = cleared
    @frame = 0
    @rank = cleared ? @run.calc_rank : "D"
    if cleared
      $best_rank = @rank if $best_rank.nil?
      $best_turns = @run.total_turns if $best_turns.nil? || @run.total_turns < $best_turns
    end
  end

  def update
    @frame += 1
    if btnp(1)
      run BattleScene.new(PlayerRun.new)
    elsif btnp(2)
      run TitleScene.new
    end
  end

  def draw
    cls(C_BLACK)
    bg(@cleared ? :sky : :cave, { fit: :screen, dim: 0.55 })

    title_str = @cleared ? "ALL STAGES CLEARED!!" : "DEFEATED..."
    title_col = @cleared ? C_YELLOW : C_RED
    draw_pc98_window(90, 42, 460, 80, "CHRONO DUEL RESULT", title_col, C_CYAN)
    draw_centered_text(title_str, 320, 68, title_col, 16, true)
    draw_centered_text(@cleared ? "時空龍クロノスを打ち破り、世界に刻を取り戻した！" : "力尽きた… だが刻は再び巡る。", 320, 96, C_WHITE, 8, true)

    draw_pc98_window(110, 144, 420, 224, "BATTLE RECORD", C_LGREY, C_CYAN)
    draw_centered_text("CLEAR RANK : #{@rank}", 320, 174, C_YELLOW, 16, true)
    draw_shadow_text("総ターン数         : #{@run.total_turns} TURNS", 164, 218, C_WHITE, 16)
    draw_shadow_text("パーフェクト目押し率 : #{@run.perfect_rate}% (#{@run.perfect_count}/#{@run.timing_attempts})", 164, 248, C_CYAN, 8)
    draw_shadow_text("ジャストガード回数   : #{@run.just_guard_count} 回", 164, 270, C_GREEN, 8)
    draw_shadow_text("到達ステージ         : STAGE #{@run.stage_idx + 1} / 4", 164, 292, C_PEACH, 8)
    rel_names = @run.relics.empty? ? "なし" : @run.relics.map { |id| RELICS_DB[id][:short] }.join(" / ")
    draw_shadow_text("獲得レリック         : #{rel_names}", 164, 314, C_WHITE, 8)

    if (@frame / 25) % 2 == 0
      draw_centered_text("[Z] 即リトライ    [X] タイトルへ", 320, 404, C_YELLOW, 16, true)
    end
  end
end

run TitleScene.new

__END__
# ==============================================================================
# カスタムパレット定義
# ==============================================================================
# 1: 主人公クロノスブレイド（蒼銀甲冑＋紅マフラー＋黄金剣）
@PALETTE 1
0: #0E0C1C
1: #1C2B54
2: #9E1B3E
4: #8A4A32
5: #4A546E
6: #A4B4CC
7: #FFF8F0
8: #FF2454
9: #FF9C22
A: #FFE838
C: #34B4FF
D: #86D8FF
F: #FFD4B8

# 2: Stage 1 森の守護者シルヴァ・ゴーレム
@PALETTE 2
0: #0C1612
1: #1E2E26
3: #1B6B42
4: #5E4332
5: #46545C
6: #8896A0
7: #E8F6EC
9: #FF9A28
A: #FFE648
B: #44BA58
C: #8BE872
F: #B6C4BC

# 3: Stage 2 炎騎士イグニス・ナイト
@PALETTE 3
0: #1C0A14
1: #481422
2: #8C1A2A
4: #6A2610
6: #B06050
7: #FFF6DC
8: #FF2438
9: #FF7818
A: #FFDA38
C: #45D1FF
F: #FFE8A0

# 4: Stage 3 機甲将軍アーク・ジェネラル
@PALETTE 4
0: #0A0E1C
1: #1C2848
2: #581C58
5: #38486C
6: #7E96BC
7: #F0F8FF
8: #FF226E
9: #FF9933
A: #FFEE44
B: #00E896
C: #28C8FF
D: #90EAFF

# 5: Stage 4 時空龍クロノス・ドラゴン
@PALETTE 5
0: #0A0816
1: #1A163C
2: #641448
5: #343062
6: #706EAA
7: #F4FBFF
8: #FF1855
9: #FF8822
A: #FFE44D
C: #00D8FF
D: #8CF2FF
E: #FF66B2
F: #B8BEFF

# 10..13: エフェクトオーバーライド用
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
# スプライト定義
# ==============================================================================
@SPRITE :hero 24x24 pal:1
........0000000.........
......00CCCCC00.........
.....0CCDDDDDCC0........
....0CC77DDDDDCC0.......
....0C111111111C0.......
....01FFFFFFFFFF0.......
....01FF07FF07FF0.......
....01FF01FF01FF0.......
.....0FFFFFFFFFF0.......
..00000888888800........
.08822011666110..00.....
08220.016777610.0A70....
.000..0166A66100AA0.....
.....0116666610A90......
.....011111111090.......
.....05551155500........
.....0565005650.........
.....0111001110.........
.....0161001610.........
....01110..01110........
....0000....0000........
........................
........................
........................
---
........0000000.........
......00CCCCC00.........
.....0CCDDDDDCC0........
....0CC77DDDDDCC0.......
....0C111111111C0.......
....01FFFFFFFFFF0.......
....01FF07FF07FF0.......
....01FF01FF01FF0.......
.....0FFFFFFFFFF0.......
.000000888888800........
088220011666110...00....
.0220.016777610..0A70...
......0166A6610.0AA0....
.....01166666100A90.....
.....0111111110090......
.....055511555000.......
.....0565005650.........
.....0111001110.........
.....0161001610.........
....01110..01110........
....0000....0000........
........................
........................
........................

@SPRITE :hero_atk 24x24 pal:1
........0000000.........
......00CCCCC00.........
.....0CCDDDDDCC0........
....0CC77DDDDDCC0.......
....0C111111111C0.......
....01FFFFFFFFFF0.......
....01FF07FF07FF0.......
....01FF01FF01FF0.......
.....0FFFFFFFFFF0.......
.000000888888800........
0882200116661100000000..
.000..016777610AA777770.
......0166A661099AAAA90.
.....01166666100000000..
.....0111111110.........
.....0555115550.........
.....0565005650.........
....01110..01110........
...01610....01610.......
..01110......01110......
..0000........0000......
........................
........................
........................

@SPRITE :hero_guard 24x24 pal:1
........0000000.........
......00CCCCC00.........
.....0CCDDDDDCC0........
....0CC77DDDDDCC0.......
....0C111111111C0.......
....01FFFFFFFFFF0.......
....01FF07FF07FF0.......
....01FF01FF01FF0.......
.....0FFFFFFFFFF0..0000.
.....00888888800..0CC7C0
....01166666610..0CD77C0
....01677766610..0CDDCC0
....0166A666610..0C1CC10
....01166666610..0C11110
.....0111111110...01110.
.....0555115550....000..
.....0565005650.........
.....0111001110.........
.....0161001610.........
....01110..01110........
....0000....0000........
........................
........................
........................

@SPRITE :slash_fx 24x24 pal:12
................00000...
.............000AAAA0...
..........000AAA777A0...
........00AA777777A0....
......00AA77777AA00.....
.....0AA77777AA00.......
....0A77777AA00.........
...0A7777AA00...........
..0A777AA00.............
..0A77A00...............
.0A77A0.................
.0A7A0..................
.0AA0...................
.000....................
........................
........................
........................
........................
........................
........................
........................
........................
........................
........................
---
........................
........................
............000000......
.........000AAAAAA0.....
.......00AAA7777AA0.....
.....00AA77777AA00......
....0AA7777AAA00........
...0A7777AA00...........
..0A777AA00.............
..0A77A00...............
.0A7A00.................
.0A0....................
........................
........................
........................
........................
........................
........................
........................
........................
........................
........................
........................
........................

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
0036FD10000099AAAA99000001DF6300
0B36FD100009AA7777AA900001DF63B0
0B56FD100009A777777A900001DF65B0
0556FD10000099AAAA99000001DF6550
056FFD11000000000000000011DFF650
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

@SPRITE :boss_knight 32x32 pal:3
..............000000............
............00AA99AA00..........
...........0AA77FF77AA0.........
..........0A9888888889A0........
.........0988228888228890.......
........098211111111112890......
........082100000000001280......
........082100A7007A001280......
........0821009A00A9001280......
.........0810000000000180.......
........008811111111118800......
......009AA88889AA98888AA900....
.....09A77A8889A77A9888A77A90...
....098888822889AA988228888890..
...088221122888888888221122880..
..008210..02882288228820..01280.
.0A700....08821122112880...000..
0A790.....08210011001280........
0980......0210.09A0.0120........
.00.......088009AA900880........
.........0882008888002880.......
........088210022220012880......
........08210.088880.01280......
.......08820..082280..02880.....
.......08210..021120..01280.....
......08820...021120...02880....
......02210...011110...01220....
.....08820....010010....02880...
.....02210....00..00....01220...
.....0110................0110...
.....000..................000...
................................
---
..............000000............
............00AA99AA00..........
...........0AA77FF77AA0.........
..........0A9888888889A0........
.........0988228888228890.......
........098211111111112890......
........082100000000001280......
........0821007A00A7001280......
........082100AA00AA001280......
.........0810000000000180.......
........008811111111118800......
......009AA88889AA98888AA900....
.....09A77A8889A77A9888A77A90...
....098888822889AA988228888890..
...088221122888888888221122880..
..008210..02882288228820..01280.
.0AA00....08821122112880...000..
0AA90.....08210011001280........
0980......0210.0AA0.0120........
.00.......088009AA900880........
.........0882008888002880.......
........088210022220012880......
........08210.088880.01280......
.......08820..082280..02880.....
.......08210..021120..01280.....
......08820...021120...02880....
......02210...011110...01220....
.....08820....010010....02880...
.....02210....00..00....01220...
.....0110................0110...
.....000..................000...
................................

@SPRITE :boss_general 32x32 pal:4
.....0000.............0000......
....09AA90...000000...09AA90....
...099AA990.05677650.099AA990...
...05566550056777765005566550...
..056777765567CCC7655567777650..
..05676676557C7DD7755567667650..
..05665566557CDDDD755566556650..
..0155555515677777765155555510..
...01155110566777766501155110...
..0056666501566666651056666500..
.056777776501555555105677777650.
05676666765501155110556766667650
05665511566556666665556655115660
056511CC156567777776556511CC1560
05511CDDC1567688886765511CDDC150
01511CCCC1566887788665111CCCC150
01151111115668888886651111111110
.0115555555566288266555555555110
..00115566555662266555665511100.
...056677776556666555677776650..
...056766676511551155676667650..
...05565556510011001565556550...
....011555110.0550.011555110....
.....0011100..0660..0011100.....
.....056650...0550...056650.....
....05677650..0110..05677650....
....05666650...00...05666650....
....01555510........01555510....
.....0BBBB0..........0BBBB0.....
.....07BB70..........07BB70.....
......0BB0............0BB0......
.......00..............00.......
---
.....0000.............0000......
....0AA990...000000...0AA990....
...09AAA990.05677650.09AAA990...
...05566550056777765005566550...
..056777765567DDDD755567777650..
..05676676557D7777D55567667650..
..05665566557D7CC7D55566556650..
..0155555515677777765155555510..
...01155110566777766501155110...
..0056666501566666651056666500..
.056777776501555555105677777650.
05676666765501155110556766667650
05665511566556666665556655115660
056511DD156567777776556511DD1560
05511D77D1567688886765511D77D150
01511CDDC1566877778665111CDDC150
01151111115668777786651111111110
.0115555555566888866555555555110
..00115566555668866555665511100.
...056677776556666555677776650..
...056766676511551155676667650..
...05565556510011001565556550...
....011555110.0550.011555110....
.....0011100..0660..0011100.....
.....056650...0550...056650.....
....05677650..0110..05677650....
....05666650...00...05666650....
....01555510........01555510....
.....07BB70..........07BB70.....
.....0BBBB0..........0BBBB0.....
......0770............0770......
.......00..............00.......

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

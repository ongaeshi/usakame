# ==============================================================================
# USAKAME SURVIVORS (うさかめサバイバーズ)
# Full-Featured Roguelite Survival Action for Usakame Retro Game Engine
# 実行コマンド: uk run game.rb  または  uk browser game.rb
# ==============================================================================
# 【操作方法 / CONTROLS】
#   矢印キー / WASD : 移動 (Move)
#   Z / Space (btn4): フォーム固有スキル (🐰ウサギ: 無敵ブリンク / 🐢カメ: 甲羅スピン粉砕)
#   X / Enter (btn5): うさかめタッグ切替 (ゲージMAXで切替バースト衝撃波！)
# ==============================================================================

# --- ゲーム状態定数 ---
STATE_TITLE    = 0
STATE_PLAY     = 1
STATE_LEVELUP  = 2
STATE_GAMEOVER = 3
STATE_VICTORY  = 4

WORLD_W = 512
WORLD_H = 512
MAP_CELLS = 32

# --- 三角関数ルックアップテーブル (15度刻み 24方向, -100..100 整数) ---
$COS24 = [100, 97, 87, 71, 50, 26, 0, -26, -50, -71, -87, -97, -100, -97, -87, -71, -50, -26, 0, 26, 50, 71, 87, 97]
$SIN24 = [0, 26, 50, 71, 87, 97, 100, 97, 87, 71, 50, 26, 0, -26, -50, -71, -87, -97, -100, -97, -87, -71, -50, -26]

# --- パレットテーブル ---
$FLASH_PAL  = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]
$SUNSET_PAL = [0, 2, 2, 4, 4, 2, 15, 7, 8, 9, 10, 9, 14, 2, 14, 15]
$NIGHT_PAL  = [0, 0, 1, 1, 2, 1, 13, 7, 8, 9, 10, 3, 12, 5, 14, 6]

# --- アップグレード定義 (0..7) ---
$UPG_ICONS = ["🥕", "🛡️", "⚡", "🔥", "🌙", "🧲", "❤️", "⭐"]
$UPG_NAMES = [
  "キャロットバルカン",
  "ガーディアンシェル",
  "サンダーボルト",
  "フレイムオーラ",
  "ムーンブーメラン",
  "俊足＆マグネット",
  "バイタリティ装甲",
  "うさかめ絆の紋章"
]
$UPG_DESCS = [
  "ウサギ連射弾の数と威力が強化",
  "周囲を回る守護甲羅の数と速度UP",
  "敵の頭上に高威力の落雷を落とす",
  "足元に灼熱の魔法陣を展開し焼く",
  "敵群を切り裂く回転三日月刃を放つ",
  "移動速度とジェム吸引範囲が拡大",
  "最大HP+30＆HP40回復＋防御強化",
  "全ダメージ+25%＆切替バースト強化"
]

# --- グローバル変数初期化 ($t はエンジンの基本テスト互換のため毎フレーム +1) ---
$t = 0
$rng_seed = 20261017
$state = STATE_TITLE
$high_score = 0
$best_frames = 0
$cleared_once = false
$endless_mode = false

# 入力エッジ検出用
$prev_b0 = false
$prev_b1 = false
$prev_b2 = false
$prev_b3 = false
$prev_b4 = false
$prev_b5 = false
$btnp0 = false
$btnp1 = false
$btnp2 = false
$btnp3 = false
$btnp4 = false
$btnp5 = false

# プレイヤー状態 (座標 px, py はピクセル整数、px10, py10 は 1/10px 固定小数点整数)
$px = 248
$py = 248
$px10 = 2480
$py10 = 2480
$dir_x10 = 10
$dir_y10 = 0
$flip_x = false
$form = 0          # 0: 🐰ウサギ (USAGI), 1: 🐢カメ (KAME)
$tag_gauge = 100   # 0..100 (100でX切替するとタッグバースト発動)
$tag_buff = 0      # タッグバースト後の攻撃速度バフ残りフレーム
$hp = 100
$max_hp = 100
$inv_timer = 0
$skill_timer = 0   # ダッシュ / 甲羅スピン持続中タイマー
$skill_cd = 0      # スキルクールダウン
$shake = 0
$cam_x = 128
$cam_y = 128

# 進行・スコア・ビルド状態
$run_frames = 0
$wave = 1
$lv = 1
$exp = 0
$next_exp = 10
$score = 0
$kills = 0
$upg_lv = [1, 1, 0, 0, 0, 0, 0, 0]
$choices = [0, 1, 2]
$cursor = 0
$boss_spawned_w3 = false
$boss_spawned_w5 = false
$boss_warning = 0

# ウェポン発射タイマー
$cd_carrot = 0
$cd_thunder = 0
$cd_moon = 0
$cd_aura = 0
$shell_angle = 0

# エンティティ配列 (すべて整数演算で高速・安全に管理)
# 弾: [x10, y10, vx10, vy10, dmg, life, kind, pierce, rot]
#   kind: 0=🥕キャロット, 1=🌙ムーン刃, 2=✨バースト星弾, 3=🔥敵魔弾
$bullets = []
# 敵: [x10, y10, hp, max_hp, kind, flash, timer]
#   kind: 0=👾スライム, 1=🦇バット, 2=💀スケルトン, 3=👻ファントム, 4=🧙メイジ, 5=👹オーガ王, 6=🐉カオス竜
$enemies = []
# アイテム・ジェム: [x, y, kind, val, life]
#   kind: 0=小ジェム(青), 1=中ジェム(黄), 2=大ジェム(💎), 3=🍎リンゴ, 4=🧲スター, 5=💣ボム
$items = []
# パーティクル: [x10, y10, vx10, vy10, col, life, radius]
$particles = []
# 電撃エフェクト: [x0, y0, x1, y1, life]
$lightnings = []
# フローティングテキスト: [x, y, text, col, life]
$popups = []

# ==============================================================================
# サウンド (効果音・BGM の定義はファイル末尾のデータセクションの @SFX / @MUSIC)
#   ch0: プレイヤー行動 / ch1: アイテム取得 / ch2: 敵撃破 / ch3: 爆発・ボス
# ==============================================================================
$se_last = [-99, -99, -99, -99]

# 同一チャンネルで gap フレーム以内の連打を間引いて効果音を鳴らす（大量撃破・大量取得時の音割れ防止）
def se(id, ch, gap)
  if $t - $se_last[ch] >= gap
    $se_last[ch] = $t
    sfx(id, ch)
  end
end

music(0)

# ==============================================================================
# ユーティリティ関数 (100% 整数演算)
# ==============================================================================
def rand_int(max)
  return 0 if max <= 0
  $rng_seed = ($rng_seed * 1103515245 + 12345) & 0x7fffffff
  $rng_seed % max
end

def rand_range(min_v, max_v)
  span = max_v - min_v + 1
  return min_v if span <= 0
  min_v + rand_int(span)
end

def clamp_val(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

def cos_idx(idx)
  $COS24[idx % 24]
end

def sin_idx(idx)
  $SIN24[idx % 24]
end

def isqrt(n)
  return 0 if n <= 0
  x = n
  y = (x + 1) / 2
  while y < x
    x = y
    y = (x + n / x) / 2
  end
  x
end

def keep_last(arr, max_len)
  return arr if arr.length <= max_len
  out = []
  start_idx = arr.length - max_len
  i = start_idx
  while i < arr.length
    out.push(arr[i])
    i += 1
  end
  out
end

def update_input_edges
  b0 = btn(0)
  b1 = btn(1)
  b2 = btn(2)
  b3 = btn(3)
  b4 = btn(4)
  b5 = btn(5)

  $btnp0 = b0 && ($prev_b0 == false)
  $btnp1 = b1 && ($prev_b1 == false)
  $btnp2 = b2 && ($prev_b2 == false)
  $btnp3 = b3 && ($prev_b3 == false)
  $btnp4 = b4 && ($prev_b4 == false)
  $btnp5 = b5 && ($prev_b5 == false)

  $prev_b0 = b0
  $prev_b1 = b1
  $prev_b2 = b2
  $prev_b3 = b3
  $prev_b4 = b4
  $prev_b5 = b5
end

# ==============================================================================
# フィールド生成 & タイルマップ判定 (mget / mset / map)
# ==============================================================================
def setup_arena_map
  ty = 0
  while ty < MAP_CELLS
    tx = 0
    while tx < MAP_CELLS
      tile = nil
      if tx == 0 || ty == 0 || tx == MAP_CELLS - 1 || ty == MAP_CELLS - 1
        tile = 2 # 外周の石壁
      elsif (tx == 8 || tx == 23) && (ty == 8 || ty == 23)
        tile = 2 # 四隅の石柱
      elsif (tx == 15 || tx == 16) && (ty == 15 || ty == 16)
        tile = 5 # 中央の癒やしの泉
      else
        r = (tx * 37 + ty * 73 + $rng_seed) % 100
        if r < 6
          tile = 3 # 木箱 (破壊可能)
        elsif r < 10
          tile = 4 # 鉱石岩 (カメのスピン等で破壊可能)
        elsif r < 15
          tile = 6 # 加速の花畑
        elsif r < 28
          tile = 7 # 草むら装飾
        end
      end
      # プレイヤー初期位置周辺 (13..18, 13..18) は障害物を置かない
      if tx >= 13 && tx <= 18 && ty >= 13 && ty <= 18
        if tile == 2 || tile == 3 || tile == 4
          tile = nil
        end
      end
      if tile.nil?
        mdel(tx, ty)
      else
        mset(tx, ty, tile)
      end
      tx += 1
    end
    ty += 1
  end
end

def solid_tile?(t)
  t == 2 || t == 3 || t == 4
end

def break_tile_at(tx, ty)
  t = mget(tx, ty)
  if t == 3 || t == 4
    mdel(tx, ty)
    wx = tx * 16 + 8
    wy = ty * 16 + 8
    spawn_burst_particles(wx, wy, (t == 3) ? 9 : 12, 8)
    $score += (t == 3) ? 30 : 80
    roll = rand_int(100)
    if t == 4
      spawn_item(wx - 6, wy - 6, 2, 15) # 鉱石岩からは大ジェム💎確定
      add_popup(wx - 8, wy - 8, "💎ORE!", 12)
    elsif roll < 25
      spawn_item(wx - 6, wy - 6, 3, 25) # 🍎回復リンゴ
      add_popup(wx - 8, wy - 8, "🍎HEAL!", 8)
    elsif roll < 35
      spawn_item(wx - 6, wy - 6, 4, 1)  # 🧲マグネットスター
      add_popup(wx - 8, wy - 8, "🧲STAR!", 10)
    else
      spawn_item(wx - 6, wy - 6, 1, 5)  # 中ジェム
    end
    return true
  end
  false
end

def can_walk?(nx, ny, break_crates)
  x0 = (nx + 3) / 16
  y0 = (ny + 4) / 16
  x1 = (nx + 12) / 16
  y1 = (ny + 13) / 16

  pts = [[x0, y0], [x1, y0], [x0, y1], [x1, y1]]
  i = 0
  while i < 4
    tx = pts[i][0]
    ty = pts[i][1]
    t = mget(tx, ty)
    if break_crates && (t == 3 || (t == 4 && $form == 1))
      break_tile_at(tx, ty)
      t = nil
    end
    return false if solid_tile?(t)
    i += 1
  end
  true
end

# ==============================================================================
# エフェクト・アイテム・エンティティ生成
# ==============================================================================
def add_popup(x, y, text, col)
  if $popups.length >= 16
    $popups = keep_last($popups, 15)
  end
  $popups.push([x, y, text, col, 26])
end

def spawn_particle(x, y, vx10, vy10, col, life, radius)
  if $particles.length >= 48
    $particles = keep_last($particles, 40)
  end
  $particles.push([x * 10, y * 10, vx10, vy10, col, life, radius])
end

def spawn_burst_particles(cx, cy, col, count)
  i = 0
  while i < count
    ang = rand_int(24)
    spd10 = 10 + rand_int(22)
    vx10 = (cos_idx(ang) * spd10) / 100
    vy10 = (sin_idx(ang) * spd10) / 100
    r = (i % 2 == 0) ? 2 : 1
    spawn_particle(cx, cy, vx10, vy10, col, 10 + rand_int(10), r)
    i += 1
  end
end

def spawn_item(x, y, kind, val)
  if $items.length >= 45
    # 既存の先頭アイテムに価値を統合して負荷を抑える
    $items[0][3] += val
    return
  end
  $items.push([x, y, kind, val, 900])
end

def spawn_bullet(x, y, vx10, vy10, dmg, life, kind, pierce, rot)
  if $bullets.length >= 38
    $bullets = keep_last($bullets, 32)
  end
  $bullets.push([x * 10, y * 10, vx10, vy10, dmg, life, kind, pierce, rot])
end

def spawn_enemy(kind, x, y)
  return if $enemies.length >= 38 && kind < 5
  # 0:👾スライム, 1:🦇バット, 2:💀スケルトン, 3:👻ファントム, 4:🧙メイジ, 5:👹オーガ王, 6:🐉カオスドラゴン
  wave_mul = 10 + ($wave - 1) * 3 + ($endless_mode ? ($run_frames / 1800) * 5 : 0)
  hp = 18
  if kind == 0
    hp = (16 * wave_mul) / 10
  elsif kind == 1
    hp = (11 * wave_mul) / 10
  elsif kind == 2
    hp = (34 * wave_mul) / 10
  elsif kind == 3
    hp = (26 * wave_mul) / 10
  elsif kind == 4
    hp = (28 * wave_mul) / 10
  elsif kind == 5
    hp = 420 + $lv * 25
  elsif kind == 6
    hp = 1100 + $lv * 45
  end
  $enemies.push([x * 10, y * 10, hp, hp, kind, 0, rand_int(60)])
end

# ==============================================================================
# ゲーム開始・リセット & レベルアップ抽選
# ==============================================================================
def start_new_game
  $state = STATE_PLAY
  $endless_mode = false
  $px = 248
  $py = 248
  $px10 = 2480
  $py10 = 2480
  $dir_x10 = 10
  $dir_y10 = 0
  $flip_x = false
  $form = 0
  $tag_gauge = 100
  $tag_buff = 0
  $max_hp = 100
  $hp = 100
  $inv_timer = 30
  $skill_timer = 0
  $skill_cd = 0
  $shake = 0

  $run_frames = 0
  $wave = 1
  $lv = 1
  $exp = 0
  $next_exp = 8
  $score = 0
  $kills = 0
  # 初期装備: キャロットバルカンLv1 + ガーディアンシェルLv1
  $upg_lv = [1, 1, 0, 0, 0, 0, 0, 0]
  $boss_spawned_w3 = false
  $boss_spawned_w5 = false
  $boss_warning = 0

  $cd_carrot = 0
  $cd_thunder = 0
  $cd_moon = 0
  $cd_aura = 0
  $shell_angle = 0

  $bullets = []
  $enemies = []
  $items = []
  $particles = []
  $lightnings = []
  $popups = []

  setup_arena_map
  sfx(14, 0)
  music(1)
  add_popup($px - 16, $py - 12, "SURVIVE! 🐰🐢", 10)
end

def roll_levelup_choices
  pool = []
  i = 0
  while i < 8
    if $upg_lv[i] < 5
      pool.push(i)
    end
    i += 1
  end
  if pool.length < 3
    pool = [0, 1, 2, 3, 4, 5, 6, 7]
  end

  k = 0
  while k < 3
    r = k + rand_int(pool.length - k)
    tmp = pool[k]
    pool[k] = pool[r]
    pool[r] = tmp
    k += 1
  end

  $choices = [pool[0], pool[1], pool[2]]
  $cursor = 0
end

def apply_upgrade(upg_id)
  $upg_lv[upg_id] += 1
  if upg_id == 6
    $max_hp += 30
    $hp += 40
    $hp = $max_hp if $hp > $max_hp
  else
    $hp += 10
    $hp = $max_hp if $hp > $max_hp
  end
  spawn_burst_particles($px + 8, $py + 8, 10, 12)
  add_popup($px - 14, $py - 14, "UPGRADE! #{$UPG_ICONS[upg_id]}", 11)
end

def gain_exp(amount)
  $exp += amount
  $score += amount * 5
  if $exp >= $next_exp
    $exp -= $next_exp
    $lv += 1
    $next_exp = 8 + ($lv * 6) + (($lv * $lv) / 2)
    $shake = 6
    sfx(12, 0)
    roll_levelup_choices
    $state = STATE_LEVELUP
  end
end

# ==============================================================================
# 戦闘・ウェポン・スキル処理
# ==============================================================================
def dmg_multiplier
  mul = 100 + ($upg_lv[7] * 25)
  mul += 30 if $tag_buff > 0
  mul
end

def scale_dmg(base)
  (base * dmg_multiplier) / 100
end

def find_nearest_enemy(cx, cy, max_dist)
  best_idx = -1
  best_d2 = max_dist * max_dist
  i = 0
  while i < $enemies.length
    e = $enemies[i]
    ex = (e[0] / 10) + 8
    ey = (e[1] / 10) + 8
    dx = ex - cx
    dy = ey - cy
    d2 = dx * dx + dy * dy
    if d2 < best_d2
      best_d2 = d2
      best_idx = i
    end
    i += 1
  end
  best_idx
end

def trigger_tag_switch
  $form = ($form == 0) ? 1 : 0
  $inv_timer = 15 if $inv_timer < 15
  spawn_burst_particles($px + 8, $py + 8, ($form == 0) ? 14 : 11, 10)

  if $tag_gauge >= 100
    # タッグバースト発動！全方位に星弾＋周囲の敵に大ダメージ＆ノックバック
    $tag_gauge = 0
    $tag_buff = 150 + $upg_lv[7] * 30
    $shake = 10
    sfx(6, 0)
    add_popup($px - 20, $py - 16, "⚡TAG BURST!⚡", 10)
    burst_dmg = scale_dmg(22 + $lv * 3)

    k = 0
    while k < 8
      ang = k * 3
      vx10 = (cos_idx(ang) * 38) / 100
      vy10 = (sin_idx(ang) * 38) / 100
      spawn_bullet($px, $py, vx10, vy10, burst_dmg, 36, 2, 3, k * 45)
      k += 1
    end

    i = 0
    while i < $enemies.length
      e = $enemies[i]
      ex = e[0] / 10
      ey = e[1] / 10
      dx = ex - $px
      dy = ey - $py
      d2 = dx * dx + dy * dy
      if d2 < 64 * 64
        e[2] -= burst_dmg
        e[5] = 8
        dist = isqrt(d2)
        dist = 1 if dist < 1
        e[0] += (dx * 180) / dist
        e[1] += (dy * 180) / dist
        add_popup(ex, ey - 6, "#{burst_dmg}", 10)
      end
      i += 1
    end
  else
    sfx(5, 0)
    add_popup($px - 12, $py - 10, ($form == 0) ? "🐰USAGI!" : "🐢KAME!", ($form == 0) ? 14 : 11)
  end
end

def trigger_active_skill
  $skill_timer = ($form == 0) ? 12 : 26
  cd_base = ($form == 0) ? 48 : 68
  cd_red = $upg_lv[5] * 5
  $skill_cd = clamp_val(cd_base - cd_red, 22, 80)
  $inv_timer = $skill_timer + 6
  $shake = 5

  if $form == 0
    # 🐰 ラビット・ブリンク: 残像と星屑の渦を残して高速移動
    sfx(3, 0)
    add_popup($px - 10, $py - 10, "💨BLINK!", 12)
    spawn_burst_particles($px + 8, $py + 8, 12, 10)
    spawn_bullet($px, $py, -$dir_x10, -$dir_y10, scale_dmg(18 + $lv * 2), 35, 2, 4, 0)
  else
    # 🐢 シェル・スピン: 周囲の岩・木箱を粉砕し、体当たりオーラを展開
    sfx(4, 0)
    add_popup($px - 14, $py - 10, "🛡️SHELL SPIN!", 11)
    spawn_burst_particles($px + 8, $py + 8, 11, 12)
    cx = ($px + 8) / 16
    cy = ($py + 8) / 16
    dy = -1
    while dy <= 1
      dx = -1
      while dx <= 1
        break_tile_at(cx + dx, cy + dy)
        dx += 1
      end
      dy += 1
    end
  end
end

def update_weapons
  cx = $px + 8
  cy = $py + 8
  haste = ($tag_buff > 0) ? 2 : 1
  form_fire_bonus = ($form == 0) ? 1 : 0

  # 1. 🥕 キャロットバルカン (ID 0)
  if $upg_lv[0] > 0
    $cd_carrot -= (1 + form_fire_bonus + ($upg_lv[0] / 3))
    if $cd_carrot <= 0
      $cd_carrot = clamp_val(26 - $upg_lv[0] * 3 - ($tag_buff > 0 ? 6 : 0), 8, 30)
      lv = $upg_lv[0]
      dmg = scale_dmg(10 + lv * 4 + (($form == 0) ? 4 : 0))
      pierce = 1 + (lv / 2)

      ni = find_nearest_enemy(cx, cy, 180)
      bx100 = $dir_x10 * 10
      by100 = $dir_y10 * 10
      if ni >= 0
        tx = ($enemies[ni][0] / 10 + 8) - cx
        ty = ($enemies[ni][1] / 10 + 8) - cy
        d = isqrt(tx * tx + ty * ty)
        if d > 0
          bx100 = (tx * 100) / d
          by100 = (ty * 100) / d
        end
      end

      shots = (lv == 1) ? 1 : ((lv == 2) ? 2 : ((lv <= 4) ? 3 : 5))
      s = 0
      while s < shots
        # 扇状スプレッド (-2, -1, 0, 1, 2)
        sp_idx = s - (shots / 2)
        svx10 = ((bx100 - (by100 * sp_idx) / 4) * 44) / 100
        svy10 = ((by100 + (bx100 * sp_idx) / 4) * 44) / 100
        spawn_bullet($px, $py, svx10, svy10, dmg, 48, 0, pierce, 0)
        s += 1
      end
    end
  end

  # 2. 🛡️ ガーディアンシェル (ID 1): 回転角度更新 & 接触ダメージ判定
  if $upg_lv[1] > 0
    lv = $upg_lv[1]
    spin_spd = 5 + lv + (($form == 1) ? 3 : 0)
    $shell_angle = ($shell_angle + spin_spd) % 360
    shells = 1 + (lv / 2) + (($form == 1) ? 1 : 0)
    rad = 26 + (($form == 1) ? 8 : 0)
    shell_dmg = scale_dmg(8 + lv * 4 + (($form == 1) ? 5 : 0))

    if ($t % 8) == 0
      s = 0
      while s < shells
        ang24 = (($shell_angle / 15) + (s * 24) / shells) % 24
        sx = cx + (cos_idx(ang24) * rad) / 100
        sy = cy + (sin_idx(ang24) * rad) / 100
        break_tile_at(sx / 16, sy / 16) if $form == 1
        i = 0
        while i < $enemies.length
          e = $enemies[i]
          ex = (e[0] / 10) + 8
          ey = (e[1] / 10) + 8
          dx = ex - sx
          dy = ey - sy
          if (dx * dx + dy * dy) < 16 * 16
            e[2] -= shell_dmg
            e[5] = 4
            add_popup(ex - 8, ey - 12, "#{shell_dmg}", 11)
          end
          i += 1
        end
        s += 1
      end
    end
  end

  # 3. ⚡ サンダーボルト (ID 2): ランダムな敵に落雷＋範囲ダメージ
  if $upg_lv[2] > 0
    $cd_thunder -= haste
    if $cd_thunder <= 0 && $enemies.length > 0
      lv = $upg_lv[2]
      $cd_thunder = clamp_val(75 - lv * 10, 24, 80)
      strikes = 1 + (lv / 2)
      dmg = scale_dmg(24 + lv * 10)
      k = 0
      while k < strikes && $enemies.length > 0
        ei = rand_int($enemies.length)
        target = $enemies[ei]
        tx = (target[0] / 10) + 8
        ty = (target[1] / 10) + 8
        $lightnings.push([tx, ty - 96, tx, ty, 12])
        spawn_burst_particles(tx, ty, 10, 8)
        $shake = 4 if $shake < 4
        j = 0
        while j < $enemies.length
          e2 = $enemies[j]
          ex2 = (e2[0] / 10) + 8
          ey2 = (e2[1] / 10) + 8
          dx = ex2 - tx
          dy = ey2 - ty
          if dx * dx + dy * dy < 28 * 28
            e2[2] -= dmg
            e2[5] = 6
            add_popup(ex2 - 8, ey2 - 14, "⚡#{dmg}", 10)
          end
          j += 1
        end
        k += 1
      end
    end
  end

  # 4. 🔥 フレイムオーラ (ID 3) + 🐢 カメ形態の重装震撃オーラ
  aura_lv = $upg_lv[3]
  has_kame_slam = ($form == 1) || ($skill_timer > 0)
  if aura_lv > 0 || has_kame_slam
    $cd_aura -= 1
    if $cd_aura <= 0
      $cd_aura = ($skill_timer > 0) ? 6 : 18
      aura_r = 28 + aura_lv * 7 + (($form == 1) ? 10 : 0)
      dmg = scale_dmg(5 + aura_lv * 4 + (($form == 1) ? 6 : 0) + (($skill_timer > 0) ? 10 : 0))
      i = 0
      while i < $enemies.length
        e = $enemies[i]
        ex = (e[0] / 10) + 8
        ey = (e[1] / 10) + 8
        dx = ex - cx
        dy = ey - cy
        if dx * dx + dy * dy <= aura_r * aura_r
          e[2] -= dmg
          e[5] = 3
          add_popup(ex - 8, ey - 12, "#{dmg}", 9)
          if $skill_timer > 0 && $form == 1
            dist = isqrt(dx * dx + dy * dy)
            dist = 1 if dist < 1
            e[0] += (dx * 100) / dist
            e[1] += (dy * 100) / dist
          end
        end
        i += 1
      end
    end
  end

  # 5. 🌙 ムーンブーメラン (ID 4)
  if $upg_lv[4] > 0
    $cd_moon -= haste
    if $cd_moon <= 0
      lv = $upg_lv[4]
      $cd_moon = clamp_val(62 - lv * 8, 22, 65)
      dmg = scale_dmg(16 + lv * 6)
      count = 1 + (lv / 3)
      c = 0
      while c < count
        ang = (($t / 3) + c * 12) % 24
        vx10 = (cos_idx(ang) * 36) / 100
        vy10 = (sin_idx(ang) * 36) / 100
        spawn_bullet($px, $py, vx10, vy10, dmg, 70, 1, 99, 0)
        c += 1
      end
    end
  end
end

# ==============================================================================
# 弾・敵・アイテム・ウェーブ進行の更新
# ==============================================================================
def update_bullets
  next_bullets = []
  i = 0
  while i < $bullets.length
    b = $bullets[i]
    # ムーンブーメラン(kind==1)は後半プレイヤーに向かって戻ってくる
    if b[6] == 1 && b[5] < 38
      dx = $px - (b[0] / 10)
      dy = $py - (b[1] / 10)
      d = isqrt(dx * dx + dy * dy)
      if d > 0
        b[2] = (b[2] * 88) / 100 + (dx * 6) / d
        b[3] = (b[3] * 88) / 100 + (dy * 6) / d
      end
    end

    b[0] += b[2]
    b[1] += b[3]
    b[5] -= 1
    b[8] = (b[8] + 18) % 360

    bx = b[0] / 10
    by = b[1] / 10
    alive = true

    if b[5] <= 0 || bx < 8 || bx > WORLD_W - 24 || by < 8 || by > WORLD_H - 24
      alive = false
    end

    if alive && b[6] == 3
      # 敵魔弾 (kind == 3) はプレイヤーとの当たり判定
      dx = ($px + 8) - (bx + 8)
      dy = ($py + 8) - (by + 8)
      if dx * dx + dy * dy < 10 * 10
        damage_player(b[4])
        alive = false
      end
    elsif alive
      # プレイヤー弾で木箱・鉱石岩を壊す判定
      tx = (bx + 8) / 16
      ty = (by + 8) / 16
      tile = mget(tx, ty)
      if tile == 3 || (tile == 4 && b[6] != 0)
        break_tile_at(tx, ty)
        b[7] -= 1
        alive = false if b[7] <= 0
      elsif tile == 2 && b[6] == 0
        spawn_particle(bx + 8, by + 8, 0, 0, 9, 6, 2)
        alive = false
      end

      # 敵との当たり判定
      if alive
        j = 0
        while j < $enemies.length
          e = $enemies[j]
          hit_r = (e[4] >= 5) ? 18 : 12
          ex = e[0] / 10
          ey = e[1] / 10
          dx = (ex + 8) - (bx + 8)
          dy = (ey + 8) - (by + 8)
          if dx * dx + dy * dy < hit_r * hit_r
            e[2] -= b[4]
            e[5] = 4
            add_popup(ex, ey - 4, "#{b[4]}", (b[6] == 2) ? 10 : 7)
            spawn_particle(ex + 8, ey + 8, b[2] / 3, b[3] / 3, 8, 8, 2)
            b[7] -= 1
            if b[7] <= 0
              alive = false
              break
            end
          end
          j += 1
        end
      end
    end

    if alive
      next_bullets.push(b)
    end
    i += 1
  end
  $bullets = next_bullets
end

def damage_player(raw_dmg)
  return if $inv_timer > 0
  dmg = raw_dmg - $upg_lv[6] * 2
  if $form == 1
    dmg = (dmg + 1) / 2
  end
  dmg = 1 if dmg < 1

  $hp -= dmg
  $inv_timer = 32
  $shake = 8
  sfx(2, 0)
  spawn_burst_particles($px + 8, $py + 8, 8, 10)
  add_popup($px - 4, $py - 10, "-#{dmg}", 8)

  if $hp <= 0
    $hp = 0
    if $score > $high_score
      $high_score = $score
    end
    if $run_frames > $best_frames
      $best_frames = $run_frames
    end
    $state = STATE_GAMEOVER
    stop_music
    sfx(16, 0)
  end
end

def update_waves_and_spawns
  $run_frames += 1
  $boss_warning -= 1 if $boss_warning > 0

  if $run_frames < 1800
    $wave = 1
  elsif $run_frames < 3600
    $wave = 2
  elsif $run_frames < 5400
    $wave = 3
  elsif $run_frames < 7200
    $wave = 4
  else
    $wave = 5
  end

  # Wave 3 中ボス「👹オーガキング」出現
  if $wave >= 3 && ($boss_spawned_w3 == false)
    $boss_spawned_w3 = true
    $boss_warning = 120
    $shake = 12
    bx = clamp_val($px + 96, 48, WORLD_W - 64)
    by = clamp_val($py - 64, 48, WORLD_H - 64)
    spawn_enemy(5, bx, by)
    sfx(9, 3)
    music(2)
    add_popup($px - 28, $py - 20, "⚠️BOSS: OGRE KING!👹", 8)
  end

  # Wave 5 最終ボス「🐉カオスドラゴン」出現
  if $wave >= 5 && ($boss_spawned_w5 == false)
    $boss_spawned_w5 = true
    $boss_warning = 150
    $shake = 16
    bx = clamp_val($px - 96, 48, WORLD_W - 64)
    by = clamp_val($py - 80, 48, WORLD_H - 64)
    spawn_enemy(6, bx, by)
    sfx(9, 3)
    music(2)
    add_popup($px - 32, $py - 20, "⚠️FINAL BOSS: DRAGON!🐉", 8)
  end

  spawn_interval = clamp_val(52 - $wave * 7, 14, 52)
  if ($run_frames % spawn_interval) == 0
    ang = rand_int(24)
    dist = 135 + rand_int(35)
    sx = clamp_val($px + (cos_idx(ang) * dist) / 100, 24, WORLD_W - 40)
    sy = clamp_val($py + (sin_idx(ang) * dist) / 100, 24, WORLD_H - 40)

    roll = rand_int(100)
    kind = 0
    if $wave == 1
      kind = (roll < 70) ? 0 : 1
    elsif $wave == 2
      kind = (roll < 40) ? 0 : ((roll < 75) ? 1 : 2)
    elsif $wave == 3
      kind = (roll < 30) ? 1 : ((roll < 70) ? 2 : 3)
    elsif $wave == 4
      kind = (roll < 25) ? 2 : ((roll < 65) ? 3 : 4)
    else
      kind = (roll < 20) ? 1 : ((roll < 45) ? 2 : ((roll < 75) ? 3 : 4))
    end
    spawn_enemy(kind, sx, sy)
  end
end

def update_enemies
  next_enemies = []
  victory_triggered = false
  i = 0
  while i < $enemies.length
    e = $enemies[i]
    kind = e[4]
    e[5] -= 1 if e[5] > 0
    e[6] += 1

    ex = e[0] / 10
    ey = e[1] / 10

    if e[2] <= 0
      # 撃破処理
      $kills += 1
      $tag_gauge = clamp_val($tag_gauge + 8, 0, 100)
      spawn_burst_particles(ex + 8, ey + 8, (kind >= 5) ? 10 : 8, (kind >= 5) ? 20 : 7)

      if kind == 6
        # 🐉 最終ボス撃破！
        $score += 5000
        $shake = 20
        sfx(10, 3)
        $cleared_once = true
        if $score > $high_score
          $high_score = $score
        end
        if $run_frames > $best_frames
          $best_frames = $run_frames
        end
        if $endless_mode == false
          victory_triggered = true
        else
          music(1)
          add_popup(ex, ey, "🐉DRAGON SLAIN! +5000", 10)
        end
      elsif kind == 5
        # 👹 中ボス撃破！
        $score += 1500
        $shake = 14
        sfx(10, 3)
        music(1)
        spawn_item(ex, ey, 2, 30)
        spawn_item(ex + 10, ey, 3, 50)
        spawn_item(ex - 10, ey, 5, 1)
        add_popup(ex - 12, ey - 8, "👹BOSS DOWN! +1500", 10)
      else
        se(1, 2, 3)
        $score += 25 + kind * 15
        r = rand_int(100)
        if r < 4
          spawn_item(ex, ey, 3, 25)
        elsif r < 6
          spawn_item(ex, ey, 5, 1)
        elsif kind >= 2 && r < 45
          spawn_item(ex, ey, 1, 4 + kind)
        else
          spawn_item(ex, ey, 0, 2 + (kind / 2))
        end
      end
      i += 1
      next
    end

    # 移動AI (1/10px 単位の速度 spd10)
    dx = $px - ex
    dy = $py - ey
    dist = isqrt(dx * dx + dy * dy)
    dist = 1 if dist < 1

    spd10 = 9
    if kind == 0
      spd10 = 9
    elsif kind == 1
      spd10 = 15 # 🦇高速バット
    elsif kind == 2
      spd10 = 8  # 💀重装スケルトン
    elsif kind == 3
      spd10 = 11 # 👻壁抜けファントム
    elsif kind == 4
      spd10 = (dist < 85) ? 4 : 9 # 🧙メイジ
    elsif kind == 5
      spd10 = ((e[6] % 120) < 35) ? 21 : 8
    elsif kind == 6
      spd10 = ((e[6] % 150) < 40) ? 19 : 10
    end

    nx10 = e[0] + (dx * spd10) / dist
    ny10 = e[1] + (dy * spd10) / dist

    if kind == 3 || kind >= 5
      e[0] = nx10
      e[1] = ny10
    else
      tx = ((nx10 / 10) + 8) / 16
      ty = ((ny10 / 10) + 8) / 16
      if solid_tile?(mget(tx, ty)) == false
        e[0] = nx10
        e[1] = ny10
      else
        e[0] += (dy * spd10) / (dist * 2)
        e[1] -= (dx * spd10) / (dist * 2)
      end
    end

    # 遠距離攻撃AI (🧙メイジ / 👹オーガ王 / 🐉カオスドラゴン)
    if kind == 4 && (e[6] % 110) == 0 && dist < 160
      vx10 = (dx * 21) / dist
      vy10 = (dy * 21) / dist
      spawn_bullet(ex, ey, vx10, vy10, 12, 95, 3, 1, 0)
    elsif kind == 5 && (e[6] % 95) == 0
      k = 0
      while k < 4
        ang = ((e[6] / 5) + k * 6) % 24
        spawn_bullet(ex, ey, (cos_idx(ang) * 23) / 100, (sin_idx(ang) * 23) / 100, 16, 80, 3, 1, 0)
        k += 1
      end
    elsif kind == 6 && (e[6] % 80) == 0
      k = 0
      while k < 6
        ang = ((e[6] / 4) + k * 4) % 24
        spawn_bullet(ex, ey, (cos_idx(ang) * 26) / 100, (sin_idx(ang) * 26) / 100, 18, 90, 3, 1, 0)
        k += 1
      end
    end

    # プレイヤーとの接触判定
    touch_r = (kind >= 5) ? 15 : 10
    if dist < touch_r
      if $skill_timer > 0 && $form == 1
        e[2] -= scale_dmg(6)
        e[5] = 3
      else
        touch_dmg = 8 + kind * 3
        damage_player(touch_dmg)
      end
    end

    next_enemies.push(e)
    i += 1
  end
  $enemies = next_enemies
  if victory_triggered
    $state = STATE_VICTORY
    stop_music
    sfx(15, 0)
  end
end

def update_items
  magnet_r = 36 + $upg_lv[5] * 18 + (($form == 0) ? 10 : 0)
  next_items = []
  attract_all = false
  i = 0
  while i < $items.length
    it = $items[i]
    it[4] -= 1
    if it[4] <= 0
      i += 1
      next
    end

    dx = $px - it[0]
    dy = $py - it[1]
    d2 = dx * dx + dy * dy

    if d2 < magnet_r * magnet_r
      d = isqrt(d2)
      d = 1 if d < 1
      pull = 4 + ($upg_lv[5] / 2)
      it[0] += (dx * pull) / d
      it[1] += (dy * pull) / d
    end

    if d2 < 12 * 12
      kind = it[2]
      val = it[3]
      if kind <= 2
        gain_exp(val)
        se(0, 1, 3)
        $tag_gauge = clamp_val($tag_gauge + 3, 0, 100)
      elsif kind == 3
        $hp = clamp_val($hp + val, 0, $max_hp)
        sfx(7, 1)
        add_popup($px - 8, $py - 10, "+#{val}HP🍎", 11)
        spawn_burst_particles($px + 8, $py + 8, 11, 8)
      elsif kind == 4
        sfx(11, 1)
        add_popup($px - 16, $py - 12, "🧲ALL ATTRACT!", 10)
        attract_all = true
      elsif kind == 5
        $shake = 12
        sfx(8, 3)
        add_popup($px - 16, $py - 12, "💣MEGA BOMB!", 8)
        j = 0
        while j < $enemies.length
          $enemies[j][2] -= scale_dmg(85)
          $enemies[j][5] = 8
          j += 1
        end
      end
    else
      next_items.push(it)
    end
    i += 1
  end

  if attract_all
    k = 0
    while k < next_items.length
      if next_items[k][2] <= 2
        next_items[k][0] = $px + rand_range(-4, 4)
        next_items[k][1] = $py + rand_range(-4, 4)
      end
      k += 1
    end
  end

  $items = next_items
end

def update_particles_and_effects
  next_p = []
  i = 0
  while i < $particles.length
    p = $particles[i]
    p[0] += p[2]
    p[1] += p[3]
    p[5] -= 1
    if p[5] > 0
      next_p.push(p)
    end
    i += 1
  end
  $particles = next_p

  next_l = []
  j = 0
  while j < $lightnings.length
    lt = $lightnings[j]
    lt[4] -= 1
    if lt[4] > 0
      next_l.push(lt)
    end
    j += 1
  end
  $lightnings = next_l

  next_pop = []
  k = 0
  while k < $popups.length
    pp = $popups[k]
    pp[1] -= 1 if ($t % 2) == 0
    pp[4] -= 1
    if pp[4] > 0
      next_pop.push(pp)
    end
    k += 1
  end
  $popups = next_pop
end

# ==============================================================================
# メイン update ループ
# ==============================================================================
def update
  $t += 1
  update_input_edges

  if $state == STATE_TITLE
    if $btnp4 || $btnp5
      start_new_game
    end
    return
  end

  if $state == STATE_LEVELUP
    if $btnp0 || $btnp2
      $cursor = ($cursor - 1) % 3
      sfx(13, 0)
    elsif $btnp1 || $btnp3
      $cursor = ($cursor + 1) % 3
      sfx(13, 0)
    elsif $btnp4 || $btnp5
      apply_upgrade($choices[$cursor])
      sfx(14, 0)
      $state = STATE_PLAY
    end
    return
  end

  if $state == STATE_GAMEOVER
    update_particles_and_effects
    if $btnp4 || $btnp5
      start_new_game
    end
    return
  end

  if $state == STATE_VICTORY
    update_particles_and_effects
    if ($t % 12) == 0
      fx = $cam_x + 32 + rand_int(192)
      fy = $cam_y + 40 + rand_int(140)
      spawn_burst_particles(fx, fy, 8 + rand_int(7), 10)
    end
    if $btnp4
      $endless_mode = true
      $state = STATE_PLAY
      sfx(14, 0)
      music(1)
      add_popup($px - 24, $py - 12, "🔥ENDLESS MODE!🔥", 10)
    elsif $btnp5
      $state = STATE_TITLE
      music(0)
    end
    return
  end

  # --- STATE_PLAY (メインゲーム進行) ---
  $inv_timer -= 1 if $inv_timer > 0
  $skill_timer -= 1 if $skill_timer > 0
  $skill_cd -= 1 if $skill_cd > 0
  $tag_buff -= 1 if $tag_buff > 0
  $shake -= 1 if $shake > 0
  if ($t % 10) == 0 && $tag_gauge < 100
    $tag_gauge += 1
  end

  if $btnp5
    trigger_tag_switch
  end

  if $btnp4 && $skill_cd <= 0
    trigger_active_skill
  end

  # 移動入力 (ix10, iy10 は -10, 0, 10)
  ix10 = 0
  iy10 = 0
  if btn(0)
    ix10 -= 10
    $flip_x = true
  end
  if btn(1)
    ix10 += 10
    $flip_x = false
  end
  if btn(2)
    iy10 -= 10
  end
  if btn(3)
    iy10 += 10
  end

  if ix10 != 0 || iy10 != 0
    if ix10 != 0 && iy10 != 0
      ix10 = (ix10 * 7) / 10
      iy10 = (iy10 * 7) / 10
    end
    $dir_x10 = ix10
    $dir_y10 = iy10
  end

  # 現在のタイル効果チェック (5:癒やしの泉, 6:加速の花畑)
  pcx = ($px + 8) / 16
  pcy = ($py + 8) / 16
  under_tile = mget(pcx, pcy)
  if under_tile == 5 && ($t % 45) == 0 && $hp < $max_hp
    $hp = clamp_val($hp + 2, 0, $max_hp)
    spawn_particle($px + 8, $py + 8, 0, -8, 12, 14, 2)
  end

  # 1/10px 単位の移動速度 (ウサギ=24, カメ=16)
  base_spd10 = ($form == 0) ? 24 : 16
  spd_bonus10 = $upg_lv[5] * 2 + ((under_tile == 6) ? 6 : 0) + (($tag_buff > 0) ? 4 : 0)
  move_spd10 = base_spd10 + spd_bonus10

  if $skill_timer > 0
    if $form == 0
      move_spd10 = 52
      ix10 = $dir_x10
      iy10 = $dir_y10
      if ($t % 2) == 0
        spawn_particle($px + 8, $py + 8, 0, 0, 12, 10, 3)
      end
    else
      move_spd10 += 14
      if ($t % 3) == 0
        spawn_particle($px + 8, $py + 8, rand_range(-10, 10), rand_range(-10, 10), 11, 8, 2)
      end
    end
  end

  break_on_touch = ($skill_timer > 0)
  nx10 = $px10 + (ix10 * move_spd10) / 10
  ny10 = $py10 + (iy10 * move_spd10) / 10
  nx = nx10 / 10
  ny = ny10 / 10

  if can_walk?(nx, $py, break_on_touch)
    $px10 = clamp_val(nx10, 160, (WORLD_W - 32) * 10)
    $px = $px10 / 10
  end
  if can_walk?($px, ny, break_on_touch)
    $py10 = clamp_val(ny10, 160, (WORLD_H - 32) * 10)
    $py = $py10 / 10
  end

  # カメラ追従 + 画面シェイク
  tcx = clamp_val($px - 120, 0, WORLD_W - 256)
  tcy = clamp_val($py - 116, 0, WORLD_H - 240)
  sh_x = ($shake > 0) ? ((($t % 2) == 0) ? 2 : -2) : 0
  sh_y = ($shake > 0) ? (((($t / 2) % 2) == 0) ? 2 : -2) : 0
  $cam_x = tcx + sh_x
  $cam_y = tcy + sh_y

  update_weapons
  update_bullets
  update_waves_and_spawns
  update_enemies
  update_items
  update_particles_and_effects
end

# ==============================================================================
# 描画処理 (draw_world / draw_hud / draw_overlays)
# ==============================================================================
def apply_wave_palette
  pal()
  if $wave == 3 || $wave == 4
    pal($SUNSET_PAL)
  elsif $wave >= 5
    pal($NIGHT_PAL)
  end
end

def draw_world
  bg_col = ($wave >= 5) ? 0 : (($wave >= 3) ? 2 : 3)
  grid_col = ($wave >= 5) ? 1 : (($wave >= 3) ? 4 : 11)
  rectfill(0, 0, WORLD_W, WORLD_H, bg_col)

  g = 64
  while g < WORLD_W
    line(g, 16, g, WORLD_H - 16, grid_col)
    line(16, g, WORLD_W - 16, g, grid_col)
    g += 64
  end
  oval(256, 256, 44, 44, grid_col)
  oval(256, 256, 40, 40, 12)

  # タイルマップ描画 (32x32 セル)
  apply_wave_palette
  map(0, 0, 0, 0, MAP_CELLS, MAP_CELLS)
  pal()

  # 🔥 フレイムオーラ & 🐢 カメ震撃リング (oval / circ)
  pcx = $px + 8
  pcy = $py + 8
  if $upg_lv[3] > 0 || $form == 1 || $skill_timer > 0
    aura_r = 28 + $upg_lv[3] * 7 + (($form == 1) ? 10 : 0)
    pulse = ($t % 12) / 3
    aura_col = ($skill_timer > 0) ? 10 : (($upg_lv[3] > 0) ? 9 : 11)
    circ(pcx, pcy, aura_r - pulse, aura_col)
    oval(pcx, pcy, aura_r, aura_r - 4, ($upg_lv[3] > 0) ? 8 : 12)
  end

  # アイテム・ジェム描画
  i = 0
  while i < $items.length
    it = $items[i]
    ix = it[0]
    iy = it[1]
    kind = it[2]
    bob = (($t + ix) / 8) % 2
    if kind == 0
      circfill(ix + 6, iy + 6 - bob, 3, 12)
      pset(ix + 5, iy + 5 - bob, 7)
    elsif kind == 1
      circfill(ix + 6, iy + 6 - bob, 4, 10)
      circ(ix + 6, iy + 6 - bob, 4, 9)
      pset(ix + 5, iy + 4 - bob, 7)
    elsif kind == 2
      spr("💎", ix, iy - bob)
    elsif kind == 3
      spr("🍎", ix, iy - bob)
    elsif kind == 4
      spr("🧲", ix, iy - bob)
    elsif kind == 5
      spr("💣", ix, iy - bob)
    end
    i += 1
  end

  # 敵軍団の描画 (足元の楕円影 ovalfill + 被弾白フラッシュ pal + スケール spr)
  j = 0
  while j < $enemies.length
    e = $enemies[j]
    ex = e[0] / 10
    ey = e[1] / 10
    kind = e[4]
    flash = e[5]

    shadow_rx = (kind >= 5) ? 11 : 6
    shadow_ry = (kind >= 5) ? 4 : 2
    ovalfill(ex + 8, ey + 15, shadow_rx, shadow_ry, 0)

    if flash > 0
      pal($FLASH_PAL)
    elsif kind == 3 && (($t / 6) % 2 == 0)
      palt(7, true)
    end

    emoji = "👾"
    if kind == 1
      emoji = "🦇"
    elsif kind == 2
      emoji = "💀"
    elsif kind == 3
      emoji = "👻"
    elsif kind == 4
      emoji = "🧙"
    elsif kind == 5
      emoji = "👹"
    elsif kind == 6
      emoji = "🐉"
    end

    ebounce = ((($t + ex) / 6) % 2 == 0) ? 0 : -2
    eflip = ($px < ex)
    if kind == 6
      spr(emoji, ex, ey + ebounce, eflip, false, 0, 2.0)
    elsif kind == 5
      spr(emoji, ex, ey + ebounce, eflip, false, 0, 1.75)
    else
      spr(emoji, ex, ey + ebounce, eflip, false, 0, 1.0)
    end

    if flash > 0 || kind == 3
      pal()
      palt()
    end

    if kind >= 5 || e[2] < e[3]
      bw = (kind >= 5) ? 28 : 14
      bx = ex + 8 - (bw / 2)
      by = ey - ((kind >= 5) ? 8 : 4)
      rectfill(bx, by, bw, 3, 0)
      fill_w = (e[2] * bw) / e[3]
      fill_w = 1 if fill_w < 1 && e[2] > 0
      rectfill(bx, by, fill_w, 3, (kind >= 5) ? 8 : 11)
    end
    j += 1
  end

  # プレイヤーの描画
  ovalfill(pcx, pcy + 7, 7, 3, 0)
  if ($inv_timer % 4) < 2
    if $tag_buff > 0 && (($t % 4) == 0)
      pal(7, 10)
    end
    pbounce = (($t / 6) % 2 == 0) ? 0 : -2
    prot = ($skill_timer > 0 && $form == 1) ? (($t * 28) % 360) : 0
    if $skill_timer > 0
      spr($form, $px, $py + pbounce, $flip_x, false, prot, 1.25)
    else
      spr($form, $px, $py + pbounce, $flip_x, false, prot, 1.0)
    end
    pal()
  end

  # 🛡️ ガーディアンシェルの公転描画
  if $upg_lv[1] > 0
    lv = $upg_lv[1]
    shells = 1 + (lv / 2) + (($form == 1) ? 1 : 0)
    rad = 26 + (($form == 1) ? 8 : 0)
    s = 0
    while s < shells
      ang24 = (($shell_angle / 15) + (s * 24) / shells) % 24
      sx = pcx - 8 + (cos_idx(ang24) * rad) / 100
      sy = pcy - 8 + (sin_idx(ang24) * rad) / 100
      spr("🛡️", sx, sy, false, false, ($t * 10) % 360, 0.9)
      s += 1
    end
  end

  # 弾の描画
  b_idx = 0
  while b_idx < $bullets.length
    b = $bullets[b_idx]
    bx = b[0] / 10
    by = b[1] / 10
    bkind = b[6]
    if bkind == 0
      spr("🥕", bx, by, false, false, ($t * 15) % 360, 0.85)
    elsif bkind == 1
      spr("🌙", bx, by, false, false, b[8], 1.1)
    elsif bkind == 2
      spr("⭐", bx, by, false, false, b[8], 0.9)
    else
      circfill(bx + 8, by + 8, 4, 8)
      circfill(bx + 8, by + 8, 2, 10)
    end
    b_idx += 1
  end

  # ⚡ サンダーボルト稲妻エフェクト描画 (line & circfill)
  l_idx = 0
  while l_idx < $lightnings.length
    lt = $lightnings[l_idx]
    x0 = lt[0]
    y0 = lt[1]
    x1 = lt[2]
    y1 = lt[3]
    mid_y = (y0 + y1) / 2
    zag = ((lt[4] % 2) == 0) ? -6 : 6
    line(x0, y0, x0 + zag, mid_y, 10)
    line(x0 + zag, mid_y, x1, y1, 7)
    line(x0 + 1, y0, x0 + zag + 1, mid_y, 7)
    circfill(x1, y1, lt[4], 10)
    circ(x1, y1, lt[4] + 3, 7)
    l_idx += 1
  end

  # パーティクル描画
  p_idx = 0
  while p_idx < $particles.length
    pt = $particles[p_idx]
    circfill(pt[0] / 10, pt[1] / 10, pt[6], pt[4])
    p_idx += 1
  end

  # ダメージ・ステータスポップアップ描画
  pop_idx = 0
  while pop_idx < $popups.length
    pp = $popups[pop_idx]
    print_text(pp[2], pp[0], pp[1], pp[3])
    pop_idx += 1
  end
end

def draw_hud
  camera()
  clip()
  pal()

  rectfill(0, 0, 256, 28, 0)
  line(0, 28, 255, 28, ($form == 0) ? 14 : 11)

  # 1. フォーム表示 & HPバー
  form_str = ($form == 0) ? "🐰USAGI" : "🐢KAME"
  form_col = ($form == 0) ? 14 : 11
  print_text(form_str, 4, 3, form_col)

  rectfill(54, 4, 64, 6, 2)
  hp_w = ($hp * 64) / $max_hp
  hp_w = 0 if hp_w < 0
  rectfill(54, 4, hp_w, 6, ($hp * 3 < $max_hp) ? 8 : 11)
  rect(54, 4, 64, 6, 7)
  print_text("#{$hp}/#{$max_hp}", 58, 12, 7)

  # 2. タッグゲージ & スキル状態
  tag_col = ($tag_gauge >= 100) ? ((($t / 4) % 2 == 0) ? 10 : 7) : 12
  print_text(($tag_gauge >= 100) ? "X:BURST!" : "X:TAG#{$tag_gauge}%", 4, 19, tag_col)
  sk_str = ($skill_cd <= 0) ? "Z:OK" : "Z:#{($skill_cd / 10) + 1}"
  print_text(sk_str, 64, 19, ($skill_cd <= 0) ? 10 : 5)

  # 3. 中央タイマー・Wave・Lv・スコア
  sec_total = $run_frames / 60
  mm = sec_total / 60
  ss = sec_total % 60
  ss_str = (ss < 10) ? "0#{ss}" : "#{ss}"
  print_text("W#{$wave} #{mm}:#{ss_str}", 124, 3, 10)
  print_text("LV:#{$lv} K:#{$kills}", 124, 11, 7)
  print_text("SC:#{$score}", 124, 19, 12)

  # 4. EXPバー (画面最上部 2px ライン)
  rectfill(0, 0, 256, 2, 1)
  exp_w = ($exp * 256) / $next_exp
  rectfill(0, 0, exp_w, 2, 12)

  # 5. 右上リアルタイム・レーダーミニマップ (clip を活用した 50x23 スコープ)
  mx = 202
  my = 3
  mw = 50
  mh = 23
  clip(mx, my, mw, mh)
  cls(1)
  e_idx = 0
  while e_idx < $enemies.length
    e = $enemies[e_idx]
    ex = e[0] / 10
    ey = e[1] / 10
    rx = mx + (ex * mw) / WORLD_W
    ry = my + (ey * mh) / WORLD_H
    ecol = (e[4] >= 5) ? 10 : 8
    rectfill(rx, ry, (e[4] >= 5) ? 2 : 1, (e[4] >= 5) ? 2 : 1, ecol)
    e_idx += 1
  end
  prx = mx + ($px * mw) / WORLD_W
  pry = my + ($py * mh) / WORLD_H
  rectfill(prx - 1, pry - 1, 2, 2, 7)
  clip()
  rect(mx - 1, my - 1, mw + 2, mh + 2, 6)

  if $boss_warning > 0 && (($t / 6) % 2 == 0)
    rectfill(36, 34, 184, 14, 8)
    rect(36, 34, 184, 14, 10)
    print_text("⚠️ WARNING: BOSS APPROACHING! ⚠️", 42, 37, 7)
  end
end

def draw_title_screen
  $cam_x = 128 + (cos_idx(($t / 8) % 24) * 32) / 100
  $cam_y = 128 + (sin_idx(($t / 8) % 24) * 32) / 100
  camera($cam_x, $cam_y)
  draw_world
  camera()
  clip()
  pal()

  rectfill(14, 14, 228, 228, 1)
  rect(14, 14, 228, 228, 12)
  rect(16, 16, 224, 224, 7)

  ovalfill(128, 44, 92, 18, 2)
  oval(128, 44, 92, 18, 10)
  print_text("✨USAKAME SURVIVORS✨", 48, 34, 10)
  print_text("うさかめサバイバーズ", 68, 46, 7)

  bounce = (($t / 8) % 2 == 0) ? 0 : -3
  ovalfill(76, 94, 14, 5, 0)
  ovalfill(180, 94, 14, 5, 0)
  spr(0, 68, 74 + bounce, false, false, 0, 2.0)
  spr(1, 172, 74 - bounce, true, false, 0, 2.0)
  spr("⚔️", 120, 74, false, false, ($t * 3) % 360, 1.5)

  print_text("🐰USAGI: 高速連射＆ブリンク", 40, 108, 14)
  print_text("🐢KAME : 重装防御＆甲羅粉砕", 40, 120, 11)
  print_text("⚡TAG  : X切替でバースト衝撃波!", 40, 132, 10)

  rectfill(26, 146, 204, 42, 0)
  rect(26, 146, 204, 42, 5)
  print_text("【CONTROLS / 操作方法】", 62, 150, 12)
  print_text("ARROWS/WASD : 移動 (Move)", 42, 161, 7)
  print_text("Z / SPACE   : スキル (Blink/Spin)", 42, 170, 7)
  print_text("X / ENTER   : フォーム切替 (Tag)", 42, 179, 7)

  if $high_score > 0
    print_text("🏆HIGH SCORE: #{$high_score}", 64, 196, 10)
  else
    print_text("💎宝石を集めてビルドを構築せよ!", 38, 196, 6)
  end

  if (($t / 15) % 2) == 0
    rectfill(44, 212, 168, 16, 8)
    rect(44, 212, 168, 16, 10)
    print_text("PRESS Z / SPACE TO START!", 52, 216, 7)
  end
end

def draw_levelup_modal
  camera()
  clip()
  pal()

  rectfill(12, 32, 232, 208, 1)
  rect(12, 32, 232, 208, 10)
  rect(14, 34, 228, 204, 7)

  print_text("🎉 LEVEL UP! (LV #{$lv}) 🎉", 62, 40, 10)
  print_text("強化するスキルを選んで Z キー!", 42, 51, 7)

  i = 0
  while i < 3
    uid = $choices[i]
    cy = 64 + i * 44
    selected = ($cursor == i)
    bg = selected ? 2 : 0
    border = selected ? 10 : 5

    rectfill(20, cy, 216, 40, bg)
    rect(20, cy, 216, 40, border)

    cur_lv = $upg_lv[uid]
    next_lv = cur_lv + 1
    if selected
      spr($UPG_ICONS[uid], 26, cy + 12, false, false, 0, 1.25)
    else
      spr($UPG_ICONS[uid], 26, cy + 12, false, false, 0, 1.0)
    end

    prefix = selected ? "▶ " : "  "
    print_text("#{prefix}#{$UPG_NAMES[uid]} [Lv#{cur_lv}->#{next_lv}]", 46, cy + 7, selected ? 10 : 7)
    print_text($UPG_DESCS[uid], 48, cy + 21, selected ? 11 : 6)
    i += 1
  end

  print_text("BUILD:", 22, 202, 12)
  b = 0
  while b < 8
    bx = 62 + b * 22
    print_text("#{$UPG_ICONS[b]}#{$upg_lv[b]}", bx, 202, ($upg_lv[b] > 0) ? 7 : 5)
    b += 1
  end
  print_text("↑/↓:SELECT   Z/SPACE:CONFIRM", 44, 220, 10)
end

def draw_result_modal(is_victory)
  camera()
  clip()
  pal()

  rectfill(20, 40, 216, 180, is_victory ? 1 : 0)
  rect(20, 40, 216, 180, is_victory ? 10 : 8)
  rect(22, 42, 212, 176, 7)

  if is_victory
    print_text("🏆 VICTORY! 混沌竜撃破! 🎉", 50, 52, 10)
    print_text("うさぎとかめの絆が世界を救った！", 34, 66, 11)
  else
    print_text("💀 GAME OVER... 💀", 74, 52, 8)
    print_text("もう一度挑戦してビルドを極めよう！", 30, 66, 7)
  end

  sec_total = $run_frames / 60
  mm = sec_total / 60
  ss = sec_total % 60
  ss_str = (ss < 10) ? "0#{ss}" : "#{ss}"

  rectfill(32, 82, 192, 72, 0)
  rect(32, 82, 192, 72, 5)
  print_text("SURVIVED TIME : #{mm}:#{ss_str} (WAVE #{$wave})", 40, 90, 7)
  print_text("FINAL LEVEL   : LV #{$lv}", 40, 104, 12)
  print_text("ENEMIES SLAIN : #{$kills}", 40, 118, 14)
  print_text("TOTAL SCORE   : #{$score}", 40, 132, 10)
  print_text("HIGH SCORE    : #{$high_score}", 40, 144, 9)

  b = 0
  while b < 8
    print_text("#{$UPG_ICONS[b]}#{$upg_lv[b]}", 38 + b * 23, 162, ($upg_lv[b] > 0) ? 7 : 5)
    b += 1
  end

  if is_victory
    print_text("Z / SPACE : 🔥エンドレスモード続行!", 34, 184, 10)
    print_text("X / ENTER : タイトル画面へ戻る", 44, 198, 6)
  else
    if (($t / 15) % 2) == 0
      print_text("PRESS Z / SPACE TO RETRY!", 54, 190, 10)
    end
  end
end

def draw
  pal()
  palt()
  clip()
  camera()
  cls(0)

  if $state == STATE_TITLE
    draw_title_screen
    return
  end

  clip(0, 28, 256, 228)
  camera($cam_x, $cam_y)
  draw_world
  camera()
  clip()

  draw_hud

  if $state == STATE_LEVELUP
    draw_levelup_modal
  elsif $state == STATE_GAMEOVER
    draw_result_modal(false)
  elsif $state == STATE_VICTORY
    draw_result_modal(true)
  end
end

__END__
# ==============================================================================
# スプライト & タイルマップ定義
# ==============================================================================

# 0: 🐰 ウサギヒーロー (USAGI - 紅のはちまき付き)
@SPRITE 0
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777...
...7777777777...
..888888888888..
.77707777770777.
.77707777770777.
.777777EE777777.
..777777777777..
...8888AA8888...
..778888888877..
..77.777777.77..
....777..777....
...777....777...
................

# 1: 🐢 カメヒーロー (KAME - 重装ガーディアン甲羅)
@SPRITE 1
................
.....BBBBBB.....
...BB333333BB...
..B33BBBBBB33B..
.B3BB33BB33BB3B.
.B3B333BB333B3B.
77B3BBBBBBBB3B77
70B333BBBB333B07
77BBBB3333BBBB77
.77999999999977.
..99AA9999AA99..
...BB999999BB...
..BBBB....BBBB..
..B33B....B33B..
................
................

# 2: 石壁・ピラータイル (通行不可)
@SPRITE 2
5555555055555550
6666665066666650
6777765067777650
6755565067555650
6666665066666650
5555555055555550
0000000000000000
5550555555505555
6650666666506666
7650677776506777
5650675556506755
6650666666506666
5550555555505555
0000000000000000
5555555055555550
6666665066666650

# 3: 木箱 (攻撃・ダッシュ・スピンで破壊可能 -> アイテム出現)
@SPRITE 3
.44444444444444.
4999999999999994
4944444444444494
4949944994499494
4944994994994494
4944499999944494
4999994994999994
4444444AA4444444
4999994AA4999994
4944499999944494
4944994994994494
4949944994499494
4944444444444494
4999999999999994
.44444444444444.
................

# 4: 結晶鉱石岩 (カメのスピンや貫通武器で破壊 -> 大ジェム💎確定)
@SPRITE 4
.....CCCCCC.....
...CC77CC55CC...
..C77CCCC5555C..
.C77CCC11CC555C.
.C55CC1771CC55C.
C555C17CC71C555C
C555C1C77C1C555C
C1155CC11CC5511C
C17155CCCC55171C
.C11555CC55511C.
.CC5555555555CC.
..CC11555511CC..
...CCCCCCCCCC...
....55555555....
................
................

# 5: 癒やしの泉タイル (乗るとHP持続回復)
@SPRITE 5
...CCCCCCCCCC...
..CCCCCCCCCCCC..
.CC77CCCCCC77CC.
.CCCC111111CCCC.
CCCC1CCCCCC1CCCC
CCC1CC7777CC1CCC
CCC1C7CCCC7C1CCC
CCC1C7C77C7C1CCC
CCC1C7CCCC7C1CCC
CCC1CC7777CC1CCC
CCCC1CCCCCC1CCCC
.CCCC111111CCCC.
.CC77CCCCCC77CC.
..CCCCCCCCCCCC..
...CCCCCCCCCC...
................

# 6: 加速の花畑タイル (乗ると移動速度UP)
@SPRITE 6
................
..A..........E..
.AAA...B....EEE.
..A...BBB....E..
.......B........
...B.......A....
..BBB.....AAA...
...B.......A....
........B.......
..E....BBB...B..
.EEE....B...BBB.
..E..........B..
.......A........
......AAA.......
.......A........
................

# 7: 草むらタイル
@SPRITE 7
................
................
................
................
.......B...B....
...B..BB..BB....
..BB..BB.BBB.B..
..BBB.BBBBBB.BB.
.BBBBBBBBBBBBBB.
.33BBBBBBBBBB33.
..3333BBBB3333..
....33333333....
................
................
................
................

# 初期アリーナマップ (32x32)
@MAP 0 0
22222222222222222222222222222222
2..7...3......7..6.....3...7...2
2....4......7........4.........2
2..3.....6.......7.......6..3..2
2......7....3.......3..........2
2...7...............7....4.....2
2.......4.....7..7.............2
2..6...............3...7....6..2
2.......2..............2.......2
2...3.......7......7.......3...2
2.......7..............7.......2
2..4........3......3........4..2
2......6................6......2
2...........7......7...........2
2.......7..............7.......2
2..............55..............2
2..............55..............2
2.......7..............7.......2
2...........7......7...........2
2......6................6......2
2..4........3......3........4..2
2.......7..............7.......2
2...3.......7......7.......3...2
2.......2..............2.......2
2..6...............3...7....6..2
2.......4.....7..7.............2
2...7...............7....4.....2
2......7....3.......3..........2
2..3.....6.......7.......6..3..2
2....4......7........4.........2
2..7...3......7..6.....3...7...2
22222222222222222222222222222222

# ==============================================================================
# 効果音 (sfx id)  ※ c2 = C4。:fade :slide :vib :drop :arp はノート単位エフェクト
# ==============================================================================
# 0: 経験値ジェム取得
@SFX 0 wave=pulse12 speed=1 e4 b4:fade
# 1: 敵撃破
@SFX 1 wave=noise speed=2 c4 c2:fade
# 2: 被ダメージ
@SFX 2 :hit
# 3: 🐰 ラビット・ブリンク
@SFX 3 wave=pulse speed=2 c3 c5:slide
# 4: 🐢 シェル・スピン
@SFX 4 wave=saw speed=3 c1 c2:slide c1:slide:fade
# 5: タッグ切替（通常）
@SFX 5 wave=square speed=2 g3 c4:fade
# 6: タッグバースト
@SFX 6 wave=square speed=2 c3 e3 g3 c4 e4 g4 c5:arp:fade
# 7: 回復 🍎
@SFX 7 wave=tri speed=3 c3 e3 g3 c4:fade
# 8: 💣 メガボム
@SFX 8 :explosion
# 9: ⚠️ ボス出現警告
@SFX 9 wave=saw speed=8 a2:vib r a2:vib r a2:vib:fade
# 10: ボス撃破
@SFX 10 :explosion pitch=0.6 speed=0.5
# 11: 🧲 全回収
@SFX 11 wave=pulse speed=2 c3 g3 c4 g4 c5:fade
# 12: レベルアップ
@SFX 12 :powerup
# 13: カーソル移動
@SFX 13 :select
# 14: 決定
@SFX 14 :coin
# 15: 勝利ファンファーレ
@SFX 15 wave=square speed=5 c3 c3 c3 c3*3 g#2*3 a#2*3 c3 r a#2 c3*6:vib:fade
# 16: ゲームオーバー
@SFX 16 :gameover

# ==============================================================================
# BGM (music id)  ※ ch0..ch3 に MML: T=テンポ L=基本音長 O=オクターブ < > でオクターブ移動
# ==============================================================================
# 0: タイトル
@MUSIC 0
ch0 wave=pulse vol=4 T100 L4 O4 e g > c < b  a g e2  f a > d c  < b g > c2
ch1 wave=tri vol=6 T100 L2 O3 c e  f g  d f  g c

# 1: フィールド (Wave 1〜5)
@MUSIC 1
ch0 wave=square vol=3 T150 L8 O4 a > c e < a > d c < b g  a > c e a g e d c  < b > d g < b > c < b a g  a e a > c < a4 r4
ch1 wave=tri vol=6 T150 L8 O2 a a > a < a a a > a < a  f f > f < f f f > f < f  g g > g < g g g > g < g  a a > a < a e e > e < e
ch2 wave=noise vol=2 T150 L8 O2 c r >>> c r <<< c c >>> c r <<<  c r >>> c r <<< c c >>> c r <<<  c r >>> c r <<< c c >>> c r <<<  c r >>> c r <<< c c >>> c c <<<

# 2: ボス戦
@MUSIC 2
ch0 wave=saw vol=3 T170 L16 O4 e e > e < e d# d# > d# < d# e e > e < e g f# e d#  c c > c < c b b > b < b c c > c < c d# e f# g
ch1 wave=tri vol=6 T170 L8 O2 e e e e d# d# d# d#  c c c c d# d# e e
ch2 wave=noise vol=2 T170 L8 O2 c >>> c <<< c >>> c <<<  c >>> c <<< c >>> c <<<  c >>> c <<< c >>> c <<<  c >>> c c c <<<

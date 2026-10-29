# ==============================================================================
# ✨ Particles & Juicy Effects Cookbook (パーティクル＆演出レシピ集) ✨
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/particles.rb
#
# 【AIエージェント・開発者向けレシピ】
# ゲームの「手触り（Juiciness）」を劇的に向上させる汎用エフェクト実装集です。
# 以下の関数群はそのまま他のゲーム（アクション、STG、RPG等）にコピーして使えます：
#   1. 円形バースト爆発 & 煙パーティクル (spawn_explosion)
#   2. 重力・床バウンド付き火花 (spawn_sparks)
#   3. 拡大リング・衝撃波 (spawn_shockwave)
#   4. ダメージ数値・テキストのバウンスポップアップ (spawn_popup)
#   5. 残像トレイル (spawn_trail)
#   6. 画面シェイク (trigger_shake) & ヒットストップ (trigger_hitstop)
#   7. イージング関数 (lerp, ease_out_quad, ease_out_back)
#
# 【操作方法】
#   - 矢印キー (WASD): うさぎを移動（残像トレイル発生）
#   - Z / Space: コンボ攻撃（斬撃＋火花＋ダメージポップアップ＋ヒットストップ）
#   - X / Enter: 大爆発マジック（衝撃波＋大シェイク＋大量パーティクル）
#   - マウス左クリック: クリック位置に花火バースト生成
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "✨ Particles & Juicy Effects Cookbook"
)

FLOOR_Y = 204.0

# --- 1. イージング・数学ヘルパー (mrubyedge 互換) ---
def lerp(a, b, t)
  a + (b - a) * t
end

def ease_out_quad(t)
  1.0 - (1.0 - t) * (1.0 - t)
end

def ease_out_back(t)
  c1 = 1.70158
  c3 = c1 + 1.0
  t1 = t - 1.0
  1.0 + c3 * (t1 * t1 * t1) + c1 * (t1 * t1)
end

# 配列からのランダム要素取得（mrubyedge には Array#sample が無いため必須のイディオム）
def pick_random(arr)
  return nil if arr.empty?
  arr[rand(arr.size)]
end

# --- 2. グローバル状態 ---
$t = 0
$particles = []
$shockwaves = []
$popups = []
$trails = []

$shake_timer = 0
$shake_power = 0.0
$hitstop_timer = 0
$flash_timer = 0

$player = {
  x: 70.0,
  y: FLOOR_Y - 16.0,
  vx: 0.0,
  vy: 0.0,
  flip_x: false,
  slash_timer: 0,
  combo: 0
}

$dummy = {
  x: 170.0,
  y: FLOOR_Y - 16.0,
  vx: 0.0,
  vy: 0.0,
  hurt_timer: 0,
  scale_x: 1.0,
  scale_y: 1.0
}

# --- 3. エフェクト生成レシピ ---

# 画面シェイクを発動
def trigger_shake(power, frames)
  if power > $shake_power || $shake_timer <= 0
    $shake_power = power.to_f
  end
  $shake_timer = frames if frames > $shake_timer
end

# ヒットストップ（一瞬だけ時間を止めて打撃感を出す）
def trigger_hitstop(frames)
  $hitstop_timer = frames if frames > $hitstop_timer
end

# 衝撃波リングを追加
def spawn_shockwave(x, y, max_r, col, speed = 2.5)
  $shockwaves << {
    x: x.to_f,
    y: y.to_f,
    r: 2.0,
    max_r: max_r.to_f,
    col: col,
    speed: speed.to_f
  }
end

# ダメージ数値・テキストのポップアップを追加
def spawn_popup(x, y, text, col = 7, is_crit = false)
  $popups << {
    x: x.to_f + rand(-8..8).to_f,
    y: y.to_f,
    start_y: y.to_f,
    vx: (rand() - 0.5) * 1.2,
    text: text.to_s,
    col: col,
    is_crit: is_crit,
    age: 0,
    max_age: is_crit ? 50 : 36
  }
end

# 爆発パーティクル（放射状粒＋煙）
def spawn_explosion(x, y, count = 24)
  fire_cols = [7, 10, 9, 8, 2]
  count.times do
    ang = rand() * 6.283185
    spd = 0.8 + rand() * 4.2
    $particles << {
      kind: :fire,
      x: x.to_f,
      y: y.to_f,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd - 0.6,
      drag: 0.92,
      grav: 0.04,
      r: 2.0 + rand() * 3.5,
      cols: fire_cols,
      age: 0,
      max_age: 18 + rand(20),
      bounce: false
    }
  end

  # 立ち昇る煙
  8.times do
    $particles << {
      kind: :smoke,
      x: x.to_f + rand(-10..10).to_f,
      y: y.to_f + rand(-6..6).to_f,
      vx: (rand() - 0.5) * 0.8,
      vy: -0.4 - rand() * 0.8,
      drag: 0.98,
      grav: -0.015,
      r: 3.0 + rand() * 3.0,
      cols: [6, 5, 1],
      age: 0,
      max_age: 30 + rand(20),
      bounce: false
    }
  end
end

# 重力＆床バウンド付き火花パーティクル
def spawn_sparks(x, y, dir_x, count = 14)
  spark_cols = [7, 10, 9, 8]
  count.times do
    ang = (dir_x >= 0 ? -0.6 : -2.54) + (rand() - 0.5) * 1.1
    spd = 1.8 + rand() * 3.8
    $particles << {
      kind: :spark,
      x: x.to_f,
      y: y.to_f,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd,
      drag: 0.98,
      grav: 0.22,
      r: 1.5,
      cols: spark_cols,
      age: 0,
      max_age: 24 + rand(18),
      bounce: true
    }
  end
end

# 移動時の残像トレイル
def spawn_trail(x, y, emoji, flip_x)
  $trails << {
    x: x.to_f,
    y: y.to_f,
    emoji: emoji,
    flip_x: flip_x,
    age: 0,
    max_age: 10
  }
end

# --- 4. アクション発動処理 ---

def perform_slash_attack
  $player[:slash_timer] = 12
  $player[:combo] = ($player[:combo] + 1) % 3
  sfx(0)

  # ターゲットとの距離判定
  dx = $dummy[:x] - $player[:x]
  dy = $dummy[:y] - $player[:y]
  dist = sqrt(dx * dx + dy * dy)

  if dist < 90.0
    hit_x = $dummy[:x] + 8.0
    hit_y = $dummy[:y] + 8.0
    dir = dx >= 0 ? 1 : -1
    is_crit = ($player[:combo] == 2)

    dmg = is_crit ? (45 + rand(25)) : (12 + rand(10))
    spawn_sparks(hit_x, hit_y, dir, is_crit ? 22 : 12)
    spawn_shockwave(hit_x, hit_y, is_crit ? 28 : 16, is_crit ? 10 : 7, 3.0)

    if is_crit
      spawn_explosion(hit_x, hit_y, 18)
      spawn_popup(hit_x, hit_y - 12.0, "CRIT #{dmg}!", 10, true)
      trigger_shake(5.0, 14)
      trigger_hitstop(5)
      $flash_timer = 3
      $dummy[:vx] = dir * 4.5
      $dummy[:vy] = -3.8
      sfx(1)
    else
      spawn_popup(hit_x, hit_y - 8.0, dmg.to_s, 7, false)
      trigger_shake(2.0, 6)
      trigger_hitstop(2)
      $dummy[:vx] = dir * 1.8
      $dummy[:vy] = -1.5
    end
    $dummy[:hurt_timer] = 12
  else
    # 空振り時も小さな衝撃波
    front_x = $player[:x] + ($player[:flip_x] ? -12.0 : 24.0)
    spawn_shockwave(front_x, $player[:y] + 8.0, 12, 6, 2.0)
  end
end

def perform_magic_blast(tx, ty)
  sfx(1)
  spawn_explosion(tx, ty, 36)
  spawn_sparks(tx, ty, 1, 16)
  spawn_sparks(tx, ty, -1, 16)
  spawn_shockwave(tx, ty, 48, 10, 3.5)
  spawn_shockwave(tx, ty, 32, 8, 2.2)
  spawn_popup(tx, ty - 14.0, "BOOM!!", 9, true)
  trigger_shake(6.0, 18)
  trigger_hitstop(4)
  $flash_timer = 4

  dx = $dummy[:x] + 8.0 - tx
  dy = $dummy[:y] + 8.0 - ty
  if sqrt(dx * dx + dy * dy) < 80.0
    $dummy[:hurt_timer] = 18
    $dummy[:vx] = (dx >= 0 ? 1 : -1) * 5.0
    $dummy[:vy] = -4.5
    spawn_popup($dummy[:x] + 8.0, $dummy[:y] - 18.0, "999", 8, true)
  end
end

# --- 5. メイン更新ループ ---

def update
  $t += 1
  $flash_timer -= 1 if $flash_timer > 0

  # シェイク減衰
  if $shake_timer > 0
    $shake_timer -= 1
    $shake_power *= 0.88
  else
    $shake_power = 0.0
  end

  # ヒットストップ中はゲームロジックの進行を一時停止（打撃感の演出）
  if $hitstop_timer > 0
    $hitstop_timer -= 1
    return
  end

  # プレイヤー移動
  move_x = 0.0
  if btn(:left)
    move_x -= 1.0
    $player[:flip_x] = true
  end
  if btn(:right)
    move_x += 1.0
    $player[:flip_x] = false
  end

  $player[:vx] = lerp($player[:vx], move_x * 2.8, 0.35)
  $player[:x] = ($player[:x] + $player[:vx]).clamp(12.0, 228.0)

  # ジャンプ
  if btnp(:up) && $player[:y] >= FLOOR_Y - 16.5
    $player[:vy] = -4.8
    spawn_shockwave($player[:x] + 8.0, FLOOR_Y, 10, 6, 1.8)
  end
  $player[:vy] += 0.28
  $player[:y] += $player[:vy]
  if $player[:y] > FLOOR_Y - 16.0
    $player[:y] = FLOOR_Y - 16.0
    $player[:vy] = 0.0
  end

  # 残像トレイル生成（高速移動中またはジャンプ中）
  if ($player[:vx].abs > 1.5 || $player[:y] < FLOOR_Y - 18.0) && ($t % 3 == 0)
    spawn_trail($player[:x], $player[:y], "🐰", $player[:flip_x])
  end

  $player[:slash_timer] -= 1 if $player[:slash_timer] > 0

  # アクション入力
  if btnp(:btn_a)
    perform_slash_attack
  end
  if btnp(:btn_b)
    perform_magic_blast($dummy[:x] + 8.0, $dummy[:y] + 8.0)
  end
  if btnp(:mouse_l)
    perform_magic_blast(mouse_x.to_f, mouse_y.to_f)
  end

  # 自動デモ演出（何も押していなくても定期的に花火や攻撃が発生して賑やかに）
  if $t % 90 == 30 && $particles.empty?
    perform_slash_attack
  elsif $t % 180 == 0
    rx = 40 + rand(176)
    ry = 60 + rand(90)
    spawn_explosion(rx, ry, 20)
    spawn_shockwave(rx, ry, 30, pick_random([10, 11, 12, 14]), 2.5)
  end

  # ターゲットダミーの物理更新
  $dummy[:x] += $dummy[:vx]
  $dummy[:y] += $dummy[:vy]
  $dummy[:vx] *= 0.85
  $dummy[:vy] += 0.28
  if $dummy[:y] > FLOOR_Y - 16.0
    if $dummy[:vy] > 2.0
      $dummy[:vy] = -$dummy[:vy] * 0.45
      spawn_shockwave($dummy[:x] + 8.0, FLOOR_Y, 12, 6, 2.0)
    else
      $dummy[:y] = FLOOR_Y - 16.0
      $dummy[:vy] = 0.0
    end
  end
  # 画面端バウンド
  if $dummy[:x] < 20.0
    $dummy[:x] = 20.0
    $dummy[:vx] = -$dummy[:vx] * 0.7
  elsif $dummy[:x] > 220.0
    $dummy[:x] = 220.0
    $dummy[:vx] = -$dummy[:vx] * 0.7
  end
  $dummy[:hurt_timer] -= 1 if $dummy[:hurt_timer] > 0

  # パーティクル更新
  $particles.each do |pt|
    pt[:age] += 1
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
    pt[:vx] *= pt[:drag]
    pt[:vy] = pt[:vy] * pt[:drag] + pt[:grav]

    if pt[:bounce] && pt[:y] >= FLOOR_Y
      pt[:y] = FLOOR_Y
      pt[:vy] = -pt[:vy].abs * 0.55
      pt[:vx] *= 0.8
    end
  end
  $particles.reject! { |pt| pt[:age] >= pt[:max_age] }

  # 衝撃波更新
  $shockwaves.each do |sw|
    sw[:r] += sw[:speed]
  end
  $shockwaves.reject! { |sw| sw[:r] >= sw[:max_r] }

  # ポップアップ更新
  $popups.each do |pop|
    pop[:age] += 1
    pop[:x] += pop[:vx]
    pop[:vx] *= 0.92
  end
  $popups.reject! { |pop| pop[:age] >= pop[:max_age] }

  # トレイル更新
  $trails.each { |tr| tr[:age] += 1 }
  $trails.reject! { |tr| tr[:age] >= tr[:max_age] }
end

# --- 6. 描画処理 ---

def draw
  # 画面シェイクをカメラオフセットに反映
  if $shake_timer > 0
    sx = (rand() - 0.5) * 2.0 * $shake_power
    sy = (rand() - 0.5) * 2.0 * $shake_power
    camera(sx.round, sy.round)
  else
    camera(0, 0)
  end

  # フラッシュ演出または背景クリア
  if $flash_timer > 0
    cls(7)
  else
    cls(1)
  end

  # 背景グリッド＆地面
  (0..8).each do |i|
    gx = i * 32
    line(gx, 32, gx, FLOOR_Y.to_i, 13)
  end
  rectfill(0, FLOOR_Y.to_i, 256, 256 - FLOOR_Y.to_i, 5)
  line(0, FLOOR_Y.to_i, 256, FLOOR_Y.to_i, 7)

  # 残像トレイル描画
  $trails.each do |tr|
    pal(7, 12)
    spr(tr[:emoji], tr[:x].to_i, tr[:y].to_i, tr[:flip_x], false)
    pal
  end

  # ターゲットダミー描画（被弾時は白フラッシュ）
  if $dummy[:hurt_timer] > 0 && ($dummy[:hurt_timer] % 2 == 0)
    circfill($dummy[:x].to_i + 8, $dummy[:y].to_i + 8, 10, 7)
  end
  spr("👾", $dummy[:x].to_i, $dummy[:y].to_i)

  # プレイヤー描画
  spr("🐰", $player[:x].to_i, $player[:y].to_i, $player[:flip_x], false)

  # 斬撃エフェクト描画
  if $player[:slash_timer] > 0
    sx = $player[:x].to_i + ($player[:flip_x] ? -14 : 16)
    sy = $player[:y].to_i
    rot = (12 - $player[:slash_timer]) * 25
    spr("⚔️", sx, sy, $player[:flip_x], false, rot, 1.3)
    circ(sx + 8, sy + 8, 14 - $player[:slash_timer], 10)
  end

  # 衝撃波リング描画
  $shockwaves.each do |sw|
    circ(sw[:x].to_i, sw[:y].to_i, sw[:r].to_i, sw[:col])
  end

  # パーティクル描画（寿命に応じて色とサイズが変化）
  $particles.each do |pt|
    ratio = pt[:age].to_f / pt[:max_age].to_f
    cols = pt[:cols]
    c_idx = (ratio * cols.size).to_i.clamp(0, cols.size - 1)
    col = cols[c_idx]

    if pt[:kind] == :spark
      # 速度方向に伸びる火花ライン
      line(
        pt[:x].to_i,
        pt[:y].to_i,
        (pt[:x] - pt[:vx] * 1.8).to_i,
        (pt[:y] - pt[:vy] * 1.8).to_i,
        col
      )
    else
      cur_r = (pt[:r] * (1.0 - ratio * 0.7)).to_i
      cur_r = 1 if cur_r < 1
      circfill(pt[:x].to_i, pt[:y].to_i, cur_r, col)
    end
  end

  # ダメージ・テキストポップアップ描画（イージングで跳ねる）
  $popups.each do |pop|
    t = (pop[:age].to_f / 14.0).clamp(0.0, 1.0)
    bounce = ease_out_back(t)
    py = pop[:start_y] - bounce * (pop[:is_crit] ? 24.0 : 16.0)
    if pop[:age] > pop[:max_age] - 10
      py -= (pop[:age] - (pop[:max_age] - 10)) * 0.8
    end

    # 黒フチ付きテキスト
    tx = pop[:x].to_i - (pop[:text].length * 3)
    ty = py.to_i
    print_text(pop[:text], tx + 1, ty + 1, 0)
    col = (pop[:is_crit] && (pop[:age] % 4 < 2)) ? 7 : pop[:col]
    print_text(pop[:text], tx, ty, col)
  end

  # UI ヘッダー（カメラ影響をリセットして固定表示）
  camera(0, 0)
  rectfill(0, 0, 256, 28, 0)
  line(0, 28, 256, 28, 12)
  print_text("✨ PARTICLES & JUICY COOKBOOK", 6, 4, 10)
  print_text("[Arrow]Move [Z]Slash [X/Click]Blast", 6, 16, 7)
  print_text("Active:#{$particles.size + $shockwaves.size + $popups.size}", 184, 4, 11)
end

__END__
@SFX 0
T180 L32 O5 C G > C
@SFX 1
T160 L16 O3 G E C < G

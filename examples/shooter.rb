# ==============================================================================
# 🚀 Cosmic Rabbit Shooter (縦スクロール弾幕シューティング) 🛸
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/shooter.rb
#
# 【AIエージェント・開発者向けレシピ】
# 縦スクロールSTGの王道要素を1ファイルに凝縮した実践テンプレートです。
#   1. 3層パララックス（多重スクロール）星空背景
#   2. 自機の移動、オート連射ショット、パワーアップ段階（シングル→3Way→5Way）
#   3. ボム（全画面弾消し＆無敵衝撃波）
#   4. 敵編隊のサインカーブ移動・円形弾幕・自機狙い弾（三角関数によるベクトル計算）
#   5. 巨大ボス戦（HPゲージ・弾幕フェーズ変化）
#
# 【操作方法】
#   - 矢印キー (WASD): 自機移動
#   - Z / Space (押しっぱなし可): ショット発射（ゲームオーバー時はリトライ）
#   - X / Enter: ボム発動（敵弾を全消去して大ダメージ）
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🚀 Cosmic Rabbit Shooter"
)

# --- 1. 初期状態と定数 ---

$t = 0
$score = 0
$hi_score = 10000
$state = :play # :play, :gameover, :victory
$shake = 0

# 3層パララックス星空の生成
$stars = []
45.times do |i|
  layer = (i % 3) + 1
  $stars << {
    x: rand(256).to_f,
    y: rand(256).to_f,
    spd: layer.to_f * 0.7,
    col: (layer == 3) ? 7 : ((layer == 2) ? 6 : 5)
  }
end

def init_game
  $t = 0
  $score = 0
  $state = :play
  $shake = 0

  $player = {
    x: 120.0,
    y: 210.0,
    hp: 3,
    bombs: 2,
    power: 1,
    inv_timer: 60
  }

  $bullets = []
  $enemy_bullets = []
  $enemies = []
  $items = []
  $particles = []
  $bomb_waves = []
  $boss = nil
end

init_game

# --- 2. 弾・エフェクト生成ヘルパー ---

def spawn_explosion(x, y, count, col_list)
  count.times do
    ang = rand() * 6.283185
    spd = 0.6 + rand() * 3.2
    $particles << {
      x: x.to_f,
      y: y.to_f,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd,
      r: 2.0 + rand() * 2.5,
      col: col_list[rand(col_list.size)],
      age: 0,
      max_age: 14 + rand(14)
    }
  end
end

# 自機狙い弾を発射（正規化ベクトルで計算）
def fire_aimed_bullet(ex, ey, speed, col = 8)
  dx = ($player[:x] + 8.0) - ex
  dy = ($player[:y] + 8.0) - ey
  dist = sqrt(dx * dx + dy * dy)
  dist = 1.0 if dist < 0.001
  $enemy_bullets << {
    x: ex,
    y: ey,
    vx: (dx / dist) * speed,
    vy: (dy / dist) * speed,
    r: 2,
    col: col
  }
end

# 放射状（全方位）弾幕を発射
def fire_radial_bullets(ex, ey, count, speed, base_angle, col = 14)
  step = 6.283185 / count.to_f
  count.times do |i|
    ang = base_angle + i.to_f * step
    $enemy_bullets << {
      x: ex,
      y: ey,
      vx: cos(ang) * speed,
      vy: sin(ang) * speed,
      r: 2,
      col: col
    }
  end
end

# --- 3. 敵スポーン & ボス管理 ---

def update_spawner
  # 一定時間経過でボス出現
  if $t == 900 && $boss.nil?
    $boss = {
      x: 120.0,
      y: -32.0,
      target_y: 44.0,
      hp: 250,
      max_hp: 250,
      hurt: 0,
      phase: 0
    }
    return
  end

  return if $boss

  # ザコ敵ウェーブ生成
  if $t % 55 == 20
    # サインカーブで降りてくる編隊
    base_x = 36.0 + rand(184).to_f
    $enemies << {
      kind: :scout,
      emoji: "🛸",
      x: base_x,
      base_x: base_x,
      y: -16.0,
      hp: 3,
      hurt: 0,
      age: 0
    }
  end

  if $t % 140 == 70
    # 全方位弾を撃つ中型機
    $enemies << {
      kind: :spinner,
      emoji: "👾",
      x: 40.0 + rand(176).to_f,
      base_x: 128.0,
      y: -16.0,
      hp: 10,
      hurt: 0,
      age: 0
    }
  end
end

# --- 4. メイン更新処理 ---

def update
  $t += 1
  $shake -= 1 if $shake > 0

  # 星空スクロール更新
  $stars.each do |st|
    st[:y] += st[:spd]
    if st[:y] >= 256.0
      st[:y] -= 256.0
      st[:x] = rand(256).to_f
    end
  end

  if $state != :play
    if btnp(:btn_a)
      init_game
    end
    return
  end

  # 自機移動
  spd = 2.8
  $player[:x] -= spd if btn(:left)
  $player[:x] += spd if btn(:right)
  $player[:y] -= spd if btn(:up)
  $player[:y] += spd if btn(:down)
  $player[:x] = $player[:x].clamp(8.0, 232.0)
  $player[:y] = $player[:y].clamp(28.0, 232.0)
  $player[:inv_timer] -= 1 if $player[:inv_timer] > 0

  # 自機ショット（Zボタン押しっぱなし、またはデモ用自動連射）
  if (btn(:btn_a) || ($t % 12 == 0)) && ($t % 5 == 0)
    px = $player[:x] + 8.0
    py = $player[:y]
    sfx(0) if $t % 10 == 0

    if $player[:power] == 1
      $bullets << { x: px, y: py, vx: 0.0, vy: -7.5 }
    elsif $player[:power] == 2
      [-1.2, 0.0, 1.2].each do |vx|
        $bullets << { x: px, y: py, vx: vx, vy: -7.2 }
      end
    else
      [-2.4, -1.2, 0.0, 1.2, 2.4].each do |vx|
        $bullets << { x: px, y: py, vx: vx, vy: -7.5 }
      end
    end
  end

  # ボム発動（Xボタン）
  if btnp(:btn_b) && $player[:bombs] > 0
    $player[:bombs] -= 1
    $player[:inv_timer] = 90
    $shake = 18
    sfx(1)
    $bomb_waves << { x: $player[:x] + 8.0, y: $player[:y] + 8.0, r: 4.0 }
    # 敵弾を全て得点アイテム風の火花に変えて消去
    $enemy_bullets.each do |eb|
      spawn_explosion(eb[:x], eb[:y], 3, [10, 7])
      $score += 10
    end
    $enemy_bullets.clear
    # 画面内の敵にダメージ
    $enemies.each { |en| en[:hp] -= 15 }
    $boss[:hp] -= 35 if $boss
  end

  # ボム衝撃波更新
  $bomb_waves.each { |bw| bw[:r] += 8.0 }
  $bomb_waves.reject! { |bw| bw[:r] > 260.0 }

  # 自機弾の移動
  $bullets.each do |b|
    b[:x] += b[:vx]
    b[:y] += b[:vy]
  end
  $bullets.reject! { |b| b[:y] < -10.0 || b[:x] < -10.0 || b[:x] > 266.0 }

  # 敵スポーンと行動更新
  update_spawner

  $enemies.each do |en|
    en[:age] += 1
    en[:hurt] -= 1 if en[:hurt] > 0

    if en[:kind] == :scout
      en[:y] += 1.4
      en[:x] = (en[:base_x] + sin(en[:age].to_f * 0.08) * 32.0).clamp(12.0, 228.0)
      if en[:age] % 45 == 25
        fire_aimed_bullet(en[:x] + 8.0, en[:y] + 12.0, 2.4, 8)
      end
    else
      en[:y] += (en[:y] < 72.0) ? 1.0 : 0.25
      if en[:age] % 50 == 30
        fire_radial_bullets(en[:x] + 8.0, en[:y] + 8.0, 8, 1.8, en[:age].to_f * 0.1, 14)
      end
    end

    # 自機弾との当たり判定
    $bullets.each do |b|
      next if b[:hit]
      if (b[:x] - (en[:x] + 8.0)).abs < 11.0 && (b[:y] - (en[:y] + 8.0)).abs < 11.0
        b[:hit] = true
        en[:hp] -= 1
        en[:hurt] = 3
        spawn_explosion(b[:x], b[:y], 3, [7, 10])
      end
    end

    if en[:hp] <= 0
      $score += (en[:kind] == :spinner) ? 500 : 150
      $hi_score = $score if $score > $hi_score
      spawn_explosion(en[:x] + 8.0, en[:y] + 8.0, 16, [7, 10, 9, 8])
      sfx(1)
      # パワーアップ人参ドロップ
      if en[:kind] == :spinner || rand(4) == 0
        $items << { x: en[:x], y: en[:y], vy: 1.2 }
      end
    end
  end
  $bullets.reject! { |b| b[:hit] }
  $enemies.reject! { |en| en[:hp] <= 0 || en[:y] > 268.0 }

  # ボス更新
  if $boss
    $boss[:hurt] -= 1 if $boss[:hurt] > 0
    if $boss[:y] < $boss[:target_y]
      $boss[:y] += 1.0
    else
      $boss[:x] = 120.0 + sin($t.to_f * 0.03) * 72.0
      if $t % 35 == 0
        fire_radial_bullets($boss[:x] + 8.0, $boss[:y] + 12.0, 12, 2.0, $t.to_f * 0.07, 14)
      end
      if $t % 50 == 25
        fire_aimed_bullet($boss[:x] + 8.0, $boss[:y] + 16.0, 3.0, 8)
      end
    end

    $bullets.each do |b|
      next if b[:hit]
      if (b[:x] - ($boss[:x] + 8.0)).abs < 20.0 && (b[:y] - ($boss[:y] + 8.0)).abs < 18.0
        b[:hit] = true
        $boss[:hp] -= 1
        $boss[:hurt] = 2
        $score += 20
        spawn_explosion(b[:x], b[:y], 2, [7, 10])
      end
    end
    $bullets.reject! { |b| b[:hit] }

    if $boss[:hp] <= 0
      $score += 5000
      $hi_score = $score if $score > $hi_score
      spawn_explosion($boss[:x] + 8.0, $boss[:y] + 8.0, 45, [7, 10, 9, 8, 14])
      $enemy_bullets.clear
      $boss = nil
      $shake = 24
      $state = :victory
      sfx(1)
    end
  end

  # パワーアップアイテム更新
  $items.each do |it|
    it[:y] += it[:vy]
    if ($player[:x] - it[:x]).abs < 14.0 && ($player[:y] - it[:y]).abs < 14.0
      it[:collected] = true
      $player[:power] = ($player[:power] + 1).clamp(1, 3)
      $score += 300
      sfx(0)
    end
  end
  $items.reject! { |it| it[:collected] || it[:y] > 264.0 }

  # 敵弾更新 & 自機被弾判定
  px = $player[:x] + 8.0
  py = $player[:y] + 8.0
  $enemy_bullets.each do |eb|
    eb[:x] += eb[:vx]
    eb[:y] += eb[:vy]

    # 自機の喰らい判定は中心の小さな点（半径 3px）にして弾幕避けを気持ちよくする
    if $player[:inv_timer] <= 0
      dx = eb[:x] - px
      dy = eb[:y] - py
      if (dx * dx + dy * dy) < 16.0
        eb[:hit] = true
        $player[:hp] -= 1
        $player[:inv_timer] = 75
        $shake = 12
        spawn_explosion(px, py, 20, [7, 8, 9, 10])
        sfx(1)
        if $player[:hp] <= 0
          $state = :gameover
        end
      end
    end
  end
  $enemy_bullets.reject! do |eb|
    eb[:hit] || eb[:y] < -12.0 || eb[:y] > 268.0 || eb[:x] < -12.0 || eb[:x] > 268.0
  end

  # パーティクル更新
  $particles.each do |pt|
    pt[:age] += 1
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
  end
  $particles.reject! { |pt| pt[:age] >= pt[:max_age] }
end

# --- 5. 描画処理 ---

def draw
  if $shake > 0
    camera(rand(-3..3), rand(-3..3))
  else
    camera(0, 0)
  end

  cls(0)

  # 星空描画
  $stars.each do |st|
    pset(st[:x].to_i, st[:y].to_i, st[:col])
  end

  # ボム衝撃波
  $bomb_waves.each do |bw|
    circ(bw[:x].to_i, bw[:y].to_i, bw[:r].to_i, 12)
    circ(bw[:x].to_i, bw[:y].to_i, (bw[:r] - 4.0).to_i, 7) if bw[:r] > 6.0
  end

  # アイテム描画
  $items.each do |it|
    spr("🥕", it[:x].to_i, it[:y].to_i)
  end

  # 自機弾描画
  $bullets.each do |b|
    bx = b[:x].to_i
    by = b[:y].to_i
    rectfill(bx - 1, by - 4, 3, 8, 10)
    pset(bx, by - 5, 7)
  end

  # 自機描画（無敵時間中は点滅）
  if $state != :gameover && ($player[:inv_timer] % 4 < 2)
    spr("🚀", $player[:x].to_i, $player[:y].to_i)
    # 中心コア（当たり判定の目安）
    pset($player[:x].to_i + 8, $player[:y].to_i + 8, 12)
  end

  # 敵描画
  $enemies.each do |en|
    if en[:hurt] > 0
      circfill(en[:x].to_i + 8, en[:y].to_i + 8, 9, 7)
    end
    spr(en[:emoji], en[:x].to_i, en[:y].to_i)
  end

  # ボス描画
  if $boss
    bx = $boss[:x].to_i
    by = $boss[:y].to_i
    if $boss[:hurt] > 0
      circfill(bx + 8, by + 8, 18, 7)
    end
    spr("🐉", bx, by, false, false, 0, 2.2)
  end

  # 敵弾描画（外枠色＋白コアで視認性アップ）
  $enemy_bullets.each do |eb|
    ex = eb[:x].to_i
    ey = eb[:y].to_i
    circfill(ex, ey, eb[:r] + 1, eb[:col])
    pset(ex, ey, 7)
  end

  # パーティクル描画
  $particles.each do |pt|
    r = (pt[:r] * (1.0 - pt[:age].to_f / pt[:max_age].to_f)).to_i
    r = 1 if r < 1
    circfill(pt[:x].to_i, pt[:y].to_i, r, pt[:col])
  end

  # HUD (上部ステータスバー)
  camera(0, 0)
  rectfill(0, 0, 256, 20, 1)
  line(0, 20, 256, 20, 12)
  print_text(sprintf("SCORE %06d", $score), 6, 6, 7)

  hearts = ""
  $player[:hp].times { hearts = hearts + "❤️" }
  print_text(hearts, 108, 4, 8)

  bombs = ""
  $player[:bombs].times { bombs = bombs + "💣" }
  print_text(bombs, 168, 4, 10)
  print_text("PW:#{$player[:power]}", 216, 6, 11)

  # ボス HP バー
  if $boss
    rectfill(28, 24, 200, 6, 0)
    rect(28, 24, 200, 6, 7)
    bw = (198.0 * ($boss[:hp].to_f / $boss[:max_hp].to_f).clamp(0.0, 1.0)).to_i
    rectfill(29, 25, bw, 4, 8) if bw > 0
  end

  # ゲームオーバー / クリア表示
  if $state == :gameover
    rectfill(36, 96, 184, 60, 0)
    rect(36, 96, 184, 60, 8)
    print_text("GAME OVER", 92, 110, 8)
    print_text("PRESS Z TO RETRY", 72, 132, 7)
  elsif $state == :victory
    rectfill(32, 92, 192, 68, 1)
    rect(32, 92, 192, 68, 10)
    print_text("🎉 STAGE CLEAR!! 🎉", 64, 106, 10)
    print_text("FINAL SCORE: #{$score}", 68, 124, 7)
    print_text("PRESS Z TO PLAY AGAIN", 58, 142, 11)
  end
end

__END__
@SFX 0
T240 L64 O5 G > C
@SFX 1
T160 L16 O3 G E C < G

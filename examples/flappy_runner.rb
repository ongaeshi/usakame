# ==============================================================================
# 🪽 Flappy Rabbit (ワンボタン・エンドレスラン＆ジャンプ) 🥕
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/flappy_runner.rb
#
# 【AIエージェント・開発者向けレシピ】
# 初学者が最も理解しやすく、コード生成の基礎としても最適なワンボタンゲームの定石です。
#   1. 重力とジャンプ力による放物線運動 & 落下速度に応じたスプライト傾き回転
#   2. 左右スクロールする障害物柱の無限生成・循環消去 (reject!)
#   3. AABB（軸平行バウンディングボックス）矩形当たり判定
#   4. 多重スクロール（遠景の雲、近景の山、地面の市松模様）
#   5. メダル判定（🥉ブロンズ、🥈シルバー、🥇ゴールド）とハイスコア記録
#
# 【操作方法】
#   - Z / Space / 上キー / マウス左クリック: はばたく（ジャンプ）
#   - ゲームオーバー時: Z / Space / クリックで即リトライ
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🪽 Flappy Rabbit"
)

FLOOR_Y = 220.0
PIPE_W = 32.0
PIPE_GAP = 68.0

$t = 0
$hi_score = 10

def init_game
  $t = 0
  $score = 0
  $state = :get_ready # :get_ready, :play, :gameover
  $shake = 0

  $player = {
    x: 64.0,
    y: 110.0,
    vy: 0.0,
    rot: 0.0,
    dead: false
  }

  $pipes = []
  $particles = []

  # 初期の障害物柱を配置
  [260.0, 390.0, 520.0].each do |spawn_x|
    gap_y = 60.0 + rand(80).to_f
    $pipes << {
      x: spawn_x,
      gap_y: gap_y,
      scored: false
    }
  end
end

init_game

# 雲の定義 (x, y, speed, size)
$clouds = [
  { x: 30.0,  y: 40.0, spd: 0.35, r: 14 },
  { x: 120.0, y: 70.0, spd: 0.25, r: 18 },
  { x: 210.0, y: 30.0, spd: 0.40, r: 12 }
]

def spawn_feather_particles(x, y)
  8.times do
    ang = rand() * 6.283185
    spd = 0.6 + rand() * 2.2
    $particles << {
      x: x.to_f,
      y: y.to_f,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd,
      age: 0,
      max_age: 18 + rand(10)
    }
  end
end

def flap_player
  $player[:vy] = -4.4
  sfx(0)
  spawn_feather_particles($player[:x] + 4.0, $player[:y] + 12.0)
end

def check_collision(px, py, pipe)
  # 自機の当たり判定ボックス (12x12)
  bx = px + 2.0
  by = py + 2.0
  bw = 12.0
  bh = 12.0

  gx = pipe[:x]
  gw = PIPE_W

  # X軸の重なり
  if bx + bw > gx && bx < gx + gw
    # 上の柱 (0 .. gap_y)
    return true if by < pipe[:gap_y]
    # 下の柱 (gap_y + PIPE_GAP .. FLOOR_Y)
    return true if by + bh > pipe[:gap_y] + PIPE_GAP
  end

  false
end

def update
  $t += 1
  $shake -= 1 if $shake > 0

  # 雲のスクロール更新
  $clouds.each do |c|
    c[:x] -= c[:spd]
    c[:x] += 280.0 if c[:x] < -30.0
  end

  # パーティクル更新
  $particles.each do |pt|
    pt[:age] += 1
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
    pt[:vy] += 0.08
  end
  $particles.reject! { |pt| pt[:age] >= pt[:max_age] }

  action_pressed = btnp(:btn_a) || btnp(:up) || btnp(:mouse_l)

  if $state == :get_ready
    # ふわふわ浮遊待機
    $player[:y] = 110.0 + sin($t.to_f * 0.12) * 5.0
    $player[:rot] = 0.0
    if action_pressed
      $state = :play
      flap_player
    end

  elsif $state == :play
    if action_pressed
      flap_player
    end

    # 重力と落下・上昇角度
    $player[:vy] += 0.26
    $player[:y] += $player[:vy]
    target_rot = ($player[:vy] * 7.5).clamp(-30.0, 75.0)
    $player[:rot] = target_rot

    # 地面・天井衝突
    if $player[:y] >= FLOOR_Y - 16.0
      $player[:y] = FLOOR_Y - 16.0
      trigger_gameover
      return
    elsif $player[:y] < 0.0
      $player[:y] = 0.0
      $player[:vy] = 0.0
    end

    # 土管のスクロールと生成
    $pipes.each do |p|
      p[:x] -= 1.6

      # 通過スコア加算
      if !p[:scored] && (p[:x] + PIPE_W < $player[:x])
        p[:scored] = true
        $score += 1
        $hi_score = $score if $score > $hi_score
        sfx(1)
      end

      # 衝突判定
      if check_collision($player[:x], $player[:y], p)
        trigger_gameover
        return
      end
    end

    # 画面外に出た土管を消去し、右端へ新規スポーン
    $pipes.reject! { |p| p[:x] < -PIPE_W - 10.0 }
    if $pipes.size < 3
      last_x = $pipes.empty? ? 260.0 : $pipes.last[:x]
      gap_y = 50.0 + rand(90).to_f
      $pipes << {
        x: last_x + 130.0,
        gap_y: gap_y,
        scored: false
      }
    end

  elsif $state == :gameover
    # 落下して地面に激突
    if $player[:y] < FLOOR_Y - 16.0
      $player[:vy] += 0.35
      $player[:y] += $player[:vy]
      $player[:y] = FLOOR_Y - 16.0 if $player[:y] > FLOOR_Y - 16.0
      $player[:rot] = 90.0
    end

    if action_pressed && $t > 20
      init_game
    end
  end
end

def trigger_gameover
  return if $state == :gameover
  $state = :gameover
  $shake = 14
  sfx(2)
  spawn_feather_particles($player[:x] + 8.0, $player[:y] + 8.0)
end

def draw_pipe(p)
  px = p[:x].to_i
  gy = p[:gap_y].to_i

  # 上の柱
  if gy > 0
    rectfill(px, 0, PIPE_W.to_i, gy, 3)
    rect(px, 0, PIPE_W.to_i, gy, 0)
    # ハイライトライン
    line(px + 4, 0, px + 4, gy, 11)
    # 下端のフチ（笠）
    rectfill(px - 2, gy - 12, PIPE_W.to_i + 4, 12, 11)
    rect(px - 2, gy - 12, PIPE_W.to_i + 4, 12, 0)
  end

  # 下の柱
  by = gy + PIPE_GAP.to_i
  bh = (FLOOR_Y - by.to_f).to_i
  if bh > 0
    rectfill(px, by, PIPE_W.to_i, bh, 3)
    rect(px, by, PIPE_W.to_i, bh, 0)
    line(px + 4, by, px + 4, by + bh, 11)
    # 上端のフチ（笠）
    rectfill(px - 2, by, PIPE_W.to_i + 4, 12, 11)
    rect(px - 2, by, PIPE_W.to_i + 4, 12, 0)
  end
end

def draw
  if $shake > 0
    camera(rand(-2..2), rand(-2..2))
  else
    camera(0, 0)
  end

  # 青空グラデーション背景
  cls(12)
  rectfill(0, 140, 256, 80, 1)

  # 遠景の山
  (0..4).each do |i|
    mx = i * 70 - ($t / 4) % 70
    trifill(mx, 180, mx + 40, 120, mx + 80, 180, 13)
  end

  # 雲
  $clouds.each do |c|
    cx = c[:x].to_i
    cy = c[:y].to_i
    cr = c[:r]
    circfill(cx, cy, cr, 7)
    circfill(cx + cr - 4, cy + 2, (cr * 0.75).to_i, 7)
    circfill(cx - cr + 4, cy + 2, (cr * 0.75).to_i, 7)
  end

  # 障害物柱の描画
  $pipes.each { |p| draw_pipe(p) }

  # 地面（草地＋土のストライプ）
  fy = FLOOR_Y.to_i
  rectfill(0, fy, 256, 36, 4)
  rectfill(0, fy, 256, 6, 11)
  line(0, fy, 256, 0, 0)
  line(0, fy + 6, 256, fy + 6, 3)

  # 地面のスクロール市松模様
  offset = ($t * 2) % 16
  (0..17).each do |i|
    gx = i * 16 - offset
    line(gx, fy + 6, gx - 10, fy + 36, 2)
  end

  # 羽パーティクル
  $particles.each do |pt|
    pset(pt[:x].to_i, pt[:y].to_i, 7)
  end

  # 自機うさぎの描画（回転付き）
  spr("🐰", $player[:x].to_i, $player[:y].to_i, false, false, $player[:rot].to_i, 1.2)

  # HUD スコア（中央大きく表示）
  camera(0, 0)
  if $state == :play || $state == :get_ready
    score_str = $score.to_s
    tx = 128 - (score_str.length * 5)
    print_text(score_str, tx + 1, 31, 0)
    print_text(score_str, tx, 30, 7)
  end

  if $state == :get_ready
    rectfill(64, 150, 128, 36, 0)
    rect(64, 150, 128, 36, 10)
    print_text("FLAPPY RABBIT", 80, 156, 10)
    print_text("PRESS Z TO FLAP!", 72, 170, 7)
  elsif $state == :gameover
    # リザルトボード
    rectfill(38, 64, 180, 112, 0)
    rect(38, 64, 180, 112, 7)
    rectfill(42, 68, 172, 104, 1)

    print_text("GAME OVER", 96, 78, 8)
    print_text("SCORE:    #{$score}", 62, 102, 7)
    print_text("HI-SCORE: #{$hi_score}", 62, 116, 10)

    # メダル判定
    medal = ($score >= 20) ? "🥇" : (($score >= 10) ? "🥈" : (($score >= 3) ? "🥉" : "ー"))
    print_text("MEDAL: #{medal}", 62, 132, 14)

    if ($t / 18) % 2 == 0
      print_text("PRESS Z TO RETRY", 70, 154, 7)
    end
  end
end

__END__
@SFX 0
T240 L64 O6 C G
@SFX 1
T200 L32 O6 C E G
@SFX 2
T160 L16 O3 G E C < B

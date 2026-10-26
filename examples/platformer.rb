# ==============================================================================
# 🐰 Usakame Adventure (うさかめアドベンチャー) 🐢
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/platformer.rb
#
# 【新機能のショーケース】
# 1. 可変サイズスプライト (Variable-Size Sprites)
#    - ちびうさぎ:  16x16 (標準サイズ)
#    - スーパーうさぎ: 16x32 (人参でパワーアップ！背の高い変身キャラ)
#    - 巨大カメボス:  32x32 (大迫力の2x2タイルボスモンスター)
#    - ゴールポール: 16x32 (縦長オブジェクト)
# 2. パレット切り替え (Palette Swapping)
#    - @PALETTE 0: 標準・昼間界パレット
#    - @PALETTE 1: レッドパレット (赤カメ・スマート挙動)
#    - @PALETTE 2: ゴールドパレット (ボーナスカメ・倒すと大量コイン)
#    - @PALETTE 3: ダークパレット (巨大ボスの禍々しいオーラ)
#    - スター無敵時のリアルタイム・レインボーパレットフラッシュ
#
# 【操作方法】
#    - 左右キー (A/D): 移動（滑らかな慣性）
#    - Z / スペース / 上キー (W): ジャンプ（長押しでハイジャンプ）
#    - 下キー (S): しゃがみ
#    - R: リスタート
# ==============================================================================

config(
  width: 256,
  height: 224,
  scale: 2.0,
  title: "🐰 Usakame Adventure 🐢 (Variable Sprites & Palettes)"
)

# ------------------------------------------------------------------------------
# 定数 & ゲーム状態
# ------------------------------------------------------------------------------
GRAVITY = 0.28
MAX_FALL = 6.0
WALK_ACCEL = 0.18
WALK_MAX = 1.8
RUN_MAX = 2.6
FRICTION = 0.85

$game_state = :play # :play, :clear, :gameover
$t = 0
$camera_x = 0

# プレイヤー状態
$p = {
  x: 24.0,
  y: 160.0,
  vx: 0.0,
  vy: 0.0,
  on_ground: false,
  flip_x: false,
  is_super: false,     # false = 16x16, true = 16x32
  transform_timer: 0,  # 変身中の一時停止・点滅
  star_timer: 0,       # スター無敵時間
  dead: false,
  crouch: false
}

$score = 0
$coins = 0

# ------------------------------------------------------------------------------
# マップ生成 (横長ステージ: 幅 64セル x 高さ 14セル)
# ------------------------------------------------------------------------------
MAP_WIDTH = 64
MAP_HEIGHT = 14

def init_stage
  # マップをクリア
  MAP_WIDTH.times do |cx|
    MAP_HEIGHT.times do |cy|
      mset(cx, cy, 0)
    end
  end

  # 地面 (Y: 12, 13)
  MAP_WIDTH.times do |cx|
    # 穴（ピット）をいくつか配置
    next if cx == 18 || cx == 19 || cx == 38 || cx == 39
    mset(cx, 12, 32) # 草原
    mset(cx, 13, 33) # 土
  end

  # 足場 & ブロックの配置
  # エリア1: 基本ジャンプ
  mset(6, 9, 35)  # ハテナブロック (人参)
  mset(7, 9, 34)  # レンガ
  mset(8, 9, 35)  # ハテナブロック (コイン)
  mset(9, 9, 34)  # レンガ

  # 階段状の丘
  mset(14, 11, 32)
  mset(15, 11, 32); mset(15, 10, 32)
  mset(16, 11, 32); mset(16, 10, 32); mset(16, 9, 32)

  # エリア2: 空中足場
  [22, 23, 24, 25].each { |cx| mset(cx, 8, 34) }
  mset(23, 5, 35) # 高い位置のハテナブロック

  # パイプ風の段差
  [30, 31].each do |cx|
    mset(cx, 11, 33)
    mset(cx, 10, 32)
  end

  # エリア3: ボス手前の足場
  [43, 44, 45, 46, 47].each { |cx| mset(cx, 8, 34) }

  # ゴールエリア (58セル目)
  # ゴールポールは 16x32 のスプライトとして描画
end

init_stage

# ------------------------------------------------------------------------------
# エンティティ（敵・アイテム・パーティクル）
# ------------------------------------------------------------------------------
$enemies = [
  # 緑カメ (通常) - pal: 0
  { x: 120.0, y: 176.0, vx: -0.6, type: :kame, pal: 0, hp: 1, shell: false, dead: false },
  # 赤カメ (崖折り返し) - pal: 1
  { x: 230.0, y: 112.0, vx: -0.8, type: :red_kame, pal: 1, hp: 1, shell: false, dead: false },
  # 金カメ (ボーナス) - pal: 2
  { x: 380.0, y: 176.0, vx: -1.2, type: :gold_kame, pal: 2, hp: 1, shell: false, dead: false },
  # 巨大カメボス (32x32) - pal: 3
  { x: 740.0, y: 160.0, vx: -0.5, type: :boss, pal: 3, hp: 3, max_hp: 3, jump_timer: 60, dead: false }
]

$items = [
  # スーパー人参 (パワーアップ 16x16)
  { x: 96.0, y: 128.0, vx: 0.8, vy: 0.0, type: :carrot, active: true },
  # コイン
  { x: 128.0, y: 112.0, type: :coin, active: true },
  { x: 144.0, y: 112.0, type: :coin, active: true },
  { x: 368.0, y: 112.0, type: :coin, active: true },
  { x: 384.0, y: 96.0,  type: :coin, active: true },
  { x: 400.0, y: 112.0, type: :coin, active: true }
]

$particles = []

def add_particle(x, y, vx, vy, col, life, size = 2)
  $particles << { x: x, y: y, vx: vx, vy: vy, col: col, life: life, max_life: life, size: size }
end

def spawn_stars(x, y, count = 8, col = 10)
  count.times do
    ang = rand(360) * Math::PI / 180.0
    spd = rand(15..35) / 10.0
    add_particle(x, y, Math.cos(ang) * spd, Math.sin(ang) * spd, col, 20 + rand(10), 3)
  end
end

# ------------------------------------------------------------------------------
# タイル衝突判定ヘルパー
# ------------------------------------------------------------------------------
def solid_at?(x, y)
  cx = (x / 16).to_i
  cy = (y / 16).to_i
  return false if cx < 0 || cx >= MAP_WIDTH || cy < 0 || cy >= MAP_HEIGHT
  tile = mget(cx, cy)
  tile == 32 || tile == 33 || tile == 34 || tile == 35 || tile == 37
end

# ------------------------------------------------------------------------------
# メイン更新ループ (update)
# ------------------------------------------------------------------------------
def update
  $t += 1

  if btnp(6) || btn(7) # R: リスタート
    reset
    return
  end

  if $p[:transform_timer] > 0
    $p[:transform_timer] -= 1
    return # 変身演出中は動きを停止
  end

  if $p[:star_timer] > 0
    $p[:star_timer] -= 1
    # 星の粒子を放出
    if $t % 3 == 0
      add_particle($p[:x] + rand(16), $p[:y] + rand(20), 0, -1.0, 10 + rand(4), 15, 2)
    end
  end

  # --- プレイヤー移動 ---
  pw = 12
  ph = $p[:is_super] ? 28 : 14

  # 入力
  move_x = 0
  move_x -= 1 if btn(0) # 左
  move_x += 1 if btn(1) # 右
  jump_btn = btn(4) || btn(2) # Z または 上
  jump_press = btnp(4) || btnp(2)
  $p[:crouch] = btn(3) && $p[:on_ground] # 下でしゃがみ

  if move_x != 0 && !$p[:crouch]
    $p[:vx] += move_x * WALK_ACCEL
    max_s = btn(5) ? RUN_MAX : WALK_MAX # Xでダッシュ
    $p[:vx] = [[$p[:vx], -max_s].max, max_s].min
    $p[:flip_x] = (move_x < 0)
  else
    $p[:vx] *= FRICTION
    $p[:vx] = 0 if $p[:vx].abs < 0.05
  end

  # ジャンプ
  if jump_press && $p[:on_ground]
    jump_power = $p[:is_super] ? -5.8 : -5.0
    $p[:vy] = jump_power
    $p[:on_ground] = false
    sfx(:jump)
    spawn_stars($p[:x] + 8, $p[:y] + ph, 4, 7)
  end

  # 可変ジャンプ（ボタンを離すと上昇が弱まる）
  if !jump_btn && $p[:vy] < -1.5
    $p[:vy] *= 0.7
  end

  # 重力
  $p[:vy] += GRAVITY
  $p[:vy] = MAX_FALL if $p[:vy] > MAX_FALL

  # X軸移動 & 衝突
  nx = $p[:x] + $p[:vx]
  box_top = $p[:y] + ($p[:is_super] ? 4.0 : 2.0)
  box_bot = $p[:y] + ph.to_f

  if $p[:vx] > 0
    if solid_at?(nx + pw, box_top) || solid_at?(nx + pw, box_bot - 1.0)
      nx = (((nx + pw) / 16.0).to_i * 16 - pw).to_f - 0.01
      $p[:vx] = 0.0
    end
  elsif $p[:vx] < 0
    if solid_at?(nx, box_top) || solid_at?(nx, box_bot - 1.0)
      nx = (((nx) / 16.0).to_i * 16 + 16).to_f
      $p[:vx] = 0.0
    end
  end
  $p[:x] = nx

  # Y軸移動 & 衝突
  ny = $p[:y] + $p[:vy]
  $p[:on_ground] = false

  if $p[:vy] > 0 # 下降
    if solid_at?($p[:x] + 2.0, ny + ph.to_f) || solid_at?($p[:x] + (pw - 2).to_f, ny + ph.to_f)
      ny = (((ny + ph.to_f) / 16.0).to_i * 16 - ph).to_f
      $p[:vy] = 0.0
      $p[:on_ground] = true
    end
  elsif $p[:vy] < 0 # 上昇（頭突き）
    head_y = ny + ($p[:is_super] ? 2.0 : 0.0)
    hit_left = solid_at?($p[:x] + 2.0, head_y)
    hit_right = solid_at?($p[:x] + (pw - 2).to_f, head_y)

    if hit_left || hit_right
      hit_cx = ((hit_left ? $p[:x] + 2.0 : $p[:x] + (pw - 2).to_f) / 16.0).to_i
      hit_cy = (head_y / 16.0).to_i
      tile = mget(hit_cx, hit_cy)

      if tile == 35 # ハテナブロック
        mset(hit_cx, hit_cy, 37) # 空きブロック
        sfx(:powerup)
        # 人参またはコインを出現
        $items << { x: hit_cx * 16.0, y: (hit_cy - 1) * 16.0, vx: 0.8, vy: -2.0, type: :carrot, active: true }
      elsif tile == 34 && $p[:is_super] # スーパーうさぎならレンガ破壊！
        mset(hit_cx, hit_cy, 0)
        sfx(:explosion)
        spawn_stars(hit_cx * 16.0 + 8.0, hit_cy * 16.0 + 8.0, 8, 9)
      else
        sfx(:hit)
      end

      ny = (hit_cy * 16 + 16).to_f - ($p[:is_super] ? 2.0 : 0.0)
      $p[:vy] = 0.0
    end
  end
  $p[:y] = ny

  # 奈落落下チェック
  if $p[:y] > 224.0
    sfx(:gameover)
    $game_state = :gameover
  end

  # --- アイテム処理 ---
  $items.each do |it|
    next unless it[:active]
    # 人参の移動
    if it[:type] == :carrot
      it[:x] += it[:vx]
      it[:vy] += GRAVITY
      it[:y] += it[:vy]
      if solid_at?(it[:x] + 8.0, it[:y] + 16.0)
        it[:y] = (((it[:y] + 16.0) / 16.0).to_i * 16 - 16).to_f
        it[:vy] = -1.2 # ポンポン跳ねる
      end
      if solid_at?(it[:x] + (it[:vx] > 0 ? 16.0 : 0.0), it[:y] + 8.0)
        it[:vx] = -it[:vx]
      end
    end

    # 取得判定
    if ($p[:x] - it[:x]).abs < 14.0 && ($p[:y] - it[:y]).abs < ph.to_f
      it[:active] = false
      if it[:type] == :carrot
        sfx(:powerup)
        $score += 1000
        unless $p[:is_super]
          $p[:is_super] = true
          $p[:y] -= 16.0 # 背が高くなるので位置を上に補正
          $p[:transform_timer] = 20 # 変身フリーズ演出
          spawn_stars($p[:x] + 8.0, $p[:y] + 16.0, 16, 11)
        end
      elsif it[:type] == :coin
        sfx(:coin)
        $coins += 1
        $score += 200
        spawn_stars(it[:x] + 8.0, it[:y] + 8.0, 6, 10)
      end
    end
  end

  # --- 敵キャラクター処理 ---
  $enemies.each do |e|
    next if e[:dead]

    # ボスの挙動 (32x32)
    if e[:type] == :boss
      e[:jump_timer] -= 1
      if e[:jump_timer] <= 0
        e[:vx] = ($p[:x] < e[:x]) ? -0.8 : 0.8
        e[:jump_timer] = 90
      end
      e[:x] += e[:vx]
      # 左右の移動範囲制限
      if e[:x] < 680.0 || e[:x] > 840.0
        e[:vx] = -e[:vx]
      end

      # 踏みつけ判定 (32x32)
      bx = e[:x] + 4.0
      bw = 24.0
      by = e[:y] + 4.0
      bh = 28.0

      if ($p[:x] + pw > bx) && ($p[:x] < bx + bw) &&
         ($p[:y] + ph.to_f > by) && ($p[:y] < by + bh)
        if $p[:vy] > 0 && ($p[:y] + ph.to_f - $p[:vy] <= by + 12.0)
          # 踏んだ！
          $p[:vy] = -4.5
          e[:hp] -= 1
          sfx(:hit)
          spawn_stars(e[:x] + 16.0, e[:y] + 8.0, 12, 8)
          if e[:hp] <= 0
            e[:dead] = true
            sfx(:explosion)
            $score += 5000
            spawn_stars(e[:x] + 16.0, e[:y] + 16.0, 24, 10)
          end
        elsif $p[:star_timer] > 0
          e[:dead] = true
          sfx(:explosion)
          spawn_stars(e[:x] + 16.0, e[:y] + 16.0, 24, 10)
        else
          # ダメージ
          player_hit
        end
      end
      next
    end

    # 通常カメの挙動 (16x16)
    if e[:shell]
      # 甲羅が滑っている
      e[:x] += e[:vx]
      if solid_at?(e[:x] + (e[:vx] > 0 ? 16.0 : 0.0), e[:y] + 8.0)
        e[:vx] = -e[:vx]
        sfx(:hit)
      end
    else
      e[:x] += e[:vx]
      # 赤カメは崖で折り返す
      if e[:type] == :red_kame
        foot_x = e[:x] + (e[:vx] > 0 ? 16.0 : 0.0)
        unless solid_at?(foot_x, e[:y] + 18.0)
          e[:vx] = -e[:vx]
        end
      end
      if solid_at?(e[:x] + (e[:vx] > 0 ? 16.0 : 0.0), e[:y] + 8.0)
        e[:vx] = -e[:vx]
      end
    end

    # プレイヤーとの接触判定
    if ($p[:x] + pw > e[:x] + 2.0) && ($p[:x] < e[:x] + 14.0) &&
       ($p[:y] + ph.to_f > e[:y] + 2.0) && ($p[:y] < e[:y] + 16.0)
      if $p[:vy] > 0 && ($p[:y] + ph.to_f - $p[:vy] <= e[:y] + 8.0)
        # 上から踏みつけた！
        $p[:vy] = -4.2
        sfx(:hit)
        if !e[:shell]
          e[:shell] = true
          e[:vx] = 0.0 # 踏むと止まる
          $score += (e[:type] == :gold_kame ? 1000 : 400)
          if e[:type] == :gold_kame
            # 金カメは大量コイン放出！
            5.times { |i| $items << { x: e[:x] + (i * 4).to_f, y: e[:y] - 8.0, type: :coin, active: true } }
          end
        else
          # 甲羅をキック！
          e[:vx] = ($p[:x] < e[:x]) ? 3.5 : -3.5
          sfx(:hit)
        end
      elsif $p[:star_timer] > 0
        e[:dead] = true
        sfx(:explosion)
        spawn_stars(e[:x] + 8.0, e[:y] + 8.0, 12, 10)
      elsif e[:shell] && e[:vx] == 0.0
        # 止まっている甲羅を歩いてキック
        e[:vx] = ($p[:x] < e[:x]) ? 3.5 : -3.5
        sfx(:hit)
      else
        player_hit
      end
    end
  end

  # ゴール判定 (X: 928 付近)
  if $p[:x] > 920.0 && $game_state == :play
    $game_state = :clear
    sfx(:powerup)
    spawn_stars($p[:x] + 8.0, $p[:y] + 8.0, 30, 10)
  end

  # パーティクル更新
  $particles.each do |pt|
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
    pt[:life] -= 1
  end
  $particles.reject! { |pt| pt[:life] <= 0 }

  # カメラスクロール（プレイヤーを画面中央付近に追従）
  target_cam = $p[:x] - 100.0
  target_cam = [[target_cam, 0.0].max, (MAP_WIDTH * 16 - 256).to_f].min
  $camera_x += (target_cam - $camera_x) * 0.1
end

def player_hit
  if $p[:is_super]
    # スーパー状態なら 16x16 に縮小
    $p[:is_super] = false
    $p[:transform_timer] = 20
    sfx(:hit)
    spawn_stars($p[:x] + 8, $p[:y] + 8, 12, 8)
  else
    sfx(:gameover)
    $game_state = :gameover
  end
end

# ------------------------------------------------------------------------------
# メイン描画ループ (draw)
# ------------------------------------------------------------------------------
def draw
  # 昼空の背景
  cls(12)

  # 遠景の山と雲（視差パララックス効果）
  cam = $camera_x
  circfill(60 - (cam * 0.2) % 300, 40, 24, 7)
  circfill(80 - (cam * 0.2) % 300, 36, 30, 7)
  circfill(105 - (cam * 0.2) % 300, 42, 20, 7)

  # 遠くの緑の山
  trifill(30 - (cam * 0.3) % 256, 192, 100 - (cam * 0.3) % 256, 110, 170 - (cam * 0.3) % 256, 192, 3)
  trifill(140 - (cam * 0.3) % 256, 192, 220 - (cam * 0.3) % 256, 95, 300 - (cam * 0.3) % 256, 192, 11)

  # カメラ移動設定
  camera(cam.to_i, 0)

  # タイルマップ描画
  map(0, 0, 0, 0, MAP_WIDTH, MAP_HEIGHT)

  # ゴールポール (16x32 の大型スプライト)
  spr(38, 928, 128)

  # アイテム描画
  $items.each do |it|
    next unless it[:active]
    if it[:type] == :carrot
      spr(15, it[:x], it[:y])
    elsif it[:type] == :coin
      # コインのアニメーション
      spr(36, it[:x], it[:y])
    end
  end

  # 敵キャラクター描画 (パレット切り替えを活用！)
  $enemies.each do |e|
    next if e[:dead]
    frame = ($t / 8) % 2

    if e[:type] == :boss
      # 巨大ボス (32x32 可変スプライト + @PALETTE 3 のダークカラー)
      boss_spr = (frame == 0) ? 8 : 10
      spr(boss_spr, e[:x], e[:y], e[:vx] > 0)
      # ボスのHPバー
      hp_w = (e[:hp].to_f / e[:max_hp] * 32).to_i
      rectfill(e[:x], e[:y] - 8, 32, 4, 0)
      rectfill(e[:x], e[:y] - 8, hp_w, 4, 8)
    elsif e[:shell]
      # 甲羅スプライト (blt でパレットスワップ描画！)
      blt(e[:x], e[:y], 0, 224, 0, 16, 16, 0, 1.0, e[:pal])
    else
      # 歩行カメ (blt でパレット 0:緑, 1:赤, 2:金 を適用！)
      u = 192 + frame * 16
      w = (e[:vx] > 0) ? -16 : 16
      blt(e[:x], e[:y], 0, u, 0, w, 16, 0, 1.0, e[:pal])
    end
  end

  # プレイヤー描画 (可変サイズ 16x16 or 16x32 + パレットフラッシュ)
  unless $p[:dead]
    p_frame = ($t / 6) % 2
    draw_spr_id = 0

    if $p[:is_super]
      # 【16x32 可変サイズスプライト】
      if !$p[:on_ground]
        draw_spr_id = 6 # ジャンプ (16x32)
      elsif $p[:vx].abs > 0.1
        draw_spr_id = (p_frame == 0) ? 4 : 5 # 歩行 (16x32)
      else
        draw_spr_id = 4 # 待機 (16x32)
      end
    else
      # 【16x16 標準スプライト】
      if !$p[:on_ground]
        draw_spr_id = 2 # ジャンプ (16x16)
      elsif $p[:crouch]
        draw_spr_id = 3 # しゃがみ (16x16)
      elsif $p[:vx].abs > 0.1
        draw_spr_id = (p_frame == 0) ? 0 : 1 # 歩行 (16x16)
      else
        draw_spr_id = 0 # 待機 (16x16)
      end
    end

    # 無敵・変身時の点滅またはレインボーパレット
    visible = true
    visible = ($t % 4 < 2) if $p[:transform_timer] > 0

    if visible
      if $p[:star_timer] > 0
        # パレットスワップで虹色点滅！
        pal_id = ($t / 3) % 3
        # spr(draw_spr_id) は自動サイズで描画される
        # パレット上書きは pal_bank で一括適用
        pal_bank(pal_id)
        spr(draw_spr_id, $p[:x], $p[:y], $p[:flip_x])
        pal_bank(0)
      else
        # 通常描画（登録された定義サイズで spr が自動描画！）
        spr(draw_spr_id, $p[:x], $p[:y], $p[:flip_x])
      end
    end
  end

  # パーティクル描画
  $particles.each do |pt|
    rectfill(pt[:x], pt[:y], pt[:size], pt[:size], pt[:col])
  end

  # カメラリセット (UI描画用)
  camera(0, 0)

  # --- HUD (ステータス表示) ---
  rectfill(0, 0, 256, 18, 0)
  print_text("USAGI", 8, 2, 7)
  print_text(format("%06d", $score), 8, 10, 10)

  print_text("COINS", 90, 2, 7)
  print_text(format("*%02d", $coins), 90, 10, 10)

  # プレイヤー状態表示バッジ
  if $p[:is_super]
    rectfill(150, 4, 46, 10, 8)
    print_text("SUPER", 154, 5, 7)
  else
    rectfill(150, 4, 46, 10, 5)
    print_text("SMALL", 154, 5, 6)
  end

  print_text("WORLD 1-1", 200, 6, 7)

  # ゲームオーバー / クリア表示
  if $game_state == :clear
    rectfill(48, 80, 160, 48, 0)
    rect(48, 80, 160, 48, 10)
    print_text("COURSE CLEAR!", 80, 92, 10)
    print_text("PRESS R TO RESTART", 68, 108, 7)
  elsif $game_state == :gameover
    rectfill(48, 80, 160, 48, 0)
    rect(48, 80, 160, 48, 8)
    print_text("GAME OVER", 96, 92, 8)
    print_text("PRESS R TO RETRY", 72, 108, 7)
  end
end

__END__
# ==============================================================================
# カラーパレット定義 (@PALETTE)
# ==============================================================================

# @PALETTE 0: 標準・昼間界パレット (SFC スーパーマリオワールド風)
@PALETTE 0
0: #101018  # フチ・シャドウ黒
1: #1B263B  # 濃紺
2: #A81000  # 濃赤
3: #008840  # 中間グリーン
4: #8B4513  # レンガブラウン
5: #5F574F  # 石グレー
6: #C2C3C7  # 明るいグレー
7: #FFF1E8  # うさぎの白
8: #FF004D  # 鮮やかな赤
9: #FFA300  # オレンジ（人参・レンガハイライト）
A: #FFEC27  # ゴールド・コイン
B: #58F878  # 鮮やかな黄緑（ハイライト）
C: #29ADFF  # 晴天の空色
D: #83769C  # 紫
E: #FF77A8  # うさぎの耳ピンク
F: #FFCCAA  # 肌色・クリーム

# @PALETTE 1: レッドパレット (赤カメ用・俊敏な敵)
@PALETTE 1
3: #C02000  # 甲羅の深赤
B: #FF6040  # 甲羅のハイライトオレンジ

# @PALETTE 2: ゴールドパレット (ボーナスカメ・スター無敵用)
@PALETTE 2
3: #D49000  # 黄金の影
B: #FFF040  # 輝くイエロー

# @PALETTE 3: ダークパレット (巨大カメボス専用)
@PALETTE 3
3: #4A154B  # 凶悪なダークパープル
B: #9B30FF  # 禍々しいネオンバイオレット
8: #FF1040  # 赤く光る目

# ==============================================================================
# スプライト定義 (@SPRITE)
# ==============================================================================

# --- ちびうさぎ (16x16) ---
# スロット 0: 歩行1
@SPRITE 0 16x16
....00....00....
...0EE0..0EE0...
...0EE0..0EE0...
...0770..0770...
...0777007770...
..077777777770..
..070777777070..
..070777777070..
..07777EE77770..
...0777777770...
..007788887700..
.07788888888770.
.07788888888770.
..00770..07700..
...0770..0770...
....00....00....

# スロット 1: 歩行2
@SPRITE 1 16x16
....00....00....
...0EE0..0EE0...
...0EE0..0EE0...
...0770..0770...
...0777007770...
..077777777770..
..070777777070..
..070777777070..
..07777EE77770..
...0777777770...
..007788887700..
.07788888888770.
..008888888800..
...077000770....
...0770..0770...
....00....00....

# スロット 2: ジャンプ
@SPRITE 2 16x16
...00......00...
..0EE0....0EE0..
..0EE0....0EE0..
...0770..0770...
....07700770....
...0777777770...
..070777777070..
..070777777070..
..07777EE77770..
...0777777770...
..077888888770..
.07788888888770.
.00.08888880.00.
....07700770....
...0770..0770...
....00....00....

# スロット 3: しゃがみ
@SPRITE 3 16x16
................
................
....00....00....
...0EE0..0EE0...
...0EE0..0EE0...
...0777007770...
..077777777770..
..070777777070..
..07777EE77770..
..077888888770..
.07788888888770.
.00088888888000.
..007777777700..
...0000000000...
................
................

# --- スーパーうさぎ (16x32 可変サイズ！) ---
# スロット 4: スーパー歩行1 (スロット4と20を占有)
@SPRITE 4 16x32
.....00....00...
....0EE0..0EE0..
....0EE0..0EE0..
....0EE0..0EE0..
....0770..0770..
....0770..0770..
....0777007770..
...07777777770..
..0777777777770.
..0707777770770.
..0707777770770.
..07777EE777770.
...07777777770..
...0077777700...
..0CC000000CC0..
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
..00CC8888CC00..
...0888888880...
...088AA88AA0...
...0888888880...
...0888888880...
....07777770....
...0777..0777...
...0777..0777...
...0770..0770...
...0770..0770...
..00770..07700..
.077770..077770.
.077770..077770.
..0000....0000..

# スロット 5: スーパー歩行2 (スロット5と21を占有)
@SPRITE 5 16x32
.....00....00...
....0EE0..0EE0..
....0EE0..0EE0..
....0EE0..0EE0..
....0770..0770..
....0770..0770..
....0777007770..
...07777777770..
..0777777777770.
..0707777770770.
..0707777770770.
..07777EE777770.
...07777777770..
...0077777700...
..0CC000000CC0..
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
..00CC8888CC00..
...0888888880...
...088AA88AA0...
...0888888880...
...0888888880...
....07777770....
....07777770....
...0770..0770...
...0770...0770..
...0770...0770..
..00770....0770.
.077770....0770.
..0000......000.
................

# スロット 6: スーパージャンプ (スロット6と22を占有)
@SPRITE 6 16x32
....00......00..
...0EE0....0EE0.
...0EE0....0EE0.
...0EE0....0EE0.
....0770..0770..
.....07700770...
....0777777770..
...077777777770.
...070777777070.
...070777777070.
...07777EE77770.
....0777777770..
...0077777700...
..0CC000000CC0..
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
.0CCCC8888CCCC0.
..00CC8888CC00..
...0888888880...
...088AA88AA0...
...0888888880...
...0888888880...
....07700770....
...0770..0770...
...0770..0770...
..0770....0770..
..0770....0770..
.07770....07770.
.07770....07770.
..000......000..
................
................

# --- 巨大カメボス (32x32 可変サイズ！) ---
# スロット 8: ボス歩行1 (スロット8, 9, 24, 25を占有)
@SPRITE 8 32x32 pal:3
............00000000............
..........003333333300..........
........0033BBBBBBBB3300........
.......033BBBBBBBBBBBB330.......
......03BBBB33333333BBBB30......
.....03BBB330000000033BBB30.....
....03BBB300FFFFFFFF003BBB30....
...03BBB30FFFFFFFFFFFF03BBB30...
...03BB30FFFF88FF88FFFF03BB30...
..03BBB30FFFF80FF80FFFF03BBB30..
..03BB30FFFFFF0000FFFFFF03BB30..
..03BB30FFFFFFFFFFFFFFFF03BB30..
.03BBB30FFFFFFEEEEFFFFFF03BBB30.
.03BB300FFFFFFFFFFFFFFFF003BB30.
.03BB30.00FFFFFFFFFFFF00.03BB30.
.03BB30...000000000000...03BB30.
.03BB30....0333333330....03BB30.
.03BB30...033BBBBBB330...03BB30.
.03BB30..03BBBBBBBBBB30..03BB30.
..03BB3003BBBBBBBBBBBB3003BB30..
..03BB333BBBBBBBBBBBBBB333BB30..
..003BBBBBBBBBBBBBBBBBBBBBB300..
...0033BBBBBBBBBBBBBBBBBB3300...
....003333BBBBBBBBBBBB333300....
......00333333333333333300......
........0000333333330000........
...........0333..3330...........
..........0FFF0..0FFF0..........
.........0FFFF0..0FFFF0.........
.........0FFFF0..0FFFF0.........
..........0000....0000..........
................................

# スロット 10: ボス歩行2 (スロット10, 11, 26, 27を占有)
@SPRITE 10 32x32 pal:3
............00000000............
..........003333333300..........
........0033BBBBBBBB3300........
.......033BBBBBBBBBBBB330.......
......03BBBB33333333BBBB30......
.....03BBB330000000033BBB30.....
....03BBB300FFFFFFFF003BBB30....
...03BBB30FFFFFFFFFFFF03BBB30...
...03BB30FFFF88FF88FFFF03BB30...
..03BBB30FFFF80FF80FFFF03BBB30..
..03BB30FFFFFF0000FFFFFF03BB30..
..03BB30FFFFFFFFFFFFFFFF03BB30..
.03BBB30FFFFFFEEEEFFFFFF03BBB30.
.03BB300FFFFFFFFFFFFFFFF003BB30.
.03BB30.00FFFFFFFFFFFF00.03BB30.
.03BB30...000000000000...03BB30.
.03BB30....0333333330....03BB30.
.03BB30...033BBBBBB330...03BB30.
.03BB30..03BBBBBBBBBB30..03BB30.
..03BB3003BBBBBBBBBBBB3003BB30..
..03BB333BBBBBBBBBBBBBB333BB30..
..003BBBBBBBBBBBBBBBBBBBBBB300..
...0033BBBBBBBBBBBBBBBBBB3300...
....003333BBBBBBBBBBBB333300....
......00333333333333333300......
........0000333333330000........
..........0333....3330..........
.........0FFF0....0FFF0.........
........0FFFF0....0FFFF0........
........0FFFF0....0FFFF0........
.........0000......0000.........
................................

# --- 小型カメ (16x16) ---
# スロット 12: カメ歩行1 (pal: 0 で緑、pal: 1 で赤、pal: 2 で金)
@SPRITE 12 16x16
......0000......
....00FFFF00....
...0FFFFFFFF0...
..0FFFF00FFFF0..
..0FFFF00FFFF0..
..0FFFFFFFFF00..
..00FFFFFFF0330.
.03300000003BB30
03BB3333333BBBB3
03BBBBBBBBBBBBB3
03BBBBBBBBBBBBB3
.033333333333330
..0000000000000.
...0FFF0..0FFF0.
...0FFF0..0FFF0.
....000....000..

# スロット 13: カメ歩行2
@SPRITE 13 16x16
......0000......
....00FFFF00....
...0FFFFFFFF0...
..0FFFF00FFFF0..
..0FFFF00FFFF0..
..0FFFFFFFFF00..
..00FFFFFFF0330.
.03300000003BB30
03BB3333333BBBB3
03BBBBBBBBBBBBB3
03BBBBBBBBBBBBB3
.033333333333330
..0000000000000.
....0FFF00FFF0..
....0FFF00FFF0..
.....000..000...

# スロット 14: カメ甲羅 (16x16)
@SPRITE 14 16x16
................
.....000000.....
...0033BBBB00...
..033BBBBBBBB0..
.03BBBBBBBBBBB0.
.03BB333333BBB0.
03BBB300003BBB30
03BBB30..03BBB30
03BBB300003BBB30
03BB33333333BB30
03BBBBBBBBBBBBB0
.03BBBBBBBBBBB0.
..033BBBBBBBB0..
...0033333300...
.....000000.....
................

# スロット 15: スーパー人参 (16x16)
@SPRITE 15 16x16
.......00.......
.....00BB00.....
....0BB33BB0....
...00BB33BB00...
.....009900.....
....09999990....
...099FFAA990...
...099FFAA990...
...0999999990...
....099FFAA90...
....099FFAA90...
.....0999990....
.....099FFA0....
......09990.....
.......090......
........0.......

# --- マップタイル & オブジェクト ---
# スロット 32: 草原ブロック (16x16)
@SPRITE 32 16x16
BBBBBBBBBBBBBBBB
3333333333333333
4443344444334444
4444444444444444
4499444444449944
4999944444499994
4499444444449944
4444444444444444
4444444444444444
4444449944444444
4444499994444444
4444449944444444
4444444444444444
4444444444444444
4444444444444444
0000000000000000

# スロット 33: 土ブロック (16x16)
@SPRITE 33 16x16
4444444444444444
4444444444444444
4499444444449944
4999944444499994
4499444444449944
4444444444444444
4444444444444444
4444449944444444
4444499994444444
4444449944444444
4444444444444444
4444444444444444
4499444444449944
4999944444499994
4499444444449944
0000000000000000

# スロット 34: レンガブロック (16x16)
@SPRITE 34 16x16
9999999099999990
9444444094444440
9444444094444440
0000000000000000
9990999999909990
9440944444409440
9440944444409440
0000000000000000
9999999099999990
9444444094444440
9444444094444440
0000000000000000
9990999999909990
9440944444409440
9440944444409440
0000000000000000

# スロット 35: ハテナブロック (16x16)
@SPRITE 35 16x16
AAAAAAAAAAAAAAAA
AFFFFFFFFFFFFFF9
AF000000000000F9
AF0AAAAAAAAAA0F9
AF0AAA0000AAA0F9
AF0AA00AA00AA0F9
AF0AAAAAA00AA0F9
AF0AAAAA00AAA0F9
AF0AAAA00AAAA0F9
AF0AAAA00AAAA0F9
AF0AAAAAAAAAA0F9
AF0AAAA00AAAA0F9
AF0AAAA00AAAA0F9
AF0AAAAAAAAAA0F9
AF000000000000F9
9999999999999999

# スロット 36: コイン (16x16)
@SPRITE 36 16x16
.....000000.....
...00AAAAAA00...
..0AAFFFFFFFAA0.
.0AAFF000000FFA0
.0AAFF0AAAA0FFA0
0AAFF0AAAAAA0FFA
0AAFF0AAAAAA0FFA
0AAFF0AAAAAA0FFA
0AAFF0AAAAAA0FFA
0AAFF0AAAAAA0FFA
0AAFF0AAAAAA0FFA
.0AAFF0AAAA0FFA0
.0AAFF000000FFA0
..0AAFFFFFFFAA0.
...00AAAAAA00...
.....000000.....

# スロット 37: 空きブロック (16x16)
@SPRITE 37 16x16
6666666666666666
6555555555555551
6500000000000051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6505555555555051
6500000000000051
1111111111111111

# スロット 38: ゴールポール (16x32 可変サイズ！)
@SPRITE 38 16x32
.......0AA0.....
......0AAAA0....
......0AAAA0....
.......0AA0.....
........660AAA0.
........660AAAA0
........660AAA0.
........660.....
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
........66......
.......0550.....
......055550....
......000000....

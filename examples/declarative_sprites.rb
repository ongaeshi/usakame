# ==============================================================================
# Declarative Sprites & New Draw APIs Showcase (examples/declarative_sprites.rb)
# ==============================================================================
# [新記法・新APIデモ]
# - @SPRITE :name による名前付き定義・2次元オートパッキング・アニメーション (--- / 複数絵文字)
# - @SPRITE :wall # 🧱 等のマップ用1文字エイリアスとシンボル指定 @MAP
# - spr_id(:name, frame, loop) によるループ再生 & クランプ(loop=false)再生
# - spr(:name, x, y, flip_x, pal) によるシンボル直接描画 & 一時パレットスワップ
# - spr_ext / spr_rot による Squash & Stretch (縦横独立拡縮) と中心ピボット回転
# - spr_clip & blt(:name) によるローカル切り抜き描画 (地面から出現する32x32ゴーレム等)
# - mget / mset(:symbol) / mset("#") によるシンボル・エイリアス対応タイルマップ操作
#
# 操作方法:
#   矢印キー / WASD : プレイヤー (:hero) 移動 (移動時に Squash & Stretch)
#   Z / Space       : 剣スラッシュ攻撃 (:slash の loop=false クランプ再生 & 敵ヒット)
#   X / Enter       : 向いているマスの壁 ('#') を設置/撤去 + スライムの属性パレット切替
# ==============================================================================

$t = 0

# プレイヤー状態
$px = 64.0
$py = 64.0
$vx = 0.0
$vy = 0.0
$flip_x = false
$dir_x = 1
$dir_y = 0
$walk_frame = 0.0
$squash_x = 1.0
$squash_y = 1.0

# 剣攻撃アニメーション (spr_id の loop = false クランプ再生デモ用)
$slash_timer = 0
$slash_frame = 0.0
$slash_x = 0.0
$slash_y = 0.0
$slash_flip = false

# スライム状態 (Squash & Stretch + pal引数による一時パレットスワップ)
$slime_x = 144.0
$slime_y = 80.0
$slime_vx = 0.8
$slime_vy = 0.5
$slime_pal_idx = 0
$SLIME_PALS = [2, 3, 4, 1]
$SLIME_PAL_NAMES = ["PAL:2 EMERALD", "PAL:3 MAGMA", "PAL:4 FROST", "PAL:1 GOLD"]
$slime_hit_timer = 0

# 32x32 ゴーレム状態 (spr_clip による地面からのせり出し演出)
$golem_x = 184
$golem_y = 48
$golem_reveal = 0.0
$golem_dir = 1
$golem_hit_timer = 0
$golem_hp = 5
$golem_max_hp = 5

# 8x8 小型スプライト (:spark) パーティクル (実サイズ中心ピボット回転 spr_rot)
$sparks = []

# スコア (コイン・宝箱回収)
$score = 0
$chests_opened = 0

# ボタンエッジ判定用
$prev_btn4 = false
$prev_btn5 = false

def spawn_sparks(x, y, count, pal_id)
  i = 0
  while i < count
    ang = (i.to_f / count.to_f) * 6.28318 + rand() * 0.5
    spd = 1.0 + rand() * 1.8
    $sparks << {
      x: x,
      y: y,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd - 0.5,
      rot: rand(360),
      vrot: rand(12..28) * (i % 2 == 0 ? 1 : -1),
      life: 24 + rand(16),
      pal: pal_id
    }
    i += 1
  end
end

def solid_tile?(cx, cy)
  # マップ範囲外または :wall スプライトなら通行不可
  return true if cx < 0 || cx >= 16 || cy < 1 || cy >= 10
  tile = mget(cx, cy)
  tile == spr_id(:wall)
end

def check_rect_wall(nx, ny)
  # プレイヤー足元の当たり判定 (10x10 px)
  left = ((nx + 3).to_i) / 16
  right = ((nx + 12).to_i) / 16
  top = ((ny + 5).to_i) / 16
  bottom = ((ny + 14).to_i) / 16

  solid_tile?(left, top) || solid_tile?(right, top) ||
    solid_tile?(left, bottom) || solid_tile?(right, bottom)
end

def update
  $t += 1

  # --- 1. プレイヤー移動と Squash & Stretch ---
  dx = 0.0
  dy = 0.0
  if btn(0)
    dx -= 1.0
    $flip_x = true
    $dir_x = -1
    $dir_y = 0
  end
  if btn(1)
    dx += 1.0
    $flip_x = false
    $dir_x = 1
    $dir_y = 0
  end
  if btn(2)
    dy -= 1.0
    $dir_x = 0
    $dir_y = -1
  end
  if btn(3)
    dy += 1.0
    $dir_x = 0
    $dir_y = 1
  end

  moving = (dx != 0.0 || dy != 0.0)
  if moving
    len = sqrt(dx * dx + dy * dy)
    spd = 1.6
    vx = (dx / len) * spd
    vy = (dy / len) * spd

    $px += vx unless check_rect_wall($px + vx, $py)
    $py += vy unless check_rect_wall($px, $py + vy)

    $walk_frame += 0.18
    # 歩行時のぷにぷに伸縮 (Squash & Stretch)
    wave = sin($t * 0.35) * 0.16
    $squash_x = 1.0 + wave
    $squash_y = 1.0 - wave
  else
    # 待機呼吸アニメーション
    $walk_frame = 0.0
    breath = sin($t * 0.1) * 0.05
    $squash_x = 1.0 - breath
    $squash_y = 1.0 + breath
  end

  # --- 2. タイルマップ上のアイテム・ギミック判定 (mget / mset / mdel) ---
  cx = (($px + 8).to_i) / 16
  cy = (($py + 8).to_i) / 16
  cur_tile = mget(cx, cy)

  if cur_tile == spr_id(:coin)
    # コイン取得 -> mdel でタイル消去
    mdel(cx, cy)
    $score += 100
    spawn_sparks(cx * 16 + 4, cy * 16 + 4, 6, 1)
  elsif cur_tile == spr_id(:chest)
    # 宝箱を開ける -> mset に Symbol (:chest_open) を直接渡して書き換え！
    mset(cx, cy, :chest_open)
    $score += 500
    $chests_opened += 1
    spawn_sparks(cx * 16 + 4, cy * 16 + 4, 12, 4)
  end

  # --- 3. Z / Space: 剣スラッシュ攻撃 (loop=false クランプ再生デモ) ---
  b4 = btn(4)
  if b4 && !$prev_btn4
    $slash_timer = 14
    $slash_frame = 0.0
    $slash_x = $px + ($flip_x ? -14 : 14)
    $slash_y = $py
    $slash_flip = $flip_x
    # 攻撃時のストレッチ演出
    $squash_x = 1.35
    $squash_y = 0.75

    # スライムとのヒット判定
    if ($slash_x - $slime_x).abs < 20 && ($slash_y - $slime_y).abs < 20
      $slime_hit_timer = 15
      $slime_vx = ($flip_x ? -2.2 : 2.2)
      $slime_vy = -1.5
      $score += 50
      spawn_sparks($slime_x + 4, $slime_y + 4, 8, $SLIME_PALS[$slime_pal_idx])
    end

    # 32x32 ゴーレムとのヒット判定
    if ($slash_x - ($golem_x + 8)).abs < 26 && ($slash_y - ($golem_y + 8)).abs < 26 && $golem_reveal > 16
      $golem_hit_timer = 12
      $golem_hp -= 1
      spawn_sparks($golem_x + 12, $golem_y + 12, 10, 3)
      if $golem_hp <= 0
        $score += 1000
        $golem_hp = $golem_max_hp
        $golem_reveal = 0.0
      end
    end
  end
  $prev_btn4 = b4

  if $slash_timer > 0
    $slash_timer -= 1
    $slash_frame += 0.35
    $slash_x = $px + ($slash_flip ? -14 : 14)
    $slash_y = $py
  end

  # --- 4. X / Enter: 壁エイリアス '#' の動的設置/撤去 + スライムパレット切替 ---
  b5 = btn(5)
  if b5 && !$prev_btn5
    # スライムのパレットを切り替え
    $slime_pal_idx = ($slime_pal_idx + 1) % $SLIME_PALS.size

    # プレイヤーの前方セルに壁 '#' をトグル配置 (外周壁は保護)
    tx = (cx + $dir_x).clamp(1, 14)
    ty = (cy + $dir_y).clamp(2, 8)
    target_tile = mget(tx, ty)
    if target_tile == spr_id(:wall)
      mdel(tx, ty)
      spawn_sparks(tx * 16 + 4, ty * 16 + 4, 5, 2)
    elsif target_tile.nil?
      # 1文字エイリアス "#" を mset に直接渡して壁を設置！
      mset(tx, ty, "#")
      spawn_sparks(tx * 16 + 4, ty * 16 + 4, 5, 1)
    end
  end
  $prev_btn5 = b5

  # --- 5. スライムの移動更新 ---
  $slime_x += $slime_vx
  $slime_y += $slime_vy
  if solid_tile?((($slime_x + 8).to_i) / 16, (($slime_y + 8).to_i) / 16)
    $slime_vx = -$slime_vx
    $slime_vy = -$slime_vy
    $slime_x += $slime_vx * 2
    $slime_y += $slime_vy * 2
  end
  $slime_x = $slime_x.clamp(20.0, 156.0)
  $slime_y = $slime_y.clamp(34.0, 124.0)
  if $slime_hit_timer > 0
    $slime_hit_timer -= 1
    $slime_vx *= 0.92
    $slime_vy *= 0.92
  else
    # 通常速度へ緩やかに戻す
    $slime_vx = ($slime_vx >= 0 ? 0.7 : -0.7) if $slime_vx.abs < 0.5 || $slime_vx.abs > 1.2
    $slime_vy = ($slime_vy >= 0 ? 0.45 : -0.45) if $slime_vy.abs < 0.3 || $slime_vy.abs > 1.0
  end

  # --- 6. 32x32 ゴーレムのせり出し更新 (spr_clip デモ用) ---
  $golem_reveal += 0.25 * $golem_dir
  if $golem_reveal >= 38.0
    $golem_dir = -1
  elsif $golem_reveal <= 6.0
    $golem_dir = 1
  end
  $golem_hit_timer -= 1 if $golem_hit_timer > 0

  # --- 7. 8x8 スパークパーティクルの更新 ---
  $sparks.each do |s|
    s[:x] += s[:vx]
    s[:y] += s[:vy]
    s[:vy] += 0.08
    s[:rot] = (s[:rot] + s[:vrot]) % 360
    s[:life] -= 1
  end
  $sparks.reject! { |s| s[:life] <= 0 }
end

def draw
  cls(0)

  # ============================================================================
  # ヘッダーバー
  # ============================================================================
  rectfill(0, 0, 256, 15, 1)
  # blt の第3引数に Symbol (:hero) を渡して顔アイコン(16x10)だけ切り抜き表示！
  blt(4, 3, :hero, 0, 1, 16, 10)
  print_text("DECLARATIVE SPRITES", 22, 4, 10)
  print_text(sprintf("SCORE:%04d", $score), 188, 4, 7)

  # ============================================================================
  # メインフィールド (y: 16..159) - @MAP と各種新描画APIの連携
  # ============================================================================
  rectfill(0, 16, 256, 144, 1)

  # 背景の床グリッド装飾
  gy = 32
  while gy < 144
    gx = 16
    while gx < 240
      pset(gx + 7, gy + 7, 5) if ((gx + gy) / 16) % 2 == 0
      gx += 16
    end
    gy += 16
  end

  # タイルマップ上のたいまつ (:torch) を spr_id でアニメーション更新 (🔥 <-> ✨)
  torch_id = spr_id(:torch, $t * 0.08, true)
  mset(1, 2, torch_id)
  mset(14, 2, torch_id)

  # タイルマップ一括描画 (@MAP で '#' や ':wall', 'coin' で配置したセル)
  map(0, 0, 0, 0, 16, 10)

  # プレイヤー前方のターゲットカーソル ('#' 壁トグル位置)
  cx = (($px + 8).to_i) / 16
  cy = (($py + 8).to_i) / 16
  tx = (cx + $dir_x).clamp(1, 14)
  ty = (cy + $dir_y).clamp(2, 8)
  rect(tx * 16 + 2, ty * 16 + 2, 12, 12, 13) if $t % 30 < 20

  # --- 32x32 ゴーレム: spr_clip による地面からのせり出し描画 ---
  rev_h = $golem_reveal.clamp(0.0, 32.0).to_i
  # 地面の割れ目楕円
  ovalfill($golem_x + 16, $golem_y + 30, 18, 4, 0)
  oval($golem_x + 16, $golem_y + 30, 18, 4, 5)
  if rev_h > 0
    g_pal = ($golem_hit_timer > 0 && $t % 2 == 0) ? 4 : 3
    # 上から rev_h ピクセル分だけを切り抜いて、足元ライン ($golem_y + 32 - rev_h) に描画
    spr_clip(:golem, $golem_x, $golem_y + (32 - rev_h), 0, 0, 32, rev_h, false, false, g_pal)
  end
  # ゴーレムHPバー
  rectfill($golem_x + 2, $golem_y - 6, 28, 4, 0)
  rectfill($golem_x + 3, $golem_y - 5, (26 * $golem_hp) / $golem_max_hp, 2, 8)

  # --- スライム: spr_ext (Squash & Stretch) + pal引数による一時パレットスワップ ---
  slime_frame = spr_id(:slime, $t * 0.12)
  bounce = sin($t * 0.22)
  s_sx = 1.0 - bounce * 0.22
  s_sy = 1.0 + bounce * 0.22
  # ダメージ中はパレット4番(白/氷フラッシュ)、通常時は選択中のカスタムパレットで描画
  active_slime_pal = ($slime_hit_timer > 0 && $t % 2 == 0) ? 4 : $SLIME_PALS[$slime_pal_idx]
  ovalfill(($slime_x + 8).to_i, ($slime_y + 15).to_i, 6, 2, 0)
  spr_ext(slime_frame, $slime_x, $slime_y, 0, s_sx, s_sy, $slime_vx < 0, false, active_slime_pal)

  # --- プレイヤー (:hero): spr_id + spr_ext (Squash & Stretch) ---
  ovalfill(($px + 8).to_i, ($py + 15).to_i, 6, 2, 0)
  hero_slot = spr_id(:hero, $walk_frame)
  spr_ext(hero_slot, $px, $py, 0, $squash_x, $squash_y, $flip_x, false, 1)

  # --- 剣スラッシュエフェクト (:slash): spr_id(name, frame, false) クランプ再生 ---
  if $slash_timer > 0
    # loop = false により最終フレーム(2)でピタッと止まるワンショット再生
    slash_slot = spr_id(:slash, $slash_frame, false)
    spr(slash_slot, $slash_x, $slash_y, $slash_flip, 1)
  end

  # --- 8x8 小型スプライト (:spark): spr_rot による中心ピボット回転 ---
  $sparks.each do |s|
    spr_ext(:spark, s[:x], s[:y], s[:rot], 1.0, 1.0, false, false, s[:pal])
  end

  # ============================================================================
  # 下部ショーケースパネル (y: 161..255) - 新記法・APIのリアルタイム図解
  # ============================================================================
  rectfill(0, 160, 256, 96, 0)
  line(0, 160, 255, 160, 12)

  # [パネル1] loop=true vs loop=false (spr_id)
  rect(4, 164, 122, 38, 5)
  print_text("1.spr_id LOOP/CLAMP", 8, 167, 10)
  cyc_f = ($t % 45) * 0.1
  # ループ再生 (true)
  spr(spr_id(:slash, cyc_f, true), 14, 178, false, 1)
  print_text("LOOP", 34, 183, 7)
  # クランプ再生 (false: 最終コマで停止)
  spr(spr_id(:slash, cyc_f, false), 68, 178, false, 4)
  print_text("CLAMP", 88, 183, 12)

  # [パネル2] spr_ext (Squash & Stretch) + 8x8 spr_rot
  rect(130, 164, 122, 38, 5)
  print_text("2.spr_ext & 8x8 ROT", 134, 167, 10)
  demo_sx = 1.0 + sin($t * 0.2) * 0.35
  demo_sy = 1.0 - sin($t * 0.2) * 0.35
  spr_ext(:hero, 144, 179, 0, demo_sx, demo_sy, false, false, 1)
  # 8x8 スプライト (:spark) の中心ピボット回転
  spr_rot(:spark, 186, 183, ($t * 6) % 360)
  spr_ext(:spark, 214, 183, -($t * 4) % 360, 1.5, 1.5, false, false, 4)

  # [パネル3] spr の第5引数 pal による一時パレットスワップ
  rect(4, 205, 148, 36, 5)
  print_text("3.PAL SWAP:", 8, 208, 10)
  print_text($SLIME_PAL_NAMES[$slime_pal_idx], 74, 208, 11)
  p_idx = 0
  while p_idx < 4
    pal_num = $SLIME_PALS[p_idx]
    bx = 12 + p_idx * 34
    if p_idx == $slime_pal_idx
      rect(bx - 2, 217, 20, 20, 7)
    end
    spr(spr_id(:slime, $t * 0.1), bx, 219, false, pal_num)
    p_idx += 1
  end

  # [パネル4] blt(:symbol) & spr_clip(:symbol)
  rect(156, 205, 96, 36, 5)
  print_text("4.CLIP & BLT", 160, 208, 10)
  clip_w = 8 + (($t / 3) % 25)
  spr_clip(:golem, 164, 217, 0, 4, clip_w, 20, false, false, 3)
  blt(212, 220, :wall, 0, 0, 16, 16)
  spr(:spark, 232, 224)

  # フッター操作ガイド
  print_text("ARROWS:MOVE  Z:SLASH(CLAMP)  X:WALL(#)/PAL", 4, 245, 6)
end

__END__
# ==============================================================================
# カスタムパレット定義 (@PALETTE 1..4)
# ==============================================================================

# パレット1: 勇者 & ゴールド (ロイヤルブルー + 黄金グラデーション)
@PALETTE 1
1: #14182E
3: #B26A00
B: #FFB300
C: #2962FF
D: #64B5F6
9: #FF8F00
A: #FFF176
7: #FFFDF0
8: #FF1744

# パレット2: エメラルドスライム (4段階グリーングラデーション)
@PALETTE 2
1: #0D2618
3: #006838
B: #00C853
A: #80FF9E
7: #FFFFFF

# パレット3: マグマゴーレム & ファイア属性 (黒曜石 + 溶岩グラデーション)
@PALETTE 3
1: #1A0F14
2: #68121B
3: #8E1B00
B: #FF3D00
8: #D50000
9: #FF6D00
A: #FFEA00
5: #3E3546
6: #7A6C82

# パレット4: フロスト属性 & ダメージフラッシュ (氷水色 + ハイライト白)
@PALETTE 4
1: #102040
3: #1E5898
B: #40B8FF
A: #B8F4FF
8: #40B8FF
9: #90E0FF
7: #FFFFFF

# ==============================================================================
# 宣言的スプライト定義 (@SPRITE :name) & 2次元オートパッキング
# ==============================================================================

# 1. 名前 + マップ用1文字エイリアス + 絵文字
@SPRITE :wall # 🧱
@SPRITE :coin $ 🪙
@SPRITE :chest C 📦
@SPRITE :chest_open O 💎

# 2. 複数絵文字によるアニメーション + マップエイリアス 'T'
@SPRITE :torch T 🔥 ✨

# 3. 8x8 小型スプライト (サブ16x16実サイズ保持・中心ピボット回転用)
@SPRITE :spark 8x8 pal:1
...AA...
...99...
..A77A..
AA7777AA
99777799
..9779..
...99...
...AA...

# 4. プレイヤー (:hero) - '---' 区切り2フレームアニメーション (16x16, pal:1)
@SPRITE :hero 16x16 pal:1
....11111111....
...1CCCCCCCC1...
..1CCDDDDDDCC1..
..1CAA1AA1AAC1..
..11FFFFFFFF11..
..1FF1FFFF1FF1..
...1FFFFFFFF1...
....11111111....
...11CCCCCC11...
..1CC9AAAA9CC1..
..1FFCCCCCCFF1..
..111CCCCCC111..
....1CC11CC1....
....14411441....
....111..111....
................
---
....11111111....
...1CCCCCCCC1...
..1CCDDDDDDCC1..
..1CAA1AA1AAC1..
..11FFFFFFFF11..
..1FF1FFFF1FF1..
...1FFFFFFFF1...
....11111111....
..11CCCCCCCC11..
.1FF9AAAAAA9FF1.
..11CCCCCCCC11..
....1CCCCCC1....
...1441..1441...
...111....111...
................
................

# 5. スライム (:slime) - '---' 区切り2フレームアニメーション (16x16, pal:2)
@SPRITE :slime 16x16 pal:2
................
......1111......
....11BBBB11....
...1BBA77ABB1...
..1BBBA7BBBB31..
.1BBBBBBBBBBB31.
.1BBB1BBBB1BB31.
.1BBB1BBBB1BB31.
.1BBBB8888BBB31.
..1BBBBBBBB331..
..1333BBBB3331..
...1133333311...
.....111111.....
................
................
................
---
................
................
.....111111.....
...11BBBBBB11...
..1BBA77ABBBB1..
.1BBBA7BBBBBB31.
1BBBB1BBBB1BBB31
1BBBB1BBBB1BBB31
1BBBBB8888BBBB31
133BBBBBBBBBB331
.13333333333331.
..111111111111..
................
................
................
................

# 6. 剣スラッシュ (:slash) - サイズ不揃い3フレーム (自動パディング正規化 & loop=false 用)
@SPRITE :slash pal:1
..1111..
.1A77A1.
1A7711..
1A71....
1971....
.19A1...
..111...
---
....111111..
..11AA777A1.
.1AA7777111.
1AA77711....
197771......
199771......
.1997A1.....
..199A71....
...11111....
---
......11111111..
....11AAAA777A1.
..11AAA7777777A1
.1AAA7777711111.
1997777711......
19977771........
19977771........
19997771........
.199977A1.......
..199977A1......
...119997A11....
.....1111111....

# 7. 32x32 大型ゴーレム (:golem) - 名前指定 & 2次元オートパッキング (32x32, pal:3)
@SPRITE :golem 32x32 pal:3
........1111111111111111........
......11666666666666666611......
....116666666111111666666611....
...166666661199AA991166666661...
..16655566199AA77AA99166555661..
..15555566199AA77AA99166555551..
.15555555661199AA99116655555551.
.155111111556111111655111111551.
15518899AA155555555551AA99881551
155189AA7715555555555177AA981551
15551111115555511555551111115551
15555555555555122155555555555551
.155511111111112211111111115551.
.1151228899AA998899AA9988221511.
..1112288111111111111118822111..
.166611115555555555555511116661.
16666615555666666666655551666661
165566155661199AA991166551665561
1555561556199AA77AA9916551655551
1555561556199AA77AA9916551655551
155556155661199AA991166551655551
15588615555661111116655551688551
15599615555555555555555551699551
115551.155555555555555551.155511
..111..155555111111555551..111..
.......155551......155551.......
.......155551......155551.......
......1665551......1555661......
......1665551......1555661......
......1558851......1588551......
......1111111......1111111......
................................

# ==============================================================================
# タイルマップ定義 (@MAP)
# - 1文字エイリアス記法 ('#' = :wall, '$' = :coin, 'C' = :chest, 'T' = :torch)
# - スペース区切りシンボル名記法 ('wall', 'coin', 'chest') のハイブリッド実演
# ==============================================================================
@MAP 0 1
################
#T....$..$....T#
#..##......##..#
#..#...$....#..#
#....C.........#
#......##......#
#..$...##......#
#............C.#
wall wall wall wall wall wall wall wall wall wall wall wall wall wall wall wall

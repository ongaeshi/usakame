# ==============================================================================
# 🐰 Rabbit Knight Demo (うさぎ剣士の四方向歩行 & 壁衝突デモ) 🗡️
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/rabbit_knight.rb
#
# 仕様:
#   - 操作: 矢印キー または WASD で四方向に歩行
#   - うさぎ剣士スプライト: 前12、上12、右12(左はflip)
#   - 待機中も足踏みアニメーション(1, 2)を継続
#   - タイルマップ配置された石壁にぶつかり通過不可
#   - アイテムのリンゴは絵文字スプライト(🍎)。取るとスコア+1
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🐰 Rabbit Knight Demo 🍎"
)

# --- プレイヤーの初期状態 ---
$px = 32
$py = 32
$pdir = :down       # :down, :up, :right, :left
$moving = false
$anim_timer = 0
$anim_frame = 0     # 0 (コマ1) または 1 (コマ2)
$bump_cooldown = 0  # 壁衝突音クールダウン

# --- スコア & アイテム ---
$score = 0
$particles = []     # キラキラ & 衝突埃パーティクル

# リンゴ配置 (x, y, 収集済みフラグ)
$initial_apples = [
  [48,  48],
  [144, 32],
  [208, 48],
  [32,  112],
  [112, 112],
  [208, 128],
  [48,  192],
  [112, 208],
  [192, 192]
]

def init_apples
  $apples = []
  i = 0
  while i < $initial_apples.size
    pos = $initial_apples[i]
    $apples << { x: pos[0], y: pos[1], collected: false, offset_y: 0 }
    i += 1
  end
end

init_apples

# BGM 再生開始
music(0)

# 壁判定 (スプライトID 6 は石壁)
def solid_tile?(tile_id)
  tile_id == 6
end

# キャラクターの足元コライダー (12x8px) による壁衝突判定
def can_move_to?(nx, ny)
  # スプライト原点 (nx, ny) に対し足元領域を検査
  # 左上, 右上, 左下, 右下の4箇所のタイル座標
  x0 = (nx + 2) / 16
  x1 = (nx + 13) / 16
  y0 = (ny + 8) / 16
  y1 = (ny + 15) / 16

  return false if solid_tile?(mget(x0, y0))
  return false if solid_tile?(x1, y0)
  return false if solid_tile?(x0, y1)
  return false if solid_tile?(x1, y1)
  true
end

# パーティクル追加 (x, y, vx, vy, col, life, kind)
def add_particle(x, y, vx, vy, col, life, kind = :star)
  $particles << [x, y, vx, vy, col, life, kind]
end

# 壁衝突時の演出 (埃パーティクル + SE)
def on_bump_wall(bx, by)
  if $bump_cooldown <= 0
    sfx(1) # コツッという壁衝突SE
    $bump_cooldown = 12
    # 衝突エフェクト (小さな埃)
    add_particle(bx + 8, by + 12, 0, -0.5, 6, 8, :dust)
  end
end

def update
  # --- 入力受付 (矢印キー & WASD) ---
  dx = 0
  dy = 0

  if btn(0) # Left
    dx -= 1
    $pdir = :left
  elsif btn(1) # Right
    dx += 1
    $pdir = :right
  end

  if btn(2) # Up
    dy -= 1
    $pdir = :up
  elsif btn(3) # Down
    dy += 1
    $pdir = :down
  end

  $moving = (dx != 0 || dy != 0)

  # --- 足踏みアニメーション管理 ---
  # 待機中も足踏み（トコトコ）を繰り返す！
  # 歩行時は少し早めのリズムで足踏み
  if $moving
    $anim_timer += 2
  else
    $anim_timer += 1
  end

  # 10カウントごとにコマ1(0)とコマ2(1)を切り替え
  $anim_frame = ($anim_timer / 10) % 2

  # --- 移動 & 壁衝突判定 (X軸・Y軸の独立スライド処理) ---
  move_speed = 2

  if dx != 0
    nx = $px + dx * move_speed
    if can_move_to?(nx, $py)
      $px = nx
    else
      on_bump_wall($px + dx * 4, $py)
    end
  end

  if dy != 0
    ny = $py + dy * move_speed
    if can_move_to?($px, ny)
      $py = ny
    else
      on_bump_wall($px, $py + dy * 4)
    end
  end

  $bump_cooldown = [$bump_cooldown - 1, 0].max

  # --- リンゴ(🍎)取得判定 ---
  # プレイヤー中心座標
  pcx = $px + 8
  pcy = $py + 8

  all_collected = true
  i = 0
  while i < $apples.size
    apple = $apples[i]
    if !apple[:collected]
      all_collected = false
      # リンゴ中心座標
      acx = apple[:x] + 8
      acy = apple[:y] + 8
      
      # 距離判定 (12ピクセル以内で取得)
      dist_x = (pcx - acx).abs
      dist_y = (pcy - acy).abs
      if dist_x < 12 && dist_y < 12
        apple[:collected] = true
        $score += 1
        sfx(0) # リンゴ取得チャイム♪

        # キラキラ星パーティクル発生
        p = 0
        while p < 6
          vx = (p % 2 == 0 ? 1 : -1) * (1 + (p % 3) * 0.5)
          vy = (p < 3 ? -1 : 1) * (1 + (p % 2) * 0.5)
          add_particle(acx, acy, vx, vy, 10, 16, :star)
          p += 1
        end
      end
    end
    i += 1
  end

  # 全て回収したら数秒後にリスポーン（何度でも遊べる）
  if all_collected
    $respawn_timer = ($respawn_timer || 0) + 1
    if $respawn_timer > 90
      init_apples
      $respawn_timer = 0
    end
  end

  # --- パーティクル更新 ---
  i = 0
  while i < $particles.size
    pt = $particles[i]
    pt[0] += pt[2] # x += vx
    pt[1] += pt[3] # y += vy
    pt[5] -= 1     # life -= 1
    if pt[5] <= 0
      $particles.delete_at(i)
    else
      i += 1
    end
  end
end

def draw
  cls(0)

  # 1. タイルマップ描画 (16x16 タイル一括描画)
  map(0, 0, 0, 0, 16, 16)

  # 2. リンゴ (絵文字スプライト 🍎) 描画
  i = 0
  while i < $apples.size
    apple = $apples[i]
    if !apple[:collected]
      # ほんの少しフワフワ上下に浮遊
      bob = (($anim_timer / 8 + i * 2) % 4 < 2) ? 0 : 1
      spr("🍎", apple[:x], apple[:y] - bob)
    end
    i += 1
  end

  # 3. うさぎ剣士スプライト描画
  # スプライト選択:
  #   前向き: 0 (コマ1), 1 (コマ2)
  #   上向き: 2 (コマ1), 3 (コマ2)
  #   右向き: 4 (コマ1), 5 (コマ2)
  #   左向き: 4 (コマ1), 5 (コマ2) を flip_x = true
  sprite_id = 0
  flip_x = false

  case $pdir
  when :down
    sprite_id = ($anim_frame == 0) ? 0 : 1
    flip_x = false
  when :up
    sprite_id = ($anim_frame == 0) ? 2 : 3
    flip_x = false
  when :right
    sprite_id = ($anim_frame == 0) ? 4 : 5
    flip_x = false
  when :left
    sprite_id = ($anim_frame == 0) ? 4 : 5
    flip_x = true
  end

  # プレイヤー影
  ovalfill($px + 2, $py + 12, 6, 3, 1)

  # プレイヤー本体描画
  spr(sprite_id, $px, $py, flip_x, false)

  # 4. パーティクル描画
  i = 0
  while i < $particles.size
    pt = $particles[i]
    if pt[6] == :star
      # キラキラ星
      pset(pt[0], pt[1], pt[4])
      pset(pt[0] + 1, pt[1], 7)
    else
      # 壁衝突時の埃
      circfill(pt[0], pt[1], 1, pt[4])
    end
    i += 1
  end

  # 5. UI (スコア表示 & 操作ガイド)
  # 上部スコアバー
  rectfill(0, 0, 256, 14, 1)
  line(0, 14, 255, 14, 5)
  print_text("🍎 SCORE: #{$score}", 6, 3, 10)

  # 右上に足踏みステータス表示
  status_str = $moving ? "WALK" : "IDLE (STEP)"
  print_text("MODE: #{status_str}", 136, 3, 7)

  # 下部操作ガイド
  rectfill(0, 244, 256, 12, 1)
  line(0, 243, 255, 243, 5)
  print_text("ARROWS/WASD: MOVE | WAIT: STEPPING | BUMP: WALL", 6, 246, 6)
end

__END__
# ==============================================================================
# スプライト定義 (@SPRITE)
# ==============================================================================

# 0: 🐰 うさぎ剣士 (前向き コマ1)
@SPRITE 0
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777.7.
...7777777777.7.
..888888888888C.
.77707777770777.
.7770777777077A.
.777777EE777774.
..777777777777..
...8888AA8888...
..778888888877..
..77.777777.77..
....777...77....
...777..........
................

# 1: 🐰 うさぎ剣士 (前向き コマ2 - 足踏み)
@SPRITE 1
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777.7.
...7777777777.7.
..888888888888C.
.77707777770777.
.7770777777077A.
.777777EE777774.
..777777777777..
...8888AA8888...
..778888888877..
..77.777777.77..
....77...777....
..........777...
................

# 2: 🐰 うさぎ剣士 (上向き/背中 コマ1)
@SPRITE 2
....77....77....
...7777..7777...
...7777..7777...
...7777..7777.7.
...7777777777.7.
..888888888888C.
.77777788777777.
.7777778877777A.
.77777777777774.
..777777777777..
...8888888888...
..778888888877..
..77.777777.77..
....777...77....
...777..........
................

# 3: 🐰 うさぎ剣士 (上向き/背中 コマ2 - 足踏み)
@SPRITE 3
....77....77....
...7777..7777...
...7777..7777...
...7777..7777.7.
...7777777777.7.
..888888888888C.
.77777788777777.
.7777778877777A.
.77777777777774.
..777777777777..
...8888888888...
..778888888877..
..77.777777.77..
....77...777....
..........777...
................

# 4: 🐰 うさぎ剣士 (右向き コマ1 - 左はflip_x)
@SPRITE 4
....77..........
...7EE7.........
...7EE7.........
....777777......
...88888888.....
..7777777707....
..7777777707....
...777777EE7....
....7777777.....
.....8888AA.....
....7788887A777.
....77.7777.....
...77...777.....
...77....777....
................
................

# 5: 🐰 うさぎ剣士 (右向き コマ2 - 足踏み)
@SPRITE 5
....77..........
...7EE7.........
...7EE7.........
....777777......
...88888888.....
..7777777707....
..7777777707....
...777777EE7....
....7777777.....
.....8888AA.....
....7788887A777.
.....77..77.....
.....777.777....
......77..77....
................
................

# 6: 🧱 ダンジョンの石壁タイル (衝突判定あり・通行不可)
@SPRITE 6
5555555055555550
8888888088888880
8888888088888880
8844488088444880
8888888088888880
8888888088888880
8888888088888880
0000000000000000
5550555555505555
8880888888808888
8880888888808888
4880884448808844
8880888888808888
8880888888808888
8880888888808888
0000000000000000

# 7: 🏛️ 石畳フロアタイル (通行可能)
@SPRITE 7
DDDDDDDDDDDDDDDD
D6666666D6666666
D6666666D6666666
D6666666D6666666
D6666666D6666666
D6666666D6666666
D6666666D6666666
DDDDDDDDDDDDDDDD
6666D6666666666D
6666D6666666666D
6666D6666666666D
6666D6666666666D
6666D6666666666D
6666D6666666666D
6666D6666666666D
DDDDDDDDDDDDDDDD

# 8: 🌿 苔むした石畳タイル (通行可能)
@SPRITE 8
DDDDDDDDDDDDDDDD
D6666666D6666666
D6655666D6666666
D6665666D6663666
D6665566D663B366
D6666666D6663666
D6666666D6666666
DDDDDDDDDDDDDDDD
6666D6666666666D
6666D6666666666D
6666D6665566666D
6666D6666566666D
6666D6666556666D
6666D6666666666D
6666D6666666666D
DDDDDDDDDDDDDDDD

# ==============================================================================
# タイルマップ定義 (16x16 セル = 256x256 ピクセル)
# ==============================================================================
@MAP 0 0
6666666666666666
6777776777777776
6787776778777876
6777776777777776
6776666776666776
6777777777776776
6787766667776776
6777767767777776
6777767767787776
6776667766667776
6777777777777776
6776666776666776
6776777777776776
6786778778776876
6776777777776776
6666666666666666

# ==============================================================================
# サウンド定義 (@SFX / @MUSIC)
# ==============================================================================
# 0: リンゴ取得音 (きらめくベル音)
@SFX 0 wave=pulse speed=2 c3 e3 g3 c4 e4:fade

# 1: 壁衝突音 (コツッとした打撃)
@SFX 1 wave=triangle speed=1 c2:drop

# 0: 冒険のほのぼのダンジョンBGM
@MUSIC 0
ch0 wave=pulse vol=3 T128 L8 O4 c e g > c < g e c d  e g a > c < b g a f  e g > c < g e g f d  c e g > c < b > d c2
ch1 wave=triangle vol=5 T128 L4 O3 c e f g  c e f g  c e f g  c g c2

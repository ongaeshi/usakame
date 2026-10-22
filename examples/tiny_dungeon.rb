# ==============================================================================
# 🏰 Kenney Tiny Dungeon Demo (広大ダンジョン & 画面端スクロール探索) 🗡️
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/tiny_dungeon.rb
#
# 特徴:
#   - 32x32 タイル (512x512 ピクセル) の広大なダンジョンマップ
#   - プレイヤーが画面端 (マージン 72px) に近づくとカメラがスムーズにスクロール！
#   - 右上にリアルタイム・ミニマップ (プレイヤー現在地レーダー付き)
#   - 矢印キー または WASD で移動
#   - 宝箱 (全9箇所) を開けてスコアを集めよう！
#   - 徘徊するスライムとスケルトン
#   - Z キー: 「ゲームモード」と「132タイル全一覧リファレンス」の切り替え
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🏰 Kenney Tiny Dungeon Explorer (Scroll Map)"
)

# --- ダンジョン寸法 ---
MAP_COLS = 32
MAP_ROWS = 32
MAP_W = MAP_COLS * 16 # 512px
MAP_H = MAP_ROWS * 16 # 512px
VIEW_W = 256
VIEW_H = 256

# --- ゲームモード ---
# :game = ダンジョン探索, :viewer = タイル一覧リファレンス
$mode = :game

# --- カメラ座標 ---
$cam_x = 0
$cam_y = 0

# --- プレイヤー初期状態 (左上スタート部屋) ---
$px = 48
$py = 48
$pdir = :right
$score = 0
$keys = 0
$hp = 3

# --- 宝箱 & アイテム状態 (全9箇所) ---
$chests = [
  # 部屋1: 左上エントランス
  { x: 32,  y: 32,  opened: false },
  { x: 112, y: 32,  opened: false },
  # 部屋2: 右上大広間
  { x: 320, y: 32,  opened: false },
  { x: 448, y: 112, opened: false },
  # 部屋3: 中央大回廊
  { x: 256, y: 224, opened: false },
  # 部屋4: 左下牢獄
  { x: 48,  y: 360, opened: false },
  { x: 128, y: 440, opened: false },
  # 部屋5: 右下最深部 (黄金の宝物庫)
  { x: 360, y: 360, opened: false },
  { x: 448, y: 440, opened: false }
]

# --- モンスター (スライム・スケルトン計6体) ---
$monsters = [
  # スライム (左右徘徊)
  { x: 180, y: 80,  vx: 0.6, vy: 0,   id: 109, dir: 1, min_x: 130, max_x: 230 },
  { x: 240, y: 240, vx: 0.5, vy: 0,   id: 109, dir: 1, min_x: 190, max_x: 300 },
  { x: 80,  y: 400, vx: 0.5, vy: 0,   id: 109, dir: 1, min_x: 40,  max_x: 140 },
  # スケルトン (上下徘徊)
  { x: 380, y: 64,  vx: 0,   vy: 0.5, id: 111, dir: 1, min_y: 32,  max_y: 120 },
  { x: 144, y: 240, vx: 0,   vy: 0.6, id: 111, dir: 1, min_y: 200, max_y: 300 },
  { x: 416, y: 380, vx: 0.5, vy: 0,   id: 111, dir: 1, min_x: 340, max_x: 440 }
]

# --- エフェクト (パーティクル) ---
$particles = []

# 壁判定用タイルIDリスト (Kenney Tiny Dungeon の壁・柱・障害物)
# 0..27 などの外壁、および 36..41 などの下壁
def solid_tile?(tile_id)
  return true if tile_id >= 0 && tile_id <= 27
  return true if tile_id >= 36 && tile_id <= 41
  return true if tile_id == 64 || tile_id == 65 # 柱や松明
  false
end

# 足元コライダー判定
def can_walk?(nx, ny)
  # マップ境界外判定
  return false if nx < 0 || ny < 0 || nx + 16 > MAP_W || ny + 16 > MAP_H

  # 16x16 スプライトの足元領域 (中央 12x8)
  tx0 = (nx + 2) / 16
  tx1 = (nx + 13) / 16
  ty0 = (ny + 8) / 16
  ty1 = (ny + 15) / 16

  return false if solid_tile?(mget(tx0, ty0))
  return false if solid_tile?(mget(tx1, ty0))
  return false if solid_tile?(mget(tx0, ty1))
  return false if solid_tile?(mget(tx1, ty1))
  true
end

def add_sparkle(x, y, col = 10)
  5.times do
    $particles << {
      x: x + 8,
      y: y + 8,
      vx: (rand(11) - 5) * 0.4,
      vy: (rand(11) - 5) * 0.4 - 0.6,
      col: col,
      life: 18
    }
  end
end

def update
  if btnp(:mouse_r) || btnp(:z)
    $mode = ($mode == :game) ? :viewer : :game
    sfx(:select)
  end

  if $mode == :game
    update_game
  end

  # パーティクル更新
  $particles.each do |p|
    p[:x] += p[:vx]
    p[:y] += p[:vy]
    p[:life] -= 1
  end
  $particles.reject! { |p| p[:life] <= 0 }
end

def update_game
  dx = 0
  dy = 0
  if btn(:left)  || btn(0); dx -= 1; $pdir = :left; end
  if btn(:right) || btn(1); dx += 1; $pdir = :right; end
  if btn(:up)    || btn(2); dy -= 1; end
  if btn(:down)  || btn(3); dy += 1; end

  # 移動処理
  if dx != 0 && can_walk?($px + dx, $py)
    $px += dx
  end
  if dy != 0 && can_walk?($px, $py + dy)
    $py += dy
  end

  # --- 画面端スクロールカメラ処理 (マージン 72px) ---
  margin_x = 72
  margin_y = 72

  # 左右端スクロール
  if $px - $cam_x < margin_x
    $cam_x = $px - margin_x
  elsif $px - $cam_x > VIEW_W - margin_x - 16
    $cam_x = $px - (VIEW_W - margin_x - 16)
  end

  # 上下端スクロール
  if $py - $cam_y < margin_y
    $cam_y = $py - margin_y
  elsif $py - $cam_y > VIEW_H - margin_y - 16
    $cam_y = $py - (VIEW_H - margin_y - 16)
  end

  # マップ外へ出ないようにクランプ
  $cam_x = [[$cam_x, 0].max, MAP_W - VIEW_W].min
  $cam_y = [[$cam_y, 0].max, MAP_H - VIEW_H].min

  # 宝箱との当たり判定 (12px 近接)
  $chests.each do |ch|
    if !ch[:opened]
      dist = ($px - ch[:x]).abs + ($py - ch[:y]).abs
      if dist < 12
        ch[:opened] = true
        $score += 100
        sfx(:coin)
        add_sparkle(ch[:x], ch[:y], 10)
      end
    end
  end

  # モンスターの巡回移動
  $monsters.each do |m|
    if m[:vx] != 0
      m[:x] += m[:vx] * m[:dir]
      if m[:x] > m[:max_x] || m[:x] < m[:min_x]
        m[:dir] *= -1
      end
    elsif m[:vy] != 0
      m[:y] += m[:vy] * m[:dir]
      if m[:y] > m[:max_y] || m[:y] < m[:min_y]
        m[:dir] *= -1
      end
    end
  end
end

def draw
  if $mode == :viewer
    draw_viewer
  else
    draw_game
  end
end

def draw_game
  cls(0)

  # 1. ワールド座標系カメラ設定
  camera($cam_x, $cam_y)

  # 2. タイルマップ一括描画 (32x32セル = 512x512px、画面外は内部で自動カリング)
  map(0, 0, 0, 0, MAP_COLS, MAP_ROWS)

  # 3. 宝箱の描画 (85: 閉じた宝箱, 86: 開いた宝箱)
  $chests.each do |ch|
    tile_id = ch[:opened] ? 86 : 85
    spr(tile_id, ch[:x], ch[:y])
  end

  # 4. モンスターの描画
  $monsters.each do |m|
    spr(m[:id], m[:x], m[:y], m[:dir] < 0)
  end

  # 5. プレイヤーの描画 (ID 96: ナイト / 勇者)
  flip = ($pdir == :left)
  spr(96, $px, $py, flip)

  # 6. パーティクル描画
  $particles.each do |p|
    pset(p[:x], p[:y], p[:col])
  end

  # ============================================================================
  # 画面固定 HUD 描画 (カメラを (0, 0) にリセット)
  # ============================================================================
  camera()

  # 上部ステータスバー
  rectfill(0, 0, 256, 14, 0)
  line(0, 14, 256, 14, 1)
  print_text("SCORE: #{$score}", 6, 3, 10)
  print_text("HP: #{"♥" * $hp}", 90, 3, 8)
  print_text("[Z]: TILES", 145, 3, 7)

  # 右上ミニマップ (32x32 マップを 1セル=1px で表示)
  # 背景枠: (218, 18, 34, 34)
  rectfill(218, 18, 34, 34, 0)
  rect(217, 17, 36, 36, 5)

  # カメラ可動矩形の枠表示 (白点線)
  cam_mx = 219 + ($cam_x / 16)
  cam_my = 219 + ($cam_y / 16)
  rect(cam_mx, cam_my, 16, 16, 6)

  # プレイヤー位置 (点滅する黄色ドット)
  pl_mx = 219 + ($px / 16)
  pl_my = 219 + ($py / 16)
  pset(pl_mx, pl_my, (rand(2) == 0 ? 10 : 7))
end

def draw_viewer
  camera()
  cls(1)
  rectfill(0, 0, 256, 18, 0)
  print_text("Kenney Tiny Dungeon - 132 Tiles", 6, 5, 7)
  print_text("[Z]: RETURN TO GAME", 145, 5, 10)

  # 12列 x 11行の全132タイルを整列表示
  11.times do |row|
    12.times do |col|
      id = row * 12 + col
      x = 8 + col * 20
      y = 22 + row * 19
      
      # 背景の市松マス
      rect(x - 1, y - 1, 18, 18, 5)
      spr(id, x, y)
    end
  end

  # マウスホバーでタイルの詳細情報と拡大プレビュー
  mx = (mouse_x - 8) / 20
  my = (mouse_y - 22) / 19
  if mx >= 0 && mx < 12 && my >= 0 && my < 11
    hover_id = my * 12 + mx
    hx = 8 + mx * 20
    hy = 22 + my * 19
    rect(hx - 1, hy - 1, 18, 18, 10)

    # 画面下部にインフォメーションバー表示
    rectfill(0, 234, 256, 22, 0)
    print_text("Tile ID: #{hover_id} (col: #{mx}, row: #{my})", 8, 240, 10)
    spr(hover_id, 220, 235, scale: 1.2)
  else
    rectfill(0, 238, 256, 18, 0)
    print_text("Hover over any tile to view its Sprite ID", 8, 242, 6)
  end
end

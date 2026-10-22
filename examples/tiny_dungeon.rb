# ==============================================================================
# 🏰 Kenney Tiny Dungeon Demo (タイルマップ & ダンジョン探索サンプル) 🗡️
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/tiny_dungeon.rb
#
# 特徴:
#   - Kenney 氏制作のパブリックドメイン (CC0) 16x16 素材「Tiny Dungeon」を
#     シングルスクリプト完結の @SHEET 形式で内蔵！
#   - 操作: 矢印キー または WASD で移動
#   - TAB キー: 「ゲームモード」と「132タイル全一覧リファレンス」の切り替え
#   - 宝箱を開けるとコイン取得 SE が鳴り、中身が手に入る！
#   - スライムやスケルトンなどの徘徊モンスター
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🏰 Kenney Tiny Dungeon Explorer"
)

# --- ゲームモード ---
# :game = ダンジョン探索, :viewer = タイル一覧リファレンス
$mode = :game

# --- プレイヤー初期状態 ---
$px = 64
$py = 64
$pdir = :right
$score = 0
$keys = 0
$hp = 3

# --- 宝箱 & アイテム状態 ---
$chests = [
  { x: 32,  y: 32,  opened: false, item: :gem },
  { x: 192, y: 32,  opened: false, item: :key },
  { x: 192, y: 192, opened: false, item: :coin },
  { x: 48,  y: 192, opened: false, item: :potion }
]

# --- モンスター (スライム・スケルトン) ---
$monsters = [
  { x: 128, y: 80,  vx: 0.5, vy: 0,   id: 109, name: "Slime", dir: 1, min_x: 96, max_x: 160 },
  { x: 160, y: 144, vx: 0,   vy: 0.5, id: 111, name: "Skeleton", dir: 1, min_y: 112, max_y: 176 }
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
      vx: (rand(11) - 5) * 0.3,
      vy: (rand(11) - 5) * 0.3 - 0.5,
      col: col,
      life: 15
    }
  end
end

def update
  # TAB キーでビューアモードと探索モードをトグル
  if btnp(:x) || btnp(4) # Xキーまたはスペースキーでもトグル可能
    # 何かのアクション
  end

  if btnp(:mouse_r) || btnp(:z)
    # Zキーでビューア切り替え
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

    # プレイヤーとの接触判定
    dist = ($px - m[:x]).abs + ($py - m[:y]).abs
    if dist < 10
      # 接触音
      # sfx(:hurt)
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

  # タイルマップ一括描画 (16x16 セル = 256x256 ピクセル)
  map(0, 0, 0, 0, 16, 16)

  # 宝箱の描画 (85: 閉じた宝箱, 86: 開いた宝箱)
  $chests.each do |ch|
    tile_id = ch[:opened] ? 86 : 85
    spr(tile_id, ch[:x], ch[:y])
  end

  # モンスターの描画
  $monsters.each do |m|
    spr(m[:id], m[:x], m[:y], m[:dir] < 0)
  end

  # プレイヤーの描画 (ID 96: ナイト / 勇者)
  flip = ($pdir == :left)
  spr(96, $px, $py, flip)

  # パーティクル描画
  $particles.each do |p|
    pset(p[:x], p[:y], p[:col])
  end

  # HUD (スコア & 操作ヘルプ)
  rectfill(0, 0, 256, 12, 1)
  print_text("SCORE: #{$score}", 6, 2, 10)
  print_text("HP: #{"♥" * $hp}", 100, 2, 8)
  print_text("[Z]: VIEW TILES", 160, 2, 7)
end

def draw_viewer
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

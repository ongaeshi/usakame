# ==============================================================================
# 🍎 Juicy Fruit Chain Puzzle (落ち物・連鎖パズル) 🍇
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/puzzle.rb
#
# 【AIエージェント・開発者向けレシピ】
# 落ち物パズル（色合わせ・連鎖消去型）の王道ロジックを完全実装したサンプルです。
#   1. 2次元配列による盤面管理 (6列 × 11行)
#   2. 2個組ブロックの移動・90度回転・壁蹴り（Wall Kick）補正
#   3. ちぎれ落下（重力による空きマス詰め）ステート処理
#   4. 幅優先探索（Flood Fill）による同色連結判定（3個以上隣接で消去）
#   5. 連鎖（Chain）ボーナス計算とポップアップ演出
#
# 【操作方法】
#   - 左右キー (A/D): ブロック移動
#   - Z / Space / 上キー (W): ブロック回転
#   - 下キー (S): 高速落下
#   - X / Enter: ハードドロップ（一瞬で設置）
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🍎 Juicy Fruit Chain Puzzle"
)

COLS = 6
ROWS = 11
CELL = 18
BOARD_X = 36
BOARD_Y = 34

# ブロック種類 (1..5)
FRUITS = [
  nil,
  { emoji: "🍎", col: 8,  name: "Apple" },
  { emoji: "🍇", col: 13, name: "Grape" },
  { emoji: "🍋", col: 10, name: "Lemon" },
  { emoji: "💎", col: 12, name: "Gem"   },
  { emoji: "🍀", col: 11, name: "Clover"}
]

# 回転オフセット (0:上, 1:右, 2:下, 3:左)
ROT_DX = [0, 1, 0, -1]
ROT_DY = [-1, 0, 1, 0]

def create_board
  b = []
  ROWS.times do
    row = []
    COLS.times { row << 0 }
    b << row
  end
  b
end

$t = 0
$score = 0
$hi_score = 5000
$max_chain = 0

def init_puzzle
  $board = create_board
  $score = 0
  $chain = 0
  $state = :falling # :falling, :gravity, :matching, :clearing, :gameover
  $state_timer = 0
  $fall_timer = 0
  $particles = []
  $popups = []

  $next_pair = [1 + rand(5), 1 + rand(5)]
  spawn_next_piece
end

def spawn_next_piece
  $piece = {
    x: 2,
    y: 1,
    rot: 0,
    c1: $next_pair[0],
    c2: $next_pair[1]
  }
  $next_pair = [1 + rand(5), 1 + rand(5)]
  $chain = 0
  $fall_timer = 0

  # スポーン位置が既に埋まっていたらゲームオーバー
  if $board[1][2] != 0
    $state = :gameover
    sfx(2)
  else
    $state = :falling
  end
end

# 指定座標が空いているか判定
def cell_free?(gx, gy)
  return false if gx < 0 || gx >= COLS || gy >= ROWS
  return true if gy < 0
  $board[gy][gx] == 0
end

# 現在の2個組ブロックが配置可能か判定
def piece_valid?(px, py, prot)
   sx = px + ROT_DX[prot]
  sy = py + ROT_DY[prot]
  cell_free?(px, py) && cell_free?(sx, sy)
end

init_puzzle

# --- エフェクトヘルパー ---

def spawn_pop_effect(gx, gy, col)
  px = (BOARD_X + gx * CELL + 9).to_f
  py = (BOARD_Y + gy * CELL + 9).to_f
  10.times do
    ang = rand() * 6.283185
    spd = 0.8 + rand() * 2.5
    $particles << {
      x: px,
      y: py,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd,
      col: col,
      age: 0,
      max_age: 16 + rand(10)
    }
  end
end

def add_chain_popup(text, col)
  $popups << {
    x: (BOARD_X + (COLS * CELL) / 2).to_f,
    y: (BOARD_Y + 80).to_f,
    text: text,
    col: col,
    age: 0,
    max_age: 45
  }
end

# --- パズル盤面ロジック ---

# 現在のピースを盤面に固定し、重力フェーズへ移行
def lock_piece
  px = $piece[:x]
  py = $piece[:y]
  sx = px + ROT_DX[$piece[:rot]]
  sy = py + ROT_DY[$piece[:rot]]

  $board[py][px] = $piece[:c1] if py >= 0 && py < ROWS
  $board[sy][sx] = $piece[:c2] if sy >= 0 && sy < ROWS
  sfx(0)

  $state = :gravity
  $state_timer = 4
end

# 空中に浮いているブロックを1段ずつ下に落とす（戻り値: いずれかのブロックが落下したら true）
def step_board_gravity
  moved = false
  (0...COLS).each do |x|
    y = ROWS - 2
    while y >= 0
      if $board[y][x] != 0 && $board[y + 1][x] == 0
        $board[y + 1][x] = $board[y][x]
        $board[y][x] = 0
        moved = true
      end
      y -= 1
    end
  end
  moved
end

# 3個以上上下左右に繋がっている同色グループを探索（Flood Fill）
def find_connected_matches
  visited = create_board
  to_clear = []
  dirs = [
    { dx: 0, dy: -1 },
    { dx: 1, dy: 0 },
    { dx: 0, dy: 1 },
    { dx: -1, dy: 0 }
  ]

  (0...ROWS).each do |y|
    (0...COLS).each do |x|
      color = $board[y][x]
      next if color == 0 || visited[y][x] != 0

      group = []
      queue = [{ x: x, y: y }]
      visited[y][x] = 1

      while !queue.empty?
        cur = queue.shift
        group << cur
        dirs.each do |d|
          nx = cur[:x] + d[:dx]
          ny = cur[:y] + d[:dy]
          if nx >= 0 && nx < COLS && ny >= 0 && ny < ROWS
            if visited[ny][nx] == 0 && $board[ny][nx] == color
              visited[ny][nx] = 1
              queue << { x: nx, y: ny }
            end
          end
        end
      end

      if group.size >= 3
        group.each { |cell| to_clear << cell }
      end
    end
  end

  to_clear
end

# --- メイン更新ループ ---

def update
  $t += 1

  # エフェクト更新
  $particles.each do |pt|
    pt[:age] += 1
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
  end
  $particles.reject! { |pt| pt[:age] >= pt[:max_age] }

  $popups.each do |pop|
    pop[:age] += 1
    pop[:y] -= 0.6
  end
  $popups.reject! { |pop| pop[:age] >= pop[:max_age] }

  if $state == :gameover
    if btnp(:btn_a)
      init_puzzle
    end
    return
  end

  if $state == :falling
    # 左右移動
    if btnp(:left) && piece_valid?($piece[:x] - 1, $piece[:y], $piece[:rot])
      $piece[:x] -= 1
      sfx(0)
    elsif btnp(:right) && piece_valid?($piece[:x] + 1, $piece[:y], $piece[:rot])
      $piece[:x] += 1
      sfx(0)
    end

    # 回転（壁蹴り補正付き）
    if btnp(:btn_a) || btnp(:up)
      new_rot = ($piece[:rot] + 1) % 4
      if piece_valid?($piece[:x], $piece[:y], new_rot)
        $piece[:rot] = new_rot
        sfx(0)
      elsif piece_valid?($piece[:x] - 1, $piece[:y], new_rot)
        $piece[:x] -= 1
        $piece[:rot] = new_rot
        sfx(0)
      elsif piece_valid?($piece[:x] + 1, $piece[:y], new_rot)
        $piece[:x] += 1
        $piece[:rot] = new_rot
        sfx(0)
      end
    end

    # ハードドロップ（Xボタン）
    if btnp(:btn_b)
      while piece_valid?($piece[:x], $piece[:y] + 1, $piece[:rot])
        $piece[:y] += 1
        $score += 2
      end
      lock_piece
      return
    end

    # 自然落下 & 高速落下
    fall_interval = btn(:down) ? 4 : 28
    $fall_timer += 1
    if $fall_timer >= fall_interval
      $fall_timer = 0
      if piece_valid?($piece[:x], $piece[:y] + 1, $piece[:rot])
        $piece[:y] += 1
        $score += 1 if btn(:down)
      else
        lock_piece
      end
    end

  elsif $state == :gravity
    $state_timer -= 1
    if $state_timer <= 0
      if step_board_gravity
        $state_timer = 3
      else
        $state = :matching
        $state_timer = 6
      end
    end

  elsif $state == :matching
    $state_timer -= 1
    if $state_timer <= 0
      matches = find_connected_matches
      if !matches.empty?
        $chain += 1
        $max_chain = $chain if $chain > $max_chain
        chain_mult = $chain * $chain
        pts = matches.size * 100 * chain_mult
        $score += pts
        $hi_score = $score if $score > $hi_score

        matches.each do |cell|
          c_id = $board[cell[:y]][cell[:x]]
          col = FRUITS[c_id] ? FRUITS[c_id][:col] : 7
          spawn_pop_effect(cell[:x], cell[:y], col)
          $board[cell[:y]][cell[:x]] = 0
        end

        add_chain_popup("#{$chain} CHAIN! +#{pts}", ($chain >= 2) ? 10 : 7)
        sfx(1)
        $state = :gravity
        $state_timer = 10
      else
        spawn_next_piece
      end
    end
  end
end

# --- 描画処理 ---

def draw_fruit_cell(gx, gy, c_id)
  return if gy < 0 || c_id == 0
  info = FRUITS[c_id]
  return unless info
  px = BOARD_X + gx * CELL + 1
  py = BOARD_Y + gy * CELL + 1
  spr(info[:emoji], px, py)
end

def draw
  cls(1)

  # ヘッダー
  rectfill(0, 0, 256, 26, 0)
  line(0, 26, 256, 26, 12)
  print_text("🍎 JUICY FRUIT CHAIN PUZZLE", 8, 4, 10)
  print_text("[Arrow]Move [Z/Up]Rotate [X]Drop", 8, 15, 7)

  # 盤面背景とグリッド枠
  bw = COLS * CELL
  bh = ROWS * CELL
  rectfill(BOARD_X - 2, BOARD_Y - 2, bw + 4, bh + 4, 0)
  rect(BOARD_X - 2, BOARD_Y - 2, bw + 4, bh + 4, 7)

  (0...ROWS).each do |y|
    (0...COLS).each do |x|
      px = BOARD_X + x * CELL
      py = BOARD_Y + y * CELL
      rect(px, py, CELL, CELL, 1)
      draw_fruit_cell(x, y, $board[y][x])
    end
  end

  # デッドライン（×印）
  print_text("X", BOARD_X + 2 * CELL + 6, BOARD_Y + 1 * CELL + 5, 8) if $board[1][2] == 0

  # 操作中の落下ピース描画
  if $state == :falling && $piece
    px = $piece[:x]
    py = $piece[:y]
    sx = px + ROT_DX[$piece[:rot]]
    sy = py + ROT_DY[$piece[:rot]]

    # ゴースト（着地予測位置）表示
    gy = py
    while piece_valid?(px, gy + 1, $piece[:rot])
      gy += 1
    end
    gsy = gy + ROT_DY[$piece[:rot]]
    rect(BOARD_X + px * CELL + 2, BOARD_Y + gy * CELL + 2, 14, 14, 5) if gy >= 0
    rect(BOARD_X + sx * CELL + 2, BOARD_Y + gsy * CELL + 2, 14, 14, 5) if gsy >= 0

    draw_fruit_cell(px, py, $piece[:c1])
    draw_fruit_cell(sx, sy, $piece[:c2])
  end

  # 右側サイドパネル (NEXT / SCORE / CHAIN)
  panel_x = 156
  rectfill(panel_x, 34, 88, 56, 0)
  rect(panel_x, 34, 88, 56, 10)
  print_text("NEXT", panel_x + 28, 40, 10)
  spr(FRUITS[$next_pair[1]][:emoji], panel_x + 36, 52)
  spr(FRUITS[$next_pair[0]][:emoji], panel_x + 36, 70)

  rectfill(panel_x, 98, 88, 86, 0)
  rect(panel_x, 98, 88, 86, 7)
  print_text("SCORE", panel_x + 8, 106, 12)
  print_text(sprintf("%07d", $score), panel_x + 8, 118, 7)

  print_text("HI-SCORE", panel_x + 8, 134, 14)
  print_text(sprintf("%07d", $hi_score), panel_x + 8, 146, 7)

  print_text("MAX CHAIN: #{$max_chain}", panel_x + 8, 166, 11)

  # ルール説明パネル
  rectfill(panel_x, 192, 88, 40, 0)
  rect(panel_x, 192, 88, 40, 6)
  print_text("Match 3+ same", panel_x + 6, 200, 7)
  print_text("fruits to pop!", panel_x + 6, 214, 10)

  # パーティクル描画
  $particles.each do |pt|
    circfill(pt[:x].to_i, pt[:y].to_i, 2, pt[:col])
  end

  # 連鎖ポップアップ描画
  $popups.each do |pop|
    tx = pop[:x].to_i - (pop[:text].length * 3)
    ty = pop[:y].to_i
    print_text(pop[:text], tx + 1, ty + 1, 0)
    print_text(pop[:text], tx, ty, pop[:col])
  end

  if $state == :gameover
    rectfill(28, 104, 124, 52, 0)
    rect(28, 104, 124, 52, 8)
    print_text("GAME OVER", 62, 116, 8)
    print_text("Press Z to Retry", 42, 136, 7)
  end
end

__END__
@SFX 0
T240 L64 O5 E G
@SFX 1
T200 L32 O5 C E G > C E
@SFX 2
T160 L16 O4 E D C < B

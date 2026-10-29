# ==============================================================================
# 🧭 ProcGen, Pathfinding & mrubyedge Algorithms (迷路生成・経路探索・標準代替関数集)
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/procgen_utils.rb
#
# 【AIエージェント・開発者向けレシピ】
# mrubyedge に未実装の標準メソッド（shuffle, sample, reverse）の安全な代替関数と、
# ローグライクやパズル、シミュレーションで頻出するアルゴリズムの実践実装集です。
#   1. Fisher-Yates シャッフル (array_shuffle! / array_shuffle)
#   2. ランダム要素抽出 (array_sample) & 逆順配列生成 (array_reverse)
#   3. 重み付き抽選・ガチャテーブル計算 (weighted_pick)
#   4. 2次元グリッドの安全な生成 (create_grid)
#   5. 穴掘り法（深さ優先探索）による迷路の自動生成 (generate_maze)
#   6. 幅優先探索（BFS）による最短経路探索 (find_shortest_path)
#
# 【操作方法】
#   - 矢印キー (WASD): うさぎを手動で移動
#   - Z / Space: 最短経路に沿って1歩進む（ゴール到達でガチャ宝箱オープン！）
#   - X / Enter: 新しい迷路を自動生成 & ガチャを回す
#   - マウス左クリック: クリックした通路マスにゴール（🥕）を移動して経路を再計算
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🧭 ProcGen, BFS Pathfinding & mrubyedge Idioms"
)

# ==============================================================================
# 1. mrubyedge 必須ユーティリティ関数（そのまま他スクリプトへコピー可能）
# ==============================================================================

# Array#sample の代替
def array_sample(arr)
  return nil if arr.empty?
  arr[rand(arr.size)]
end

# Array#shuffle! の代替（Fisher-Yates シャッフル）
def array_shuffle!(arr)
  i = arr.size - 1
  while i > 0
    j = rand(i + 1)
    tmp = arr[i]
    arr[i] = arr[j]
    arr[j] = tmp
    i -= 1
  end
  arr
end

# Array#shuffle の代替（非破壊）
def array_shuffle(arr)
   array_shuffle!(arr.dup)
end

# Array#reverse の代替（非破壊）
def array_reverse(arr)
  out = []
  i = arr.size - 1
  while i >= 0
    out << arr[i]
    i -= 1
  end
  out
end

# 重み付き抽選（例: [{ item: "SSR", weight: 5 }, { item: "R", weight: 95 }]）
def weighted_pick(entries)
  total = 0
  entries.each { |e| total += e[:weight] }
  return nil if total <= 0

  r = rand(total)
  acc = 0
  entries.each do |e|
    acc += e[:weight]
    return e if r < acc
  end
  entries.last
end

# 安全な 2次元配列生成（w 列 × h 行）
def create_grid(w, h, default_val = 0)
  grid = []
  h.times do
    row = []
    w.times { row << default_val }
    grid << row
  end
  grid
end

# ==============================================================================
# 2. 迷路生成（穴掘り法） & 幅優先探索（BFS）最短経路アルゴリズム
# ==============================================================================

GRID_W = 15
GRID_H = 11
CELL_SIZE = 16
OFFSET_X = 8
OFFSET_Y = 36

TILE_FLOOR = 0
TILE_WALL  = 1

$t = 0
$grid = create_grid(GRID_W, GRID_H, TILE_WALL)
$player = { gx: 1, gy: 1 }
$goal   = { gx: GRID_W - 2, gy: GRID_H - 2 }
$path   = []
$visited_order = []

# ガチャドロップテーブル定義
LOOT_TABLE = [
  { rank: "SSR", name: "黄金の王冠", emoji: "👑", weight: 5,  col: 10 },
  { rank: "SR",  name: "神秘のダイヤ", emoji: "💎", weight: 15, col: 12 },
  { rank: "R",   name: "勇者の剣",   emoji: "⚔️", weight: 30, col: 14 },
  { rank: "N",   name: "森のキノコ", emoji: "🍄", weight: 50, col: 11 }
]

$last_loot = LOOT_TABLE[0]
$loot_history = []
$shuffled_deck = ["♠A", "♥K", "♦Q", "♣J", "🃏"]

# スタックを用いた非再帰・穴掘り法（深さ優先探索）による迷路生成
def generate_maze
  $grid = create_grid(GRID_W, GRID_H, TILE_WALL)
  $grid[1][1] = TILE_FLOOR

  stack = [{ x: 1, y: 1 }]
  dirs = [
    { dx: 0, dy: -2 },
    { dx: 2, dy: 0 },
    { dx: 0, dy: 2 },
    { dx: -2, dy: 0 }
  ]

  while !stack.empty?
    cur = stack.last
    shuffled_dirs = array_shuffle(dirs)
    moved = false

    shuffled_dirs.each do |d|
      next if moved
      nx = cur[:x] + d[:dx]
      ny = cur[:y] + d[:dy]

      if nx > 0 && nx < GRID_W - 1 && ny > 0 && ny < GRID_H - 1
        if $grid[ny][nx] == TILE_WALL
          # 間の壁を壊して通路にする
          $grid[cur[:y] + d[:dy] / 2][cur[:x] + d[:dx] / 2] = TILE_FLOOR
          $grid[ny][nx] = TILE_FLOOR
          stack << { x: nx, y: ny }
          moved = true
        end
      end
    end

    stack.pop unless moved
  end

  # ゲーム性を高めるため数箇所の壁を追加で抜いてループ経路を作る
  6.times do
    rx = 2 + rand(GRID_W - 4)
    ry = 2 + rand(GRID_H - 4)
    $grid[ry][rx] = TILE_FLOOR
  end

  $player[:gx] = 1
  $player[:gy] = 1
  $goal[:gx] = GRID_W - 2
  $goal[:gy] = GRID_H - 2
  $grid[$goal[:gy]][$goal[:gx]] = TILE_FLOOR

  recalculate_bfs_path
end

# 幅優先探索（BFS）でスタートからゴールまでの最短経路を求める
def recalculate_bfs_path
  sx = $player[:gx]
  sy = $player[:gy]
  gx = $goal[:gx]
  gy = $goal[:gy]

  queue = [{ x: sx, y: sy }]
  came_from = {}
  start_key = "#{sx},#{sy}"
  came_from[start_key] = :root
  $visited_order = []

  found = false
  dirs = [
    { dx: 0, dy: -1 },
    { dx: 1, dy: 0 },
    { dx: 0, dy: 1 },
    { dx: -1, dy: 0 }
  ]

  while !queue.empty?
    cur = queue.shift
    $visited_order << cur
    if cur[:x] == gx && cur[:y] == gy
      found = true
      break
    end

    dirs.each do |d|
      nx = cur[:x] + d[:dx]
      ny = cur[:y] + d[:dy]
      next if nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H
      next if $grid[ny][nx] == TILE_WALL

      nkey = "#{nx},#{ny}"
      # mrubyedge では Hash#key? ではなく Hash#has_key? を使用する
      unless came_from.has_key?(nkey)
        came_from[nkey] = cur
        queue << { x: nx, y: ny }
      end
    end
  end

  # ゴールから親を辿って経路を復元し、array_reverse で順方向にする
  rev_path = []
  if found
    curr = { x: gx, y: gy }
    while curr != :root
      rev_path << curr
      ckey = "#{curr[:x]},#{curr[:y]}"
      curr = came_from[ckey]
    end
  end
  $path = array_reverse(rev_path)
end

def roll_gacha_loot
  picked = weighted_pick(LOOT_TABLE)
  if picked
    $last_loot = picked
    $loot_history << picked[:emoji]
    $loot_history.shift if $loot_history.size > 8
  end
  array_shuffle!($shuffled_deck)
  sfx(0)
end

# 初期化実行
generate_maze
roll_gacha_loot

# ==============================================================================
# 3. 更新・描画ループ
# ==============================================================================

def try_move_player(dx, dy)
  nx = $player[:gx] + dx
  ny = $player[:gy] + dy
  return if nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H
  return if $grid[ny][nx] == TILE_WALL

  $player[:gx] = nx
  $player[:gy] = ny
  sfx(1)

  if $player[:gx] == $goal[:gx] && $player[:gy] == $goal[:gy]
    roll_gacha_loot
    # 新しいランダムな通路マスにゴールを再配置
    floors = []
    (1...(GRID_H - 1)).each do |y|
      (1...(GRID_W - 1)).each do |x|
        if $grid[y][x] == TILE_FLOOR && (x != $player[:gx] || y != $player[:gy])
          floors << { x: x, y: y }
        end
      end
    end
    target = array_sample(floors)
    if target
      $goal[:gx] = target[:x]
      $goal[:gy] = target[:y]
    end
  end

  recalculate_bfs_path
end

def update
  $t += 1

  # 方向キーで移動
  if btnp(:left)
    try_move_player(-1, 0)
  elsif btnp(:right)
    try_move_player(1, 0)
  elsif btnp(:up)
    try_move_player(0, -1)
  elsif btnp(:down)
    try_move_player(0, 1)
  end

  # Zキー: BFS最短経路に沿って自動で1歩進む
  if btnp(:btn_a)
    if $path.size >= 2
      next_step = $path[1]
      try_move_player(next_step[:x] - $player[:gx], next_step[:y] - $player[:gy])
    end
  end

  # Xキー: 迷路再生成＆ガチャ抽選
  if btnp(:btn_b)
    generate_maze
    roll_gacha_loot
  end

  # マウス左クリックで任意通路にゴールを設定
  if btnp(:mouse_l)
    gx = (mouse_x - OFFSET_X) / CELL_SIZE
    gy = (mouse_y - OFFSET_Y) / CELL_SIZE
    if gx >= 0 && gx < GRID_W && gy >= 0 && gy < GRID_H
      if $grid[gy][gx] == TILE_FLOOR
        $goal[:gx] = gx
        $goal[:gy] = gy
        recalculate_bfs_path
        sfx(1)
      end
    end
  end
end

def draw
  cls(0)

  # ヘッダー
  rectfill(0, 0, 256, 32, 1)
  line(0, 32, 256, 32, 12)
  print_text("🧭 PROCGEN MAZE & BFS PATHFINDING", 6, 4, 10)
  print_text("[Arrow]Move [Z]AutoStep [X]NewMaze [Click]Goal", 6, 17, 7)

  # 迷路グリッド描画
  (0...GRID_H).each do |y|
    (0...GRID_W).each do |x|
      px = OFFSET_X + x * CELL_SIZE
      py = OFFSET_Y + y * CELL_SIZE
      if $grid[y][x] == TILE_WALL
        rectfill(px, py, CELL_SIZE - 1, CELL_SIZE - 1, 5)
        rect(px, py, CELL_SIZE - 1, CELL_SIZE - 1, 1)
      else
        rectfill(px, py, CELL_SIZE - 1, CELL_SIZE - 1, 1)
      end
    end
  end

  # BFS 最短経路のハイライト描画
  $path.each_with_index do |node, idx|
    px = OFFSET_X + node[:x] * CELL_SIZE
    py = OFFSET_Y + node[:y] * CELL_SIZE
    circfill(px + 7, py + 7, 3, 11)
    if idx > 0
      prev = $path[idx - 1]
      line(
        OFFSET_X + prev[:x] * CELL_SIZE + 7,
        OFFSET_Y + prev[:y] * CELL_SIZE + 7,
        px + 7,
        py + 7,
        11
      )
    end
  end

  # ゴール（人参）とプレイヤー（うさぎ）の描画
  spr("🥕", OFFSET_X + $goal[:gx] * CELL_SIZE, OFFSET_Y + $goal[:gy] * CELL_SIZE)
  spr("🐰", OFFSET_X + $player[:gx] * CELL_SIZE, OFFSET_Y + $player[:gy] * CELL_SIZE)

  # 下部情報パネル（重み付きガチャ＆シャッフル結果表示）
  rectfill(0, 214, 256, 42, 1)
  line(0, 214, 256, 214, 13)

  steps = ($path.size > 0) ? ($path.size - 1) : 0
  print_text("BFS Shortest Steps: #{steps}", 8, 219, 11)
  print_text("Deck:#{$shuffled_deck.join(' ')}", 134, 219, 14)

  if $last_loot
    print_text(
      "Loot[#{ $last_loot[:rank] }]: #{$last_loot[:emoji]}#{$last_loot[:name]}",
      8,
      233,
      $last_loot[:col]
    )
  end
  print_text("Hist:#{$loot_history.join('')}", 148, 233, 7)
end

__END__
@SFX 0
T200 L32 O5 C E G > C
@SFX 1
T240 L64 O6 E

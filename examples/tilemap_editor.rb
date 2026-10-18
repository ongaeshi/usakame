# ==============================================================================
# 🐰 Usakame Sample: Tilemap Editor (タイルマップエディタ) 🐢
# ------------------------------------------------------------------------------
# 32x32 のタイルマップを直感的に作成・編集・エクスポートできるツールです。
#
# 【特徴】
# - 16種類の高品質なレトロゲーム用タイルスプライト内蔵（壁・草・水・木・宝箱など）
# - ペン、矩形、バケツ（塗りつぶし）、スポイトツール
# - ズーム切り替え（16x16 標準詳細表示 ⇔ 8x8 広域表示）
# - 矢印キー / WASD によるスムーズなマップスクロール
# - リアルタイム全体ミニマップ（クリックでカメラジャンプ）
# - [EXP MAP] / [EXP ALL]: スクリプト末尾 (__END__ 以降) に貼り付け可能な
#   @MAP および @SPRITE データをコンソール (標準出力) に一発出力！
# - [CODE]: 画面上で生成コードを確認できるビューワー
#
# 【使い方】
# - 実行: uk run examples/tilemap_editor.rb
# - 左クリック: タイル配置 / ツール選択 / パレット選択 / ミニマップジャンプ
# - 右クリック: 消しゴム (空タイル '.' で消去)
# - マウスホイール: タイルパレットを前後に切り替え
# - 矢印キー / WASD: マップスクロール
# - ショートカット:
#     Z: アンドゥ (元に戻す)
#     E / Enter: マップデータのエクスポート
#     G: グリッド線 ON/OFF
#     Tab: ズーム切り替え (16px ⇔ 8px)
#     C: マップ全消去
# ==============================================================================

# OS 標準マウスカーソルを非表示にし、ゲーム内カーソルを使用
show_mouse(false)

# ------------------------------------------------------------------------------
# 定数 & 初期設定
# ------------------------------------------------------------------------------
MAP_WIDTH  = 32
MAP_HEIGHT = 32
NUM_TILES  = 16

# キャンバス表示領域 (176 x 160 px)
VIEW_X = 4
VIEW_Y = 18
VIEW_W = 176
VIEW_H = 160

# タイル情報定義 [ID, 名前, 代表色]
TILE_INFO = [
  [0,  "EMPTY",  0],
  [1,  "BRICK",  5],
  [2,  "DIRT",   4],
  [3,  "GRASS",  11],
  [4,  "WATER",  12],
  [5,  "STONE",  6],
  [6,  "TREE",   3],
  [7,  "SAND",   9],
  [8,  "SPIKE",  8],
  [9,  "LADDER", 4],
  [10, "CHEST",  9],
  [11, "COIN",   10],
  [12, "KEY",    10],
  [13, "DOOR",   4],
  [14, "SIGN",   4],
  [15, "FLAG",   8]
]

# ------------------------------------------------------------------------------
# グローバル状態
# ------------------------------------------------------------------------------
$map = Array.new(MAP_WIDTH * MAP_HEIGHT, 0)

$cam_x = 0         # カメラ原点 (タイル単位)
$cam_y = 0
$selected_tile = 1 # 選択中タイルID (0..15)
$current_tool = :pen # :pen, :rect, :fill, :picker
$cell_size = 16    # 16 or 8
$show_grid = true  # グリッド線の表示
$rect_drag = nil   # 矩形ツールのドラッグ始点 [start_tx, start_ty]

$undo_stack = []   # アンドゥ用履歴スタック
$notify_msg = ""   # 通知メッセージ
$notify_timer = 0

$show_code_modal = false
$modal_tab = :all  # :map, :sprite, :all
$modal_scroll = 0
$cached_export_text = ""

# ------------------------------------------------------------------------------
# サンプルマップ初期化（起動時に見本ダンジョンをロード）
# ------------------------------------------------------------------------------
def init_sample_map
  # 外壁の配置
  MAP_HEIGHT.times do |y|
    MAP_WIDTH.times do |x|
      if x == 0 || x == MAP_WIDTH - 1 || y == 0 || y == MAP_HEIGHT - 1
        $map[y * MAP_WIDTH + x] = 1 # レンガ壁
      end
    end
  end

  # 中央に部屋と通路
  10.times { |i| $map[8 * MAP_WIDTH + (5 + i)] = 1 }
  8.times  { |i| $map[(8 + i) * MAP_WIDTH + 14] = 1 }
  $map[8 * MAP_WIDTH + 10] = 13 # 扉

  # 水場
  (12..16).each do |y|
    (3..7).each do |x|
      $map[y * MAP_WIDTH + x] = 4
    end
  end

  # 草むらと木
  (2..6).each do |y|
    (20..28).each do |x|
      $map[y * MAP_WIDTH + x] = 3
    end
  end
  $map[3 * MAP_WIDTH + 22] = 6
  $map[4 * MAP_WIDTH + 26] = 6
  $map[5 * MAP_WIDTH + 23] = 6

  # 石畳フロア
  (18..24).each do |y|
    (18..26).each do |x|
      $map[y * MAP_WIDTH + x] = 5
    end
  end

  # 砂の小道
  (10..22).each { |y| $map[y * MAP_WIDTH + 10] = 7 }
  (10..18).each { |x| $map[22 * MAP_WIDTH + x] = 7 }

  # ハシゴ
  (12..15).each { |y| $map[y * MAP_WIDTH + 14] = 9 }

  # アイテム・装飾
  $map[5 * MAP_WIDTH + 5]   = 12 # 鍵
  $map[20 * MAP_WIDTH + 24] = 10 # 宝箱
  $map[20 * MAP_WIDTH + 20] = 11 # コイン
  $map[21 * MAP_WIDTH + 20] = 11
  $map[22 * MAP_WIDTH + 20] = 11
  $map[14 * MAP_WIDTH + 9]  = 14 # 看板
  $map[17 * MAP_WIDTH + 14] = 8  # トゲ
  $map[18 * MAP_WIDTH + 14] = 8
  $map[28 * MAP_WIDTH + 28] = 15 # ゴール旗
end

init_sample_map

# ------------------------------------------------------------------------------
# ユーティリティ関数
# ------------------------------------------------------------------------------
def notify(msg)
  $notify_msg = msg
  $notify_timer = 120
end

def push_undo
  $undo_stack << $map.dup
  $undo_stack.shift if $undo_stack.size > 20
end

def perform_undo
  return if $undo_stack.empty?
  $map = $undo_stack.pop
  sfx(:click)
  notify("UNDO")
end

def get_tile(tx, ty)
  return 0 if tx < 0 || tx >= MAP_WIDTH || ty < 0 || ty >= MAP_HEIGHT
  $map[ty * MAP_WIDTH + tx]
end

def set_tile(tx, ty, tid)
  return if tx < 0 || tx >= MAP_WIDTH || ty < 0 || ty >= MAP_HEIGHT
  $map[ty * MAP_WIDTH + tx] = tid
end

# タイルIDを1文字表記に変換 (0: '.', 1..9: '1'..'9', 10..15: 'A'..'F')
def tile_to_char(tid)
  if tid <= 0
    "."
  elsif tid < 10
    tid.to_s
  else
    ("A".ord + (tid - 10)).chr
  end
end

# 塗りつぶし (バケツ / Flood Fill)
def flood_fill_tile(start_tx, start_ty, new_tid)
  target_tid = get_tile(start_tx, start_ty)
  return if target_tid == new_tid

  push_undo
  queue = [[start_tx, start_ty]]
  visited = {}

  while !queue.empty?
    pt = queue.shift
    tx = pt[0]
    ty = pt[1]
    key = ty * MAP_WIDTH + tx
    next if visited[key]
    visited[key] = true

    if get_tile(tx, ty) == target_tid
      set_tile(tx, ty, new_tid)
      queue << [tx + 1, ty] if tx + 1 < MAP_WIDTH
      queue << [tx - 1, ty] if tx - 1 >= 0
      queue << [tx, ty + 1] if ty + 1 < MAP_HEIGHT
      queue << [tx, ty - 1] if ty - 1 >= 0
    end
  end
  sfx(:click)
end

# 矩形配置
def apply_rect(x0, y0, x1, y1, tid)
  min_x = [x0, x1].min
  max_x = [x0, x1].max
  min_y = [y0, y1].min
  max_y = [y0, y1].max

  push_undo
  (min_y..max_y).each do |ty|
    (min_x..max_x).each do |tx|
      set_tile(tx, ty, tid)
    end
  end
  sfx(:click)
end

# マップ全消去
def clear_map
  push_undo
  $map = Array.new(MAP_WIDTH * MAP_HEIGHT, 0)
  sfx(:boom)
  notify("CLEARED MAP")
end

# ------------------------------------------------------------------------------
# テキストエクスポート生成
# ------------------------------------------------------------------------------
# @MAP 形式のテキスト生成
def generate_map_text
  lines = ["@MAP 0 0"]
  MAP_HEIGHT.times do |y|
    row = ""
    MAP_WIDTH.times do |x|
      row << tile_to_char(get_tile(x, y))
    end
    lines << row
  end
  lines.join("\n")
end

# タイルスプライト定義テキスト
SPRITE_DEFINITIONS = [
  "", # 0 は空
  # 1: BRICK
  "@SPRITE 1\n5555555055555550\n8888888088888880\n8888888088888880\n8844488088444880\n8888888088888880\n8888888088888880\n8888888088888880\n0000000000000000\n5550555555505555\n8880888888808888\n8880888888808888\n4880884448808844\n8880888888808888\n8880888888808888\n8880888888808888\n0000000000000000",
  # 2: DIRT
  "@SPRITE 2\n.44444444444444.\n4994499994499994\n4944944449449944\n4449444044444444\n4494440444994494\n4444404449444944\n4994400444449444\n4944044044444444\n4440444404499444\n4444499440494444\n4944944444044994\n4494440444449444\n4444404499444444\n4994044944944994\n4444444444444444\n.44444444444444.",
  # 3: GRASS
  "@SPRITE 3\n................\n................\n..3...3.........\n.3B3.3B3....3...\n.3B3.3B3...3B3..\n.BBB.BBB3..3B3..\n.BBBBBBBB3.BBB..\n3BBBBBBBBBBBBB3.\n33BBBBBBBBBBB33.\n.33BBBBBBBBB33..\n.3333BBBBB3333..\n..33333333333...\n...444444444....\n....4444444.....\n................\n................",
  # 4: WATER
  "@SPRITE 4\n................\n..CCCCCCCCCCCC..\n.CCCCCCCCCCCCCC.\nCCCCCCCCCCCCCCCC\nCC77CCCCCCCC77CC\nC7777CCCCCC7777C\nCCCCCCCCCCCCCCCC\nCCCCCCCCCCCCCCCC\nCCCC77CCCCCCCC77\nCCC7777CCCCCC777\nCCCCCCCCCCCCCCCC\nCCCCCCCCCCCCCCCC\n.CCCCCCCCCCCCCC.\n..CCCCCCCCCCCC..\n................\n................",
  # 5: STONE
  "@SPRITE 5\n0000000000000000\n0666666606666660\n0677776606776660\n0676666606766660\n0666666606666660\n0000000000000000\n0666606666666660\n0676606777776660\n0676606766666660\n0666606666666660\n0000000000000000\n0666666606666660\n0677766606776660\n0676666606766660\n0666666606666660\n0000000000000000",
  # 6: TREE
  "@SPRITE 6\n.......3........\n......333.......\n.....33B33......\n....33BBB33.....\n.....33B33......\n....33BBBB3.....\n...33BBBBBB3....\n..333BBBBBBB3...\n....33BBBB3.....\n...33BBBBBB3....\n..33BBBBBBBB3...\n.3333333333333..\n......4444......\n......4444......\n......4444......\n.....444444.....",
  # 7: SAND
  "@SPRITE 7\n9999999999999999\n9999499999949999\n9949999999999999\n9999999499999499\n9999999999999999\n9499999994999999\n9999949999999999\n9999999999994999\n9999999499999999\n9949999999999999\n9999999999499999\n9999499999999499\n9999999999999999\n9499999949999999\n9999999999999999\n9999999999999999",
  # 8: SPIKE
  "@SPRITE 8\n................\n................\n...8........8...\n..888......888..\n..878......878..\n.88788....88788.\n.87778....87778.\n8877788..8877788\n8770778..8770778\n8700078..8700078\n8700078..8700078\n8800088..8800088\n.888888..888888.\n.555555..555555.\n5555555555555555\n0000000000000000",
  # 9: LADDER
  "@SPRITE 9\n.444........444.\n.494........494.\n.49444444444494.\n.49499999999494.\n.49444444444494.\n.494........494.\n.494........494.\n.49444444444494.\n.49499999999494.\n.49444444444494.\n.494........494.\n.494........494.\n.49444444444494.\n.49499999999494.\n.49444444444494.\n.444........444.",
  # 10: CHEST
  "@SPRITE 10\n................\n...0000000000...\n..099999999990..\n.09999999999990.\n.04444444444440.\n.04AAAAAAAAAA40.\n.04AA000000AA40.\n.04AA0AA00AA40.\n.00000AA0000000.\n.09990AA0099990.\n.09990000099990.\n.09999999999990.\n.04444444444440.\n.04444444444440.\n..000000000000..\n................",
  # 11: COIN
  "@SPRITE 11\n................\n......AAAA......\n....AA7777AA....\n...A77AAAA77A...\n..A7AA9999AA7A..\n..A7A99AA99A7A..\n..A7A9A77A9A7A..\n..A7A9A77A9A7A..\n..A7A99AA99A7A..\n..A7AA9999AA7A..\n...A77AAAA77A...\n....AA9999AA....\n......AAAA......\n................\n................\n................",
  # 12: KEY
  "@SPRITE 12\n..........AAAA..\n.........A7777A.\n.........A7AA7A.\n.........A7AA7A.\n..........AAAA..\n..........A7A...\n..........A7A...\n.........AA7A...\n..........A7A...\n.........AA7A...\n..........A7A...\n..........A7A...\n..........AAA...\n................\n................\n................",
  # 13: DOOR
  "@SPRITE 13\n.55555555555555.\n5666666666666665\n5644444444444465\n5649999449999465\n5649449449449465\n5644444444444465\n564444AAAA444465\n56444AA00AA44465\n56444AA00AA44465\n564444A00A444465\n564444A00A444465\n564444AAAA444465\n5649449449449465\n5649999449999465\n5644444444444465\n5555555555555555",
  # 14: SIGN
  "@SPRITE 14\n................\n.00000000000000.\n.04999999999940.\n.09900000000990.\n.09999999999990.\n.09900000000990.\n.04999999999940.\n.00000044000000.\n......0440......\n......0440......\n......0440......\n......0440......\n......0440......\n......0440......\n.....004400.....\n................",
  # 15: FLAG
  "@SPRITE 15\n................\n...888888888....\n...88888888.....\n...8888888......\n...88888888.....\n...888888888....\n...8............\n...7............\n...7............\n...7............\n...7............\n...7............\n...7............\n...7............\n..575...........\n.55755.........."
]

# 全スプライト定義テキストの生成
def generate_sprites_text
  lines = []
  (1..15).each do |tid|
    lines << SPRITE_DEFINITIONS[tid]
  end
  lines.join("\n\n")
end

# 一括エクスポートテキストの生成
def generate_all_text
  map_text = generate_map_text
  spr_text = generate_sprites_text
  "# ==================================================\n" +
  "# 🐰 USAKAME TILEMAP & SPRITE DATA\n" +
  "# Copy & paste below __END__ in your script!\n" +
  "# ==================================================\n\n" +
  map_text + "\n\n" + spr_text + "\n"
end

# コンソール出力関数
def export_map_only
  puts "\n# =================================================="
  puts "# 🐰 USAKAME @MAP DATA (Copy & paste below __END__)"
  puts "# =================================================="
  puts generate_map_text
  puts "# ==================================================\n"
  sfx(:pickup)
  notify("EXPORTED @MAP TO CONSOLE!")
end

def export_all_data
  puts "\n" + generate_all_text
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED MAP & SPRITES TO CONSOLE!")
end

def export_sprites_only
  puts "\n# =================================================="
  puts "# 🐰 USAKAME @SPRITE DEFINITIONS (1..15)"
  puts "# =================================================="
  puts generate_sprites_text
  puts "# ==================================================\n"
  sfx(:pickup)
  notify("EXPORTED @SPRITES TO CONSOLE!")
end

# ------------------------------------------------------------------------------
# 更新処理 (update)
# ------------------------------------------------------------------------------
def update
  mx = mouse_x
  my = mouse_y

  $notify_timer = [$notify_timer - 1, 0].max

  # --- キーボードショートカット ---
  perform_undo if btnp(:z)
  export_all_data if btnp(:e)
  export_all_data if btnp(5) # :enter / :x
  clear_map if btnp(:c)

  # G: グリッドトグル
  if btnp(:g)
    $show_grid = !$show_grid
    sfx(:click)
    notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
  end

  # Tab: ズーム切り替え (16px ⇔ 8px)
  if btnp(:tab)
    $cell_size = ($cell_size == 16) ? 8 : 16
    sfx(:click)
    notify("ZOOM: #{$cell_size}px")
  end

  # 1..4: ツール切り替え
  $current_tool = :pen    if btnp(:key_1) || btnp(1)
  $current_tool = :rect   if btnp(:key_2)
  $current_tool = :fill   if btnp(:key_3)
  $current_tool = :picker if btnp(:key_4)

  # スクロール (矢印キー / WASD)
  scroll_speed = ($cell_size == 16) ? 1 : 2
  $cam_x -= scroll_speed if btn(0) # left
  $cam_x += scroll_speed if btn(1) # right
  $cam_y -= scroll_speed if btn(2) # up
  $cam_y += scroll_speed if btn(3) # down

  # 表示タイル数に応じたカメラ範囲クランプ
  max_tiles_x = (VIEW_W / $cell_size).to_i
  max_tiles_y = (VIEW_H / $cell_size).to_i
  $cam_x = [[$cam_x, 0].max, MAP_WIDTH - max_tiles_x].min
  $cam_y = [[$cam_y, 0].max, MAP_HEIGHT - max_tiles_y].min

  # マウスホイールでタイル切り替え
  wheel = mouse_wheel
  if wheel > 0.2
    $selected_tile = ($selected_tile - 1) % NUM_TILES
    sfx(:cursor)
  elsif wheel < -0.2
    $selected_tile = ($selected_tile + 1) % NUM_TILES
    sfx(:cursor)
  end

  # --- コードモーダル表示中の操作 ---
  if $show_code_modal
    if btnp(:mouse_l)
      # 閉じるボタン (x: 206..236, y: 16..30)
      if mx >= 206 && mx <= 236 && my >= 16 && my <= 30
        $show_code_modal = false
        sfx(:click)
      # タブ切り替え: [ALL] (x: 20..50), [MAP] (x: 56..86), [SPR] (x: 92..122)
      elsif my >= 32 && my <= 46
        if mx >= 20 && mx <= 50
          $modal_tab = :all
          $modal_scroll = 0
          sfx(:click)
        elsif mx >= 56 && mx <= 86
          $modal_tab = :map
          $modal_scroll = 0
          sfx(:click)
        elsif mx >= 92 && mx <= 122
          $modal_tab = :sprite
          $modal_scroll = 0
          sfx(:click)
        end
      # [EXPORT TO CONSOLE] (x: 24..140, y: 220..236)
      elsif mx >= 24 && mx <= 140 && my >= 220 && my <= 236
        if $modal_tab == :map
          export_map_only
        elsif $modal_tab == :sprite
          export_sprites_only
        else
          export_all_data
        end
      # モーダル外クリックで閉じる
      elsif mx < 12 || mx > 244 || my < 12 || my > 244
        $show_code_modal = false
      end
    end

    # モーダル内のホイールスクロール
    if wheel > 0.2
      $modal_scroll = [$modal_scroll - 3, 0].max
    elsif wheel < -0.2
      $modal_scroll += 3
    end
    return
  end

  # --- UI クリック判定 ---
  if btnp(:mouse_l)
    # 1. タイルパレット (x: 184..248, y: 28..92) - 4x4 グリッド
    if mx >= 184 && mx <= 248 && my >= 28 && my <= 92
      col = ((mx - 184) / 16).to_i
      row = ((my - 28) / 16).to_i
      if col >= 0 && col < 4 && row >= 0 && row < 4
        tid = row * 4 + col
        if tid < NUM_TILES
          $selected_tile = tid
          sfx(:select)
        end
      end
    end

    # 2. ミニマップクリック (x: 184..248, y: 114..178) -> カメラジャンプ
    if mx >= 184 && mx < 248 && my >= 114 && my < 178
      jump_tx = ((mx - 184) / 2).to_i
      jump_ty = ((my - 114) / 2).to_i
      $cam_x = jump_tx - (max_tiles_x / 2)
      $cam_y = jump_ty - (max_tiles_y / 2)
      $cam_x = [[$cam_x, 0].max, MAP_WIDTH - max_tiles_x].min
      $cam_y = [[$cam_y, 0].max, MAP_HEIGHT - max_tiles_y].min
      sfx(:cursor)
    end

    # 3. ツールボタン 行1 (y: 182..196)
    if my >= 182 && my <= 196
      # [PEN] (x: 4..32)
      if mx >= 4 && mx <= 32
        $current_tool = :pen
        sfx(:click)
      # [RECT] (x: 36..68)
      elsif mx >= 36 && mx <= 68
        $current_tool = :rect
        sfx(:click)
      # [FILL] (x: 72..102)
      elsif mx >= 72 && mx <= 102
        $current_tool = :fill
        sfx(:click)
      # [PICK] (x: 106..138)
      elsif mx >= 106 && mx <= 138
        $current_tool = :picker
        sfx(:click)
      # [ZOOM] (x: 142..176)
      elsif mx >= 142 && mx <= 176
        $cell_size = ($cell_size == 16) ? 8 : 16
        sfx(:click)
        notify("ZOOM: #{$cell_size}px")
      # [GRID] (x: 180..212)
      elsif mx >= 180 && mx <= 212
        $show_grid = !$show_grid
        sfx(:click)
      # [CLR] (x: 216..252)
      elsif mx >= 216 && mx <= 252
        clear_map
      end
    end

    # 4. ツールボタン 行2 (y: 198..212)
    if my >= 198 && my <= 212
      # [UNDO] (x: 4..38)
      if mx >= 4 && mx <= 38
        perform_undo
      # [EXP MAP] (x: 42..104)
      elsif mx >= 42 && mx <= 104
        export_map_only
      # [EXP ALL] (x: 108..188)
      elsif mx >= 108 && mx <= 188
        export_all_data
      # [CODE] (x: 192..252)
      elsif mx >= 192 && mx <= 252
        $show_code_modal = true
        $modal_scroll = 0
        sfx(:click)
      end
    end
  end

  # --- キャンバス内での描画 & ツール操作 ---
  in_canvas = (mx >= VIEW_X && mx < VIEW_X + VIEW_W &&
               my >= VIEW_Y && my < VIEW_Y + VIEW_H)

  if in_canvas
    tx = $cam_x + ((mx - VIEW_X) / $cell_size).to_i
    ty = $cam_y + ((my - VIEW_Y) / $cell_size).to_i

    if tx >= 0 && tx < MAP_WIDTH && ty >= 0 && ty < MAP_HEIGHT
      case $current_tool
      when :pen
        # 左ドラッグで選択タイル配置、右ドラッグで消しゴム (空タイル 0)
        draw_tid = btn(:mouse_l) ? $selected_tile : (btn(:mouse_r) ? 0 : nil)
        if !draw_tid.nil?
          if btnp(:mouse_l) || btnp(:mouse_r)
            push_undo
          end
          if get_tile(tx, ty) != draw_tid
            set_tile(tx, ty, draw_tid)
            sfx(:click)
          end
        end

      when :rect
        if btnp(:mouse_l) || btnp(:mouse_r)
          $rect_drag = [tx, ty, btnp(:mouse_l) ? $selected_tile : 0]
        elsif (!btn(:mouse_l) && !btn(:mouse_r)) && $rect_drag
          start_tx, start_ty, rect_tid = $rect_drag
          apply_rect(start_tx, start_ty, tx, ty, rect_tid)
          $rect_drag = nil
        end

      when :fill
        if btnp(:mouse_l)
          flood_fill_tile(tx, ty, $selected_tile)
        elsif btnp(:mouse_r)
          flood_fill_tile(tx, ty, 0)
        end

      when :picker
        if btnp(:mouse_l) || btnp(:mouse_r)
          picked = get_tile(tx, ty)
          $selected_tile = picked
          $current_tool = :pen
          sfx(:select)
          notify("PICKED TILE: #{picked}")
        end
      end
    end
  else
    # キャンバス外でドラッグが離されたらキャンセル
    if !btn(:mouse_l) && !btn(:mouse_r) && $rect_drag
      $rect_drag = nil
    end
  end
end

# ------------------------------------------------------------------------------
# 描画処理 (draw)
# ------------------------------------------------------------------------------
def draw
  cls(0)

  # --- 1. ヘッダーバー (y: 0..16) ---
  rectfill(0, 0, 256, 16, 1)
  line(0, 16, 255, 16, 5)
  print_text("🗺️ MAP EDITOR", 4, 4, 10)

  # タイル情報 & カメラ座標
  cur_info = TILE_INFO[$selected_tile]
  print_text("SEL:#{$selected_tile}:#{cur_info[1]}", 100, 4, 7)
  print_text("CAM:(#{$cam_x},#{$cam_y})", 196, 4, 6)

  # --- 2. メインタイルマップキャンバス (x: 4, y: 18, 176x160) ---
  rectfill(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 0)
  rect(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 5)

  # クリッピング領域を設定してタイルマップ描画
  clip(VIEW_X, VIEW_Y, VIEW_W, VIEW_H)

  tiles_x = (VIEW_W / $cell_size).to_i + 1
  tiles_y = (VIEW_H / $cell_size).to_i + 1

  scale = ($cell_size == 16) ? 1.0 : 0.5

  tiles_y.times do |dy|
    ty = $cam_y + dy
    next if ty >= MAP_HEIGHT
    tiles_x.times do |dx|
      tx = $cam_x + dx
      next if tx >= MAP_WIDTH

      tid = get_tile(tx, ty)
      draw_px = VIEW_X + dx * $cell_size
      draw_py = VIEW_Y + dy * $cell_size

      if tid > 0
        # 16x16 スプライトの描画 (scale で 1.0 または 0.5)
        spr(tid, draw_px, draw_py, false, false, 0, scale)
      else
        # 空タイル (背景市松模様)
        half = $cell_size / 2
        rectfill(draw_px, draw_py, half, half, 0)
        rectfill(draw_px + half, draw_py, half, half, 1)
        rectfill(draw_px, draw_py + half, half, half, 1)
        rectfill(draw_px + half, draw_py + half, half, half, 0)
      end

      # グリッド線
      if $show_grid
        line(draw_px, draw_py + $cell_size - 1, draw_px + $cell_size - 1, draw_py + $cell_size - 1, 0)
        line(draw_px + $cell_size - 1, draw_py, draw_px + $cell_size - 1, draw_py + $cell_size - 1, 0)
      end
    end
  end

  # 矩形ドラッグ中のプレビュー枠
  if $rect_drag
    stx, sty, _ = $rect_drag
    mx = mouse_x
    my = mouse_y
    cur_tx = $cam_x + ((mx - VIEW_X) / $cell_size).to_i
    cur_ty = $cam_y + ((my - VIEW_Y) / $cell_size).to_i
    cur_tx = [[cur_tx, 0].max, MAP_WIDTH - 1].min
    cur_ty = [[cur_ty, 0].max, MAP_HEIGHT - 1].min

    min_x = [stx, cur_tx].min
    max_x = [stx, cur_tx].max
    min_y = [sty, cur_ty].min
    max_y = [sty, cur_ty].max

    rx = VIEW_X + (min_x - $cam_x) * $cell_size
    ry = VIEW_Y + (min_y - $cam_y) * $cell_size
    rw = (max_x - min_x + 1) * $cell_size
    rh = (max_y - min_y + 1) * $cell_size
    rect(rx, ry, rw, rh, 10) # 黄色いプレビュー枠
  end

  # キャンバス上のマウスカーソル枠
  mx = mouse_x
  my = mouse_y
  if mx >= VIEW_X && mx < VIEW_X + VIEW_W && my >= VIEW_Y && my < VIEW_Y + VIEW_H
    htx = ((mx - VIEW_X) / $cell_size).to_i
    hty = ((my - VIEW_Y) / $cell_size).to_i
    hx = VIEW_X + htx * $cell_size
    hy = VIEW_Y + hty * $cell_size
    rect(hx, hy, $cell_size, $cell_size, 7) # 白いハイライト枠
  end

  # クリッピング解除
  clip()

  # --- 3. 右側パネル: タイルパレット & ミニマップ ---
  # パレットヘッダー
  print_text("TILES", 184, 18, 6)

  # 4x4 タイルグリッド (x: 184..248, y: 28..92)
  4.times do |row|
    4.times do |col|
      tid = row * 4 + col
      bx = 184 + col * 16
      by = 28 + row * 16
      rectfill(bx, by, 15, 15, 0)

      if tid == 0
        # 消しゴム / 空タイル
        rect(bx + 1, by + 1, 13, 13, 5)
        line(bx + 3, by + 3, bx + 11, by + 11, 8)
        line(bx + 3, by + 11, bx + 11, by + 3, 8)
      else
        # スプライト描画
        spr(tid, bx, by)
      end

      # 選択ハイライト枠
      if $selected_tile == tid
        rect(bx - 1, by - 1, 17, 17, 7)
      else
        rect(bx - 1, by - 1, 17, 17, 5)
      end
    end
  end

  # 選択中タイルの名前・情報 (y: 96)
  sel_name = TILE_INFO[$selected_tile][1]
  print_text("#{sel_name}", 184, 98, 10)

  # ミニマップヘッダー (y: 106)
  print_text("MINIMAP (32x32)", 184, 107, 6)

  # ミニマップ領域 (x: 184, y: 116, 64x64 px = 2px/セル)
  rectfill(183, 115, 66, 66, 1)
  rect(183, 115, 66, 66, 5)

  MAP_HEIGHT.times do |my_idx|
    MAP_WIDTH.times do |mx_idx|
      mtid = get_tile(mx_idx, my_idx)
      if mtid > 0
        mcol = TILE_INFO[mtid][2]
        rectfill(184 + mx_idx * 2, 116 + my_idx * 2, 2, 2, mcol)
      end
    end
  end

  # ミニマップ上のカメラ表示枠
  max_tiles_x = (VIEW_W / $cell_size).to_i
  max_tiles_y = (VIEW_H / $cell_size).to_i
  cam_box_x = 184 + $cam_x * 2
  cam_box_y = 116 + $cam_y * 2
  cam_box_w = max_tiles_x * 2
  cam_box_h = max_tiles_y * 2
  rect(cam_box_x, cam_box_y, cam_box_w, cam_box_h, 7)

  # --- 4. ツールボタン 行1 (y: 182..196) ---
  # [PEN] (x: 4..32)
  rectfill(4, 182, 28, 14, ($current_tool == :pen) ? 8 : 2)
  rect(4, 182, 28, 14, 7)
  print_text("PEN", 9, 185, 7)

  # [RECT] (x: 36..68)
  rectfill(36, 182, 32, 14, ($current_tool == :rect) ? 8 : 2)
  rect(36, 182, 32, 14, 7)
  print_text("RECT", 41, 185, 7)

  # [FILL] (x: 72..102)
  rectfill(72, 182, 30, 14, ($current_tool == :fill) ? 8 : 2)
  rect(72, 182, 30, 14, 7)
  print_text("FILL", 77, 185, 7)

  # [PICK] (x: 106..138)
  rectfill(106, 182, 32, 14, ($current_tool == :picker) ? 8 : 2)
  rect(106, 182, 32, 14, 7)
  print_text("PICK", 111, 185, 7)

  # [ZOOM] (x: 142..176)
  rectfill(142, 182, 34, 14, 3)
  rect(142, 182, 34, 14, 7)
  print_text(($cell_size == 16) ? "Z:16" : "Z:8", 147, 185, 7)

  # [GRID] (x: 180..212)
  rectfill(180, 182, 32, 14, $show_grid ? 11 : 1)
  rect(180, 182, 32, 14, 7)
  print_text("GRID", 185, 185, $show_grid ? 0 : 7)

  # [CLR] (x: 216..252)
  rectfill(216, 182, 36, 14, 8)
  rect(216, 182, 36, 14, 7)
  print_text("CLR", 226, 185, 7)

  # --- 5. ツールボタン 行2 (y: 198..212) ---
  # [UNDO] (x: 4..38)
  rectfill(4, 198, 34, 14, 5)
  rect(4, 198, 34, 14, 7)
  print_text("UNDO", 8, 201, 7)

  # [EXP MAP] (x: 42..104)
  rectfill(42, 198, 62, 14, 12)
  rect(42, 198, 62, 14, 7)
  print_text("EXP MAP", 52, 201, 0)

  # [EXP ALL] (x: 108..188)
  rectfill(108, 198, 80, 14, 11)
  rect(108, 198, 80, 14, 7)
  print_text("★ EXP ALL", 118, 201, 0)

  # [CODE] (x: 192..252)
  rectfill(192, 198, 60, 14, 9)
  rect(192, 198, 60, 14, 7)
  print_text("CODE", 210, 201, 0)

  # --- 6. ステータスバー (y: 216..255) ---
  rectfill(0, 216, 256, 40, 0)
  line(0, 216, 255, 216, 5)

  if $notify_timer > 0
    # 通知ポップアップ
    rectfill(4, 220, 248, 16, 3)
    rect(4, 220, 248, 16, 11)
    print_text($notify_msg, 10, 224, 7)
  else
    # 通常ステータス
    tool_str = $current_tool.to_s.upcase
    print_text("TOOL:#{tool_str}  TILE:#{$selected_tile}(#{sel_name})", 4, 220, 6)
  end

  print_text("L:Draw  R:Erase(.)  Wheel:Tile  WASD:Scroll", 4, 236, 5)
  print_text("Z:Undo  Tab:Zoom  G:Grid  E/Enter:Export", 4, 246, 5)

  # --- 7. コードプレビューモーダル ---
  if $show_code_modal
    rectfill(12, 12, 232, 232, 0)
    rect(12, 12, 232, 232, 7)
    rect(14, 14, 228, 228, 6)

    # ヘッダー
    print_text("RESOURCE CODE PREVIEW", 20, 18, 10)

    # 閉じるボタン
    rectfill(206, 16, 30, 14, 8)
    rect(206, 16, 30, 14, 7)
    print_text("X", 218, 19, 7)

    # タブ選択: [ALL] [MAP] [SPR]
    rectfill(20, 32, 32, 14, ($modal_tab == :all) ? 11 : 5)
    rect(20, 32, 32, 14, 7)
    print_text("ALL", 27, 35, ($modal_tab == :all) ? 0 : 7)

    rectfill(56, 32, 32, 14, ($modal_tab == :map) ? 11 : 5)
    rect(56, 32, 32, 14, 7)
    print_text("MAP", 63, 35, ($modal_tab == :map) ? 0 : 7)

    rectfill(92, 32, 32, 14, ($modal_tab == :sprite) ? 11 : 5)
    rect(92, 32, 32, 14, 7)
    print_text("SPR", 99, 35, ($modal_tab == :sprite) ? 0 : 7)

    # テキスト行の準備
    lines = case $modal_tab
            when :map
              generate_map_text.split("\n")
            when :sprite
              generate_sprites_text.split("\n")
            else
              generate_all_text.split("\n")
            end

    # 本文クリッピング表示 (y: 50..214, 約18行表示)
    clip(20, 50, 216, 164)
    line_y = 52 - $modal_scroll * 9
    lines.each_with_index do |ln, idx|
      if line_y >= 44 && line_y <= 214
        col = ln.start_with?("@") ? 10 : (ln.start_with?("#") ? 6 : 7)
        # 長い行は切り詰めて表示
        disp_ln = ln.length > 26 ? ln[0, 26] + "..." : ln
        print_text(disp_ln, 22, line_y, col)
      end
      line_y += 9
    end
    clip()

    # スクロールバー装飾
    total_lines = lines.size
    if total_lines > 18
      bar_h = [(164 * 18) / total_lines, 20].max
      max_scroll = total_lines - 18
      bar_y = 50 + (($modal_scroll.to_f / max_scroll) * (164 - bar_h)).to_i
      rectfill(234, 50, 3, 164, 1)
      rectfill(234, bar_y, 3, bar_h, 7)
    end

    # [EXPORT TO CONSOLE] ボタン
    rectfill(24, 218, 120, 18, 11)
    rect(24, 218, 120, 18, 7)
    print_text("★ EXPORT CONSOLE", 32, 223, 0)

    print_text("Wheel:Scroll", 154, 223, 6)
  end

  # ゲーム内マウスカーソル
  mx = mouse_x
  my = mouse_y
  line(mx, my, mx + 6, my + 6, 7)
  line(mx, my, mx + 4, my, 7)
  line(mx, my, mx, my + 4, 7)
  pset(mx + 1, my + 1, 0)
end

__END__
# 1: レンガ壁 (破壊不可)
@SPRITE 1
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

# 2: ひび割れ土ブロック
@SPRITE 2
.44444444444444.
4994499994499994
4944944449449944
4449444044444444
4494440444994494
4444404449444944
4994400444449444
4944044044444444
4440444404499444
4444499440494444
4944944444044994
4494440444449444
4444404499444444
4994044944944994
4444444444444444
.44444444444444.

# 3: 草原 / 芝生
@SPRITE 3
................
................
..3...3.........
.3B3.3B3....3...
.3B3.3B3...3B3..
.BBB.BBB3..3B3..
.BBBBBBBB3.BBB..
3BBBBBBBBBBBBB3.
33BBBBBBBBBBB33.
.33BBBBBBBBB33..
.3333BBBBB3333..
..33333333333...
...444444444....
....4444444.....
................
................

# 4: 水面
@SPRITE 4
................
..CCCCCCCCCCCC..
.CCCCCCCCCCCCCC.
CCCCCCCCCCCCCCCC
CC77CCCCCCCC77CC
C7777CCCCCC7777C
CCCCCCCCCCCCCCCC
CCCCCCCCCCCCCCCC
CCCC77CCCCCCCC77
CCC7777CCCCCC777
CCCCCCCCCCCCCCCC
CCCCCCCCCCCCCCCC
.CCCCCCCCCCCCCC.
..CCCCCCCCCCCC..
................
................

# 5: 石畳フロア
@SPRITE 5
0000000000000000
0666666606666660
0677776606776660
0676666606766660
0666666606666660
0000000000000000
0666606666666660
0676606777776660
0676606766666660
0666606666666660
0000000000000000
0666666606666660
0677766606776660
0676666606766660
0666666606666660
0000000000000000

# 6: 木 / 針葉樹
@SPRITE 6
.......3........
......333.......
.....33B33......
....33BBB33.....
.....33B33......
....33BBBB3.....
...33BBBBBB3....
..333BBBBBBB3...
....33BBBB3.....
...33BBBBBB3....
..33BBBBBBBB3...
.3333333333333..
......4444......
......4444......
......4444......
.....444444.....

# 7: 砂地 / 小道
@SPRITE 7
9999999999999999
9999499999949999
9949999999999999
9999999499999499
9999999999999999
9499999994999999
9999949999999999
9999999999994999
9999999499999999
9949999999999999
9999999999499999
9999499999999499
9999999999999999
9499999949999999
9999999999999999
9999999999999999

# 8: トゲ罠
@SPRITE 8
................
................
...8........8...
..888......888..
..878......878..
.88788....88788.
.87778....87778.
8877788..8877788
8770778..8770778
8700078..8700078
8700078..8700078
8800088..8800088
.888888..888888.
.555555..555555.
5555555555555555
0000000000000000

# 9: ハシゴ
@SPRITE 9
.444........444.
.494........494.
.49444444444494.
.49499999999494.
.49444444444494.
.494........494.
.494........494.
.49444444444494.
.49499999999494.
.49444444444494.
.494........494.
.494........494.
.49444444444494.
.49499999999494.
.49444444444494.
.444........444.

# 10: 宝箱
@SPRITE 10
................
...0000000000...
..099999999990..
.09999999999990.
.04444444444440.
.04AAAAAAAAAA40.
.04AA000000AA40.
.04AA0AA00AA40.
.00000AA0000000.
.09990AA0099990.
.09990000099990.
.09999999999990.
.04444444444440.
.04444444444440.
..000000000000..
................

# 11: コイン
@SPRITE 11
................
......AAAA......
....AA7777AA....
...A77AAAA77A...
..A7AA9999AA7A..
..A7A99AA99A7A..
..A7A9A77A9A7A..
..A7A9A77A9A7A..
..A7A99AA99A7A..
..A7AA9999AA7A..
...A77AAAA77A...
....AA9999AA....
......AAAA......
................
................
................

# 12: 鍵
@SPRITE 12
..........AAAA..
.........A7777A.
.........A7AA7A.
.........A7AA7A.
..........AAAA..
..........A7A...
..........A7A...
.........AA7A...
..........A7A...
.........AA7A...
..........A7A...
..........A7A...
..........AAA...
................
................
................

# 13: 扉
@SPRITE 13
.55555555555555.
5666666666666665
5644444444444465
5649999449999465
5649449449449465
5644444444444465
564444AAAA444465
56444AA00AA44465
56444AA00AA44465
564444A00A444465
564444A00A444465
564444AAAA444465
5649449449449465
5649999449999465
5644444444444465
5555555555555555

# 14: 看板
@SPRITE 14
................
.00000000000000.
.04999999999940.
.09900000000990.
.09999999999990.
.09900000000990.
.04999999999940.
.00000044000000.
......0440......
......0440......
......0440......
......0440......
......0440......
......0440......
.....004400.....
................

# 15: ゴール旗
@SPRITE 15
................
...888888888....
...88888888.....
...8888888......
...88888888.....
...888888888....
...8............
...7............
...7............
...7............
...7............
...7............
...7............
...7............
..575...........
.55755..........

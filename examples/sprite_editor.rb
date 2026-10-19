# ==============================================================================
# 🐰 Usakame Sample: High-Resolution Sprite Editor (スプライトエディタ) 🐢
# ------------------------------------------------------------------------------
# 16x16 のドット絵スプライトを直感的に作成・編集・保存できる高解像度ツールです。
#
# 【特徴】
# - 高解像度UI (480x270): 広々としたキャンバスと使いやすいパレット・スロット一覧
# - 外部ファイル自動連携:
#     uk run examples/sprite_editor.rb -- game.rb
#     uk run examples/sprite_editor.rb -- game.spr
# - 安全な非破壊保存:
#     game.rb を指定した場合でも、game.rb 本体を壊さず自動的に game.spr を生成・保存。
#     ゲーム側（uk run game.rb）が自動でホットリロードされ、リアルタイムに反映！
# - [SAVE] (Ctrl+S / S): ターゲットファイルに即座に書き込み
# - [EXPORT]: クリップボード用テキストやコンソール出力
# ==============================================================================

config(
  width: 480,
  height: 270,
  window_scale: 2.0,
  text_size: 8,
  title: "Usakame Sprite Editor"
)

# OS 標準マウスカーソルを非表示にし、ゲーム内カーソルを使用
show_mouse(false)

# ------------------------------------------------------------------------------
# 定数 & 初期化
# ------------------------------------------------------------------------------
GRID_SIZE = 16
NUM_SLOTS = 16

COLOR_NAMES = [
  "BLACK", "DARK-BLUE", "PURPLE", "DARK-GREEN",
  "BROWN", "DARK-GRAY", "LIGHT-GRAY", "WHITE",
  "RED", "ORANGE", "YELLOW", "GREEN",
  "BLUE", "INDIGO", "PINK", "PEACH"
]

# キャンバス配置 (16x16, 1セル = 12px -> 192x192)
$canvas_x = 12
$canvas_y = 28
$cell_size = 12

# ツール一覧: :pen, :fill, :picker, :eraser
$current_tool = :pen
$current_col = 8     # 初期描画色 (赤)
$current_slot = 0    # 選択中スロット (0..15)
$show_grid = true    # グリッド線の表示
$bg_mode = 0         # プレビュー背景 (0: 黒, 1: 濃紺, 2: 白, 3: 市松)

# アニメーションプレビュー
$anim_playing = false
$anim_frame = 0
$anim_timer = 0

# コードプレビューモーダル
$show_code_modal = false

# 通知メッセージ
$notify_msg = ""
$notify_timer = 0

# アンドゥ用履歴スタック (最大30手)
$undo_stack = []

# スプライトスロット (16スロット x 256要素)
$slots = Array.new(NUM_SLOTS) { Array.new(GRID_SIZE * GRID_SIZE, nil) }

# ------------------------------------------------------------------------------
# ターゲットファイル検出 & 初期ロード
# ------------------------------------------------------------------------------
$target_path = "game.rb"
if ARGV && ARGV.size > 0 && ARGV[0]
  $target_path = ARGV[0]
end

$save_path = $target_path
tlen = $target_path.size
if tlen >= 3
  # 末尾3文字が ".rb" かどうか確認
  suf = $target_path[tlen - 3, 3]
  if suf == ".rb"
    $save_path = $target_path[0, tlen - 3] + ".spr"
  end
end

def notify(msg)
  $notify_msg = msg
  $notify_timer = 120 # 約2秒表示
end

def push_undo
  $undo_stack << [$current_slot, $slots[$current_slot].dup]
  $undo_stack.shift if $undo_stack.size > 30
end

def perform_undo
  return if $undo_stack.empty?
  slot_id, saved_grid = $undo_stack.pop
  $current_slot = slot_id
  $slots[slot_id] = saved_grid
  sfx(:click)
  notify("UNDO")
end
# 起動時の読み込み
load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
loaded_slots = load_resource_sprites(load_source, NUM_SLOTS)

loaded_count = 0
loaded_slots.each_with_index do |sgrid, sid|
  if sgrid && sid < NUM_SLOTS
    $slots[sid] = sgrid
    loaded_count += 1
  end
end

if loaded_count > 0
  notify("LOADED #{loaded_count} SPRITES FROM #{load_source}")
else
  # サンプルうさぎスプライトをスロット0に初期設定
  sample_usagi = [
    "....77....77....",
    "...7EE7..7EE7...",
    "...7EE7..7EE7...",
    "...7777..7777...",
    "...7777777777...",
    "..888888888888..",
    ".77707777770777.",
    ".77707777770777.",
    ".777777EE777777.",
    "..777777777777..",
    "...8888AA8888...",
    "..778888888877..",
    "..77.777777.77..",
    "....777..777....",
    "...777....777...",
    "................"
  ]
  sample_usagi.each_with_index do |row, y|
    16.times do |x|
      ch = row[x]
      if ch && ch != "."
        $slots[0][y * 16 + x] = ch.to_i(16)
      end
    end
  end
  notify("TARGET: #{$target_path} (NEW)")
end

# ------------------------------------------------------------------------------
# エクスポート & 保存処理
# ------------------------------------------------------------------------------
def slot_to_lines(slot_id)
  lines = ["@SPRITE #{slot_id}"]
  grid = $slots[slot_id]
  16.times do |y|
    row = ""
    16.times do |x|
      c = grid[y * 16 + x]
      if c.nil?
        row << "."
      elsif c >= 0 && c <= 9
        row << c.to_s
      else
        row << ("A".ord + (c - 10)).chr
      end
    end
    lines << row
  end
  lines
end

def slot_to_text(slot_id)
  slot_to_lines(slot_id).join("\n")
end

def build_all_sprites_text
  blocks = []
  NUM_SLOTS.times do |sid|
    has_pixel = false
    $slots[sid].each do |c|
      if !c.nil?
        has_pixel = true
        break
      end
    end
    if has_pixel || sid == 0
      blocks << slot_to_text(sid)
    end
  end
  blocks.join("\n\n") + "\n"
end

def save_to_target
  out_text = build_all_sprites_text
  if save_file($save_path, out_text)
    sfx(:powerup)
    notify("SAVED TO #{$save_path}!")
  else
    sfx(:boom)
    notify("ERROR: FAILED TO SAVE #{$save_path}")
  end
end

def export_current
  puts "\n# =================================================="
  puts "# 🐰 USAKAME SPRITE DATA (Slot #{$current_slot})"
  puts "# =================================================="
  puts slot_to_text($current_slot)
  puts "# ==================================================\n"
  sfx(:pickup)
  notify("EXPORTED @SPRITE #{$current_slot} TO CONSOLE!")
end

def export_all
  puts "\n# =================================================="
  puts "# 🐰 USAKAME ALL SPRITES DATA"
  puts "# =================================================="
  puts build_all_sprites_text
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED ALL TO CONSOLE!")
end

# 塗りつぶし (Flood Fill)
def flood_fill(start_x, start_y, new_col)
  grid = $slots[$current_slot]
  target_col = grid[start_y * 16 + start_x]
  return if target_col == new_col

  push_undo
  queue = [[start_x, start_y]]
  visited = {}

  while !queue.empty?
    pt = queue.shift
    x = pt[0]
    y = pt[1]
    key = y * 16 + x
    next if visited[key]
    visited[key] = true

    if grid[key] == target_col
      grid[key] = new_col
      queue << [x + 1, y] if x + 1 < 16
      queue << [x - 1, y] if x - 1 >= 0
      queue << [x, y + 1] if y + 1 < 16
      queue << [x, y - 1] if y - 1 >= 0
    end
  end
  sfx(:click)
end

# 反転 (左右 / 上下)
def flip_sprite(horizontal)
  push_undo
  grid = $slots[$current_slot]
  new_grid = Array.new(256, nil)
  16.times do |y|
    16.times do |x|
      src_idx = y * 16 + x
      nx = horizontal ? (15 - x) : x
      ny = horizontal ? y : (15 - y)
      new_grid[ny * 16 + nx] = grid[src_idx]
    end
  end
  $slots[$current_slot] = new_grid
  sfx(:select)
end

# シフト移動 (dx, dy)
def shift_sprite(dx, dy)
  push_undo
  grid = $slots[$current_slot]
  new_grid = Array.new(256, nil)
  16.times do |y|
    16.times do |x|
      src_idx = y * 16 + x
      nx = (x + dx) % 16
      ny = (y + dy) % 16
      new_grid[ny * 16 + nx] = grid[src_idx]
    end
  end
  $slots[$current_slot] = new_grid
  sfx(:cursor)
end

def clear_sprite
  push_undo
  $slots[$current_slot] = Array.new(256, nil)
  sfx(:boom)
  notify("CLEARED SLOT #{$current_slot}")
end

# ------------------------------------------------------------------------------
# 更新処理 (update)
# ------------------------------------------------------------------------------
def update
  mx = mouse_x
  my = mouse_y

  $notify_timer = [$notify_timer - 1, 0].max

  if $anim_playing
    $anim_timer += 1
    if $anim_timer >= 8
      $anim_timer = 0
      $anim_frame = ($anim_frame + 1) % 4
    end
  end

  # --- キーボードショートカット ---
  perform_undo if btnp(:z)
  save_to_target if btnp(:s)
  export_current if btnp(:x)
  clear_sprite if btnp(:c)

  # 矢印キーでシフト
  shift_sprite(-1, 0) if btnp(0) # left
  shift_sprite(1, 0)  if btnp(1) # right
  shift_sprite(0, -1) if btnp(2) # up
  shift_sprite(0, 1)  if btnp(3) # down

  # マウスホイールで色変更
  wheel = mouse_wheel
  if wheel > 0.2
    $current_col = ($current_col.nil? ? 15 : ($current_col - 1) % 16)
    sfx(:cursor)
  elsif wheel < -0.2
    $current_col = ($current_col.nil? ? 0 : ($current_col + 1) % 16)
    sfx(:cursor)
  end

  # モーダル中のクリック
  if $show_code_modal
    if btnp(:mouse_l)
      $show_code_modal = false
      sfx(:click)
    end
    return
  end

  # --- ボタンクリック判定 (mouse_l / mouse_r) ---
  if btnp(:mouse_l)
    # 1. ヘッダーボタン
    if my >= 3 && my <= 21
      if mx >= 330 && mx <= 385 # [SAVE]
        save_to_target
      elsif mx >= 390 && mx <= 430 # [EXP]
        export_all
      elsif mx >= 435 && mx <= 475 # [CODE]
        $show_code_modal = true
        sfx(:click)
      end
    end

    # 2. プレビュー操作
    if my >= 28 && my <= 44
      if mx >= 282 && mx <= 306 # [BG]
        $bg_mode = ($bg_mode + 1) % 4
        sfx(:click)
      elsif mx >= 310 && mx <= 334 # [▶/■]
        $anim_playing = !$anim_playing
        $anim_frame = 0
        sfx(:click)
      end
    end

    # 3. パレット選択 (4x4, x: 220..316, y: 76..172, 各22x22, 間隔3px)
    if mx >= 220 && mx < 320 && my >= 76 && my < 176
      col_idx = (mx - 220) / 25
      row_idx = (my - 76) / 25
      if col_idx >= 0 && col_idx < 4 && row_idx >= 0 && row_idx < 4
        $current_col = row_idx * 4 + col_idx
        $current_tool = :pen if $current_tool == :eraser
        sfx(:select)
      end
    end

    # [TRANS] 透過色ボタン (x: 220..316, y: 180..196)
    if mx >= 220 && mx <= 316 && my >= 180 && my <= 196
      $current_col = nil
      sfx(:select)
    end

    # 4. ツールボタン (キャンバス下部, y: 224..242)
    if my >= 224 && my <= 242
      if mx >= 12 && mx <= 42 # [PEN]
        $current_tool = :pen
        sfx(:click)
      elsif mx >= 46 && mx <= 76 # [FILL]
        $current_tool = :fill
        sfx(:click)
      elsif mx >= 80 && mx <= 110 # [PICK]
        $current_tool = :picker
        sfx(:click)
      elsif mx >= 114 && mx <= 152 # [ERASER]
        $current_tool = :eraser
        sfx(:click)
      elsif mx >= 156 && mx <= 186 # [GRID]
        $show_grid = !$show_grid
        sfx(:click)
      elsif mx >= 190 && mx <= 204 # [CLR]
        clear_sprite
      end
    end

    # 5. アクションボタン (中央下部, y: 202..242)
    if my >= 202 && my <= 220
      if mx >= 220 && mx <= 264 # [UNDO]
        perform_undo
      elsif mx >= 268 && mx <= 316 # [FLIP-H]
        flip_sprite(true)
      elsif mx >= 320 && mx <= 340 # [↑]
        shift_sprite(0, -1)
      end
    elsif my >= 224 && my <= 242
      if mx >= 220 && mx <= 264 # [FLIP-V]
        flip_sprite(false)
      elsif mx >= 268 && mx <= 288 # [←]
        shift_sprite(-1, 0)
      elsif mx >= 292 && mx <= 312 # [↓]
        shift_sprite(0, 1)
      elsif mx >= 316 && mx <= 336 # [→]
        shift_sprite(1, 0)
      end
    end

    # 6. スロット選択 (4列 x 4行, x: 350..470, y: 40..160, 各26x26, 間隔4px)
    if mx >= 350 && mx < 470 && my >= 40 && my < 160
      col = (mx - 350) / 30
      row = (my - 40) / 30
      if col >= 0 && col < 4 && row >= 0 && row < 4
        slot_id = row * 4 + col
        if slot_id < NUM_SLOTS
          $current_slot = slot_id
          sfx(:click)
        end
      end
    end
  end

  # --- キャンバス内での描画 & ツール操作 ---
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + GRID_SIZE * $cell_size &&
               my >= $canvas_y && my < $canvas_y + GRID_SIZE * $cell_size)

  if in_canvas
    px = (mx - $canvas_x) / $cell_size
    py = (my - $canvas_y) / $cell_size
    px = [[px, 0].max, 15].min
    py = [[py, 0].max, 15].min
    idx = py * 16 + px

    case $current_tool
    when :pen
      push_undo if btnp(:mouse_l) || btnp(:mouse_r)
      if btn(:mouse_l)
        $slots[$current_slot][idx] = $current_col if $slots[$current_slot][idx] != $current_col
      elsif btn(:mouse_r)
        $slots[$current_slot][idx] = nil unless $slots[$current_slot][idx].nil?
      end
    when :eraser
      push_undo if btnp(:mouse_l)
      if btn(:mouse_l)
        $slots[$current_slot][idx] = nil unless $slots[$current_slot][idx].nil?
      end
    when :fill
      if btnp(:mouse_l)
        flood_fill(px, py, $current_col)
      elsif btnp(:mouse_r)
        flood_fill(px, py, nil)
      end
    when :picker
      if btnp(:mouse_l)
        picked = $slots[$current_slot][idx]
        $current_col = picked
        $current_tool = :pen
        sfx(:pickup)
        notify("PICKED: #{picked ? COLOR_NAMES[picked] : 'TRANS'}")
      end
    end
  end
end

# ------------------------------------------------------------------------------
# 描画処理 (draw)
# ------------------------------------------------------------------------------
def draw
  cls(0) # 背景: 黒

  mx = mouse_x
  my = mouse_y

  # 1. 上部ヘッダーバー (y: 0..24)
  rectfill(0, 0, 480, 24, 1) # 濃紺
  line(0, 24, 480, 24, 5)

  print_text("USAKAME SPRITE STUDIO", 8, 7, 7)
  print_text("Target: #{$target_path} -> Save: #{$save_path}", 160, 7, 6)

  # [SAVE] ボタン (緑)
  rectfill(330, 4, 55, 16, 11)
  rect(330, 4, 55, 16, 7)
  print_text("SAVE", 344, 8, 0)

  # [EXP] ボタン
  rectfill(390, 4, 40, 16, 2)
  rect(390, 4, 40, 16, 6)
  print_text("EXP", 401, 8, 7)

  # [CODE] ボタン
  rectfill(435, 4, 40, 16, 2)
  rect(435, 4, 40, 16, 6)
  print_text("CODE", 442, 8, 7)

  # 2. キャンバス描画 (16x16, 12px/cell)
  # 枠線
  rectfill($canvas_x - 2, $canvas_y - 2, GRID_SIZE * $cell_size + 4, GRID_SIZE * $cell_size + 4, 1)
  rect($canvas_x - 2, $canvas_y - 2, GRID_SIZE * $cell_size + 4, GRID_SIZE * $cell_size + 4, 5)

  grid = $slots[$current_slot]
  GRID_SIZE.times do |y|
    GRID_SIZE.times do |x|
      cx = $canvas_x + x * $cell_size
      cy = $canvas_y + y * $cell_size
      c = grid[y * 16 + x]

      if c.nil?
        # 市松模様
        pattern_col = ((x + y) % 2 == 0) ? 0 : 5
        rectfill(cx, cy, $cell_size, $cell_size, pattern_col)
      else
        rectfill(cx, cy, $cell_size, $cell_size, c)
      end

      # グリッド線
      if $show_grid
        rect(cx, cy, $cell_size + 1, $cell_size + 1, 1)
      end
    end
  end

  # カーソル枠プレビュー
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + GRID_SIZE * $cell_size &&
               my >= $canvas_y && my < $canvas_y + GRID_SIZE * $cell_size)
  if in_canvas
    hx = (mx - $canvas_x) / $cell_size
    hy = (my - $canvas_y) / $cell_size
    rect($canvas_x + hx * $cell_size, $canvas_y + hy * $cell_size, $cell_size, $cell_size, 7)
  end

  # 3. ツールバー (キャンバス下部, y: 224..242)
  tools = [
    [:pen, "PEN", 12, 30],
    [:fill, "FILL", 46, 30],
    [:picker, "PICK", 80, 30],
    [:eraser, "ERASER", 114, 38]
  ]
  tools.each do |item|
    tool_id = item[0]
    label = item[1]
    bx = item[2]
    bw = item[3]
    is_active = ($current_tool == tool_id)
    rectfill(bx, 224, bw, 18, is_active ? 8 : 1)
    rect(bx, 224, bw, 18, is_active ? 7 : 5)
    print_text(label, bx + 4, 229, is_active ? 7 : 6)
  end

  # [GRID]
  rectfill(156, 224, 30, 18, $show_grid ? 12 : 1)
  rect(156, 224, 30, 18, 5)
  print_text("GRID", 160, 229, $show_grid ? 7 : 5)

  # [CLR]
  rectfill(190, 224, 26, 18, 1)
  rect(190, 224, 26, 18, 8)
  print_text("CLR", 193, 229, 8)

  # 4. 中央ペイン: プレビュー & パレット
  print_text("PREVIEW", 220, 27, 6)

  preview_bg = case $bg_mode
               when 0 then 0
               when 1 then 1
               when 2 then 7
               else 5
               end

  disp_slot = $anim_playing ? ($anim_frame % 4) : $current_slot
  disp_grid = $slots[disp_slot]

  # 1x プレビュー (16x16, x: 220, y: 38)
  rectfill(219, 37, 18, 18, preview_bg)
  rect(219, 37, 18, 18, 5)
  16.times do |y|
    16.times do |x|
      c = disp_grid[y * 16 + x]
      pset(220 + x, 38 + y, c) unless c.nil?
    end
  end

  # 2x プレビュー (32x32, x: 242, y: 30)
  rectfill(241, 29, 34, 34, preview_bg)
  rect(241, 29, 34, 34, 5)
  16.times do |y|
    16.times do |x|
      c = disp_grid[y * 16 + x]
      rectfill(242 + x * 2, 30 + y * 2, 2, 2, c) unless c.nil?
    end
  end

  # [BG]
  rectfill(282, 32, 24, 15, 2)
  rect(282, 32, 24, 15, 6)
  print_text("BG", 288, 36, 7)

  # [▶/■]
  rectfill(310, 32, 24, 15, $anim_playing ? 8 : 3)
  rect(310, 32, 24, 15, 6)
  print_text($anim_playing ? "■" : "▶", 318, 36, 7)

  # パレットヘッダー (y: 65)
  print_text("PALETTE (#{$current_col ? COLOR_NAMES[$current_col] : 'TRANS'})", 220, 66, 6)

  # 16色グリッド (4x4, y: 76..172)
  4.times do |row|
    4.times do |col_idx|
      c_id = row * 4 + col_idx
      bx = 220 + col_idx * 25
      by = 76 + row * 25
      rectfill(bx, by, 22, 22, c_id)
      if $current_col == c_id
        rect(bx - 1, by - 1, 24, 24, 7)
      else
        rect(bx, by, 22, 22, 0)
      end
    end
  end

  # [TRANS]
  rectfill(220, 180, 96, 16, $current_col.nil? ? 8 : 1)
  rect(220, 180, 96, 16, $current_col.nil? ? 7 : 5)
  print_text("TRANSPARENT (.)", 232, 184, $current_col.nil? ? 7 : 6)

  # アクションボタン群 (y: 202..242)
  rectfill(220, 202, 44, 18, 1)
  rect(220, 202, 44, 18, 5)
  print_text("UNDO", 228, 207, 7)

  rectfill(268, 202, 48, 18, 1)
  rect(268, 202, 48, 18, 5)
  print_text("FLIP-H", 274, 207, 7)

  rectfill(220, 224, 44, 18, 1)
  rect(220, 224, 44, 18, 5)
  print_text("FLIP-V", 225, 229, 7)

  # シフト矢印
  arrow_buttons = [
    ["←", 268, 224, 20],
    ["↓", 292, 224, 20],
    ["→", 316, 224, 20],
    ["↑", 320, 202, 20]
  ]
  arrow_buttons.each do |item|
    lbl = item[0]
    sx = item[1]
    sy = item[2]
    sw = item[3]
    rectfill(sx, sy, sw, 18, 1)
    rect(sx, sy, sw, 18, 5)
    print_text(lbl, sx + 5, sy + 5, 7)
  end

  # 5. 右ペイン: 16スロット一覧 (4x4 サムネイル, x: 350..470, y: 35..180)
  print_text("SLOTS (0..15)", 350, 27, 6)

  4.times do |row|
    4.times do |col|
      sid = row * 4 + col
      sx = 350 + col * 30
      sy = 40 + row * 30
      is_sel = ($current_slot == sid)

      rectfill(sx, sy, 26, 26, is_sel ? 2 : 1)
      rect(sx, sy, 26, 26, is_sel ? 7 : 5)

      sgrid = $slots[sid]
      16.times do |py|
        16.times do |px|
          c = sgrid[py * 16 + px]
          # 26x26 内に 16x16 を縮小表示 (簡易ドット)
          pset(sx + 5 + px, sy + 5 + py, c) unless c.nil?
        end
      end
      # スロット番号
      print_text(sid.to_s, sx + 2, sy + 2, is_sel ? 10 : 5)
    end
  end

  # スロット情報
  active_pixels = 0
  $slots[$current_slot].each do |c|
    active_pixels += 1 unless c.nil?
  end
  print_text("Slot ##{$current_slot}: #{active_pixels}/256 px", 350, 168, 6)
  print_text("Shortcuts: Z (Undo), S (Save), X (Exp)", 350, 184, 5)
  print_text("Arrows: Shift, Wheel: Color", 350, 198, 5)

  # 6. 下部ステータスバー (y: 250..270)
  rectfill(0, 250, 480, 20, 1)
  line(0, 250, 480, 250, 5)

  if $notify_timer > 0
    print_text("▶ #{$notify_msg}", 10, 256, 10)
  else
    print_text("Ready. [SAVE] to write #{$save_path}. Auto hot-reload active.", 10, 256, 6)
  end

  # 7. コードプレビューモーダル
  if $show_code_modal
    rectfill(30, 20, 420, 230, 0)
    rect(30, 20, 420, 230, 7)
    print_text("--- SPRITE CODE PREVIEW (Click anywhere to close) ---", 40, 28, 10)

    preview_lines = slot_to_lines($current_slot)
    preview_lines.each_with_index do |pl, i|
      break if i > 18
      print_text(pl, 40, 44 + i * 10, 7)
    end
  end

  # 8. マウスカーソル描画
  pset(mx, my, 7)
  pset(mx + 1, my, 7)
  pset(mx, my + 1, 7)
  pset(mx + 2, my + 2, 7)
  pset(mx + 3, my + 3, 0)
end

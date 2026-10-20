# ==============================================================================
# 🐰 Usakame Sample: High-Resolution Sprite Editor (スプライトエディタ) 🐢
# ------------------------------------------------------------------------------
# 256x256 バンク対応 & 32x32 キャンバス編集ツールです。
#
# 【特徴】
# - 256x256 バンクシステム対応:
#     1バンク = 256x256 ピクセル（16x16スプライト換算で最大256個格納）。
# - 32x32 編集キャンバス:
#     16x16 はもちろん、大型キャラ・ボス・パーツ用の 32x32 ドット絵もシームレスに編集可能。
# - 256x256 全体ミニマップ:
#     右側のミニマップから 16px 単位で編集エリアを選択（ジャンプ）。
# - 高速プレビュー & テクスチャ同期:
#     ランタイムのバンクテクスチャと即時同期（blt 高速描画）。
# - 非破壊保存:
#     ターゲットファイル内の @BANK <id> セクションを安全に更新。
# ==============================================================================

config(
  width: 480,
  height: 270,
  window_scale: 2.0,
  text_size: 8,
  title: "Usakame Sprite Editor"
)

# OS 標準マウスカーソルを使用
show_mouse(true)

# ------------------------------------------------------------------------------
# 定数 & 初期化
# ------------------------------------------------------------------------------
BANK_SIZE = 256
CANVAS_GRID = 32

COLOR_NAMES = [
  "BLACK", "DARK-BLUE", "PURPLE", "DARK-GREEN",
  "BROWN", "DARK-GRAY", "LIGHT-GRAY", "WHITE",
  "RED", "ORANGE", "YELLOW", "GREEN",
  "BLUE", "INDIGO", "PINK", "PEACH"
]

# キャンバス配置 (32x32, 1セル = 6px -> 192x192)
$canvas_x = 12
$canvas_y = 28
$cell_size = 6

# ミニマップ配置 (256x256 を 1/2 スケールで 128x128)
$minimap_x = 342
$minimap_y = 38
$minimap_size = 128

# 編集位置 (16の倍数, 0..224)
$sel_x = 0
$sel_y = 0

# バンク番号
$current_bank = 0

# ツール一覧: :pen, :fill, :picker, :eraser
$current_tool = :pen
$current_col = 8     # 初期描画色 (赤)
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

# 256x256 バンクピクセルデータ (65536要素, nil または 0..15)
$bank_pixels = Array.new(BANK_SIZE * BANK_SIZE, nil)

# ------------------------------------------------------------------------------
# ターゲットファイル検出 & バンク指定
# ------------------------------------------------------------------------------
def is_numeric_arg?(s)
  return false if s.nil? || s.empty?
  s.size.times do |i|
    ch = s[i]
    return false if ch < "0" || ch > "9"
  end
  true
end

$target_path = "game.rb"
if ARGV && ARGV.size > 0 && ARGV[0]
  # 第1引数が数値ならバンク番号、それ以外ならパス
  if is_numeric_arg?(ARGV[0])
    $current_bank = ARGV[0].to_i
  else
    $target_path = ARGV[0]
  end
end
if ARGV && ARGV.size > 1 && ARGV[1]
  $current_bank = ARGV[1].to_i
end

$save_path = $target_path
tlen = $target_path.size
if tlen >= 3
  suf = $target_path[tlen - 3, 3]
  if suf == ".rb"
    $save_path = $target_path[0, tlen - 3] + ".spr"
  end
end

def notify(msg)
  $notify_msg = msg
  $notify_timer = 120 # 約2秒表示
end

# 32x32 領域のピクセルを配列で取得
def get_canvas_pixels(bx, by)
  pixels = Array.new(CANVAS_GRID * CANVAS_GRID, nil)
  CANVAS_GRID.times do |cy|
    CANVAS_GRID.times do |cx|
      gx = bx + cx
      gy = by + cy
      if gx < BANK_SIZE && gy < BANK_SIZE
        pixels[cy * CANVAS_GRID + cx] = $bank_pixels[gy * BANK_SIZE + gx]
      end
    end
  end
  pixels
end

# 32x32 領域のピクセルを復元
def set_canvas_pixels(bx, by, pixels)
  CANVAS_GRID.times do |cy|
    CANVAS_GRID.times do |cx|
      gx = bx + cx
      gy = by + cy
      if gx < BANK_SIZE && gy < BANK_SIZE
        $bank_pixels[gy * BANK_SIZE + gx] = pixels[cy * CANVAS_GRID + cx]
      end
    end
  end
end

def push_undo
  $undo_stack << [$sel_x, $sel_y, get_canvas_pixels($sel_x, $sel_y)]
  $undo_stack.shift if $undo_stack.size > 30
end

def perform_undo
  return if $undo_stack.empty?
  sel_x, sel_y, saved_grid = $undo_stack.pop
  $sel_x = sel_x
  $sel_y = sel_y
  set_canvas_pixels(sel_x, sel_y, saved_grid)
  update_bank($current_bank, $bank_pixels)
  sfx(:click)
  notify("UNDO")
end

# 起動時の読み込み
load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
loaded_bank = load_resource_bank(load_source, $current_bank)

if loaded_bank && loaded_bank.size == BANK_SIZE * BANK_SIZE
  $bank_pixels = loaded_bank
  update_bank($current_bank, $bank_pixels)
  notify("LOADED BANK #{$current_bank} FROM #{load_source}")
else
  # サンプルうさぎスプライトをバンク0の (0, 0) に初期設定
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
        $bank_pixels[y * BANK_SIZE + x] = ch.to_i(16)
      end
    end
  end
  update_bank($current_bank, $bank_pixels)
  notify("TARGET: #{$target_path} (NEW BANK #{$current_bank})")
end

# ------------------------------------------------------------------------------
# バンク切り替え処理
# ------------------------------------------------------------------------------
def switch_bank(new_bank)
  return if new_bank < 0
  $current_bank = new_bank
  $undo_stack.clear

  load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
  loaded = load_resource_bank(load_source, $current_bank)
  if loaded && loaded.size == BANK_SIZE * BANK_SIZE
    $bank_pixels = loaded
  else
    $bank_pixels = Array.new(BANK_SIZE * BANK_SIZE, nil)
  end
  update_bank($current_bank, $bank_pixels)
  notify("SWITCHED TO BANK #{$current_bank}")
end

# ------------------------------------------------------------------------------
# 保存 & エクスポート処理
# ------------------------------------------------------------------------------
def save_to_target
  b64 = bank_to_b64_png($bank_pixels)
  unless b64
    sfx(:boom)
    notify("ERROR: FAILED TO ENCODE PNG")
    return
  end

  # 既存ファイルの読み込みとセクション更新
  original_content = read_file($save_path) || ""
  bank_header = "@BANK #{$current_bank}"
  bank_block = "#{bank_header}\n#{b64}\n"

  new_content = ""
  if original_content.include?(bank_header)
    # 既存の @BANK <id> セクションを置換
    lines = original_content.split("\n")
    in_target_bank = false
    lines.each do |line|
      if line.strip == bank_header
        in_target_bank = true
        new_content << bank_block
      elsif in_target_bank && (line.start_with?("@") || line.start_with?("__END__"))
        in_target_bank = false
        new_content << line << "\n"
      elsif !in_target_bank
        new_content << line << "\n"
      end
    end
  else
    # 末尾に追記
    new_content = original_content
    new_content << "\n" unless new_content.empty? || new_content.end_with?("\n")
    new_content << bank_block
  end

  if save_file($save_path, new_content)
    sfx(:powerup)
    notify("SAVED BANK #{$current_bank} TO #{$save_path}!")
  else
    sfx(:boom)
    notify("ERROR: FAILED TO SAVE #{$save_path}")
  end
end

def export_all
  b64 = bank_to_b64_png($bank_pixels)
  puts "\n# =================================================="
  puts "# 🐰 USAKAME BANK DATA (Bank #{$current_bank})"
  puts "# =================================================="
  puts "@BANK #{$current_bank}"
  puts b64
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED @BANK #{$current_bank} TO CONSOLE!")
end

# 塗りつぶし (Flood Fill on 32x32 canvas)
def flood_fill(start_cx, start_cy, new_col)
  start_gx = $sel_x + start_cx
  start_gy = $sel_y + start_cy
  return if start_gx >= BANK_SIZE || start_gy >= BANK_SIZE

  target_col = $bank_pixels[start_gy * BANK_SIZE + start_gx]
  return if target_col == new_col

  push_undo
  queue = [[start_cx, start_cy]]
  visited = {}

  while !queue.empty?
    pt = queue.shift
    cx = pt[0]
    cy = pt[1]
    key = cy * CANVAS_GRID + cx
    next if visited[key]
    visited[key] = true

    gx = $sel_x + cx
    gy = $sel_y + cy
    next if gx >= BANK_SIZE || gy >= BANK_SIZE

    idx = gy * BANK_SIZE + gx
    if $bank_pixels[idx] == target_col
      $bank_pixels[idx] = new_col
      queue << [cx + 1, cy] if cx + 1 < CANVAS_GRID
      queue << [cx - 1, cy] if cx - 1 >= 0
      queue << [cx, cy + 1] if cy + 1 < CANVAS_GRID
      queue << [cx, cy - 1] if cy - 1 >= 0
    end
  end
  update_bank($current_bank, $bank_pixels)
  sfx(:click)
end

# 反転 (32x32 領域内)
def flip_canvas(horizontal)
  push_undo
  cur = get_canvas_pixels($sel_x, $sel_y)
  new_grid = Array.new(CANVAS_GRID * CANVAS_GRID, nil)
  CANVAS_GRID.times do |cy|
    CANVAS_GRID.times do |cx|
      src_idx = cy * CANVAS_GRID + cx
      nx = horizontal ? (CANVAS_GRID - 1 - cx) : cx
      ny = horizontal ? cy : (CANVAS_GRID - 1 - cy)
      new_grid[ny * CANVAS_GRID + nx] = cur[src_idx]
    end
  end
  set_canvas_pixels($sel_x, $sel_y, new_grid)
  update_bank($current_bank, $bank_pixels)
  sfx(:select)
end

# シフト移動 (dx, dy on 32x32)
def shift_canvas(dx, dy)
  push_undo
  cur = get_canvas_pixels($sel_x, $sel_y)
  new_grid = Array.new(CANVAS_GRID * CANVAS_GRID, nil)
  CANVAS_GRID.times do |cy|
    CANVAS_GRID.times do |cx|
      src_idx = cy * CANVAS_GRID + cx
      nx = (cx + dx) % CANVAS_GRID
      ny = (cy + dy) % CANVAS_GRID
      new_grid[ny * CANVAS_GRID + nx] = cur[src_idx]
    end
  end
  set_canvas_pixels($sel_x, $sel_y, new_grid)
  update_bank($current_bank, $bank_pixels)
  sfx(:cursor)
end

def clear_canvas
  push_undo
  new_grid = Array.new(CANVAS_GRID * CANVAS_GRID, nil)
  set_canvas_pixels($sel_x, $sel_y, new_grid)
  update_bank($current_bank, $bank_pixels)
  sfx(:boom)
  notify("CLEARED 32x32 AT (#{$sel_x}, #{$sel_y})")
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
  export_all if btnp(:x)
  clear_canvas if btnp(:c)

  # 矢印キーで 32x32 シフト
  if btn(:ctrl)
    # Ctrl+矢印で選択エリア移動 (16px刻み)
    $sel_x = [$sel_x - 16, 0].max if btnp(0)
    $sel_x = [$sel_x + 16, 224].min if btnp(1)
    $sel_y = [$sel_y - 16, 0].max if btnp(2)
    $sel_y = [$sel_y + 16, 224].min if btnp(3)
  else
    shift_canvas(-1, 0) if btnp(0) # left
    shift_canvas(1, 0)  if btnp(1) # right
    shift_canvas(0, -1) if btnp(2) # up
    shift_canvas(0, 1)  if btnp(3) # down
  end

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

  # --- ミニマップ上でのドラッグ／クリック判定 ---
  in_minimap = (mx >= $minimap_x && mx < $minimap_x + $minimap_size &&
                my >= $minimap_y && my < $minimap_y + $minimap_size)
  if in_minimap && (btn(:mouse_l) || btn(:mouse_r))
    # ミニマップ上では 1セル = 0.5px -> 8px が 16px グリッド
    gx = ((mx - $minimap_x) / 8) * 16
    gy = ((my - $minimap_y) / 8) * 16
    gx = [[gx, 0].max, 224].min
    gy = [[gy, 0].max, 224].min
    if $sel_x != gx || $sel_y != gy
      $sel_x = gx
      $sel_y = gy
      sfx(:cursor)
    end
  end

  # --- ボタンクリック判定 (mouse_l / mouse_r) ---
  if btnp(:mouse_l)
    # 1. ヘッダーボタン
    if my >= 3 && my <= 21
      if mx >= 260 && mx <= 276 # [<] バンク減
        switch_bank([$current_bank - 1, 0].max)
        sfx(:click)
      elsif mx >= 324 && mx <= 340 # [>] バンク増
        switch_bank($current_bank + 1)
        sfx(:click)
      elsif mx >= 346 && mx <= 390 # [SAVE]
        save_to_target
      elsif mx >= 395 && mx <= 430 # [EXP]
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

    # 3. パレット選択 (4x4, x: 220..316, y: 76..172)
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
        clear_canvas
      end
    end

    # 5. アクションボタン (中央下部, y: 202..242)
    if my >= 202 && my <= 220
      if mx >= 220 && mx <= 264 # [UNDO]
        perform_undo
      elsif mx >= 268 && mx <= 316 # [FLIP-H]
        flip_canvas(true)
      elsif mx >= 320 && mx <= 340 # [↑]
        shift_canvas(0, -1)
      end
    elsif my >= 224 && my <= 242
      if mx >= 220 && mx <= 264 # [FLIP-V]
        flip_canvas(false)
      elsif mx >= 268 && mx <= 288 # [←]
        shift_canvas(-1, 0)
      elsif mx >= 292 && mx <= 312 # [↓]
        shift_canvas(0, 1)
      elsif mx >= 316 && mx <= 336 # [→]
        shift_canvas(1, 0)
      end
    end
  end

  # --- キャンバス内での描画 & ツール操作 (32x32) ---
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + CANVAS_GRID * $cell_size &&
               my >= $canvas_y && my < $canvas_y + CANVAS_GRID * $cell_size)

  if in_canvas
    cx = (mx - $canvas_x) / $cell_size
    cy = (my - $canvas_y) / $cell_size
    cx = [[cx, 0].max, CANVAS_GRID - 1].min
    cy = [[cy, 0].max, CANVAS_GRID - 1].min

    gx = $sel_x + cx
    gy = $sel_y + cy

    if gx < BANK_SIZE && gy < BANK_SIZE
      idx = gy * BANK_SIZE + gx

      case $current_tool
      when :pen
        push_undo if btnp(:mouse_l) || btnp(:mouse_r)
        if btn(:mouse_l)
          if $bank_pixels[idx] != $current_col
            $bank_pixels[idx] = $current_col
            update_bank($current_bank, $bank_pixels)
          end
        elsif btn(:mouse_r)
          unless $bank_pixels[idx].nil?
            $bank_pixels[idx] = nil
            update_bank($current_bank, $bank_pixels)
          end
        end
      when :eraser
        push_undo if btnp(:mouse_l)
        if btn(:mouse_l)
          unless $bank_pixels[idx].nil?
            $bank_pixels[idx] = nil
            update_bank($current_bank, $bank_pixels)
          end
        end
      when :fill
        if btnp(:mouse_l)
          flood_fill(cx, cy, $current_col)
        elsif btnp(:mouse_r)
          flood_fill(cx, cy, nil)
        end
      when :picker
        if btnp(:mouse_l)
          picked = $bank_pixels[idx]
          $current_col = picked
          $current_tool = :pen
          sfx(:pickup)
          notify("PICKED: #{picked ? COLOR_NAMES[picked] : 'TRANS'}")
        end
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

  print_text("USAKAME STUDIO", 8, 7, 7)
  print_text("Bank: #{$current_bank}", 110, 7, 10)

  # [< BANK n >] バンク選択ボタン
  rectfill(260, 4, 16, 16, 2)
  rect(260, 4, 16, 16, 6)
  print_text("<", 265, 8, 7)

  rectfill(280, 4, 40, 16, 1)
  rect(280, 4, 40, 16, 5)
  print_text("B#{$current_bank}", 292, 8, 10)

  rectfill(324, 4, 16, 16, 2)
  rect(324, 4, 16, 16, 6)
  print_text(">", 330, 8, 7)

  # [SAVE] ボタン (緑)
  rectfill(346, 4, 44, 16, 11)
  rect(346, 4, 44, 16, 7)
  print_text("SAVE", 356, 8, 0)

  # [EXP] ボタン
  rectfill(395, 4, 35, 16, 2)
  rect(395, 4, 35, 16, 6)
  print_text("EXP", 403, 8, 7)

  # [CODE] ボタン
  rectfill(435, 4, 38, 16, 2)
  rect(435, 4, 38, 16, 6)
  print_text("CODE", 441, 8, 7)

  # 2. キャンバス描画 (32x32, 6px/cell -> 192x192)
  rectfill($canvas_x - 2, $canvas_y - 2, CANVAS_GRID * $cell_size + 4, CANVAS_GRID * $cell_size + 4, 1)
  rect($canvas_x - 2, $canvas_y - 2, CANVAS_GRID * $cell_size + 4, CANVAS_GRID * $cell_size + 4, 5)

  CANVAS_GRID.times do |cy|
    CANVAS_GRID.times do |cx|
      px = $canvas_x + cx * $cell_size
      py = $canvas_y + cy * $cell_size
      gx = $sel_x + cx
      gy = $sel_y + cy

      if gx >= BANK_SIZE || gy >= BANK_SIZE
        # バンク領域外
        rectfill(px, py, $cell_size, $cell_size, 0)
      else
        c = $bank_pixels[gy * BANK_SIZE + gx]
        if c.nil?
          pattern_col = ((cx + cy) % 2 == 0) ? 0 : 5
          rectfill(px, py, $cell_size, $cell_size, pattern_col)
        else
          rectfill(px, py, $cell_size, $cell_size, c)
        end
      end
    end
  end

  # グリッド線 (一括描画で高速化)
  if $show_grid
    (CANVAS_GRID + 1).times do |i|
      gx = $canvas_x + i * $cell_size
      gy = $canvas_y + i * $cell_size
      line(gx, $canvas_y, gx, $canvas_y + CANVAS_GRID * $cell_size, 1)
      line($canvas_x, gy, $canvas_x + CANVAS_GRID * $cell_size, gy, 1)
    end
  end

  # 16x16 ガイド十字線 (中央)
  guide_x = $canvas_x + 16 * $cell_size
  guide_y = $canvas_y + 16 * $cell_size
  line(guide_x, $canvas_y, guide_x, $canvas_y + 192, 6)
  line($canvas_x, guide_y, $canvas_x + 192, guide_y, 6)

  # カーソル枠プレビュー
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + CANVAS_GRID * $cell_size &&
               my >= $canvas_y && my < $canvas_y + CANVAS_GRID * $cell_size)
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

  # 1x プレビュー (16x16, x: 220, y: 38)
  rectfill(219, 37, 18, 18, preview_bg)
  rect(219, 37, 18, 18, 5)
  anim_off_x = $anim_playing ? (($anim_frame % 4) * 16) : 0
  draw_u = ($sel_x + anim_off_x) % BANK_SIZE
  blt(220, 38, $current_bank, draw_u, $sel_y, 16, 16)

  # 2x プレビュー (32x32, x: 242, y: 30)
  rectfill(241, 29, 34, 34, preview_bg)
  rect(241, 29, 34, 34, 5)
  blt(242, 30, $current_bank, $sel_x, $sel_y, 32, 32, 0, 1.0)

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

  # 5. 右ペイン: 256x256 バンクミニマップ (x: 342, y: 38, 幅128x高128)
  print_text("BANK #{$current_bank} MINIMAP (256x256)", 342, 27, 6)

  # ミニマップ外枠
  rectfill($minimap_x - 1, $minimap_y - 1, $minimap_size + 2, $minimap_size + 2, 1)
  rect($minimap_x - 1, $minimap_y - 1, $minimap_size + 2, $minimap_size + 2, 5)

  # バンク全体の 1/2 縮小テクスチャ転送描画
  blt($minimap_x, $minimap_y, $current_bank, 0, 0, 256, 256, 0, 0.5)

  # 選択中 32x32 領域の枠線表示 (ミニマップ上では 16x16 px)
  sel_box_x = $minimap_x + $sel_x / 2
  sel_box_y = $minimap_y + $sel_y / 2
  rect(sel_box_x, sel_box_y, 16, 16, 7)
  rect(sel_box_x - 1, sel_box_y - 1, 18, 18, 10)

  # ミニマップ下部情報
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  print_text("Pos:(#{$sel_x},#{$sel_y})  Sprite ID:#{cur_spr_id}", 342, 172, 10)
  print_text("Minimap: Click/Drag to jump", 342, 186, 6)
  print_text("Shortcuts: Z (Undo), S (Save), X (Exp)", 342, 200, 5)
  print_text("Arrows: Shift 32x32  Ctrl+Arrows: Move", 342, 214, 5)
  print_text("Mouse Wheel: Switch Color", 342, 228, 5)

  # 6. 下部ステータスバー (y: 250..270)
  rectfill(0, 250, 480, 20, 1)
  line(0, 250, 480, 250, 5)

  if $notify_timer > 0
    print_text("▶ #{$notify_msg}", 10, 256, 10)
  else
    print_text("Ready. Bank #{$current_bank} | [SAVE] to write #{$save_path}. Hot-reload active.", 10, 256, 6)
  end
  print_text("FPS:#{fps}", 424, 256, 11)

  # 7. コードプレビューモーダル
  if $show_code_modal
    rectfill(30, 20, 420, 230, 0)
    rect(30, 20, 420, 230, 7)
    print_text("--- BANK DATA PREVIEW (Click anywhere to close) ---", 40, 28, 10)
    print_text("@BANK #{$current_bank}", 40, 44, 7)
    b64 = bank_to_b64_png($bank_pixels) || ""
    16.times do |i|
      chunk = b64[i * 64, 64]
      break if chunk.nil? || chunk.empty?
      print_text(chunk, 40, 58 + i * 10, 6)
    end
    print_text("... (truncated)", 40, 58 + 16 * 10, 5) if b64.size > 16 * 64
  end
end

# ==============================================================================
# 🐰 Usakame Sample: Sprite Editor (スプライトエディタ) 🐢
# ------------------------------------------------------------------------------
# 16x16 のドット絵スプライトを直感的に作成・編集・エクスポートできるツールです。
#
# 【使い方】
# - 実行: uk run examples/sprite_editor.rb
# - 左クリック: ペン描画 / 塗りつぶし / スポイト / ツール選択
# - 右クリック: 消しゴム (透過色 `.` で描画)
# - マウスホイール: パレット色を前後に切り替え
# - [EXPORT]: 現在のスプライトデータをコンソール (標準出力) に出力
#   -> 出力されたテキストを自分のスクリプト末尾 (__END__ 以降) に貼り付ければ
#      spr(id, x, y) でそのまま使えます！
# - [EXP ALL]: 作成した全スロットのスプライトを一括出力
# - [CODE]: 画面上でスプライトコードを確認
# - ショートカット:
#     Z: アンドゥ (元に戻す)
#     E: エクスポート
#     0〜7: スロット切り替え
#     矢印キー: シフト移動 (上下左右)
# ==============================================================================

# OS 標準マウスカーソルを非表示にし、ゲーム内カーソルを使用
show_mouse(false)

# ------------------------------------------------------------------------------
# 定数 & 初期化
# ------------------------------------------------------------------------------
GRID_SIZE = 16
NUM_SLOTS = 8

# PICO-8 16色パレット名
COLOR_NAMES = [
  "BLACK", "DARK-BLUE", "PURPLE", "DARK-GREEN",
  "BROWN", "DARK-GRAY", "LIGHT-GRAY", "WHITE",
  "RED", "ORANGE", "YELLOW", "GREEN",
  "BLUE", "INDIGO", "PINK", "PEACH"
]

# キャンバス配置
$canvas_x = 6
$canvas_y = 22
$cell_size = 8

# ツール一覧: :pen, :fill, :picker
$current_tool = :pen
$current_col = 8     # 初期描画色 (赤)
$current_slot = 0    # 選択中スロット (0..7)
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

# アンドゥ用履歴スタック (最大20手)
$undo_stack = []

# ------------------------------------------------------------------------------
# スプライトスロットの初期化
# ------------------------------------------------------------------------------
# 各スロットは 256要素 (16x16) の配列。nil は透過 (.)、0〜15 はカラー番号。
$slots = Array.new(NUM_SLOTS) { Array.new(GRID_SIZE * GRID_SIZE, nil) }

# 初期サンプルスプライト (スロット0: 🐰 うさぎ)
SAMPLE_USAGI = [
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

SAMPLE_USAGI.each_with_index do |row, y|
  row.chars.each_with_index do |ch, x|
    if ch != "."
      col = ch.to_i(16)
      $slots[0][y * 16 + x] = col
    end
  end
end

# ------------------------------------------------------------------------------
# ユーティリティ関数
# ------------------------------------------------------------------------------

# 通知メッセージの設定
def notify(msg)
  $notify_msg = msg
  $notify_timer = 120 # 約2秒表示
end

# アンドゥ履歴の保存
def push_undo
  # 現在のスロットのグリッドを複製して保存
  $undo_stack << [$current_slot, $slots[$current_slot].dup]
  $undo_stack.shift if $undo_stack.size > 20
end

# アンドゥ実行
def perform_undo
  return if $undo_stack.empty?
  slot_id, saved_grid = $undo_stack.pop
  $current_slot = slot_id
  $slots[slot_id] = saved_grid
  sfx(:click)
  notify("UNDO")
end

# 1スロットをテキスト形式 (@SPRITE <id> ...) に変換
def slot_to_text(slot_id)
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
  lines.join("\n")
end

# 現在のスプライトをコンソールに出力
def export_current
  text = slot_to_text($current_slot)
  puts "\n# =================================================="
  puts "# 🐰 USAKAME SPRITE DATA (Copy & paste below __END__)"
  puts "# =================================================="
  puts text
  puts "# ==================================================\n"
  sfx(:pickup)
  notify("EXPORTED @SPRITE #{$current_slot} TO CONSOLE!")
end

# 全スロットをコンソールに出力
def export_all
  puts "\n# =================================================="
  puts "# 🐰 USAKAME ALL SPRITES DATA (Copy & paste below __END__)"
  puts "# =================================================="
  count = 0
  NUM_SLOTS.times do |sid|
    # 空スロットでなければ出力
    has_pixel = $slots[sid].any? { |c| !c.nil? }
    if has_pixel || sid == 0
      puts slot_to_text(sid)
      count += 1
    end
  end
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED #{count} SPRITES TO CONSOLE!")
end

# 塗りつぶし (バケツ / Flood Fill)
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

# スプライト反転 (左右 / 上下)
def flip_sprite(horizontal)
  push_undo
  grid = $slots[$current_slot]
  new_grid = Array.new(256, nil)
  16.times do |y|
    16.times do |x|
      src_idx = y * 16 + x
      nx = horizontal ? (15 - x) : x
      ny = horizontal ? y : (15 - y)
      dst_idx = ny * 16 + nx
      new_grid[dst_idx] = grid[src_idx]
    end
  end
  $slots[$current_slot] = new_grid
  sfx(:select)
end

# スプライトシフト移動 (dx, dy) - 端は循環
def shift_sprite(dx, dy)
  push_undo
  grid = $slots[$current_slot]
  new_grid = Array.new(256, nil)
  16.times do |y|
    16.times do |x|
      src_idx = y * 16 + x
      nx = (x + dx) % 16
      ny = (y + dy) % 16
      dst_idx = ny * 16 + nx
      new_grid[dst_idx] = grid[src_idx]
    end
  end
  $slots[$current_slot] = new_grid
  sfx(:cursor)
end

# スプライト全クリア
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

  # 通知タイマー減少
  $notify_timer = [$notify_timer - 1, 0].max

  # アニメーションプレビュー更新 (8フレームごと)
  if $anim_playing
    $anim_timer += 1
    if $anim_timer >= 8
      $anim_timer = 0
      $anim_frame = ($anim_frame + 1) % 4
    end
  end

  # --- キーボードショートカット ---
  perform_undo if btnp(:z)
  export_current if btnp(:x)
  export_current if btnp(5) # :enter / :x
  clear_sprite if btnp(:c)

  # 矢印キーでシフト
  shift_sprite(-1, 0) if btnp(0) # left
  shift_sprite(1, 0)  if btnp(1) # right
  shift_sprite(0, -1) if btnp(2) # up
  shift_sprite(0, 1)  if btnp(3) # down

  # 数字キーでスロット切り替え (0〜7)
  # btnp はシンボル以外に数値も受け取るが、キーコード定数がなければクリックを優先

  # マウスホイールで色変更
  wheel = mouse_wheel
  if wheel > 0.2
    $current_col = ($current_col.nil? ? 15 : ($current_col - 1) % 16)
    sfx(:cursor)
  elsif wheel < -0.2
    $current_col = ($current_col.nil? ? 0 : ($current_col + 1) % 16)
    sfx(:cursor)
  end

  # --- コードモーダル表示中の操作 ---
  if $show_code_modal
    if btnp(:mouse_l)
      # 閉じるボタン (x: 206..236, y: 22..36)
      if mx >= 206 && mx <= 236 && my >= 22 && my <= 36
        $show_code_modal = false
        sfx(:click)
      # [EXPORT TO CONSOLE] ボタン (x: 30..130, y: 196..212)
      elsif mx >= 30 && mx <= 130 && my >= 196 && my <= 212
        export_current
      # モーダル外クリックで閉じる
      elsif mx < 16 || mx > 240 || my < 16 || my > 240
        $show_code_modal = false
      end
    end
    return
  end

  # --- UI ボタンクリック判定 ---
  if btnp(:mouse_l)
    # 1. スロット選択ヘッダー (y: 2..16)
    if my >= 2 && my <= 16
      NUM_SLOTS.times do |i|
        bx = 76 + i * 16
        if mx >= bx && mx < bx + 14
          $current_slot = i
          sfx(:select)
        end
      end
    end

    # 2. プレビュー操作ボタン (y: 24..38)
    if my >= 24 && my <= 38
      # [BG] 背景切り替え (x: 202..222)
      if mx >= 202 && mx < 222
        $bg_mode = ($bg_mode + 1) % 4
        sfx(:click)
      # [▶/■] アニメーショントグル (x: 226..248)
      elsif mx >= 226 && mx < 248
        $anim_playing = !$anim_playing
        $anim_frame = 0
        sfx(:select)
      end
    end

    # 3. パレットクリック (y: 72..130)
    if my >= 72 && my <= 130
      # 16色グリッド (x: 140..198)
      4.times do |row|
        4.times do |col_idx|
          bx = 140 + col_idx * 15
          by = 72 + row * 15
          if mx >= bx && mx < bx + 13 && my >= by && my < by + 13
            $current_col = row * 4 + col_idx
            sfx(:select)
          end
        end
      end

      # TRANS (.) 透過色ボタン (x: 204..248, y: 72..98)
      if mx >= 204 && mx <= 248 && my >= 72 && my <= 98
        $current_col = nil
        sfx(:select)
      end
    end

    # 4. ツールボタン 行1 (y: 154..168)
    if my >= 154 && my <= 168
      # [PEN] (x: 6..36)
      if mx >= 6 && mx <= 36
        $current_tool = :pen
        sfx(:click)
      # [FILL] (x: 40..74)
      elsif mx >= 40 && mx <= 74
        $current_tool = :fill
        sfx(:click)
      # [PICK] (x: 78..112)
      elsif mx >= 78 && mx <= 112
        $current_tool = :picker
        sfx(:click)
      # [UNDO] (x: 116..152)
      elsif mx >= 116 && mx <= 152
        perform_undo
      # [GRID] (x: 156..190)
      elsif mx >= 156 && mx <= 190
        $show_grid = !$show_grid
        sfx(:click)
      # [CLR] (x: 194..226)
      elsif mx >= 194 && mx <= 226
        clear_sprite
      end
    end

    # 5. ツールボタン 行2 (y: 172..186)
    if my >= 172 && my <= 186
      # [FLIP-H] (x: 6..46)
      if mx >= 6 && mx <= 46
        flip_sprite(true)
      # [FLIP-V] (x: 50..90)
      elsif mx >= 50 && mx <= 90
        flip_sprite(false)
      # [←] (x: 96..112)
      elsif mx >= 96 && mx <= 112
        shift_sprite(-1, 0)
      # [→] (x: 116..132)
      elsif mx >= 116 && mx <= 132
        shift_sprite(1, 0)
      # [↑] (x: 136..152)
      elsif mx >= 136 && mx <= 152
        shift_sprite(0, -1)
      # [↓] (x: 156..172)
      elsif mx >= 156 && mx <= 172
        shift_sprite(0, 1)
      # [CODE] (x: 180..226)
      elsif mx >= 180 && mx <= 226
        $show_code_modal = true
        sfx(:click)
      end
    end

    # 6. エクスポートボタン 行3 (y: 190..206)
    if my >= 190 && my <= 206
      # [EXPORT @SPRITE] (x: 6..144)
      if mx >= 6 && mx <= 144
        export_current
      # [EXP ALL] (x: 150..248)
      elsif mx >= 150 && mx <= 248
        export_all
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
      # 左ドラッグで選択色描画、右ドラッグで透過 (消しゴム)
      if btnp(:mouse_l) || btnp(:mouse_r)
        push_undo
      end

      if btn(:mouse_l)
        if $slots[$current_slot][idx] != $current_col
          $slots[$current_slot][idx] = $current_col
          sfx(:click)
        end
      elsif btn(:mouse_r)
        if $slots[$current_slot][idx] != nil
          $slots[$current_slot][idx] = nil
          sfx(:click)
        end
      end

    when :fill
      if btnp(:mouse_l)
        flood_fill(px, py, $current_col)
      elsif btnp(:mouse_r)
        flood_fill(px, py, nil) # 透過で塗りつぶし
      end

    when :picker
      if btnp(:mouse_l) || btnp(:mouse_r)
        picked = $slots[$current_slot][idx]
        $current_col = picked
        $current_tool = :pen # スポイト後にペンに自動復帰
        sfx(:select)
        notify(picked.nil? ? "PICKED: TRANS" : "PICKED: #{COLOR_NAMES[picked]}")
      end
    end
  end
end

# ------------------------------------------------------------------------------
# 描画処理 (draw)
# ------------------------------------------------------------------------------
def draw
  cls(1) # 濃紺で背景クリア

  # --- 1. ヘッダー (y: 0..18) ---
  rectfill(0, 0, 256, 18, 0)
  print_text("🎨SP-EDIT", 4, 5, 10) # 黄色タイトル
  print_text("SLOT:", 48, 5, 6)

  NUM_SLOTS.times do |i|
    bx = 76 + i * 16
    selected = (i == $current_slot)
    rectfill(bx, 3, 14, 12, selected ? 8 : 5)
    rect(bx, 3, 14, 12, selected ? 7 : 0)
    print_text(i.to_s, bx + 4, 5, selected ? 7 : 6)
  end
  line(0, 18, 255, 18, 5)

  # --- 2. メインキャンバス (x: 6, y: 22, 128x128) ---
  rectfill($canvas_x - 1, $canvas_y - 1, 130, 130, 0)
  rect($canvas_x - 1, $canvas_y - 1, 130, 130, 6)

  grid = $slots[$current_slot]
  16.times do |py|
    16.times do |px|
      cx = $canvas_x + px * $cell_size
      cy = $canvas_y + py * $cell_size
      c = grid[py * 16 + px]

      if c.nil?
        # 透過色の市松模様
        rectfill(cx, cy, 4, 4, 0)
        rectfill(cx + 4, cy, 4, 4, 5)
        rectfill(cx, cy + 4, 4, 4, 5)
        rectfill(cx + 4, cy + 4, 4, 4, 0)
      else
        rectfill(cx, cy, 8, 8, c)
      end

      # グリッド線
      if $show_grid
        line(cx, cy + 7, cx + 7, cy + 7, 0)
        line(cx + 7, cy, cx + 7, cy + 7, 0)
      end
    end
  end

  # キャンバス上のマウスホバーカーソル枠
  mx = mouse_x
  my = mouse_y
  if mx >= $canvas_x && mx < $canvas_x + 128 && my >= $canvas_y && my < $canvas_y + 128
    hx = $canvas_x + ((mx - $canvas_x) / 8) * 8
    hy = $canvas_y + ((my - $canvas_y) / 8) * 8
    rect(hx, hy, 8, 8, 7) # 白いハイライト枠
  end

  # --- 3. 右側パネル: プレビュー & パレット ---
  # プレビューヘッダー
  print_text("PREV", 140, 22, 6)

  # 背景色の決定
  preview_bg = case $bg_mode
               when 0 then 0  # 黒
               when 1 then 1  # 濃紺
               when 2 then 7  # 白
               else 5         # 暗灰 (市松代用)
               end

  # 表示するスプライトの選択 (通常は現在のスロット、再生中はフレーム番号)
  disp_slot = $anim_playing ? ($anim_frame % NUM_SLOTS) : $current_slot
  disp_grid = $slots[disp_slot]

  # 1x プレビュー (16x16, x: 140, y: 32)
  rectfill(139, 31, 18, 18, preview_bg)
  rect(139, 31, 18, 18, 5)
  16.times do |y|
    16.times do |x|
      c = disp_grid[y * 16 + x]
      pset(140 + x, 32 + y, c) unless c.nil?
    end
  end

  # 2x プレビュー (32x32, x: 164, y: 24)
  rectfill(163, 23, 34, 34, preview_bg)
  rect(163, 23, 34, 34, 5)
  16.times do |y|
    16.times do |x|
      c = disp_grid[y * 16 + x]
      unless c.nil?
        rectfill(164 + x * 2, 24 + y * 2, 2, 2, c)
      end
    end
  end

  # [BG] 背景色切り替えボタン
  rectfill(202, 24, 20, 14, 2)
  rect(202, 24, 20, 14, 6)
  print_text("BG", 206, 27, 7)

  # [▶/■] アニメ再生ボタン
  rectfill(226, 24, 22, 14, $anim_playing ? 8 : 3)
  rect(226, 24, 22, 14, 6)
  print_text($anim_playing ? "■" : "▶", 233, 27, 7)

  # パレットヘッダー (y: 62)
  print_text("PALETTE", 140, 62, 6)

  # 16色グリッド (4x4, y: 72..130)
  4.times do |row|
    4.times do |col_idx|
      c_id = row * 4 + col_idx
      bx = 140 + col_idx * 15
      by = 72 + row * 15
      rectfill(bx, by, 13, 13, c_id)
      if $current_col == c_id
        rect(bx - 1, by - 1, 15, 15, 7) # 白枠ハイライト
      else
        rect(bx, by, 13, 13, 0)
      end
    end
  end

  # TRANS (.) 透過色ボタン (x: 204..248, y: 72..96)
  rectfill(204, 72, 45, 25, 0)
  # 市松模様
  rectfill(206, 74, 10, 10, 5)
  rectfill(216, 84, 10, 10, 5)
  if $current_col.nil?
    rect(203, 71, 47, 27, 7)
  else
    rect(204, 72, 45, 25, 5)
  end
  print_text(". TRANS", 207, 98, $current_col.nil? ? 10 : 6)

  # 現在色インジケータ (x: 204..248, y: 110..130)
  if $current_col.nil?
    rectfill(204, 110, 45, 20, 0)
    print_text("TRANS", 210, 116, 6)
  else
    rectfill(204, 110, 45, 20, $current_col)
    rect(204, 110, 45, 20, 7)
    txt_col = ($current_col == 7 || $current_col == 10 || $current_col == 15) ? 0 : 7
    print_text("COL: #{$current_col}", 208, 116, txt_col)
  end

  # --- 4. ツールボタン 行1 (y: 154..168) ---
  # ツールボタン描画ヘルパー
  # [PEN]
  is_pen = ($current_tool == :pen)
  rectfill(6, 154, 31, 14, is_pen ? 8 : 2)
  rect(6, 154, 31, 14, is_pen ? 7 : 5)
  print_text("PEN", 12, 157, 7)

  # [FILL]
  is_fill = ($current_tool == :fill)
  rectfill(41, 154, 34, 14, is_fill ? 8 : 2)
  rect(41, 154, 34, 14, is_fill ? 7 : 5)
  print_text("FILL", 45, 157, 7)

  # [PICK]
  is_pick = ($current_tool == :picker)
  rectfill(79, 154, 34, 14, is_pick ? 8 : 2)
  rect(79, 154, 34, 14, is_pick ? 7 : 5)
  print_text("PICK", 83, 157, 7)

  # [UNDO]
  rectfill(117, 154, 35, 14, 2)
  rect(117, 154, 35, 14, 5)
  print_text("UNDO", 120, 157, 7)

  # [GRID]
  rectfill(156, 154, 34, 14, $show_grid ? 3 : 2)
  rect(156, 154, 34, 14, 5)
  print_text("GRID", 160, 157, 7)

  # [CLR]
  rectfill(194, 154, 32, 14, 8)
  rect(194, 154, 32, 14, 7)
  print_text("CLR", 200, 157, 7)

  # --- 5. ツールボタン 行2 (y: 172..186) ---
  # [FLIP-H]
  rectfill(6, 172, 41, 14, 2)
  rect(6, 172, 41, 14, 5)
  print_text("FLP-H", 9, 175, 7)

  # [FLIP-V]
  rectfill(51, 172, 41, 14, 2)
  rect(51, 172, 41, 14, 5)
  print_text("FLP-V", 54, 175, 7)

  # [←][→][↑][↓]
  rectfill(96, 172, 17, 14, 2)
  rect(96, 172, 17, 14, 5)
  print_text("←", 100, 175, 7)

  rectfill(116, 172, 17, 14, 2)
  rect(116, 172, 17, 14, 5)
  print_text("→", 120, 175, 7)

  rectfill(136, 172, 17, 14, 2)
  rect(136, 172, 17, 14, 5)
  print_text("↑", 140, 175, 7)

  rectfill(156, 172, 17, 14, 2)
  rect(156, 172, 17, 14, 5)
  print_text("↓", 160, 175, 7)

  # [CODE] (画面内コードビューモーダル)
  rectfill(180, 172, 46, 14, 12)
  rect(180, 172, 46, 14, 7)
  print_text("CODE", 190, 175, 0)

  # --- 6. エクスポートボタン 行3 (y: 190..206) ---
  # [EXPORT @SPRITE <id>]
  rectfill(6, 190, 138, 16, 11) # 明るい緑
  rect(6, 190, 138, 16, 7)
  print_text("★ EXPORT @SPRITE #{$current_slot}", 14, 194, 0)

  # [EXPORT ALL]
  rectfill(150, 190, 99, 16, 9) # 橙色
  rect(150, 190, 99, 16, 7)
  print_text("★ EXP ALL", 166, 194, 0)

  # --- 7. ステータスバー (y: 212..255) ---
  rectfill(0, 212, 256, 44, 0)
  line(0, 212, 255, 212, 5)

  if $notify_timer > 0
    # 通知ポップアップ
    rectfill(6, 216, 244, 16, 3)
    rect(6, 216, 244, 16, 11)
    print_text($notify_msg, 12, 220, 7)
  else
    # 通常ステータス
    col_str = $current_col.nil? ? "TRANS" : "#{COLOR_NAMES[$current_col]} (#{$current_col})"
    print_text("SLOT:#{$current_slot}  TOOL:#{$current_tool.upcase}  COL:#{col_str}", 6, 218, 6)
  end

  print_text("L:Draw/Fill  R:Erase(.)  Wheel:Color", 6, 235, 5)
  print_text("Z:Undo  C:Clear  E/Enter:Export", 6, 245, 5)

  # --- 8. コードプレビューモーダル表示 ---
  if $show_code_modal
    # 半透明調の背景覆い (黒枠で囲む)
    rectfill(12, 12, 232, 232, 0)
    rect(12, 12, 232, 232, 7)
    rect(14, 14, 228, 228, 6)

    # モーダルヘッダー
    print_text("SPRITE #{$current_slot} CODE", 20, 18, 10)

    # 閉じるボタン
    rectfill(206, 16, 32, 14, 8)
    rect(206, 16, 32, 14, 7)
    print_text("X", 218, 19, 7)

    # コード本文表示
    print_text("@SPRITE #{$current_slot}", 20, 34, 11)
    grid = $slots[$current_slot]
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
      print_text(row, 20, 46 + y * 9, 7)
    end

    # フッター案内 & ボタン
    rectfill(20, 196, 120, 16, 11)
    rect(20, 196, 120, 16, 7)
    print_text("EXPORT TO CONSOLE", 26, 200, 0)

    print_text("Paste after __END__", 20, 218, 6)
    print_text("in your game script!", 20, 228, 6)
  end

  # --- 9. カスタムカーソルの描画 ---
  if mx >= 0 && mx < 256 && my >= 0 && my < 256
    case $current_tool
    when :pen
      if btn(:mouse_l)
        print_text("✏️", mx - 2, my - 8)
      elsif btn(:mouse_r)
        print_text("🧹", mx - 2, my - 8)
      else
        print_text("👆", mx, my)
      end
    when :fill
      print_text("🪣", mx - 2, my - 8)
    when :picker
      print_text("💉", mx - 2, my - 8)
    else
      print_text("👆", mx, my)
    end
  end
end

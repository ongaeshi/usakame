# ==============================================================================
# 🐰 Usakame Sample: High-Resolution Sprite Editor (スプライトエディタ 640x360) 🐢
# ------------------------------------------------------------------------------
# 256x256 バンク対応 & 32x32 キャンバス編集ツールです。
#
# 【特徴】
# - 640x360 ワイドレイアウト (タイルマップエディタと共通解像度):
#     上部の [SPRITE] / [TILEMAP] タブでエディタ間をシームレスに切り替え可能。
# - ドット編集キャンバスと 1倍(等倍)スプライトシートの隣接配置:
#     左側のドット編集画面 (224x224) のすぐ右隣に 1倍(256x256) の全体プレビューと
#     1倍/2倍アニメーションプレビューを配置し、最終的な見た目を常時確認可能。
# - アイコン化されたコンパクトなツールバー & 小型カラーパレット:
#     14種の機能アイコンボタンと 12x12 px の小型カラーパレットをキャンバス直下に集約。
# - 常時同時表示可能なビジュアル・カラーピッカー:
#     右端の独立パネル (2D HSV + Hueバー + RGBスライダー + 32色プリセット) により、
#     1倍スプライトシートを隠さずにリアルタイムな色調整が可能。
# ==============================================================================

config(
  width: 640,
  height: 360,
  scale: 2.0,
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
CANVAS_BG_PALETTE = 99 # キャンバス背景用固定システムパレット (Maya風単色グレー #C0C0C0)
ICON_BANK = 126        # ツールアイコン高速描画用内部バンク

COLOR_NAMES = [
  "BLACK", "DARK-BLUE", "PURPLE", "DARK-GREEN",
  "BROWN", "DARK-GRAY", "LIGHT-GRAY", "WHITE",
  "RED", "ORANGE", "YELLOW", "GREEN",
  "BLUE", "INDIGO", "PINK", "PEACH"
]

# レイアウト座標定数 (640x360)
# 1) 左ペイン: 32x32 ドット編集キャンバス (1セル = 7px -> 224x224)
$canvas_x = 10
$canvas_y = 28
$cell_size = 7

# 2) 中央ペイン: 256x256 等倍(1x)スプライトシート (キャンバスのすぐ右隣)
$sheet_x = 244
$sheet_y = 28
$sheet_size = 256

# 3) 右ペイン: カラーピッカー & インスペクタ (x: 506..634)
$picker_panel_x = 506
$picker_panel_y = 28
$picker_panel_w = 128
$picker_panel_h = 306

# 編集位置 (16の倍数, 0..240)
$sel_x = 0
$sel_y = 0

# バンク番号
$current_bank = 0

# ツール一覧: :pen, :fill, :picker, :eraser, :select
$current_tool = :pen
$current_col = 8     # 初期描画色 (赤)
$show_grid = true    # グリッド線の表示
$bg_mode = 0         # プレビュー背景 (0: 黒, 1: 濃紺, 2: 白, 3: グレー)
$ui_tick = 0         # マーチングアンツ等のアニメーション用フレームカウンタ
$hover_tip = nil     # マウスホバー中のツールチップ文字列

# ------------------------------------------------------------------------------
# 11x11 ドット絵ツールアイコン定義 (15x15 ボタンの中央に描画)
# '.' = 透明, '1' = メイン色(白/黒), '2' = アクセント色(黄/水色/赤等)
# ------------------------------------------------------------------------------
TOOL_BUTTONS = [
  [:pen,    "PEN (B): Draw pixel"],
  [:fill,   "FILL (F): Flood fill area"],
  [:picker, "EYEDROPPER (Right-Click): Pick color from canvas"],
  [:eraser, "ERASER (E): Erase pixel to transparent"],
  [:select, "SELECT (M / Ctrl+A): Box select & move pixels"],
  [:grid,   "GRID (G): Toggle pixel grid lines"],
  [:onion,  "ONION SKIN (O): Show previous frame silhouette"],
  [:undo,   "UNDO (Z): Undo last action"],
  [:copy,   "COPY (Ctrl+C): Copy sprite or selected region"],
  [:paste,  "PASTE (Ctrl+V): Paste clipboard as floating selection"],
  [:flip_h, "FLIP-H (H): Flip horizontally"],
  [:flip_v, "FLIP-V (V): Flip vertically"],
  [:rotate, "ROTATE (R): Rotate 90 degrees clockwise"],
  [:clear,  "CLEAR (C / Del): Clear sprite or selected region"]
]

ICON_BITMAPS = {
  :pen => [
    "........22.",
    ".......2112",
    "......2111.",
    ".....2111..",
    "....2111...",
    "...2111....",
    "..2111.....",
    ".2211......",
    ".222.......",
    "22.........",
    "..........."
  ],
  :fill => [
    "....111....",
    "...1...1...",
    "..1111111..",
    "..1222221..",
    "..11111112.",
    "...11111.22",
    "....111..22",
    ".........2.",
    "...........",
    "...........",
    "..........."
  ],
  :picker => [
    "........22.",
    ".......2222",
    "......2122.",
    ".....1112..",
    "....111....",
    "...111.....",
    "..121......",
    ".12........",
    "2..........",
    "...........",
    "..........."
  ],
  :eraser => [
    ".....1111..",
    "....122221.",
    "...1222221.",
    "..1111121..",
    ".1111111...",
    ".111111....",
    "..1111.....",
    "...........",
    ".22222222..",
    "...........",
    "..........."
  ],
  :select => [
    "11.11.11.11",
    "1.........1",
    "...........",
    "1.........1",
    "1.........1",
    "...........",
    "1.........1",
    "1.........1",
    "...........",
    "1.........1",
    "11.11.11.11"
  ],
  :grid => [
    "..1..1..1..",
    "..1..1..1..",
    "11111111111",
    "..1..1..1..",
    "..1..1..1..",
    "11111111111",
    "..1..1..1..",
    "..1..1..1..",
    "11111111111",
    "..1..1..1..",
    "..1..1..1.."
  ],
  :onion => [
    ".222222....",
    ".2....2....",
    ".2.1111111.",
    ".2.1.....1.",
    ".2.1.....1.",
    ".221.....1.",
    "...1.....1.",
    "...1.....1.",
    "...1111111.",
    "...........",
    "..........."
  ],
  :undo => [
    "....1......",
    "...11......",
    "..1111111..",
    "...11....1.",
    "....1.....1",
    "..........1",
    "..........1",
    ".........1.",
    "....11111..",
    "...........",
    "..........."
  ],
  :copy => [
    ".111111....",
    ".1....1....",
    ".1.2222222.",
    ".1.2.....2.",
    ".1.2.....2.",
    ".1.2.....2.",
    ".112.....2.",
    "...2.....2.",
    "...2222222.",
    "...........",
    "..........."
  ],
  :paste => [
    "...22222...",
    ".112111211.",
    ".1.22222.1.",
    ".1.......1.",
    ".1.11111.1.",
    ".1.......1.",
    ".1.11111.1.",
    ".1.......1.",
    ".111111111.",
    "...........",
    "..........."
  ],
  :flip_h => [
    ".....2.....",
    "...1.2.1...",
    "..11.2.11..",
    ".111.2.111.",
    "1111.2.1111",
    "1111.2.1111",
    ".111.2.111.",
    "..11.2.11..",
    "...1.2.1...",
    ".....2.....",
    "..........."
  ],
  :flip_v => [
    "....11.....",
    "...1111....",
    "..111111...",
    ".11111111..",
    "...........",
    "22222222222",
    "...........",
    ".11111111..",
    "..111111...",
    "...1111....",
    "....11....."
  ],
  :rotate => [
    "...11111...",
    "..1.....1..",
    ".1.......1.",
    ".1.....1111",
    ".1......11.",
    ".1.......1.",
    "..1........",
    "...11111...",
    "...........",
    "...........",
    "..........."
  ],
  :clear => [
    "...11111...",
    ".111111111.",
    "...........",
    "..1111111..",
    "..1.1.1.1..",
    "..1.1.1.1..",
    "..1.1.1.1..",
    "..1.1.1.1..",
    "..1111111..",
    "...........",
    "..........."
  ]
}

$icons_baked = false

def bake_tool_icons
  return if $icons_baked
  TOOL_BUTTONS.each_with_index do |tb, idx|
    tid = tb[0]
    bmp = ICON_BITMAPS[tid]
    next unless bmp
    2.times do |state|
      is_active = (state == 1)
      main_c = (is_active && (tid == :grid || tid == :onion)) ? 0 : 7
      acc_c = is_active ? 10 : (tid == :clear ? 8 : 12)
      pixels = Array.new(11 * 11, nil)
      11.times do |iy|
        row = bmp[iy]
        next unless row
        11.times do |ix|
          ch = row[ix]
          if ch == "1"
            pixels[iy * 11 + ix] = main_c
          elsif ch == "2"
            pixels[iy * 11 + ix] = acc_c
          end
        end
      end
      update_bank_rect(ICON_BANK, idx * 16, state * 16, 11, 11, pixels)
    end
  end
  $icons_baked = true
end

# 矩形範囲選択 & フローティング移動用ステート
# $rect_sel: [rx, ry, rw, rh] (キャンバス内ローカル座標 0...$edit_w, 0...$edit_h) または nil
$rect_sel = nil
$floating_pixels = nil # フローティング中のピクセル配列 (rw * rh) または nil
$sel_drag_mode = nil   # :create (ドラッグ選択中) または :move (選択領域移動中)
$sel_start_cx = 0
$sel_start_cy = 0
$sel_move_ox = 0
$sel_move_oy = 0

def commit_floating_selection
  if $floating_pixels && $rect_sel
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
    rh.times do |fy|
      rw.times do |fx|
        tx = rx + fx
        ty = ry + fy
        if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
          col = $floating_pixels[fy * rw + fx]
          cur[ty * $edit_w + tx] = col unless col.nil?
        end
      end
    end
    update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur)
    $floating_pixels = nil
    # 確定後の選択枠をキャンバス範囲内にクランプ
    nx0 = [[rx, 0].max, $edit_w].min
    ny0 = [[ry, 0].max, $edit_h].min
    nx1 = [[rx + rw, 0].max, $edit_w].min
    ny1 = [[ry + rh, 0].max, $edit_h].min
    if nx1 > nx0 && ny1 > ny0
      $rect_sel = [nx0, ny0, nx1 - nx0, ny1 - ny0]
    else
      $rect_sel = nil
    end
  end
end

def clear_rect_selection(commit = true)
  commit_floating_selection if commit
  $rect_sel = nil
  $floating_pixels = nil
  $sel_drag_mode = nil
end

def lift_rect_selection_to_floating
  return if $rect_sel.nil? || !$floating_pixels.nil?
  push_undo
  rx = $rect_sel[0]
  ry = $rect_sel[1]
  rw = $rect_sel[2]
  rh = $rect_sel[3]
  cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
  $floating_pixels = Array.new(rw * rh, nil)
  rh.times do |fy|
    rw.times do |fx|
      tx = rx + fx
      ty = ry + fy
      if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
        idx = ty * $edit_w + tx
        $floating_pixels[fy * rw + fx] = cur[idx]
        cur[idx] = nil
      end
    end
  end
  update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur)
end

def select_all_rect
  commit_floating_selection
  $current_tool = :select
  $rect_sel = [0, 0, $edit_w, $edit_h]
  $floating_pixels = nil
  $sel_drag_mode = nil
  sfx(:select)
  notify("SELECTED ALL (#{$edit_w}x#{$edit_h})")
end

def switch_tool(new_tool)
  if $current_tool == :select && new_tool != :select
    clear_rect_selection(true)
  end
  $current_tool = new_tool
end

# 編集サイズモード (16x16, 16x32, 32x16, 32x32)
SIZE_MODES = [
  [16, 16],
  [16, 32],
  [32, 16],
  [32, 32]
]
$size_mode_idx = 0
$edit_w = 16
$edit_h = 16

def set_size_mode(idx)
  clear_rect_selection(true)
  $size_mode_idx = idx % SIZE_MODES.size
  $edit_w = SIZE_MODES[$size_mode_idx][0]
  $edit_h = SIZE_MODES[$size_mode_idx][1]
  $sel_x = [[$sel_x, 0].max, 256 - $edit_w].min
  $sel_y = [[$sel_y, 0].max, 256 - $edit_h].min
  sfx(:click)
  notify("SIZE: #{$edit_w}x#{$edit_h}")
end

def cycle_size_mode
  set_size_mode(($size_mode_idx + 1) % SIZE_MODES.size)
end

# アニメーションプレビュー
$anim_playing = false
$anim_frame = 0
$anim_timer = 0
$anim_frames = 4       # 1..8 コマ
$anim_speed = 8        # ticks per frame (8 = ~7.5fps, 6 = 10fps, 4 = 15fps)
$anim_pingpong = false # true: 往復ピンポン, false: 通常ループ

def toggle_anim
  $anim_playing = !$anim_playing
  $anim_frame = 0
  $anim_timer = 0
  sfx(:click)
end

def cycle_anim_frames(delta)
  $anim_frames = [[$anim_frames + delta, 1].max, 8].min
  $anim_frame = 0
  sfx(:cursor)
  notify("ANIM FRAMES: #{$anim_frames}")
end

def toggle_anim_pingpong
  $anim_pingpong = !$anim_pingpong
  $anim_frame = 0
  sfx(:click)
  notify("ANIM LOOP: #{$anim_pingpong ? 'PING-PONG' : 'LOOP'}")
end

def anim_current_step
  return 0 unless $anim_playing
  n = $anim_frames
  return 0 if n <= 1
  if $anim_pingpong
    period = (n - 1) * 2
    step = $anim_frame % period
    step < n ? step : (period - step)
  else
    $anim_frame % n
  end
end

# オニオンスキン (前フレーム透かし表示)
$show_onion = false

def toggle_onion
  $show_onion = !$show_onion
  sfx(:click)
  notify("ONION SKIN: #{$show_onion ? 'ON' : 'OFF'}")
end

# クリップボード (コピー & ペースト)
$clipboard = nil
$clipboard_w = 0
$clipboard_h = 0

def copy_selection
  if $rect_sel
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    if $floating_pixels
      $clipboard = $floating_pixels.dup
    else
      cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
      $clipboard = Array.new(rw * rh, nil)
      rh.times do |fy|
        rw.times do |fx|
          tx = rx + fx
          ty = ry + fy
          if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
            $clipboard[fy * rw + fx] = cur[ty * $edit_w + tx]
          end
        end
      end
    end
    $clipboard_w = rw
    $clipboard_h = rh
    sfx(:coin)
    notify("COPIED SELECTION #{rw}x#{rh}")
  else
    $clipboard = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
    $clipboard_w = $edit_w
    $clipboard_h = $edit_h
    sfx(:coin)
    notify("COPIED #{$edit_w}x#{$edit_h}")
  end
end

def cut_selection
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  copy_selection
  clear_canvas
  notify("CUT #{$clipboard_w}x#{$clipboard_h}")
end

def paste_selection
  return unless $clipboard
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  commit_floating_selection
  $current_tool = :select
  px = $rect_sel ? $rect_sel[0] : 0
  py = $rect_sel ? $rect_sel[1] : 0
  px = [[px, 0].max, [$edit_w - 1, 0].max].min
  py = [[py, 0].max, [$edit_h - 1, 0].max].min
  $rect_sel = [px, py, $clipboard_w, $clipboard_h]
  $floating_pixels = $clipboard.dup
  $sel_drag_mode = nil
  sfx(:powerup)
  notify("PASTED #{$clipboard_w}x#{$clipboard_h} (DRAG/ARROWS TO MOVE)")
end

# コードプレビューモーダル
$show_code_modal = false

# 通知メッセージ
$notify_msg = ""
$notify_timer = 0

# アンドゥ用履歴スタック (最大30手)
$undo_stack = []

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
$open_picker_on_start = true # 640x360では右端の独立ペインにカラーピッカーを常時表示可能
$open_select_on_start = false
if ARGV && ARGV.size > 0
  pos_args = []
  ARGV.each do |arg|
    if arg == "--picker" || arg == "-k"
      $open_picker_on_start = true
    elsif arg == "--no-picker"
      $open_picker_on_start = false
    elsif arg == "--select" || arg == "-m"
      $open_select_on_start = true
    elsif arg
      pos_args << arg
    end
  end
  if pos_args.size > 0 && pos_args[0]
    if is_numeric_arg?(pos_args[0])
      $current_bank = pos_args[0].to_i
    else
      $target_path = pos_args[0]
    end
  end
  if pos_args.size > 1 && pos_args[1]
    $current_bank = pos_args[1].to_i
  end
end

$save_path = $target_path
tlen = $target_path.size
if tlen >= 3
  suf = $target_path[tlen - 3, 3]
  candidate_spr = nil
  if suf == ".rb"
    candidate_spr = $target_path[0, tlen - 3] + ".spr"
  elsif suf == "map"
    candidate_spr = $target_path[0, tlen - 4] + ".spr"
  end
  # 既存の .spr ファイルが存在する場合のみ .spr を優先し、なければ .rb 直接保存
  if candidate_spr && read_file(candidate_spr)
    $save_path = candidate_spr
  end
end
$last_target_mtime = file_mtime($save_path)

def notify(msg)
  $notify_msg = msg
  $notify_timer = 120 # 約2秒表示
end

def push_undo
  $undo_stack << [$sel_x, $sel_y, $edit_w, $edit_h, get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)]
  $undo_stack.shift if $undo_stack.size > 30
end

def perform_undo
  return if $is_read_only
  if $floating_pixels
    clear_rect_selection(false)
  end
  return if $undo_stack.empty?
  sel_x, sel_y, uw, uh, saved_grid = $undo_stack.pop
  set_selection(sel_x, sel_y)
  update_bank_rect($current_bank, sel_x, sel_y, uw, uh, saved_grid)
  sfx(:click)
  notify("UNDO")
end

# 起動時の読み込み
load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
$is_read_only = is_resource_read_only(load_source) || is_resource_read_only($save_path) || is_resource_read_only($target_path)

# パレット管理 & カラーピッカー
$current_pal = 0
$available_palettes = [0]
$sprite_palettes = {}

HEX_CHARS = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]

# 32色プリセット (上段: PICO-8標準16色, 下段: PICO-8拡張/裏パレット16色)
PRESET_SWATCHES = [
  # Row 0: Standard 16
  [0, 0, 0],       [29, 43, 83],    [126, 37, 83],   [0, 135, 81],
  [171, 82, 54],   [95, 87, 79],    [194, 195, 199], [255, 241, 232],
  [255, 0, 77],    [255, 163, 0],   [255, 236, 39],  [0, 228, 54],
  [41, 173, 255],  [131, 118, 156], [255, 119, 168], [255, 204, 170],
  # Row 1: Extended 16 (Secret PICO-8 / Retro Harmony)
  [41, 24, 20],    [17, 29, 53],    [66, 33, 54],    [18, 83, 89],
  [116, 47, 41],   [73, 51, 59],    [162, 136, 121], [243, 239, 125],
  [190, 18, 80],   [255, 108, 36],  [168, 231, 46],  [0, 181, 67],
  [6, 90, 181],    [117, 70, 101],  [255, 110, 89],  [255, 157, 129]
]

$show_color_picker = true
$picker_h = 0
$picker_s = 100
$picker_v = 100
$picker_r = 255
$picker_g = 0
$picker_b = 77
$picker_drag = nil # :sv, :hue, :r, :g, :b
$col_clipboard = nil

def byte_to_hex(n)
  v = [[n.to_i, 0].max, 255].min
  HEX_CHARS[(v / 16) % 16] + HEX_CHARS[v % 16]
end

def rgb_to_hex_str(r, g, b)
  "#" + byte_to_hex(r) + byte_to_hex(g) + byte_to_hex(b)
end

def sync_picker_from_current_color
  col_idx = $current_col || 0
  info = get_palette_color($current_pal, col_idx)
  if info
    $picker_r = info[0]
    $picker_g = info[1]
    $picker_b = info[2]
    hsv = rgb_to_hsv($picker_r, $picker_g, $picker_b)
    if hsv
      $picker_h = hsv[0] if hsv[1] > 0
      $picker_s = hsv[1]
      $picker_v = hsv[2]
    end
  end
end

def duplicate_current_palette
  new_id = 1
  while $available_palettes.include?(new_id) || new_id == 99
    new_id += 1
  end
  src_id = $current_pal
  copy_palette(src_id, new_id)
  $available_palettes << new_id
  $available_palettes.sort!
  $current_pal = new_id
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  $sprite_palettes[cur_spr_id] = $current_pal
  sync_picker_from_current_color
  sfx(:powerup)
  notify("COPIED P#{src_id} -> P#{new_id} (ASSIGNED TO ##{cur_spr_id})")
end

def ensure_editable_palette
  if $current_pal <= 0
    new_id = 1
    while $available_palettes.include?(new_id) || new_id == 99
      new_id += 1
    end
    copy_palette(0, new_id)
    $available_palettes << new_id
    $available_palettes.sort!
    $current_pal = new_id
    cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
    $sprite_palettes[cur_spr_id] = $current_pal
    notify("AUTO-CREATED P#{new_id} FROM P0")
  end
end

def apply_picker_rgb(r, g, b, update_hsv = false)
  return if $is_read_only
  $current_col = 8 if $current_col.nil?
  ensure_editable_palette
  $picker_r = [[r.to_i, 0].max, 255].min
  $picker_g = [[g.to_i, 0].max, 255].min
  $picker_b = [[b.to_i, 0].max, 255].min
  if update_hsv
    hsv = rgb_to_hsv($picker_r, $picker_g, $picker_b)
    if hsv
      $picker_h = hsv[0] if hsv[1] > 0
      $picker_s = hsv[1]
      $picker_v = hsv[2]
    end
  end
  set_palette_color($current_pal, $current_col, $picker_r, $picker_g, $picker_b)
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  $sprite_palettes[cur_spr_id] = $current_pal
end

def reset_current_palette_color
  return if $current_pal <= 0
  col_idx = $current_col || 0
  base = get_palette_color(0, col_idx)
  if base
    apply_picker_rgb(base[0], base[1], base[2], true)
    sfx(:click)
    notify("RESET COL #{HEX_CHARS[col_idx]} TO PICO-8 BASE")
  end
end

def reset_all_palette_colors
  return if $current_pal <= 0
  copy_palette(0, $current_pal)
  sync_picker_from_current_color
  sfx(:boom)
  notify("RESET ALL P#{$current_pal} COLORS TO P0")
end

def sync_sprite_default_palette
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  def_pal = $sprite_palettes ? $sprite_palettes[cur_spr_id] : nil
  if def_pal
    if $current_pal != def_pal
      $current_pal = def_pal
      sync_picker_from_current_color
      notify("PALETTE: P#{$current_pal} (AUTO)")
    end
  end
end

def reload_palettes(source)
  pals = load_resource_palettes(source)
  if pals && !pals.empty?
    filtered = []
    pals.each do |pid|
      filtered << pid if pid != 99
    end
    filtered << 0 unless filtered.include?(0)
    $available_palettes = filtered
    $current_pal = filtered[0] unless $available_palettes.include?($current_pal)
  end
  $sprite_palettes = load_resource_sprite_palettes(source) || {}
  sync_sprite_default_palette
  sync_picker_from_current_color
end

def set_selection(gx, gy)
  gx = [[gx, 0].max, 256 - $edit_w].min
  gy = [[gy, 0].max, 256 - $edit_h].min
  if $sel_x != gx || $sel_y != gy
    clear_rect_selection(true)
    $sel_x = gx
    $sel_y = gy
    sfx(:cursor)
    sync_sprite_default_palette
  end
end

def cycle_palette(dir)
  if $available_palettes.size > 1
    idx = $available_palettes.index($current_pal) || 0
    new_idx = (idx + dir) % $available_palettes.size
    $current_pal = $available_palettes[new_idx]
  else
    $current_pal = ($current_pal + dir) % 8
    $current_pal = 0 if $current_pal < 0
  end
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  $sprite_palettes[cur_spr_id] = $current_pal
  sync_picker_from_current_color
  sfx(:click)
  notify("PALETTE: P#{$current_pal}")
end

reload_palettes(load_source)
$show_color_picker = $open_picker_on_start
sync_picker_from_current_color
if $open_select_on_start
  $current_tool = :select
  $rect_sel = [2, 1, 12, 10]
end

if $is_read_only
  if load_bank($current_bank, load_source)
    notify("LOADED BANK #{$current_bank} (READ-ONLY: PNG REFERENCE)")
  else
    notify("FAILED TO LOAD BANK #{$current_bank} FROM #{load_source}")
  end
else
  loaded_bank = load_resource_bank(load_source, $current_bank)
  if loaded_bank && loaded_bank.size == BANK_SIZE * BANK_SIZE
    update_bank($current_bank, loaded_bank)
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
          set_bank_pixel($current_bank, x, y, ch.to_i(16))
        end
      end
    end
    notify("TARGET: #{$target_path} (NEW BANK #{$current_bank})")
  end
end

# ------------------------------------------------------------------------------
# バンク切り替え処理
# ------------------------------------------------------------------------------
def switch_bank(new_bank)
  return if new_bank < 0
  clear_rect_selection(true)
  $current_bank = new_bank
  $undo_stack.clear

  load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
  $is_read_only = is_resource_read_only(load_source) || is_resource_read_only($save_path) || is_resource_read_only($target_path)
  if $is_read_only
    if load_bank($current_bank, load_source)
      notify("SWITCHED TO BANK #{$current_bank} (READ-ONLY)")
    else
      notify("SWITCHED TO BANK #{$current_bank} (READ-ONLY: EMPTY)")
    end
  else
    loaded = load_resource_bank(load_source, $current_bank)
    if loaded && loaded.size == BANK_SIZE * BANK_SIZE
      update_bank($current_bank, loaded)
    else
      update_bank($current_bank, Array.new(BANK_SIZE * BANK_SIZE, nil))
    end
    notify("SWITCHED TO BANK #{$current_bank}")
  end

  reload_palettes(load_source)
end

# ------------------------------------------------------------------------------
# 保存 & エクスポート処理
# ------------------------------------------------------------------------------
def save_to_target
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot overwrite PNG-backed resource!")
    return
  end

  commit_floating_selection
  if save_resource_bank($save_path, $current_bank, nil, $sprite_palettes)
    $last_target_mtime = file_mtime($save_path)
    sfx(:powerup)
    notify("SAVED BANK #{$current_bank} & PALETTES TO #{$save_path}!")
  else
    sfx(:boom)
    notify("ERROR: FAILED TO SAVE #{$save_path}")
  end
end

def export_all
  commit_floating_selection
  text = export_bank_sprites_text($save_path, $current_bank, $sprite_palettes)
  puts "\n# =================================================="
  puts "# 🐰 USAKAME BANK DATA (Bank #{$current_bank})"
  puts "# =================================================="
  puts text
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED @PALETTE & @SPRITE DATA TO CONSOLE!")
end

# 塗りつぶし (選択領域 $edit_w x $edit_h 内での高速 DFS & 部分更新)
def flood_fill(start_cx, start_cy, new_col)
  return if start_cx >= $edit_w || start_cy >= $edit_h
  start_gx = $sel_x + start_cx
  start_gy = $sel_y + start_cy
  return if start_gx >= BANK_SIZE || start_gy >= BANK_SIZE

  cur_pixels = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
  start_idx = start_cy * $edit_w + start_cx
  target_col = cur_pixels[start_idx]
  return if target_col == new_col

  push_undo
  stack = [[start_cx, start_cy]]
  visited = Array.new($edit_w * $edit_h, false)

  while !stack.empty?
    pt = stack.pop
    cx = pt[0]
    cy = pt[1]
    key = cy * $edit_w + cx
    next if visited[key]
    visited[key] = true

    if cur_pixels[key] == target_col
      cur_pixels[key] = new_col
      stack << [cx + 1, cy] if cx + 1 < $edit_w
      stack << [cx - 1, cy] if cx - 1 >= 0
      stack << [cx, cy + 1] if cy + 1 < $edit_h
      stack << [cx, cy - 1] if cy - 1 >= 0
    end
  end
  update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur_pixels)
  sfx(:click)
end

# 反転 (矩形選択範囲 または $edit_w x $edit_h 全体)
def flip_canvas(horizontal)
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  if $rect_sel
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    if $floating_pixels
      new_fp = Array.new(rw * rh, nil)
      rh.times do |fy|
        rw.times do |fx|
          nx = horizontal ? (rw - 1 - fx) : fx
          ny = horizontal ? fy : (rh - 1 - fy)
          new_fp[ny * rw + nx] = $floating_pixels[fy * rw + fx]
        end
      end
      $floating_pixels = new_fp
    else
      push_undo
      cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
      sub = Array.new(rw * rh, nil)
      rh.times do |fy|
        rw.times do |fx|
          tx = rx + fx
          ty = ry + fy
          if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
            sub[fy * rw + fx] = cur[ty * $edit_w + tx]
          end
        end
      end
      rh.times do |fy|
        rw.times do |fx|
          nx = horizontal ? (rw - 1 - fx) : fx
          ny = horizontal ? fy : (rh - 1 - fy)
          tx = rx + nx
          ty = ry + ny
          if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
            cur[ty * $edit_w + tx] = sub[fy * rw + fx]
          end
        end
      end
      update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur)
    end
    sfx(:select)
    notify(horizontal ? "FLIP-H (SEL #{rw}x#{rh})" : "FLIP-V (SEL #{rw}x#{rh})")
    return
  end

  push_undo
  cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
  new_grid = Array.new($edit_w * $edit_h, nil)
  $edit_h.times do |cy|
    $edit_w.times do |cx|
      src_idx = cy * $edit_w + cx
      nx = horizontal ? ($edit_w - 1 - cx) : cx
      ny = horizontal ? cy : ($edit_h - 1 - cy)
      new_grid[ny * $edit_w + nx] = cur[src_idx]
    end
  end
  update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, new_grid)
  sfx(:select)
  notify(horizontal ? "FLIP-H" : "FLIP-V")
end

# 90度回転 (矩形選択時は非正方形もフローティング回転対応 / 未選択時は正方形 $edit_w == $edit_h のみ)
def rotate_canvas
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  if $rect_sel
    lift_rect_selection_to_floating if $floating_pixels.nil?
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    new_w = rh
    new_h = rw
    new_fp = Array.new(new_w * new_h, nil)
    rh.times do |fy|
      rw.times do |fx|
        new_fp[fx * new_w + (new_w - 1 - fy)] = $floating_pixels[fy * rw + fx]
      end
    end
    $floating_pixels = new_fp
    $rect_sel = [rx, ry, new_w, new_h]
    sfx(:select)
    notify("ROTATE 90° (SEL #{new_w}x#{new_h})")
    return
  end

  if $edit_w != $edit_h
    sfx(:boom)
    notify("ROTATE: Square only (#{$edit_w}x#{$edit_h}) or use [SEL]")
    return
  end
  push_undo
  n = $edit_w
  cur = get_bank_rect($current_bank, $sel_x, $sel_y, n, n)
  new_grid = Array.new(n * n, nil)
  n.times do |cy|
    n.times do |cx|
      new_grid[cx * n + (n - 1 - cy)] = cur[cy * n + cx]
    end
  end
  update_bank_rect($current_bank, $sel_x, $sel_y, n, n, new_grid)
  sfx(:select)
  notify("ROTATE 90°")
end

# シフト移動 (矩形選択時は選択領域を1px移動 / 未選択時は $edit_w x $edit_h ループシフト)
def shift_canvas(dx, dy)
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  if $rect_sel
    lift_rect_selection_to_floating if $floating_pixels.nil?
    $rect_sel[0] += dx
    $rect_sel[1] += dy
    sfx(:cursor)
    return
  end

  push_undo
  cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
  new_grid = Array.new($edit_w * $edit_h, nil)
  $edit_h.times do |cy|
    $edit_w.times do |cx|
      src_idx = cy * $edit_w + cx
      nx = (cx + dx) % $edit_w
      ny = (cy + dy) % $edit_h
      new_grid[ny * $edit_w + nx] = cur[src_idx]
    end
  end
  update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, new_grid)
  sfx(:cursor)
end

def clear_canvas
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  if $rect_sel
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    if $floating_pixels
      $floating_pixels = nil
      $rect_sel = nil
    else
      push_undo
      cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
      rh.times do |fy|
        rw.times do |fx|
          tx = rx + fx
          ty = ry + fy
          if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
            cur[ty * $edit_w + tx] = nil
          end
        end
      end
      update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur)
      $rect_sel = nil
    end
    sfx(:boom)
    notify("CLEARED SELECTION #{rw}x#{rh}")
    return
  end

  push_undo
  new_grid = Array.new($edit_w * $edit_h, nil)
  update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, new_grid)
  sfx(:boom)
  notify("CLEARED #{$edit_w}x#{$edit_h}")
end

# ------------------------------------------------------------------------------
# 更新処理 (update)
# ------------------------------------------------------------------------------
def update
  $ui_tick += 1
  $hover_tip = nil

  # --- 外部更新（ホットリロード）の検知 ---
  if $save_path
    cur_mtime = file_mtime($save_path)
    if cur_mtime > 0 && cur_mtime != $last_target_mtime
      $last_target_mtime = cur_mtime
      loaded = load_resource_bank($save_path, $current_bank)
      if loaded && loaded.size == BANK_SIZE * BANK_SIZE
        clear_rect_selection(false)
        update_bank($current_bank, loaded)
        reload_palettes($save_path)
        notify("RELOADED BANK #{$current_bank} (EXTERNAL MODIFIED)")
      end
    end
  end

  mx = mouse_x
  my = mouse_y

  $notify_timer = [$notify_timer - 1, 0].max

  if $anim_playing
    $anim_timer += 1
    if $anim_timer >= $anim_speed
      $anim_timer = 0
      $anim_frame += 1
    end
  end

  # --- ホバーツールチップ判定 ---
  if my >= 256 && my <= 272 && mx >= 10 && mx < 10 + 14 * 16
    t_idx = (mx - 10) / 16
    if t_idx >= 0 && t_idx < TOOL_BUTTONS.size
      $hover_tip = TOOL_BUTTONS[t_idx][1]
    end
  elsif my >= 3 && my <= 19
    if mx >= 8 && mx <= 66
      $hover_tip = "SPRITE EDITOR (Current mode)"
    elsif mx >= 70 && mx <= 134
      $hover_tip = "SWITCH TO TILEMAP EDITOR"
    end
  end

  # --- キーボードショートカット ---
  perform_undo if btnp(:z)
  save_to_target if btnp(:s)
  export_all if btnp(:x) && !btn(:ctrl)
  clear_canvas if (btnp(:c) && !btn(:ctrl)) || btnp(:delete) || btnp(:backspace)
  cycle_size_mode if btnp(:tab)
  toggle_anim if btnp(:space)
  flip_canvas(true) if btnp(:h)
  flip_canvas(false) if btnp(:v)
  rotate_canvas if btnp(:r)
  toggle_onion if btnp(:o)
  if btnp(:g)
    $show_grid = !$show_grid
    sfx(:click)
  end
  cycle_anim_frames(-1) if btnp(:"[")
  cycle_anim_frames(1) if btnp(:"]")

  # Escape / Enter で範囲選択確定＆解除
  if btnp(:escape) || btnp(:enter)
    if $rect_sel
      clear_rect_selection(true)
      sfx(:click)
      notify("SELECTION CLEARED")
    end
  end

  # Ctrl+A (全選択) / Ctrl+C (コピー) / Ctrl+X (切り取り) / Ctrl+V (貼り付け)
  if btn(:ctrl)
    if btnp(:a)
      select_all_rect
    elsif btnp(:c)
      copy_selection
    elsif btnp(:x)
      cut_selection
    elsif btnp(:v)
      paste_selection
    end
  end

  # パレット切り替え (P / Shift+P) & カラーピッカー表示切替 (K)
  if btnp(:p)
    cycle_palette(btn(:shift) ? -1 : 1)
  end
  if btnp(:k)
    $show_color_picker = !$show_color_picker
    sync_picker_from_current_color if $show_color_picker
    sfx(:click)
    notify($show_color_picker ? "COLOR PICKER: OPEN" : "COLOR PICKER: CLOSED")
  end

  # ツールショートカット
  switch_tool(:pen) if btnp(:b)
  switch_tool(:fill) if btnp(:f)
  switch_tool(:eraser) if btnp(:e)
  if btnp(:m)
    switch_tool(:select)
    sfx(:click)
    notify("TOOL: SELECT (Drag to select / Drag inside to move)")
  end

  # 矢印キーで移動 / シフト
  if btn(:ctrl)
    nx = $sel_x
    ny = $sel_y
    nx = [nx - 16, 0].max if btnp(0)
    nx = [nx + 16, 256 - $edit_w].min if btnp(1)
    ny = [ny - 16, 0].max if btnp(2)
    ny = [ny + 16, 256 - $edit_h].min if btnp(3)
    set_selection(nx, ny)
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
    sync_picker_from_current_color
    sfx(:cursor)
  elsif wheel < -0.2
    $current_col = ($current_col.nil? ? 0 : ($current_col + 1) % 16)
    sync_picker_from_current_color
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

  # --- 1倍スプライトシート (256x256, x: 244..500, y: 28..284) での選択 ---
  in_sheet = (mx >= $sheet_x && mx < $sheet_x + $sheet_size &&
              my >= $sheet_y && my < $sheet_y + $sheet_size)
  if in_sheet && $picker_drag.nil? && $sel_drag_mode.nil? && (btn(:mouse_l) || btn(:mouse_r))
    gx = ((mx - $sheet_x) / 16) * 16
    gy = ((my - $sheet_y) / 16) * 16
    gx = [[gx, 0].max, 256 - $edit_w].min
    gy = [[gy, 0].max, 256 - $edit_h].min
    set_selection(gx, gy)
  end

  # --- 右ペイン: カラーピッカーの操作 (x: 506..634, y: 28..334) ---
  if !btn(:mouse_l)
    $picker_drag = nil
  end

  if $show_color_picker
    if btnp(:mouse_l)
      # [X] 閉じるボタン (x: 618..631, y: 30..42)
      if mx >= 618 && mx <= 631 && my >= 30 && my <= 42
        $show_color_picker = false
        $picker_drag = nil
        sfx(:click)
      # SV 2Dボックス (x: 510..589, y: 48..127, 80x80)
      elsif mx >= 510 && mx < 590 && my >= 48 && my < 128
        $picker_drag = :sv
      # Hue バー (x: 593..604, y: 48..127, 11x80)
      elsif mx >= 593 && mx <= 604 && my >= 48 && my < 128
        $picker_drag = :hue
      # R スライダー (x: 520..602, y: 136..148)
      elsif mx >= 520 && mx <= 602 && my >= 136 && my <= 148
        $picker_drag = :r
      # G スライダー (x: 520..602, y: 152..164)
      elsif mx >= 520 && mx <= 602 && my >= 152 && my <= 164
        $picker_drag = :g
      # B スライダー (x: 520..602, y: 168..180)
      elsif mx >= 520 && mx <= 602 && my >= 168 && my <= 180
        $picker_drag = :b
      # 右側ユーティリティボタン群 (x: 608..631)
      elsif mx >= 608 && mx <= 631
        if my >= 48 && my <= 65 # [RST]
          reset_current_palette_color
        elsif my >= 68 && my <= 85 # [CPY]
          $col_clipboard = [$picker_r, $picker_g, $picker_b]
          sfx(:coin)
          notify("COPIED COLOR #{rgb_to_hex_str($picker_r, $picker_g, $picker_b)}")
        elsif my >= 88 && my <= 105 # [PST]
          if $col_clipboard
            apply_picker_rgb($col_clipboard[0], $col_clipboard[1], $col_clipboard[2], true)
            sfx(:powerup)
            notify("PASTED COLOR #{rgb_to_hex_str($picker_r, $picker_g, $picker_b)}")
          end
        elsif my >= 108 && my <= 125 # [ALL]
          reset_all_palette_colors
        end
      # 32色プリセットスウォッチ (x: 510..621, y: 196..221, 16列x2段, 1セル7x13)
      elsif mx >= 510 && mx < 622 && my >= 196 && my < 222
        sw_col = (mx - 510) / 7
        sw_row = (my - 196) / 13
        sw_idx = sw_row * 16 + sw_col
        if sw_idx >= 0 && sw_idx < PRESET_SWATCHES.size
          rgb = PRESET_SWATCHES[sw_idx]
          apply_picker_rgb(rgb[0], rgb[1], rgb[2], true)
          sfx(:select)
          notify("PRESET: #{rgb_to_hex_str(rgb[0], rgb[1], rgb[2])}")
        end
      end
    end

    if btn(:mouse_l) && $picker_drag
      if $picker_drag == :sv
        $picker_s = (((mx - 510) * 100) / 79).clamp(0, 100)
        $picker_v = (100 - (((my - 48) * 100) / 79)).clamp(0, 100)
        rgb = hsv_to_rgb($picker_h, $picker_s, $picker_v)
        apply_picker_rgb(rgb[0], rgb[1], rgb[2], false) if rgb
      elsif $picker_drag == :hue
        $picker_h = (((my - 48) * 359) / 79).clamp(0, 359)
        rgb = hsv_to_rgb($picker_h, $picker_s, $picker_v)
        apply_picker_rgb(rgb[0], rgb[1], rgb[2], false) if rgb
      elsif $picker_drag == :r
        nr = (((mx - 520) * 255) / 81).clamp(0, 255)
        apply_picker_rgb(nr, $picker_g, $picker_b, true)
      elsif $picker_drag == :g
        ng = (((mx - 520) * 255) / 81).clamp(0, 255)
        apply_picker_rgb($picker_r, ng, $picker_b, true)
      elsif $picker_drag == :b
        nb = (((mx - 520) * 255) / 81).clamp(0, 255)
        apply_picker_rgb($picker_r, $picker_g, nb, true)
      end
    end
  end

  # --- 小型8x2カラーパレットの右クリックでカラーピッカーを開く ---
  if btnp(:mouse_r) && mx >= 10 && mx < 114 && my >= 278 && my < 304
    col_idx = (mx - 10) / 13
    row_idx = (my - 278) / 13
    if col_idx >= 0 && col_idx < 8 && row_idx >= 0 && row_idx < 2
      $current_col = row_idx * 8 + col_idx
      switch_tool(:pen) if $current_tool == :eraser
      $show_color_picker = true
      sync_picker_from_current_color
      sfx(:select)
      notify("EDITING P#{$current_pal} COL #{HEX_CHARS[$current_col]}")
    end
  end

  # --- ボタンクリック判定 (mouse_l) ---
  if btnp(:mouse_l)
    # 1. 上部メニューバー (y: 3..19)
    if my >= 3 && my <= 19
      if mx >= 70 && mx <= 134 # [TILEMAP] タブ
        commit_floating_selection
        spawn_editor("map", $target_path) if respond_to?(:spawn_editor)
        sfx(:click)
      elsif mx >= 244 && mx <= 290 # [SIZE: 16x16]
        cycle_size_mode
      elsif mx >= 298 && mx <= 314 # [<] バンク減
        switch_bank([$current_bank - 1, 0].max)
        sfx(:click)
      elsif mx >= 346 && mx <= 362 # [>] バンク増
        switch_bank($current_bank + 1)
        sfx(:click)
      elsif mx >= 492 && mx <= 538 # [SAVE]
        save_to_target
      elsif mx >= 544 && mx <= 582 # [EXP]
        export_all
      elsif mx >= 588 && mx <= 632 # [CODE]
        commit_floating_selection
        $show_code_modal = true
        sfx(:click)
      end
    end

    # 2. アイコンツールバー (14個, x: 10..233, y: 256..272)
    if my >= 256 && my <= 272 && mx >= 10 && mx < 10 + 14 * 16
      t_idx = (mx - 10) / 16
      rel_x = (mx - 10) % 16
      if rel_x < 15 && t_idx >= 0 && t_idx < TOOL_BUTTONS.size
        act = TOOL_BUTTONS[t_idx][0]
        case act
        when :pen, :fill, :picker, :eraser, :select
          switch_tool(act)
          sfx(:click)
        when :grid
          $show_grid = !$show_grid
          sfx(:click)
        when :onion
          toggle_onion
        when :undo
          perform_undo
        when :copy
          copy_selection
        when :paste
          paste_selection
        when :flip_h
          flip_canvas(true)
        when :flip_v
          flip_canvas(false)
        when :rotate
          rotate_canvas
        when :clear
          clear_canvas
        end
      end
    end

    # 3. 小型カラーパレット (8x2, x: 10..114, y: 278..304)
    if mx >= 10 && mx < 114 && my >= 278 && my < 304
      col_idx = (mx - 10) / 13
      row_idx = (my - 278) / 13
      if col_idx >= 0 && col_idx < 8 && row_idx >= 0 && row_idx < 2
        $current_col = row_idx * 8 + col_idx
        switch_tool(:pen) if $current_tool == :eraser || $current_tool == :select
        sync_picker_from_current_color
        sfx(:select)
      end
    end

    # [TRANS (.)] ボタン (x: 10..72, y: 308..322)
    if mx >= 10 && mx <= 72 && my >= 308 && my <= 322
      $current_col = nil
      sfx(:select)
    end

    # 4. パレット切替 & [+DUP] & [PICK] (x: 118..234, y: 278..292)
    if my >= 278 && my <= 292
      if mx >= 118 && mx <= 131 # [<]
        cycle_palette(-1)
      elsif mx >= 159 && mx <= 172 # [>]
        cycle_palette(1)
      elsif mx >= 175 && mx <= 204 # [+DUP]
        duplicate_current_palette
      elsif mx >= 207 && mx <= 234 # [PICK]
        $show_color_picker = !$show_color_picker
        sync_picker_from_current_color if $show_color_picker
        sfx(:click)
      end
    end

    # 5. 1px シフト移動ボタン [←][↑][↓][→] (x: 118..234, y: 296..310)
    if my >= 296 && my <= 310
      if mx >= 118 && mx <= 144 # [←]
        shift_canvas(-1, 0)
      elsif mx >= 148 && mx <= 174 # [↑]
        shift_canvas(0, -1)
      elsif mx >= 178 && mx <= 204 # [↓]
        shift_canvas(0, 1)
      elsif mx >= 208 && mx <= 234 # [→]
        shift_canvas(1, 0)
      end
    end

    # 6. アニメーションプレビュー操作バー (x: 322..500, y: 290..304)
    if my >= 290 && my <= 304
      if mx >= 322 && mx <= 346 # [▶/■]
        toggle_anim
      elsif mx >= 350 && mx <= 378 # [#F]
        cycle_anim_frames(1)
      elsif mx >= 382 && mx <= 422 # [LOOP/PING]
        toggle_anim_pingpong
      elsif mx >= 426 && mx <= 464 # [SPD]
        $anim_speed = case $anim_speed; when 8 then 6; when 6 then 4; when 4 then 12; else 8; end
        sfx(:cursor)
        notify("ANIM SPEED: #{$anim_speed} ticks")
      elsif mx >= 468 && mx <= 498 # [BG]
        $bg_mode = ($bg_mode + 1) % 4
        sfx(:click)
      end
    end
  end

  # --- キャンバス内での描画 & 範囲選択 & スポイト操作 ---
  if !btn(:mouse_l)
    $sel_drag_mode = nil
  end

  in_canvas = (mx >= $canvas_x && mx < $canvas_x + CANVAS_GRID * $cell_size &&
               my >= $canvas_y && my < $canvas_y + CANVAS_GRID * $cell_size)

  if $current_tool == :select && $picker_drag.nil?
    if $sel_drag_mode && btn(:mouse_l)
      if $sel_drag_mode == :create
        ccx = [[(mx - $canvas_x) / $cell_size, 0].max, $edit_w - 1].min
        ccy = [[(my - $canvas_y) / $cell_size, 0].max, $edit_h - 1].min
        x0 = [$sel_start_cx, ccx].min
        y0 = [$sel_start_cy, ccy].min
        x1 = [$sel_start_cx, ccx].max
        y1 = [$sel_start_cy, ccy].max
        $rect_sel = [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
      elsif $sel_drag_mode == :move && $rect_sel
        mcx = (mx - $canvas_x) / $cell_size
        mcy = (my - $canvas_y) / $cell_size
        $rect_sel[0] = mcx - $sel_move_ox
        $rect_sel[1] = mcy - $sel_move_oy
      end
    elsif in_canvas
      if $is_read_only
        if btnp(:mouse_l) || btnp(:mouse_r)
          sfx(:boom)
          notify("READ ONLY: Direct PNG reference (view-only). Edit PNG in external tool.")
        end
      else
        cx = (mx - $canvas_x) / $cell_size
        cy = (my - $canvas_y) / $cell_size
        if btnp(:mouse_r)
          clear_rect_selection(true)
          sfx(:click)
          notify("SELECTION CLEARED")
        elsif btnp(:mouse_l) && cx >= 0 && cx < $edit_w && cy >= 0 && cy < $edit_h
          if $rect_sel && cx >= $rect_sel[0] && cx < $rect_sel[0] + $rect_sel[2] && cy >= $rect_sel[1] && cy < $rect_sel[1] + $rect_sel[3]
            lift_rect_selection_to_floating
            $sel_drag_mode = :move
            $sel_move_ox = cx - $rect_sel[0]
            $sel_move_oy = cy - $rect_sel[1]
            sfx(:cursor)
          else
            commit_floating_selection
            $sel_drag_mode = :create
            $sel_start_cx = cx
            $sel_start_cy = cy
            $rect_sel = [cx, cy, 1, 1]
            sfx(:select)
          end
        end
      end
    end
  elsif in_canvas && $picker_drag.nil?
    if $is_read_only
      if btnp(:mouse_l) || btnp(:mouse_r)
        sfx(:boom)
        notify("READ ONLY: Direct PNG reference (view-only). Edit PNG in external tool.")
      end
    else
      cx = (mx - $canvas_x) / $cell_size
      cy = (my - $canvas_y) / $cell_size

      if cx >= 0 && cx < $edit_w && cy >= 0 && cy < $edit_h
        gx = $sel_x + cx
        gy = $sel_y + cy

        # 【右クリック = スポイト (カラーピック)】
        if btn(:mouse_r)
          picked = get_bank_pixel($current_bank, gx, gy)
          if picked != $current_col
            $current_col = picked
            sync_picker_from_current_color
            sfx(:pickup)
            col_name = picked ? COLOR_NAMES[picked] : "TRANS"
            notify("PICKED: #{col_name}")
          end
        elsif btn(:mouse_l)
          case $current_tool
          when :pen
            push_undo if btnp(:mouse_l)
            set_bank_pixel($current_bank, gx, gy, $current_col)
          when :eraser
            push_undo if btnp(:mouse_l)
            set_bank_pixel($current_bank, gx, gy, nil)
          when :fill
            if btnp(:mouse_l)
              flood_fill(cx, cy, $current_col)
            end
          when :picker
            if btnp(:mouse_l)
              picked = get_bank_pixel($current_bank, gx, gy)
              $current_col = picked
              switch_tool(:pen)
              sync_picker_from_current_color
              sfx(:pickup)
              notify("PICKED: #{picked ? COLOR_NAMES[picked] : 'TRANS'}")
            end
          end
        end
      end
    end
  end
end

# マーチングアンツ（アニメーション破線矩形枠）の描画ヘルパー
def draw_marching_rect(rx, ry, rw, rh, tick)
  return if rw <= 0 || rh <= 0
  phase = (tick / 6) % 4
  x1 = rx + rw - 1
  y1 = ry + rh - 1
  rw.times do |i|
    c_top = ((i + phase) % 4 < 2) ? 10 : 0
    c_bot = ((i + (4 - phase)) % 4 < 2) ? 10 : 0
    pset(rx + i, ry, c_top)
    pset(rx + i, y1, c_bot)
  end
  rh.times do |j|
    c_left = ((j + (4 - phase)) % 4 < 2) ? 10 : 0
    c_right = ((j + phase) % 4 < 2) ? 10 : 0
    pset(rx, ry + j, c_left)
    pset(x1, ry + j, c_right)
  end
end

# ------------------------------------------------------------------------------
# 描画処理 (draw)
# ------------------------------------------------------------------------------
def draw
  pal_bank(0)
  cls(0)

  mx = mouse_x
  my = mouse_y
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16

  # ============================================================================
  # 1. 上部統合メニューバー (y: 0..22, 幅 640)
  # ============================================================================
  rectfill(0, 0, 640, 22, 1)
  line(0, 22, 640, 22, 5)

  # モード切替タブ: [SPRITE] (アクティブ) / [TILEMAP]
  rectfill(8, 3, 58, 16, 12)
  rect(8, 3, 58, 16, 7)
  print_text("SPRITE", 16, 7, 0)

  rectfill(70, 3, 64, 16, 2)
  rect(70, 3, 64, 16, 6)
  print_text("TILEMAP", 78, 7, 7)

  # スプライト番号 & 座標
  print_text("##{cur_spr_id} (#{$sel_x},#{$sel_y})", 144, 7, 10)

  # [SIZE: 16x16] ボタン
  rectfill(244, 3, 46, 16, 2)
  rect(244, 3, 46, 16, 6)
  print_text("#{$edit_w}x#{$edit_h}", 250, 7, 11)

  # [< B0 >] バンク選択ボタン
  rectfill(298, 3, 16, 16, 2)
  rect(298, 3, 16, 16, 6)
  print_text("<", 303, 7, 7)

  rectfill(316, 3, 28, 16, 0)
  rect(316, 3, 28, 16, 5)
  print_text("B#{$current_bank}", 322, 7, 10)

  rectfill(346, 3, 16, 16, 2)
  rect(346, 3, 16, 16, 6)
  print_text(">", 351, 7, 7)

  # ターゲットファイル名
  print_text("#{$save_path}", 372, 7, 6)

  # [SAVE] / [EXP] / [CODE]
  if $is_read_only
    rectfill(492, 3, 46, 16, 5)
    rect(492, 3, 46, 16, 6)
    print_text("R-ONLY", 495, 7, 7)
  else
    rectfill(492, 3, 46, 16, 11)
    rect(492, 3, 46, 16, 7)
    print_text("SAVE", 502, 7, 0)
  end

  rectfill(544, 3, 38, 16, 2)
  rect(544, 3, 38, 16, 6)
  print_text("EXP", 554, 7, 7)

  rectfill(588, 3, 44, 16, 2)
  rect(588, 3, 44, 16, 6)
  print_text("CODE", 596, 7, 7)

  # ============================================================================
  # 2. 左ペイン: ドット編集キャンバス (32x32, 7px/cell -> 224x224) + アイコンバー + 小型パレット
  # ============================================================================
  cw_px = CANVAS_GRID * $cell_size
  ch_px = CANVAS_GRID * $cell_size
  rectfill($canvas_x - 1, $canvas_y - 1, cw_px + 2, ch_px + 2, 1)
  rect($canvas_x - 1, $canvas_y - 1, cw_px + 2, ch_px + 2, 5)

  # キャンバス背景描画 (Maya風単色ライトグレー #C0C0C0)
  pal_bank(CANVAS_BG_PALETTE)
  rectfill($canvas_x, $canvas_y, cw_px, ch_px, 0)
  pal_bank(0)

  # バンクテクスチャ描画 (7.0倍)
  blt($canvas_x, $canvas_y, $current_bank, $sel_x, $sel_y, 32, 32, 0, 7.0, $current_pal)

  # フローティング選択中のドットを描画
  if $rect_sel && $floating_pixels
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    pal_bank($current_pal)
    rh.times do |fy|
      rw.times do |fx|
        tx = rx + fx
        ty = ry + fy
        if tx >= 0 && tx < $edit_w && ty >= 0 && ty < $edit_h
          col = $floating_pixels[fy * rw + fx]
          if col
            rectfill($canvas_x + tx * $cell_size, $canvas_y + ty * $cell_size, $cell_size, $cell_size, col)
          end
        end
      end
    end
    pal_bank(0)
  end

  # オニオンスキン描画 (前フレームのドットを透かし表示)
  if $show_onion && $sel_x >= $edit_w
    prev_x = $sel_x - $edit_w
    prev_pixels = get_bank_rect($current_bank, prev_x, $sel_y, $edit_w, $edit_h)
    cur_pixels = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
    $edit_h.times do |cy|
      $edit_w.times do |cx|
        cur_c = cur_pixels[cy * $edit_w + cx]
        prev_c = prev_pixels[cy * $edit_w + cx]
        if cur_c.nil? && prev_c
          px = $canvas_x + cx * $cell_size
          py = $canvas_y + cy * $cell_size
          rectfill(px + 2, py + 2, 3, 3, 12)
        end
      end
    end
  end

  # 非アクティブ領域のディム表示 (枠外の半透明シェード)
  if $edit_w < 32 || $edit_h < 32
    32.times do |cy|
      32.times do |cx|
        if cx >= $edit_w || cy >= $edit_h
          px = $canvas_x + cx * $cell_size
          py = $canvas_y + cy * $cell_size
          pset(px + 1, py + 1, 0)
          pset(px + 4, py + 4, 0)
        end
      end
    end
  end

  # グリッド線
  if $show_grid
    (CANVAS_GRID + 1).times do |i|
      gx = $canvas_x + i * $cell_size
      gy = $canvas_y + i * $cell_size
      line(gx, $canvas_y, gx, $canvas_y + ch_px, 1)
      line($canvas_x, gy, $canvas_x + cw_px, gy, 1)
    end
  end

  # アクティブスプライトの境界枠
  rect($canvas_x, $canvas_y, $edit_w * $cell_size, $edit_h * $cell_size, 7)
  rect($canvas_x - 1, $canvas_y - 1, $edit_w * $cell_size + 2, $edit_h * $cell_size + 2, 10)

  # 矩形選択枠 (マーチングアンツ)
  if $rect_sel
    rx = $rect_sel[0]
    ry = $rect_sel[1]
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    cx0 = [[rx, 0].max, $edit_w].min
    cy0 = [[ry, 0].max, $edit_h].min
    cx1 = [[rx + rw, 0].max, $edit_w].min
    cy1 = [[ry + rh, 0].max, $edit_h].min
    if cx1 > cx0 && cy1 > cy0
      sx = $canvas_x + cx0 * $cell_size
      sy = $canvas_y + cy0 * $cell_size
      sw = (cx1 - cx0) * $cell_size
      sh = (cy1 - cy0) * $cell_size
      draw_marching_rect(sx, sy, sw, sh, $ui_tick)
      draw_marching_rect(sx - 1, sy - 1, sw + 2, sh + 2, $ui_tick + 12)
    end
  end

  # カーソル枠プレビュー
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + cw_px &&
               my >= $canvas_y && my < $canvas_y + ch_px)
  if in_canvas
    hx = (mx - $canvas_x) / $cell_size
    hy = (my - $canvas_y) / $cell_size
    if hx < $edit_w && hy < $edit_h
      rect($canvas_x + hx * $cell_size, $canvas_y + hy * $cell_size, $cell_size, $cell_size, 7)
    end
  end

  # --- 2.1 アイコンツールバー (14個, x: 10..233, y: 256..271) ---
  bake_tool_icons
  TOOL_BUTTONS.each_with_index do |tb, idx|
    tid = tb[0]
    bx = 10 + idx * 16
    by = 256
    is_active = false
    if tid == :pen || tid == :fill || tid == :picker || tid == :eraser || tid == :select
      is_active = ($current_tool == tid)
    elsif tid == :grid
      is_active = $show_grid
    elsif tid == :onion
      is_active = $show_onion
    end

    bg_col = is_active ? ((tid == :grid || tid == :onion) ? 12 : 8) : (tid == :clear ? 2 : 1)
    border_col = is_active ? 7 : (tid == :clear ? 8 : 5)
    rectfill(bx, by, 15, 15, bg_col)
    rect(bx, by, 15, 15, border_col)

    blt(bx + 2, by + 2, ICON_BANK, idx * 16, is_active ? 16 : 0, 11, 11)
  end

  # --- 2.2 小型カラーパレット (8列×2段, 1セル 12x12 px, x: 10..113, y: 278..303) ---
  pal_bank($current_pal)
  2.times do |row|
    8.times do |col_idx|
      c_id = row * 8 + col_idx
      bx = 10 + col_idx * 13
      by = 278 + row * 13
      rectfill(bx, by, 12, 12, c_id)
    end
  end
  pal_bank(0)
  2.times do |row|
    8.times do |col_idx|
      c_id = row * 8 + col_idx
      bx = 10 + col_idx * 13
      by = 278 + row * 13
      # ベースパレット(P0)から変更されている差分カラーには右上に●マーカーを表示
      col_info = get_palette_color($current_pal, c_id)
      if col_info && col_info[3]
        rectfill(bx + 9, by + 1, 2, 2, 7)
      end
      if $current_col == c_id
        rect(bx - 1, by - 1, 14, 14, 7)
      else
        rect(bx, by, 12, 12, 0)
      end
    end
  end

  # [TRANS (.)] ボタン & 選択色情報 (y: 308..322)
  rectfill(10, 308, 62, 14, $current_col.nil? ? 8 : 1)
  rect(10, 308, 62, 14, $current_col.nil? ? 7 : 5)
  print_text("TRANS(.)", 16, 311, $current_col.nil? ? 7 : 6)

  if $current_col
    print_text("COL:#{HEX_CHARS[$current_col]}", 76, 311, 10)
  else
    print_text("COL:.", 76, 311, 6)
  end

  # パレット切替バー [<] [P0] [>] [+DUP] [PICK] (x: 118..234, y: 278..292)
  rectfill(118, 278, 13, 14, 2)
  rect(118, 278, 13, 14, 6)
  print_text("<", 122, 281, 7)

  rectfill(133, 278, 24, 14, 1)
  rect(133, 278, 24, 14, 5)
  print_text("P#{$current_pal}", 137, 281, 10)

  rectfill(159, 278, 13, 14, 2)
  rect(159, 278, 13, 14, 6)
  print_text(">", 163, 281, 7)

  rectfill(175, 278, 29, 14, 3)
  rect(175, 278, 29, 14, 11)
  print_text("+DUP", 178, 281, 7)

  rectfill(207, 278, 27, 14, $show_color_picker ? 8 : 2)
  rect(207, 278, 27, 14, $show_color_picker ? 7 : 6)
  print_text("PICK", 209, 281, 7)

  # 1px シフト移動ボタン [←][↑][↓][→] (x: 118..234, y: 296..310)
  shift_btns = [
    ["←", 118],
    ["↑", 148],
    ["↓", 178],
    ["→", 208]
  ]
  shift_btns.each do |sb|
    rectfill(sb[1], 296, 26, 14, 1)
    rect(sb[1], 296, 26, 14, 5)
    print_text(sb[0], sb[1] + 10, 299, 7)
  end

  # 選択範囲・アクティブツール表示 (y: 314)
  if $rect_sel
    print_text("SEL:(#{$rect_sel[0]},#{$rect_sel[1]}) #{$rect_sel[2]}x#{$rect_sel[3]}#{$floating_pixels ? '*' : ''}", 118, 314, 11)
  else
    print_text("TOOL: #{$current_tool.to_s.upcase}", 118, 314, 6)
  end

  # ============================================================================
  # 3. 中央ペイン (キャンバスのすぐ右隣!): 1倍(256x256) スプライトシート & アニメプレビュー
  # ============================================================================
  rectfill($sheet_x - 1, $sheet_y - 1, $sheet_size + 2, $sheet_size + 2, 0)
  rect($sheet_x - 1, $sheet_y - 1, $sheet_size + 2, $sheet_size + 2, 5)

  # 等倍 (1.0x = 256x256 px) でバンク全体を描画！
  blt($sheet_x, $sheet_y, $current_bank, 0, 0, 256, 256, 0, 1.0, $current_pal)

  # 選択中スプライトの境界枠 (等倍 $edit_w x $edit_h px)
  s_bx = $sheet_x + $sel_x
  s_by = $sheet_y + $sel_y
  rect(s_bx, s_by, $edit_w, $edit_h, 7)
  rect(s_bx - 1, s_by - 1, $edit_w + 2, $edit_h + 2, 10)

  # --- 3.1 シート下部: 1倍 & 2倍 アニメーションプレビューバー (x: 244..500, y: 290..334) ---
  preview_bg = case $bg_mode
               when 0 then 0
               when 1 then 1
               when 2 then 7
               else 5
               end
  anim_step = anim_current_step
  draw_u = ($sel_x + anim_step * $edit_w) % BANK_SIZE

  # (A) 1x 等倍プレビューボックス (36x36, x: 244, y: 290)
  rectfill(244, 290, 36, 36, preview_bg)
  rect(244, 290, 36, 36, 5)
  ox_1x = 244 + (36 - $edit_w) / 2
  oy_1x = 290 + (36 - $edit_h) / 2
  blt(ox_1x, oy_1x, $current_bank, draw_u, $sel_y, $edit_w, $edit_h, 0, 1.0, $current_pal)
  print_text("1x", 246, 328, 6)

  # (B) 2x 拡大プレビューボックス (36x36, x: 284, y: 290)
  rectfill(284, 290, 36, 36, preview_bg)
  rect(284, 290, 36, 36, 5)
  scale_2x = ($edit_w <= 16 && $edit_h <= 16) ? 2.0 : 1.0
  pw_2x = ($edit_w * scale_2x).to_i
  ph_2x = ($edit_h * scale_2x).to_i
  ox_2x = 284 + (36 - pw_2x) / 2
  oy_2x = 290 + (36 - ph_2x) / 2
  blt(ox_2x, oy_2x, $current_bank, draw_u, $sel_y, $edit_w, $edit_h, 0, scale_2x, $current_pal)
  print_text(scale_2x == 2.0 ? "2x" : "1x", 286, 328, 6)

  # (C) アニメーション設定ボタン群 (x: 324..500, y: 290..304)
  # [▶/■]
  rectfill(324, 290, 22, 14, $anim_playing ? 8 : 3)
  rect(324, 290, 22, 14, 6)
  print_text($anim_playing ? "■" : "▶", 332, 293, 7)

  # [#F]
  rectfill(350, 290, 28, 14, 2)
  rect(350, 290, 28, 14, 6)
  print_text("#{$anim_frames}F", 358, 293, 10)

  # [LOOP / PING]
  rectfill(382, 290, 40, 14, $anim_pingpong ? 12 : 2)
  rect(382, 290, 40, 14, $anim_pingpong ? 7 : 6)
  print_text($anim_pingpong ? "PING" : "LOOP", 388, 293, $anim_pingpong ? 0 : 7)

  # [SPD]
  rectfill(426, 290, 38, 14, 2)
  rect(426, 290, 38, 14, 6)
  fps_label = ($anim_speed == 4 ? "FAST" : ($anim_speed == 6 ? "MID" : ($anim_speed == 12 ? "SLOW" : "NORM")))
  print_text(fps_label, 431, 293, 7)

  # [BG]
  rectfill(468, 290, 30, 14, 2)
  rect(468, 290, 30, 14, 6)
  print_text("BG", 477, 293, 7)

  # (D) 1倍アニメーションストリップ (最大8コマ並べて表示, y: 308..326)
  $anim_frames.times do |f_idx|
    fx = 324 + f_idx * 22
    fy = 308
    break if fx + 18 > 502
    rectfill(fx, fy, 18, 18, preview_bg)
    is_cur_f = ($anim_playing && anim_step == f_idx)
    rect(fx, fy, 18, 18, is_cur_f ? 10 : 5)
    fu = ($sel_x + f_idx * $edit_w) % BANK_SIZE
    f_scale = ($edit_w <= 16 && $edit_h <= 16) ? 1.0 : 0.5
    blt(fx + 1, fy + 1, $current_bank, fu, $sel_y, $edit_w, $edit_h, 0, f_scale, $current_pal)
  end

  # ============================================================================
  # 4. 右ペイン: カラーピッカー & ショートカットガイド (x: 506..634, y: 28..334)
  # ============================================================================
  rectfill(506, 28, 128, 306, 1)
  rect(506, 28, 128, 306, 5)

  if $show_color_picker
    act_col = $current_col || 0
    hex_str = rgb_to_hex_str($picker_r, $picker_g, $picker_b)
    print_text("P#{$current_pal}:#{HEX_CHARS[act_col]}", 510, 33, 10)
    rectfill_rgb(546, 31, 12, 11, $picker_r, $picker_g, $picker_b)
    rect(546, 31, 12, 11, 7)
    print_text(hex_str, 562, 33, 7)

    # [X] 閉じるボタン
    rectfill(618, 30, 13, 12, 8)
    rect(618, 30, 13, 12, 7)
    print_text("X", 622, 32, 7)

    # 2D HSV ボックス (80x80) & Hue レインボーバー (10x80)
    draw_hsv_picker(510, 48, 80, 80, 594, 48, 10, 80, $picker_h)
    rect(509, 47, 82, 82, 6)
    rect(593, 47, 12, 82, 6)

    # SV カーソル
    sv_cx = 510 + ($picker_s * 79) / 100
    sv_cy = 48 + ((100 - $picker_v) * 79) / 100
    rect(sv_cx - 2, sv_cy - 2, 5, 5, 0)
    rect(sv_cx - 1, sv_cy - 1, 3, 3, 7)

    # Hue バーカーソル
    h_cy = 48 + ($picker_h * 79) / 359
    rect(592, h_cy - 1, 14, 3, 7)

    # 右側ユーティリティボタン [RST] [CPY] [PST] [ALL]
    rectfill(608, 48, 23, 17, 2)
    rect(608, 48, 23, 17, 6)
    print_text("RST", 611, 53, 7)

    rectfill(608, 68, 23, 17, 2)
    rect(608, 68, 23, 17, 6)
    print_text("CPY", 611, 73, 7)

    rectfill(608, 88, 23, 17, $col_clipboard ? 3 : 1)
    rect(608, 88, 23, 17, $col_clipboard ? 11 : 5)
    print_text("PST", 611, 93, $col_clipboard ? 7 : 5)

    rectfill(608, 108, 23, 17, 2)
    rect(608, 108, 23, 17, 8)
    print_text("ALL", 611, 113, 8)

    # RGB スライダー (x: 520..602, width 82)
    # R
    print_text("R", 510, 138, 8)
    rectfill(520, 137, 82, 10, 0)
    rw = ($picker_r * 80) / 255
    rectfill_rgb(521, 138, rw, 8, $picker_r, 40, 40) if rw > 0
    rect(520, 137, 82, 10, 5)
    rectfill(520 + rw, 136, 3, 12, 7)
    print_text("#{$picker_r}", 606, 138, 7)

    # G
    print_text("G", 510, 154, 11)
    rectfill(520, 153, 82, 10, 0)
    gw = ($picker_g * 80) / 255
    rectfill_rgb(521, 154, gw, 8, 40, $picker_g, 40) if gw > 0
    rect(520, 153, 82, 10, 5)
    rectfill(520 + gw, 152, 3, 12, 7)
    print_text("#{$picker_g}", 606, 154, 7)

    # B
    print_text("B", 510, 170, 12)
    rectfill(520, 169, 82, 10, 0)
    bw = ($picker_b * 80) / 255
    rectfill_rgb(521, 170, bw, 8, 40, 80, $picker_b) if bw > 0
    rect(520, 169, 82, 10, 5)
    rectfill(520 + bw, 168, 3, 12, 7)
    print_text("#{$picker_b}", 606, 170, 7)

    # 32色プリセットスウォッチ (16x2, x: 510..622, y: 196..222)
    print_text("PRESETS (32 COLORS)", 510, 186, 6)
    2.times do |s_row|
      16.times do |s_col|
        sw = PRESET_SWATCHES[s_row * 16 + s_col]
        sx = 510 + s_col * 7
        sy = 196 + s_row * 13
        rectfill_rgb(sx, sy, 7, 12, sw[0], sw[1], sw[2])
      end
    end
    rect(509, 195, 114, 27, 5)
  else
    print_text("COLOR PICKER CLOSED", 512, 36, 6)
    print_text("Press K or [PICK]", 512, 50, 11)
    print_text("or Right-Click Swatch", 512, 64, 11)
  end

  # 右ペイン下部: 常時表示のショートカット一覧 (y: 230..328)
  line(510, 228, 630, 228, 5)
  print_text("SHORTCUTS", 510, 234, 10)
  print_text("B:Pen F:Fill E:Eras", 510, 248, 6)
  print_text("M:Sel Ctrl+A:All", 510, 260, 6)
  print_text("Ctrl+C/X/V: Copy/Pst", 510, 272, 6)
  print_text("H/V/R:Flip/Rot Z:Undo", 510, 284, 6)
  print_text("G:Grid O:Onion P:Pal", 510, 296, 6)
  print_text("Tab:Size S:Save", 510, 308, 6)
  print_text("R-Click: Eyedropper", 510, 320, 11)

  # ============================================================================
  # 5. 下部ステータスバー (y: 340..360, 幅 640)
  # ============================================================================
  rectfill(0, 340, 640, 20, 1)
  line(0, 340, 640, 340, 5)

  if $hover_tip
    print_text("💡 #{$hover_tip}", 10, 346, 11)
  elsif $notify_timer > 0
    print_text("▶ #{$notify_msg}", 10, 346, 10)
  elsif $is_read_only
    print_text("🔒 READ-ONLY: Direct PNG reference (view-only). Edit PNG in external tool.", 10, 346, 10)
  else
    print_text("Ready. Bank #{$current_bank} | Left: Canvas(32x32) | Center: 1x Sheet(256x256) | Right: Color Picker", 10, 346, 6)
  end
  print_text("FPS:#{fps}", 584, 346, 11)

  # ============================================================================
  # 6. コードプレビューモーダル
  # ============================================================================
  if $show_code_modal
    rectfill(60, 24, 520, 310, 0)
    rect(60, 24, 520, 310, 7)
    print_text("--- SPRITE & PALETTE DATA PREVIEW (Click anywhere to close) ---", 72, 32, 10)
    preview_text = export_bank_sprites_text($save_path, $current_bank, $sprite_palettes)
    lines = preview_text ? preview_text.split("\n") : []
    25.times do |i|
      break if i >= lines.size
      print_text(lines[i], 72, 48 + i * 10, 6)
    end
    print_text("... (truncated)", 72, 48 + 25 * 10, 5) if lines.size > 25
  end
end

__END__

# ==============================================================================
# スプライトエディタ用 特殊パレット
# ==============================================================================
# @PALETTE 99: キャンバス背景用 (Maya風ライトグレー #C0C0C0)
# 黒のアウトラインや白・濃色・原色の視認性を高め、PICO-8カラーと衝突しない無彩色グレー
@PALETTE 99
0: #C0C0C0
1: #E0E0E0

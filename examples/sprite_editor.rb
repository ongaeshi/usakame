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
CANVAS_BG_PALETTE = 99 # キャンバス背景用固定システムパレット (Maya風単色グレー #C0C0C0)

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

# ツール一覧: :pen, :fill, :picker, :eraser, :select
$current_tool = :pen
$current_col = 8     # 初期描画色 (赤)
$show_grid = true    # グリッド線の表示
$bg_mode = 0         # プレビュー背景 (0: 黒, 1: 濃紺, 2: 白, 3: 市松)
$ui_tick = 0         # マーチングアンツ等のアニメーション用フレームカウンタ

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
$open_picker_on_start = false
$open_select_on_start = false
if ARGV && ARGV.size > 0
  pos_args = []
  ARGV.each do |arg|
    if arg == "--picker" || arg == "-k"
      $open_picker_on_start = true
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

# 32x32 領域のピクセルを配列で取得 (Rust ネイティブAPIで超高速取得)
def get_canvas_pixels(bx, by)
  get_bank_rect($current_bank, bx, by, CANVAS_GRID, CANVAS_GRID)
end

# 32x32 領域のピクセルを復元 (Rust ネイティブAPIで一括更新)
def set_canvas_pixels(bx, by, pixels)
  update_bank_rect($current_bank, bx, by, CANVAS_GRID, CANVAS_GRID, pixels)
end

def push_undo
  $undo_stack << [$sel_x, $sel_y, $edit_w, $edit_h, get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)]
  $undo_stack.shift if $undo_stack.size > 30
end

def perform_undo
  return if $is_read_only
  if $floating_pixels
    # フローティング移動・貼り付け中なら、まず未確定のフローティング状態を破棄して直前のバンク状態に戻す
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

$show_color_picker = false
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
      # 彩度0（白〜黒）のときは現在の色相を維持して使いやすくする
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
if $open_picker_on_start
  $show_color_picker = true
  sync_picker_from_current_color
end
if $open_select_on_start
  $current_tool = :select
  $rect_sel = [2, 1, 12, 10]
end

if $is_read_only
  # テクスチャ（PNG参照）から読み込んだ場合：リードオンリーモードなので減色処理は不要！
  # フルカラーRGBAテクスチャのまま直接バンクへロードする
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
  if $open_picker_on_start
    $show_color_picker = true
    sync_picker_from_current_color
  end
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
    # Ctrl+矢印で選択エリア移動 (16px刻み)
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

  # --- カラーピッカーまたはミニマップの操作 ---
  if $show_color_picker
    if !btn(:mouse_l)
      $picker_drag = nil
    end

    if btnp(:mouse_l)
      # [×] 閉じるボタン (x: 460..474, y: 28..42)
      if mx >= 460 && mx <= 474 && my >= 28 && my <= 42
        $show_color_picker = false
        $picker_drag = nil
        sfx(:click)
      # SV 2Dボックス開始 (x: 344..428, y: 48..132)
      elsif mx >= 344 && mx <= 428 && my >= 48 && my <= 132
        $picker_drag = :sv
      # Hue バー開始 (x: 434..446, y: 48..132)
      elsif mx >= 434 && mx <= 446 && my >= 48 && my <= 132
        $picker_drag = :hue
      # R スライダー (x: 356..446, y: 138..150)
      elsif mx >= 356 && mx <= 446 && my >= 138 && my <= 150
        $picker_drag = :r
      # G スライダー (x: 356..446, y: 154..166)
      elsif mx >= 356 && mx <= 446 && my >= 154 && my <= 166
        $picker_drag = :g
      # B スライダー (x: 356..446, y: 170..182)
      elsif mx >= 356 && mx <= 446 && my >= 170 && my <= 182
        $picker_drag = :b
      # 右側ユーティリティボタン群 (x: 450..474)
      elsif mx >= 450 && mx <= 474
        if my >= 48 && my <= 66 # [RST] 1色リセット
          reset_current_palette_color
        elsif my >= 70 && my <= 88 # [CPY] 色コピー
          $col_clipboard = [$picker_r, $picker_g, $picker_b]
          sfx(:coin)
          notify("COPIED COLOR #{rgb_to_hex_str($picker_r, $picker_g, $picker_b)}")
        elsif my >= 92 && my <= 110 # [PST] 色ペースト
          if $col_clipboard
            apply_picker_rgb($col_clipboard[0], $col_clipboard[1], $col_clipboard[2], true)
            sfx(:powerup)
            notify("PASTED COLOR #{rgb_to_hex_str($picker_r, $picker_g, $picker_b)}")
          end
        elsif my >= 114 && my <= 132 # [ALL] パレット全色リセット
          reset_all_palette_colors
        end
      # 32色プリセットスウォッチ (x: 344..471, y: 198..225, 16列x2段, 1セル8x14)
      elsif mx >= 344 && mx < 472 && my >= 198 && my < 226
        sw_col = (mx - 344) / 8
        sw_row = (my - 198) / 14
        sw_idx = sw_row * 16 + sw_col
        if sw_idx >= 0 && sw_idx < PRESET_SWATCHES.size
          rgb = PRESET_SWATCHES[sw_idx]
          apply_picker_rgb(rgb[0], rgb[1], rgb[2], true)
          sfx(:select)
          notify("PRESET: #{rgb_to_hex_str(rgb[0], rgb[1], rgb[2])}")
        end
      end
    end

    # ドラッグ中の連続更新
    if btn(:mouse_l) && $picker_drag
      if $picker_drag == :sv
        $picker_s = (((mx - 344) * 100) / 83).clamp(0, 100)
        $picker_v = (100 - (((my - 48) * 100) / 83)).clamp(0, 100)
        rgb = hsv_to_rgb($picker_h, $picker_s, $picker_v)
        apply_picker_rgb(rgb[0], rgb[1], rgb[2], false) if rgb
      elsif $picker_drag == :hue
        $picker_h = (((my - 48) * 359) / 83).clamp(0, 359)
        rgb = hsv_to_rgb($picker_h, $picker_s, $picker_v)
        apply_picker_rgb(rgb[0], rgb[1], rgb[2], false) if rgb
      elsif $picker_drag == :r
        nr = (((mx - 356) * 255) / 89).clamp(0, 255)
        apply_picker_rgb(nr, $picker_g, $picker_b, true)
      elsif $picker_drag == :g
        ng = (((mx - 356) * 255) / 89).clamp(0, 255)
        apply_picker_rgb($picker_r, ng, $picker_b, true)
      elsif $picker_drag == :b
        nb = (((mx - 356) * 255) / 89).clamp(0, 255)
        apply_picker_rgb($picker_r, $picker_g, nb, true)
      end
    end
  else
    # --- ミニマップ上でのドラッグ／クリック判定 ---
    in_minimap = (mx >= $minimap_x && mx < $minimap_x + $minimap_size &&
                  my >= $minimap_y && my < $minimap_y + $minimap_size)
    if in_minimap && (btn(:mouse_l) || btn(:mouse_r))
      gx = ((mx - $minimap_x) / 8) * 16
      gy = ((my - $minimap_y) / 8) * 16
      gx = [[gx, 0].max, 256 - $edit_w].min
      gy = [[gy, 0].max, 256 - $edit_h].min
      set_selection(gx, gy)
    end
  end

  # --- 4x4 パレットの右クリックで即座にカラーピッカーを起動 ---
  if btnp(:mouse_r) && mx >= 220 && mx < 320 && my >= 88 && my < 188
    col_idx = (mx - 220) / 25
    row_idx = (my - 88) / 25
    if col_idx >= 0 && col_idx < 4 && row_idx >= 0 && row_idx < 4
      $current_col = row_idx * 4 + col_idx
      switch_tool(:pen) if $current_tool == :eraser
      $show_color_picker = true
      sync_picker_from_current_color
      sfx(:select)
      notify("EDITING P#{$current_pal} COL #{HEX_CHARS[$current_col]}")
    end
  end

  # --- ボタンクリック判定 (mouse_l) ---
  if btnp(:mouse_l)
    # 1. ヘッダーボタン (y: 3..21)
    if my >= 3 && my <= 21
      if mx >= 124 && mx <= 176 # [SIZE]
        cycle_size_mode
      elsif mx >= 182 && mx <= 198 # [<] バンク減
        switch_bank([$current_bank - 1, 0].max)
        sfx(:click)
      elsif mx >= 232 && mx <= 248 # [>] バンク増
        switch_bank($current_bank + 1)
        sfx(:click)
      elsif mx >= 252 && mx <= 296 # [SAVE]
        save_to_target
      elsif mx >= 302 && mx <= 340 # [EXP]
        export_all
      elsif mx >= 346 && mx <= 386 # [MAP]
        commit_floating_selection
        spawn_editor("map", $target_path) if respond_to?(:spawn_editor)
        sfx(:click)
      elsif mx >= 392 && mx <= 434 # [ONION]
        toggle_onion
      elsif mx >= 440 && mx <= 476 # [CODE]
        commit_floating_selection
        $show_code_modal = true
        sfx(:click)
      end
    end

    # 2. プレビュー操作 (y: 28..44)
    if my >= 28 && my <= 44
      if mx >= 282 && mx <= 306 # [BG]
        $bg_mode = ($bg_mode + 1) % 4
        sfx(:click)
      elsif mx >= 310 && mx <= 334 # [▶/■]
        toggle_anim
      end
    end

    # 2.2 アニメーション設定 (y: 46..62)
    if my >= 46 && my <= 62
      if mx >= 220 && mx <= 250 # [#F] フレーム数
        cycle_anim_frames(1)
      elsif mx >= 254 && mx <= 296 # [LOOP/PING]
        toggle_anim_pingpong
      elsif mx >= 300 && mx <= 336 # [SPD]
        $anim_speed = case $anim_speed; when 8 then 6; when 6 then 4; when 4 then 12; else 8; end
        sfx(:cursor)
        notify("ANIM SPEED: #{$anim_speed} ticks")
      end
    end

    # 2.5 パレット操作バー [< P0 >] [+DUP] [PICK] (y: 66..82)
    if my >= 66 && my <= 82
      if mx >= 220 && mx <= 233 # [<]
        cycle_palette(-1)
      elsif mx >= 261 && mx <= 274 # [>]
        cycle_palette(1)
      elsif mx >= 277 && mx <= 306 # [+DUP] パレット複製・新規作成
        duplicate_current_palette
      elsif mx >= 309 && mx <= 336 # [PICK] カラーピッカー開閉
        $show_color_picker = !$show_color_picker
        sync_picker_from_current_color if $show_color_picker
        sfx(:click)
        notify($show_color_picker ? "COLOR PICKER: OPEN" : "COLOR PICKER: CLOSED")
      end
    end

    # 3. パレットカラー選択 (4x4, x: 220..320, y: 88..188)
    if mx >= 220 && mx < 320 && my >= 88 && my < 188
      col_idx = (mx - 220) / 25
      row_idx = (my - 88) / 25
      if col_idx >= 0 && col_idx < 4 && row_idx >= 0 && row_idx < 4
        $current_col = row_idx * 4 + col_idx
        switch_tool(:pen) if $current_tool == :eraser || $current_tool == :select
        sync_picker_from_current_color
        sfx(:select)
      end
    end

    # [TRANS] 透過色ボタン (x: 220..316, y: 192..208)
    if mx >= 220 && mx <= 316 && my >= 192 && my <= 208
      $current_col = nil
      sfx(:select)
    end

    # 4. ツールボタン (キャンバス下部, y: 224..242)
    if my >= 224 && my <= 242
      if mx >= 12 && mx <= 38 # [PEN]
        switch_tool(:pen)
        sfx(:click)
      elsif mx >= 40 && mx <= 68 # [FILL]
        switch_tool(:fill)
        sfx(:click)
      elsif mx >= 70 && mx <= 98 # [PICK]
        switch_tool(:picker)
        sfx(:click)
      elsif mx >= 100 && mx <= 128 # [ERAS]
        switch_tool(:eraser)
        sfx(:click)
      elsif mx >= 130 && mx <= 156 # [SEL]
        switch_tool(:select)
        sfx(:click)
        notify("TOOL: SELECT (Drag to select / Drag inside to move)")
      elsif mx >= 158 && mx <= 186 # [GRID]
        $show_grid = !$show_grid
        sfx(:click)
      elsif mx >= 188 && mx <= 212 # [CLR]
        clear_canvas
      end
    end

    # 5. アクションボタン (中央下部, y: 212..246)
    if my >= 212 && my <= 228
      if mx >= 220 && mx <= 248 # [UNDO]
        perform_undo
      elsif mx >= 252 && mx <= 280 # [COPY]
        copy_selection
      elsif mx >= 284 && mx <= 314 # [PASTE]
        paste_selection
      elsif mx >= 322 && mx <= 342 # [↑]
        shift_canvas(0, -1)
      end
    elsif my >= 230 && my <= 246
      if mx >= 220 && mx <= 250 # [FLIP-H]
        flip_canvas(true)
      elsif mx >= 254 && mx <= 284 # [FLIP-V]
        flip_canvas(false)
      elsif mx >= 288 && mx <= 312 # [ROT]
        rotate_canvas
      elsif mx >= 316 && mx <= 328 # [←]
        shift_canvas(-1, 0)
      elsif mx >= 330 && mx <= 342 # [↓]
        shift_canvas(0, 1)
      elsif mx >= 344 && mx <= 356 # [→]
        shift_canvas(1, 0)
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

      # 選択中スプライト範囲 ($edit_w x $edit_h) の内側のみ描画可能
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
  # 上辺 & 下辺
  rw.times do |i|
    c_top = ((i + phase) % 4 < 2) ? 10 : 0
    c_bot = ((i + (4 - phase)) % 4 < 2) ? 10 : 0
    pset(rx + i, ry, c_top)
    pset(rx + i, y1, c_bot)
  end
  # 左辺 & 右辺
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
  cls(0) # 背景: 黒

  mx = mouse_x
  my = mouse_y
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16

  # 1. 上部ヘッダーバー (y: 0..24)
  rectfill(0, 0, 480, 24, 1) # 濃紺
  line(0, 24, 480, 24, 5)

  print_text("USAKAME", 8, 7, 7)
  print_text("##{cur_spr_id}", 76, 7, 10)

  # [SIZE: 16x16] ボタン
  rectfill(124, 4, 52, 16, 2)
  rect(124, 4, 52, 16, 6)
  print_text("#{$edit_w}x#{$edit_h}", 132, 8, 11)

  # [< BANK n >] バンク選択ボタン
  rectfill(182, 4, 16, 16, 2)
  rect(182, 4, 16, 16, 6)
  print_text("<", 187, 8, 7)

  rectfill(200, 4, 30, 16, 1)
  rect(200, 4, 30, 16, 5)
  print_text("B#{$current_bank}", 206, 8, 10)

  rectfill(232, 4, 16, 16, 2)
  rect(232, 4, 16, 16, 6)
  print_text(">", 238, 8, 7)

  # [SAVE] ボタン
  if $is_read_only
    rectfill(252, 4, 44, 16, 5)
    rect(252, 4, 44, 16, 6)
    print_text("R-ONLY", 254, 8, 7)
  else
    rectfill(252, 4, 44, 16, 11)
    rect(252, 4, 44, 16, 7)
    print_text("SAVE", 262, 8, 0)
  end

  # [EXP] ボタン
  rectfill(302, 4, 38, 16, 2)
  rect(302, 4, 38, 16, 6)
  print_text("EXP", 312, 8, 7)

  # [MAP] ボタン
  rectfill(346, 4, 40, 16, 3)
  rect(346, 4, 40, 16, 11)
  print_text("MAP", 356, 8, 7)

  # [ONION] ボタン
  rectfill(392, 4, 42, 16, $show_onion ? 12 : 2)
  rect(392, 4, 42, 16, $show_onion ? 7 : 6)
  print_text("ONION", 397, 8, $show_onion ? 0 : 7)

  # [CODE] ボタン
  rectfill(440, 4, 36, 16, 2)
  rect(440, 4, 36, 16, 6)
  print_text("CODE", 446, 8, 7)

  # 2. キャンバス描画 (32x32, 6px/cell -> 192x192)
  rectfill($canvas_x - 2, $canvas_y - 2, CANVAS_GRID * $cell_size + 4, CANVAS_GRID * $cell_size + 4, 1)
  rect($canvas_x - 2, $canvas_y - 2, CANVAS_GRID * $cell_size + 4, CANVAS_GRID * $cell_size + 4, 5)

  # キャンバス背景描画 (Maya風単色ライトグレー #C0C0C0)
  pal_bank(CANVAS_BG_PALETTE)
  rectfill($canvas_x, $canvas_y, 192, 192, 0)
  pal_bank(0)

  # バンクテクスチャ描画
  blt($canvas_x, $canvas_y, $current_bank, $sel_x, $sel_y, 32, 32, 0, 6.0, $current_pal)

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
          rectfill(px + 2, py + 2, 2, 2, 12) # 淡い水色ドット
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
      line(gx, $canvas_y, gx, $canvas_y + CANVAS_GRID * $cell_size, 1)
      line($canvas_x, gy, $canvas_x + CANVAS_GRID * $cell_size, gy, 1)
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
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + CANVAS_GRID * $cell_size &&
               my >= $canvas_y && my < $canvas_y + CANVAS_GRID * $cell_size)
  if in_canvas
    hx = (mx - $canvas_x) / $cell_size
    hy = (my - $canvas_y) / $cell_size
    if hx < $edit_w && hy < $edit_h
      rect($canvas_x + hx * $cell_size, $canvas_y + hy * $cell_size, $cell_size, $cell_size, 7)
    end
  end

  # 3. ツールバー (キャンバス下部, y: 224..242)
  tools = [
    [:pen,    "PEN",  12,  26],
    [:fill,   "FILL", 40,  28],
    [:picker, "PICK", 70,  28],
    [:eraser, "ERAS", 100, 28],
    [:select, "SEL",  130, 26]
  ]
  tools.each do |item|
    tool_id = item[0]
    label = item[1]
    bx = item[2]
    bw = item[3]
    is_active = ($current_tool == tool_id)
    rectfill(bx, 224, bw, 18, is_active ? 8 : 1)
    rect(bx, 224, bw, 18, is_active ? 7 : 5)
    print_text(label, bx + 2, 229, is_active ? 7 : 6)
  end

  # [GRID]
  rectfill(158, 224, 28, 18, $show_grid ? 12 : 1)
  rect(158, 224, 28, 18, 5)
  print_text("GRID", 160, 229, $show_grid ? 7 : 5)

  # [CLR]
  rectfill(188, 224, 24, 18, 1)
  rect(188, 224, 24, 18, 8)
  print_text("CLR", 191, 229, 8)

  # 4. 中央ペイン: プレビュー & パレット
  print_text("PREVIEW", 220, 27, 6)

  preview_bg = case $bg_mode
               when 0 then 0
               when 1 then 1
               when 2 then 7
               else 0
               end
  # 1x プレビュー背景 (x: 219, y: 35)
  rectfill(219, 35, $edit_w + 2, $edit_h + 2, preview_bg)
  rect(219, 35, $edit_w + 2, $edit_h + 2, 5)

  # アニメーション再生オフセット計算
  anim_step = anim_current_step
  draw_u = ($sel_x + anim_step * $edit_w) % BANK_SIZE
  blt(220, 36, $current_bank, draw_u, $sel_y, $edit_w, $edit_h, 0, 1.0, $current_pal)

  # 2x プレビュー (x: 254, y: 28)
  rectfill(253, 27, 24, 24, preview_bg)
  rect(253, 27, 24, 24, 5)
  blt(254, 28, $current_bank, $sel_x, $sel_y, $edit_w, $edit_h, 0, 1.0, $current_pal)

  # [BG]
  rectfill(282, 32, 24, 14, 2)
  rect(282, 32, 24, 14, 6)
  print_text("BG", 288, 36, 7)

  # [▶/■]
  rectfill(310, 32, 24, 14, $anim_playing ? 8 : 3)
  rect(310, 32, 24, 14, 6)
  print_text($anim_playing ? "■" : "▶", 318, 36, 7)

  # アニメーション設定ボタン群 (y: 48..62)
  # [#F] フレーム数
  rectfill(220, 48, 30, 14, 2)
  rect(220, 48, 30, 14, 6)
  print_text("#{$anim_frames}F", 228, 52, 10)

  # [LOOP / PING]
  rectfill(254, 48, 42, 14, $anim_pingpong ? 12 : 2)
  rect(254, 48, 42, 14, $anim_pingpong ? 7 : 6)
  print_text($anim_pingpong ? "PING" : "LOOP", 260, 52, $anim_pingpong ? 0 : 7)

  # [SPD]
  rectfill(300, 48, 36, 14, 2)
  rect(300, 48, 36, 14, 6)
  fps_label = ($anim_speed == 4 ? "FAST" : ($anim_speed == 6 ? "MID" : ($anim_speed == 12 ? "SLOW" : "NORM")))
  print_text(fps_label, 305, 52, 7)

  # パレット操作バー [<] [P0] [>] [+DUP] [PICK] (y: 66..80)
  rectfill(220, 66, 13, 14, 2)
  rect(220, 66, 13, 14, 6)
  print_text("<", 224, 69, 7)

  rectfill(235, 66, 24, 14, 1)
  rect(235, 66, 24, 14, 5)
  print_text("P#{$current_pal}", 239, 69, 10)

  rectfill(261, 66, 13, 14, 2)
  rect(261, 66, 13, 14, 6)
  print_text(">", 265, 69, 7)

  # [+DUP] 現在のパレットを複製して新規パレット作成
  rectfill(277, 66, 29, 14, 3)
  rect(277, 66, 29, 14, 11)
  print_text("+DUP", 280, 69, 7)

  # [PICK] カラーピッカー開閉ボタン
  rectfill(309, 66, 27, 14, $show_color_picker ? 8 : 2)
  rect(309, 66, 27, 14, $show_color_picker ? 7 : 6)
  print_text("PICK", 311, 69, 7)

  # 16色グリッド (4x4, y: 88..188)
  pal_bank($current_pal)
  4.times do |row|
    4.times do |col_idx|
      c_id = row * 4 + col_idx
      bx = 220 + col_idx * 25
      by = 88 + row * 25
      rectfill(bx, by, 22, 22, c_id)
    end
  end
  pal_bank(0)
  4.times do |row|
    4.times do |col_idx|
      c_id = row * 4 + col_idx
      bx = 220 + col_idx * 25
      by = 88 + row * 25
      # ベースパレット(P0)から変更されている差分カラーには右上に●マーカーを表示
      col_info = get_palette_color($current_pal, c_id)
      if col_info && col_info[3]
        rectfill(bx + 17, by + 2, 3, 3, 7)
        pset(bx + 18, by + 3, 0)
      end
      if $current_col == c_id
        rect(bx - 1, by - 1, 24, 24, 7)
      else
        rect(bx, by, 22, 22, 0)
      end
    end
  end

  # [TRANS]
  rectfill(220, 192, 96, 16, $current_col.nil? ? 8 : 1)
  rect(220, 192, 96, 16, $current_col.nil? ? 7 : 5)
  print_text("TRANSPARENT (.)", 232, 196, $current_col.nil? ? 7 : 6)

  # アクションボタン群 (y: 212..246)
  # 行 1: UNDO, COPY, PASTE, ↑
  rectfill(220, 212, 30, 16, 1)
  rect(220, 212, 30, 16, 5)
  print_text("UNDO", 223, 216, 7)

  rectfill(254, 212, 28, 16, 1)
  rect(254, 212, 28, 16, 5)
  print_text("COPY", 257, 216, 7)

  rectfill(286, 212, 32, 16, 1)
  rect(286, 212, 32, 16, 5)
  print_text("PASTE", 288, 216, 7)

  rectfill(322, 212, 20, 16, 1)
  rect(322, 212, 20, 16, 5)
  print_text("↑", 328, 216, 7)

  # 行 2: FLIP-H, FLIP-V, ROT, ←, ↓, →
  rectfill(220, 230, 30, 16, 1)
  rect(220, 230, 30, 16, 5)
  print_text("FL-H", 224, 234, 7)

  rectfill(254, 230, 28, 16, 1)
  rect(254, 230, 28, 16, 5)
  print_text("FL-V", 257, 234, 7)

  rectfill(286, 230, 28, 16, 1)
  rect(286, 230, 28, 16, 5)
  print_text("ROT", 291, 234, 7)

  rectfill(318, 230, 12, 16, 1)
  rect(318, 230, 12, 16, 5)
  print_text("←", 320, 234, 7)

  rectfill(332, 230, 12, 16, 1)
  rect(332, 230, 12, 16, 5)
  print_text("↓", 334, 234, 7)

  rectfill(346, 230, 12, 16, 1)
  rect(346, 230, 12, 16, 5)
  print_text("→", 348, 234, 7)

  # 5. 右ペイン: カラーピッカー または 256x256 バンクミニマップ
  if $show_color_picker
    # パネル枠 (x: 340..476, y: 26..246)
    rectfill(340, 26, 136, 220, 1)
    rect(340, 26, 136, 220, 6)

    act_col = $current_col || 0
    hex_str = rgb_to_hex_str($picker_r, $picker_g, $picker_b)
    print_text("P#{$current_pal}:#{HEX_CHARS[act_col]}", 344, 32, 10)
    rectfill_rgb(384, 29, 14, 12, $picker_r, $picker_g, $picker_b)
    rect(384, 29, 14, 12, 7)
    print_text(hex_str, 402, 32, 7)

    # [×] 閉じるボタン
    rectfill(460, 28, 14, 14, 8)
    rect(460, 28, 14, 14, 7)
    print_text("X", 464, 31, 7)

    # 2D HSV ボックス (84x84) & Hue レインボーバー (12x84)
    draw_hsv_picker(344, 48, 84, 84, 434, 48, 12, 84, $picker_h)
    rect(343, 47, 86, 86, 6)
    rect(433, 47, 14, 86, 6)

    # SV カーソル
    sv_cx = 344 + ($picker_s * 83) / 100
    sv_cy = 48 + ((100 - $picker_v) * 83) / 100
    rect(sv_cx - 2, sv_cy - 2, 5, 5, 0)
    rect(sv_cx - 1, sv_cy - 1, 3, 3, 7)

    # Hue バーカーソル
    h_cy = 48 + ($picker_h * 83) / 359
    rect(432, h_cy - 1, 16, 3, 7)

    # 右側ユーティリティボタン [RST] [CPY] [PST] [ALL]
    rectfill(450, 48, 24, 18, 2)
    rect(450, 48, 24, 18, 6)
    print_text("RST", 453, 53, 7)

    rectfill(450, 70, 24, 18, 2)
    rect(450, 70, 24, 18, 6)
    print_text("CPY", 453, 75, 7)

    rectfill(450, 92, 24, 18, $col_clipboard ? 3 : 1)
    rect(450, 92, 24, 18, $col_clipboard ? 11 : 5)
    print_text("PST", 453, 97, $col_clipboard ? 7 : 5)

    rectfill(450, 114, 24, 18, 2)
    rect(450, 114, 24, 18, 8)
    print_text("ALL", 453, 119, 8)

    # RGB スライダー (x: 356..446, width 90)
    # R
    print_text("R", 345, 140, 8)
    rectfill(356, 139, 90, 10, 0)
    rw = ($picker_r * 88) / 255
    rectfill_rgb(357, 140, rw, 8, $picker_r, 40, 40) if rw > 0
    rect(356, 139, 90, 10, 5)
    rectfill(356 + rw, 138, 3, 12, 7)
    print_text("#{$picker_r}", 450, 140, 7)

    # G
    print_text("G", 345, 156, 11)
    rectfill(356, 155, 90, 10, 0)
    gw = ($picker_g * 88) / 255
    rectfill_rgb(357, 156, gw, 8, 40, $picker_g, 40) if gw > 0
    rect(356, 155, 90, 10, 5)
    rectfill(356 + gw, 154, 3, 12, 7)
    print_text("#{$picker_g}", 450, 156, 7)

    # B
    print_text("B", 345, 172, 12)
    rectfill(356, 171, 90, 10, 0)
    bw = ($picker_b * 88) / 255
    rectfill_rgb(357, 172, bw, 8, 40, 80, $picker_b) if bw > 0
    rect(356, 171, 90, 10, 5)
    rectfill(356 + bw, 170, 3, 12, 7)
    print_text("#{$picker_b}", 450, 172, 7)

    # 32色プリセットスウォッチ (16x2, x: 344..472, y: 198..226)
    print_text("PRESETS (32 COLORS)", 344, 188, 6)
    2.times do |s_row|
      16.times do |s_col|
        sw = PRESET_SWATCHES[s_row * 16 + s_col]
        sx = 344 + s_col * 8
        sy = 198 + s_row * 14
        rectfill_rgb(sx, sy, 8, 13, sw[0], sw[1], sw[2])
      end
    end
    rect(343, 197, 129, 29, 5)
    print_text("R-Click Cell / K:Close", 344, 232, 11)
  else
    print_text("BANK #{$current_bank} MINIMAP (256x256)", 342, 27, 6)

    rectfill($minimap_x - 1, $minimap_y - 1, $minimap_size + 2, $minimap_size + 2, 1)
    rect($minimap_x - 1, $minimap_y - 1, $minimap_size + 2, $minimap_size + 2, 5)

    blt($minimap_x, $minimap_y, $current_bank, 0, 0, 256, 256, 0, 0.5, $current_pal)

    # 選択中スプライト領域の枠線表示 (ミニマップ上では $edit_w/2 x $edit_h/2 px)
    sel_box_x = $minimap_x + $sel_x / 2
    sel_box_y = $minimap_y + $sel_y / 2
    sel_box_w = $edit_w / 2
    sel_box_h = $edit_h / 2
    rect(sel_box_x, sel_box_y, sel_box_w, sel_box_h, 7)
    rect(sel_box_x - 1, sel_box_y - 1, sel_box_w + 2, sel_box_h + 2, 10)

    # ミニマップ下部情報
    print_text("Pos:(#{$sel_x},#{$sel_y}) Spr##{cur_spr_id}(#{$edit_w}x#{$edit_h})", 342, 172, 10)
    if $rect_sel
      print_text("Sel:(#{$rect_sel[0]},#{$rect_sel[1]}) #{$rect_sel[2]}x#{$rect_sel[3]}#{$floating_pixels ? '*' : ''}", 342, 186, 11)
    else
      print_text("R-Click Swatch / [PICK]", 342, 186, 11)
    end
    print_text("M:Sel P:Pal K:Pick O:Oni", 342, 200, 5)
    print_text("Ctrl+A/C/X/V H/V/R:Flip", 342, 214, 5)
  end

  # 6. 下部ステータスバー (y: 250..270)
  rectfill(0, 250, 480, 20, 1)
  line(0, 250, 480, 250, 5)

  if $notify_timer > 0
    print_text("▶ #{$notify_msg}", 10, 256, 10)
  elsif $is_read_only
    print_text("🔒 READ-ONLY: Direct PNG reference (view-only). Edit PNG in external tool.", 10, 256, 10)
  else
    print_text("Ready. Bank #{$current_bank} | [SAVE] to write #{$save_path}. Hot-reload active.", 10, 256, 6)
  end
  print_text("FPS:#{fps}", 424, 256, 11)

  # 7. コードプレビューモーダル
  if $show_code_modal
    rectfill(30, 20, 420, 230, 0)
    rect(30, 20, 420, 230, 7)
    print_text("--- SPRITE & PALETTE DATA PREVIEW (Click to close) ---", 40, 28, 10)
    preview_text = export_bank_sprites_text($save_path, $current_bank, $sprite_palettes)
    lines = preview_text ? preview_text.split("\n") : []
    18.times do |i|
      break if i >= lines.size
      print_text(lines[i], 40, 44 + i * 10, 6)
    end
    print_text("... (truncated)", 40, 44 + 18 * 10, 5) if lines.size > 18
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

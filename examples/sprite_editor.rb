# ==============================================================================
# 🐰 Usakame Sprite Editor (640x360) — Non-Destructive Pixel Editor 🐢
# ------------------------------------------------------------------------------
# AI やテキストエディタで書いた @SPRITE / @PALETTE / # コメント を一切壊さず、
# 既存スプライトのプレビューとドット打ちだけに特化したエディタです。
#
# 【主な機能】
# - 名前付き (:hero)、サイズ指定 (8x8..48x48)、複数フレーム (---)、絵文字に対応
# - 複数スプライトを左リストで切り替えながら連続編集し、* マークで未保存を確認
# - Ctrl+S のみで非破壊インプレース保存（コメント・空行・ヘッダー・他ブロック完全保持）
# - ドット編集ツール: PEN / FILL / PICKER / ERASER / SELECT (矩形選択＆移動)
# - コピー＆ペースト (Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+A / Del)
# - 反転 (H/V)・90度回転 (R)・1pxシフト (矢印)・グリッド (G)
# - Ctrl+Z のみで Undo / Ctrl+Y または Ctrl+Shift+Z で Redo
# ==============================================================================

config(
  width: 640,
  height: 360,
  scale: 2.0,
  text_size: 8,
  title: "Usakame Sprite Editor"
)

show_mouse(true)

EDIT_BANK = 1
THUMB_BANK = 2

HEX_CHARS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]

COLOR_NAMES = [
  "BLACK", "DARK-BLUE", "PURPLE", "DARK-GREEN",
  "BROWN", "DARK-GRAY", "LIGHT-GRAY", "WHITE",
  "RED", "ORANGE", "YELLOW", "GREEN",
  "BLUE", "INDIGO", "PINK", "PEACH"
]

# ------------------------------------------------------------------------------
# 引数とターゲットファイル解決
# ------------------------------------------------------------------------------
$target_path = "game.rb"
if ARGV && ARGV.size > 0
  ARGV.each do |arg|
    if arg && arg[0] != "-"
      $target_path = arg
      break
    end
  end
end

$save_path = $target_path
tlen = $target_path.size
if tlen >= 3
  suf = $target_path[tlen - 3, 3]
  candidate_spr = nil
  if suf == ".rb"
    candidate_spr = $target_path[0, tlen - 3] + ".spr"
  elsif tlen >= 4 && $target_path[tlen - 4, 4] == ".map"
    candidate_spr = $target_path[0, tlen - 4] + ".spr"
  end
  if candidate_spr && read_file(candidate_spr)
    $save_path = candidate_spr
  end
end

$load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
$is_read_only = is_resource_read_only($load_source) || is_resource_read_only($save_path) || is_resource_read_only($target_path)
$last_target_mtime = file_mtime($save_path)

# ------------------------------------------------------------------------------
# 状態変数
# ------------------------------------------------------------------------------
$sprites = []
$selected_idx = 0
$frame_idx = 0
$list_scroll = 0

$current_tool = :pen   # :pen, :fill, :picker, :eraser, :select
$current_col = 8
$prev_col = 8
$show_grid = true

$anim_playing = false
$anim_timer = 0
$anim_fps = 6

$rect_sel = nil        # [x, y, w, h]
$floating_pixels = nil # [ [col_or_nil, ...], ... ] (h rows x w cols)
$sel_drag_mode = nil   # :creating, :moving, nil
$sel_anchor = [0, 0]
$move_offset = [0, 0]

$clipboard = nil
$clipboard_w = 0
$clipboard_h = 0

$undo_stack = []
$redo_stack = []
$stroke_undo_pushed = false

$palette_cache = {}
$notify_msg = ""
$notify_timer = 0
$ui_tick = 0
$hover_canvas_pos = nil

# レイアウト定数 (640x360)
LIST_X = 6
LIST_Y = 24
LIST_W = 166
LIST_H = 310
LIST_ROW_H = 22
LIST_VISIBLE_ROWS = 13

CANVAS_BOX_X = 180
CANVAS_BOX_Y = 24
CANVAS_BOX_SIZE = 256

RIGHT_X = 446
RIGHT_W = 188

def notify(msg)
  $notify_msg = msg
  $notify_timer = 140
end

# ------------------------------------------------------------------------------
# パース用ユーティリティ (mrubyedge 互換)
# ------------------------------------------------------------------------------
def is_ascii_int?(s)
  return false if s.nil? || s.length == 0
  i = 0
  while i < s.length
    b = s.getbyte(i)
    return false if b < 48 || b > 57
    i += 1
  end
  true
end

def parse_wxh(tok)
  parts = tok.downcase.split("x")
  return nil if parts.size != 2
  return nil unless is_ascii_int?(parts[0]) && is_ascii_int?(parts[1])
  w = parts[0].to_i
  h = parts[1].to_i
  return nil if w <= 0 || h <= 0
  [w, h]
end

def parse_hex_char(ch)
  return nil if ch.nil? || ch.length == 0
  b = ch.getbyte(0)
  return b - 48 if b >= 48 && b <= 57
  return b - 65 + 10 if b >= 65 && b <= 70
  return b - 97 + 10 if b >= 97 && b <= 102
  nil
end

def col_to_hex(col)
  return "." if col.nil? || col < 0 || col > 15
  HEX_CHARS[col]
end

def clone_grid(grid)
  out = []
  y = 0
  while y < grid.size
    row = grid[y]
    new_row = []
    x = 0
    while x < row.size
      new_row << row[x]
      x += 1
    end
    out << new_row
    y += 1
  end
  out
end

def clone_frames(frames)
  out = []
  i = 0
  while i < frames.size
    out << clone_grid(frames[i])
    i += 1
  end
  out
end

def grids_equal?(a, b)
  return false if a.size != b.size
  y = 0
  while y < a.size
    ra = a[y]
    rb = b[y]
    return false if ra.size != rb.size
    x = 0
    while x < ra.size
      return false if ra[x] != rb[x]
      x += 1
    end
    y += 1
  end
  true
end

def frames_equal?(fa, fb)
  return false if fa.size != fb.size
  i = 0
  while i < fa.size
    return false unless grids_equal?(fa[i], fb[i])
    i += 1
  end
  true
end

def truncate_label(s, max_len)
  return s if s.length <= max_len
  s[0, max_len - 1] + "~"
end

def can_fit_slot(used, cid, tw, th)
  sx = cid % 16
  sy = cid / 16
  return false if sx + tw > 16 || sy + th > 16
  dy = 0
  while dy < th
    dx = 0
    while dx < tw
      return false if used[(sy + dy) * 16 + (sx + dx)]
      dx += 1
    end
    dy += 1
  end
  true
end

def find_free_slot(used, tw, th)
  cid = 1
  while cid < 256
    return cid if can_fit_slot(used, cid, tw, th)
    cid += 1
  end
  0
end

def mark_slot_used(used, cid, tw, th)
  sx = cid % 16
  sy = cid / 16
  dy = 0
  while dy < th
    dx = 0
    while dx < tw
      idx = (sy + dy) * 16 + (sx + dx)
      used[idx] = true if idx >= 0 && idx < 256
      dx += 1
    end
    dy += 1
  end
end

# ------------------------------------------------------------------------------
# リソース読み込み & スプライト一覧構築
# ------------------------------------------------------------------------------
def refresh_palette_cache(pal_id)
  cols = []
  c = 0
  while c < 16
    info = get_palette_color(pal_id, c)
    cols << [info[0], info[1], info[2]]
    c += 1
  end
  $palette_cache[pal_id] = cols
end

def palette_rgb(pal_id, col_idx)
  refresh_palette_cache(pal_id) unless $palette_cache.has_key?(pal_id)
  $palette_cache[pal_id][col_idx]
end

def parse_sprite_header(tokens)
  explicit_id = nil
  name = nil
  w = nil
  h = nil
  pal = 0
  inline_tokens = []

  idx = 1
  while idx < tokens.size
    tok = tokens[idx]
    break if tok[0] == "#"
    if idx == 1 && is_ascii_int?(tok)
      explicit_id = tok.to_i
    elsif tok[0] == ":" && !name
      name = tok
    elsif tok.length > 4 && tok[0, 4] == "pal:"
      ps = tok[4, tok.length - 4]
      pal = ps.to_i if is_ascii_int?(ps)
    elsif tok.length > 2 && tok[0, 2] == "p:"
      ps = tok[2, tok.length - 2]
      pal = ps.to_i if is_ascii_int?(ps)
    else
      wh = parse_wxh(tok)
      if wh && !w
        w = wh[0]
        h = wh[1]
      else
        inline_tokens << tok
      end
    end
    idx += 1
  end

  {
    explicit_id: explicit_id,
    name: name,
    w: w,
    h: h,
    pal: pal,
    inline_tokens: inline_tokens,
    raw_frames: []
  }
end

def load_all_sprites
  load_bank(0, $load_source)
  load_resource_palettes($load_source)
  $palette_cache.clear
  refresh_palette_cache(0)

  raw = read_file($load_source) || ""
  lines = raw.split("\n")

  # __END__ がある場合はその次の行からパース (.spr 等は先頭から)
  start_line = 0
  i = 0
  while i < lines.size
    t = lines[i].strip
    if t == "__END__" || (t.length > 7 && t[0, 7] == "__END__" && t[7] == " ")
      start_line = i + 1
      break
    end
    i += 1
  end

  raw_defs = []
  cur = nil
  cur_frame = []
  mode = :none

  i = start_line
  while i < lines.size
    trimmed = lines[i].strip
    if trimmed.length > 0 && trimmed[0] == "@"
      if cur
        cur[:raw_frames] << cur_frame
        raw_defs << cur
        cur = nil
        cur_frame = []
      end
      tokens = trimmed.split(" ")
      if tokens[0] == "@SPRITE"
        cur = parse_sprite_header(tokens)
        cur[:order_idx] = raw_defs.size
        cur_frame = []
        mode = :sprite
      else
        mode = :other
      end
    elsif mode == :sprite && cur
      if trimmed == "---"
        cur[:raw_frames] << cur_frame
        cur_frame = []
      elsif trimmed.length > 0 && trimmed[0] != "#"
        cur_frame << trimmed
      end
    end
    i += 1
  end

  if cur
    cur[:raw_frames] << cur_frame
    raw_defs << cur
  end

  # スロット割り当て (絵文字スプライトのピクセルを Bank 0 から取り出すため)
  used = Array.new(256, false)
  used[0] = true

  raw_defs.each do |d|
    non_empty = []
    d[:raw_frames].each { |fl| non_empty << fl if fl.size > 0 }
    d[:non_empty_frames] = non_empty
    if non_empty.size > 0
      d[:w] = non_empty[0][0].length unless d[:w]
      d[:h] = non_empty[0].size unless d[:h]
      d[:frame_count] = non_empty.size
    else
      d[:w] = 16 unless d[:w]
      d[:h] = 16 unless d[:h]
      fc = d[:inline_tokens].size
      d[:frame_count] = fc > 0 ? fc : 1
    end
  end

  raw_defs.each do |d|
    if d[:explicit_id]
      base = d[:explicit_id]
      tw = (d[:w] + 15) / 16
      th = (d[:h] + 15) / 16
      slots = []
      f = 0
      while f < d[:frame_count]
        sid = base + f
        slots << sid
        mark_slot_used(used, sid, tw, th)
        f += 1
      end
      d[:slots] = slots
    end
  end

  raw_defs.each do |d|
    unless d[:explicit_id]
      tw = (d[:w] + 15) / 16
      th = (d[:h] + 15) / 16
      slots = []
      f = 0
      while f < d[:frame_count]
        sid = find_free_slot(used, tw, th)
        slots << sid
        mark_slot_used(used, sid, tw, th)
        f += 1
      end
      d[:slots] = slots
    end
  end

  $sprites = []
  raw_defs.each_with_index do |d, idx|
    w = d[:w]
    h = d[:h]
    frames = []
    if d[:non_empty_frames].size > 0
      d[:non_empty_frames].each do |raw_rows|
        grid = []
        y = 0
        while y < h
          row_str = y < raw_rows.size ? raw_rows[y] : ""
          row = []
          x = 0
          while x < w
            ch = x < row_str.length ? row_str[x] : "."
            row << parse_hex_char(ch)
            x += 1
          end
          grid << row
          y += 1
        end
        frames << grid
      end
    else
      # インライン絵文字定義: Bank 0 の割り当てスロットから 16x16 ピクセルを読み出す
      d[:slots].each do |sid|
        sx = (sid % 16) * 16
        sy = (sid / 16) * 16
        flat = get_bank_rect(0, sx, sy, w, h)
        grid = []
        y = 0
        while y < h
          row = []
          x = 0
          while x < w
            row << flat[y * w + x]
            x += 1
          end
          grid << row
          y += 1
        end
        frames << grid
      end
    end

    label = d[:name] ? d[:name] : "##{d[:explicit_id] || idx}"
    refresh_palette_cache(d[:pal])
    $sprites << {
      order_idx: d[:order_idx],
      label: label,
      w: w,
      h: h,
      pal: d[:pal],
      is_emoji: d[:non_empty_frames].size == 0,
      frames: frames,
      orig_frames: clone_frames(frames),
      dirty: false
    }
  end

  $selected_idx = 0 if $selected_idx >= $sprites.size
  $frame_idx = 0
  $undo_stack.clear
  $redo_stack.clear
  $rect_sel = nil
  $floating_pixels = nil
  sync_all_thumbnails
  sync_active_sprite_to_edit_bank
end

# ------------------------------------------------------------------------------
# Bank 同期 (高速プレビュー・サムネイル描画用)
# ------------------------------------------------------------------------------
def sync_grid_to_bank(bank_id, bx, by, w, h, grid)
  flat = []
  y = 0
  while y < h
    row = grid[y]
    x = 0
    while x < w
      flat << row[x]
      x += 1
    end
    y += 1
  end
  update_bank_rect(bank_id, bx, by, w, h, flat)
end

def sync_active_sprite_to_edit_bank
  sp = current_sprite
  return unless sp
  # 各フレームを EDIT_BANK の y=0, x=f*64 に転送 (最大48x48まで重ならない)
  f = 0
  while f < sp[:frames].size && f < 4
    sync_grid_to_bank(EDIT_BANK, f * 64, 0, sp[:w], sp[:h], sp[:frames][f])
    f += 1
  end
end

def sync_all_thumbnails
  # サムネイル用に THUMB_BANK へ 16x16 相当の縮小は不要、そのまま左上16x16 または縮小して転送
  i = 0
  while i < $sprites.size && i < 256
    sp = $sprites[i]
    tx = (i % 16) * 16
    ty = (i / 16) * 16
    grid = sp[:frames][0]
    flat = []
    y = 0
    while y < 16
      sy = (y * sp[:h]) / 16
      x = 0
      while x < 16
        sx = (x * sp[:w]) / 16
        flat << grid[sy][sx]
        x += 1
      end
      y += 1
    end
    update_bank_rect(THUMB_BANK, tx, ty, 16, 16, flat)
    i += 1
  end
end

def sync_current_thumbnail
  sp = current_sprite
  return unless sp
  return if $selected_idx >= 256
  tx = ($selected_idx % 16) * 16
  ty = ($selected_idx / 16) * 16
  grid = sp[:frames][0]
  flat = []
  y = 0
  while y < 16
    sy = (y * sp[:h]) / 16
    x = 0
    while x < 16
      sx = (x * sp[:w]) / 16
      flat << grid[sy][sx]
      x += 1
    end
    y += 1
  end
  update_bank_rect(THUMB_BANK, tx, ty, 16, 16, flat)
end

def current_sprite
  return nil if $sprites.empty?
  $sprites[$selected_idx]
end

def current_grid
  sp = current_sprite
  return nil unless sp
  $frame_idx = 0 if $frame_idx >= sp[:frames].size
  sp[:frames][$frame_idx]
end

def refresh_dirty_flag(sp)
  sp[:dirty] = !frames_equal?(sp[:frames], sp[:orig_frames])
end

def any_dirty?
  i = 0
  while i < $sprites.size
    return true if $sprites[i][:dirty]
    i += 1
  end
  false
end

def canvas_geometry(sp)
  max_dim = sp[:w] > sp[:h] ? sp[:w] : sp[:h]
  cell = CANVAS_BOX_SIZE / max_dim
  cell = 1 if cell < 1
  cw = sp[:w] * cell
  ch = sp[:h] * cell
  cx = CANVAS_BOX_X + (CANVAS_BOX_SIZE - cw) / 2
  cy = CANVAS_BOX_Y + (CANVAS_BOX_SIZE - ch) / 2
  [cx, cy, cell, cw, ch]
end

# ------------------------------------------------------------------------------
# Undo / Redo (Ctrl+Z / Ctrl+Y, Ctrl+Shift+Z)
# ------------------------------------------------------------------------------
def push_undo_state
  sp = current_sprite
  return unless sp
  $undo_stack << [$selected_idx, $frame_idx, clone_grid(sp[:frames][$frame_idx])]
  $undo_stack.shift if $undo_stack.size > 50
  $redo_stack.clear
end

def apply_history_snapshot(sp_idx, f_idx, grid_snapshot)
  return if sp_idx < 0 || sp_idx >= $sprites.size
  sp = $sprites[sp_idx]
  return if f_idx < 0 || f_idx >= sp[:frames].size
  $selected_idx = sp_idx
  $frame_idx = f_idx
  sp[:frames][f_idx] = clone_grid(grid_snapshot)
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
end

def perform_undo
  return if $is_read_only
  commit_floating_selection(false) if $floating_pixels
  return if $undo_stack.empty?

  entry = $undo_stack.pop
  sp_idx = entry[0]
  f_idx = entry[1]
  saved_grid = entry[2]

  if sp_idx >= 0 && sp_idx < $sprites.size
    cur_sp = $sprites[sp_idx]
    if f_idx >= 0 && f_idx < cur_sp[:frames].size
      $redo_stack << [sp_idx, f_idx, clone_grid(cur_sp[:frames][f_idx])]
      $redo_stack.shift if $redo_stack.size > 50
    end
  end

  apply_history_snapshot(sp_idx, f_idx, saved_grid)
  sfx(:select, -1, 0.25)
  notify("UNDO")
end

def perform_redo
  return if $is_read_only
  commit_floating_selection(false) if $floating_pixels
  return if $redo_stack.empty?

  entry = $redo_stack.pop
  sp_idx = entry[0]
  f_idx = entry[1]
  redo_grid = entry[2]

  if sp_idx >= 0 && sp_idx < $sprites.size
    cur_sp = $sprites[sp_idx]
    if f_idx >= 0 && f_idx < cur_sp[:frames].size
      $undo_stack << [sp_idx, f_idx, clone_grid(cur_sp[:frames][f_idx])]
      $undo_stack.shift if $undo_stack.size > 50
    end
  end

  apply_history_snapshot(sp_idx, f_idx, redo_grid)
  sfx(:select, -1, 0.25)
  notify("REDO")
end

def revert_current_sprite
  sp = current_sprite
  return unless sp && sp[:dirty] && !$is_read_only
  clear_rect_selection(false)
  push_undo_state
  sp[:frames][$frame_idx] = clone_grid(sp[:orig_frames][$frame_idx])
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  sfx(:select, -1, 0.3)
  notify("REVERTED #{sp[:label]}")
end

# ------------------------------------------------------------------------------
# 範囲選択 & クリップボード操作
# ------------------------------------------------------------------------------
def commit_floating_selection(record_undo = true)
  return unless $floating_pixels && $rect_sel
  sp = current_sprite
  return unless sp
  grid = current_grid
  rx, ry, rw, rh = $rect_sel
  push_undo_state if record_undo

  y = 0
  while y < rh
    py = ry + y
    if py >= 0 && py < sp[:h]
      x = 0
      while x < rw
        px = rx + x
        if px >= 0 && px < sp[:w]
          c = $floating_pixels[y][x]
          grid[py][px] = c if c != nil
        end
        x += 1
      end
    end
    y += 1
  end

  $floating_pixels = nil
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
end

def clear_rect_selection(commit = true)
  commit_floating_selection(false) if commit && $floating_pixels
  $floating_pixels = nil
  $rect_sel = nil
end

def lift_selection_to_floating
  return if $rect_sel.nil? || !$floating_pixels.nil?
  sp = current_sprite
  return unless sp
  grid = current_grid
  rx, ry, rw, rh = $rect_sel
  push_undo_state

  lifted = []
  y = 0
  while y < rh
    row = []
    x = 0
    while x < rw
      px = rx + x
      py = ry + y
      if px >= 0 && px < sp[:w] && py >= 0 && py < sp[:h]
        row << grid[py][px]
        grid[py][px] = nil
      else
        row << nil
      end
      x += 1
    end
    lifted << row
    y += 1
  end

  $floating_pixels = lifted
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
end

def select_all_rect
  sp = current_sprite
  return unless sp
  commit_floating_selection(false) if $floating_pixels
  $current_tool = :select
  $rect_sel = [0, 0, sp[:w], sp[:h]]
  sfx(:select, -1, 0.2)
  notify("SELECT ALL")
end

def copy_selection
  sp = current_sprite
  return unless sp
  grid = current_grid
  if $floating_pixels
    $clipboard = clone_grid($floating_pixels)
    $clipboard_w = $rect_sel[2]
    $clipboard_h = $rect_sel[3]
  elsif $rect_sel
    rx, ry, rw, rh = $rect_sel
    buf = []
    y = 0
    while y < rh
      row = []
      x = 0
      while x < rw
        px = rx + x
        py = ry + y
        row << ((px >= 0 && px < sp[:w] && py >= 0 && py < sp[:h]) ? grid[py][px] : nil)
        x += 1
      end
      buf << row
      y += 1
    end
    $clipboard = buf
    $clipboard_w = rw
    $clipboard_h = rh
  else
    $clipboard = clone_grid(grid)
    $clipboard_w = sp[:w]
    $clipboard_h = sp[:h]
  end
  sfx(:select, -1, 0.2)
  notify("COPIED #{$clipboard_w}x#{$clipboard_h}")
end

def cut_selection
  return if $is_read_only
  sp = current_sprite
  return unless sp
  copy_selection
  if $floating_pixels
    $floating_pixels = nil
    $rect_sel = nil
  elsif $rect_sel
    push_undo_state
    grid = current_grid
    rx, ry, rw, rh = $rect_sel
    y = 0
    while y < rh
      py = ry + y
      if py >= 0 && py < sp[:h]
        x = 0
        while x < rw
          px = rx + x
          grid[py][px] = nil if px >= 0 && px < sp[:w]
          x += 1
        end
      end
      y += 1
    end
    $rect_sel = nil
  else
    push_undo_state
    y = 0
    while y < sp[:h]
      x = 0
      while x < sp[:w]
        current_grid[y][x] = nil
        x += 1
      end
      y += 1
    end
  end
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  notify("CUT")
end

def paste_selection
  return if $is_read_only || $clipboard.nil?
  sp = current_sprite
  return unless sp
  commit_floating_selection(false) if $floating_pixels
  push_undo_state
  $current_tool = :select
  px = $rect_sel ? $rect_sel[0] : 0
  py = $rect_sel ? $rect_sel[1] : 0
  $floating_pixels = clone_grid($clipboard)
  $rect_sel = [px, py, $clipboard_w, $clipboard_h]
  sfx(:select, -1, 0.2)
  notify("PASTED #{$clipboard_w}x#{$clipboard_h}")
end

# ------------------------------------------------------------------------------
# ドット編集操作
# ------------------------------------------------------------------------------
def flood_fill(start_x, start_y, new_col)
  sp = current_sprite
  return unless sp
  grid = current_grid
  return if start_x < 0 || start_x >= sp[:w] || start_y < 0 || start_y >= sp[:h]
  target_col = grid[start_y][start_x]
  return if target_col == new_col

  push_undo_state
  queue = [[start_x, start_y]]
  visited = {}
  while !queue.empty?
    cx, cy = queue.shift
    next if cx < 0 || cx >= sp[:w] || cy < 0 || cy >= sp[:h]
    key = cy * sp[:w] + cx
    next if visited.has_key?(key)
    next if grid[cy][cx] != target_col
    visited[key] = true
    grid[cy][cx] = new_col
    queue << [cx + 1, cy]
    queue << [cx - 1, cy]
    queue << [cx, cy + 1]
    queue << [cx, cy - 1]
  end

  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
end

def flip_active(horizontal)
  return if $is_read_only
  sp = current_sprite
  return unless sp

  if $floating_pixels
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    out = []
    y = 0
    while y < rh
      row = []
      x = 0
      while x < rw
        sx = horizontal ? (rw - 1 - x) : x
        sy = horizontal ? y : (rh - 1 - y)
        row << $floating_pixels[sy][sx]
        x += 1
      end
      out << row
      y += 1
    end
    $floating_pixels = out
    sfx(:select, -1, 0.2)
    return
  end

  push_undo_state
  grid = current_grid
  if $rect_sel
    rx, ry, rw, rh = $rect_sel
    src = clone_grid(grid)
    y = 0
    while y < rh
      x = 0
      while x < rw
        tx = rx + x
        ty = ry + y
        sx = rx + (horizontal ? (rw - 1 - x) : x)
        sy = ry + (horizontal ? y : (rh - 1 - y))
        if tx >= 0 && tx < sp[:w] && ty >= 0 && ty < sp[:h] && sx >= 0 && sx < sp[:w] && sy >= 0 && sy < sp[:h]
          grid[ty][tx] = src[sy][sx]
        end
        x += 1
      end
      y += 1
    end
  else
    src = clone_grid(grid)
    y = 0
    while y < sp[:h]
      x = 0
      while x < sp[:w]
        sx = horizontal ? (sp[:w] - 1 - x) : x
        sy = horizontal ? y : (sp[:h] - 1 - y)
        grid[y][x] = src[sy][sx]
        x += 1
      end
      y += 1
    end
  end

  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  sfx(:select, -1, 0.2)
  notify(horizontal ? "FLIP H" : "FLIP V")
end

def rotate_active_cw
  return if $is_read_only
  sp = current_sprite
  return unless sp

  if $floating_pixels
    rw = $rect_sel[2]
    rh = $rect_sel[3]
    out = []
    nx = 0
    while nx < rw
      row = []
      ny = 0
      while ny < rh
        row << $floating_pixels[rh - 1 - ny][nx]
        ny += 1
      end
      out << row
      nx += 1
    end
    $floating_pixels = out
    $rect_sel = [$rect_sel[0], $rect_sel[1], rh, rw]
    sfx(:select, -1, 0.2)
    return
  end

  if sp[:w] != sp[:h]
    notify("ROTATE ONLY FOR SQUARE OR SELECTION")
    return
  end

  push_undo_state
  grid = current_grid
  src = clone_grid(grid)
  n = sp[:w]
  y = 0
  while y < n
    x = 0
    while x < n
      grid[y][x] = src[n - 1 - x][y]
      x += 1
    end
    y += 1
  end

  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  sfx(:select, -1, 0.2)
  notify("ROTATE 90")
end

def shift_active(dx, dy)
  return if $is_read_only
  sp = current_sprite
  return unless sp

  if $rect_sel
    lift_selection_to_floating if $floating_pixels.nil?
    $rect_sel[0] += dx
    $rect_sel[1] += dy
    sfx(:select, -1, 0.15)
    return
  end

  push_undo_state
  grid = current_grid
  src = clone_grid(grid)
  w = sp[:w]
  h = sp[:h]
  y = 0
  while y < h
    x = 0
    while x < w
      sx = (x - dx) % w
      sy = (y - dy) % h
      grid[y][x] = src[sy][sx]
      x += 1
    end
    y += 1
  end

  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  sfx(:select, -1, 0.15)
end

def clear_active
  return if $is_read_only
  sp = current_sprite
  return unless sp
  if $floating_pixels
    $floating_pixels = nil
    $rect_sel = nil
    notify("CLEARED SELECTION")
    return
  end
  push_undo_state
  grid = current_grid
  if $rect_sel
    rx, ry, rw, rh = $rect_sel
    y = 0
    while y < rh
      py = ry + y
      if py >= 0 && py < sp[:h]
        x = 0
        while x < rw
          px = rx + x
          grid[py][px] = nil if px >= 0 && px < sp[:w]
          x += 1
        end
      end
      y += 1
    end
  else
    y = 0
    while y < sp[:h]
      x = 0
      while x < sp[:w]
        grid[y][x] = nil
        x += 1
      end
      y += 1
    end
  end
  refresh_dirty_flag(sp)
  sync_active_sprite_to_edit_bank
  sync_current_thumbnail
  sfx(:select, -1, 0.2)
  notify("CLEARED")
end

# ------------------------------------------------------------------------------
# 非破壊インプレース保存 (Ctrl+S)
# ------------------------------------------------------------------------------
def save_dirty_sprites
  if $is_read_only
    notify("READ-ONLY: CANNOT SAVE")
    return
  end
  commit_floating_selection(false) if $floating_pixels

  updates = {}
  updated_count = 0
  i = 0
  while i < $sprites.size
    sp = $sprites[i]
    if sp[:dirty]
      frames_text = []
      f = 0
      while f < sp[:frames].size
        grid = sp[:frames][f]
        rows_text = []
        y = 0
        while y < sp[:h]
          line = ""
          x = 0
          while x < sp[:w]
            line += col_to_hex(grid[y][x])
            x += 1
          end
          rows_text << line
          y += 1
        end
        frames_text << rows_text
        f += 1
      end
      updates[sp[:order_idx]] = frames_text
      updated_count += 1
    end
    i += 1
  end

  if updated_count == 0
    notify("NO CHANGES TO SAVE")
    return
  end

  if save_sprite_pixels_in_place($save_path, updates)
    $last_target_mtime = file_mtime($save_path)
    i = 0
    while i < $sprites.size
      sp = $sprites[i]
      if sp[:dirty]
        sp[:orig_frames] = clone_frames(sp[:frames])
        sp[:dirty] = false
        sp[:is_emoji] = false
      end
      i += 1
    end
    sfx(:ok, -1, 0.4)
    notify("SAVED #{updated_count} SPRITE(S) TO #{$save_path}")
  else
    notify("ERROR: FAILED TO SAVE #{$save_path}")
  end
end

# 初回ロード
load_all_sprites

# ------------------------------------------------------------------------------
# 入力処理 (update)
# ------------------------------------------------------------------------------
def hit?(mx, my, x, y, w, h)
  mx >= x && mx < x + w && my >= y && my < y + h
end

def select_sprite(new_idx)
  return if new_idx < 0 || new_idx >= $sprites.size
  return if new_idx == $selected_idx
  commit_floating_selection(false) if $floating_pixels
  $rect_sel = nil
  $selected_idx = new_idx
  $frame_idx = 0
  $anim_playing = false
  sync_active_sprite_to_edit_bank
  sfx(:select, -1, 0.2)
end

def switch_tool(new_tool)
  if $current_tool == :select && new_tool != :select
    clear_rect_selection(true)
  end
  $current_tool = new_tool
  sfx(:select, -1, 0.15)
end

def update
  $ui_tick += 1
  $notify_timer -= 1 if $notify_timer > 0

  # 外部ファイル変更のホットリロード (未保存変更がない場合のみ)
  if $save_path && !any_dirty?
    cur_mtime = file_mtime($save_path)
    if cur_mtime != $last_target_mtime
      $last_target_mtime = cur_mtime
      load_all_sprites
      notify("RELOADED #{$save_path}")
    end
  end

  mx = mouse_x
  my = mouse_y
  ctrl = btn(:ctrl) || btn(:rctrl)
  shift = btn(:shift) || btn(:rshift)

  # 1. 必須ホットキー: Ctrl+S 保存, Ctrl+Z Undo, Ctrl+Y / Ctrl+Shift+Z Redo
  if ctrl
    if btnp(:key_s)
      save_dirty_sprites
      return
    elsif btnp(:key_z)
      if shift
        perform_redo
      else
        perform_undo
      end
      return
    elsif btnp(:key_y)
      perform_redo
      return
    elsif btnp(:key_a)
      select_all_rect
      return
    elsif btnp(:key_c)
      copy_selection
      return
    elsif btnp(:key_x)
      cut_selection
      return
    elsif btnp(:key_v)
      paste_selection
      return
    end
  else
    # 単キーショートカット (S と Z は誤爆防止のため割り当てない)
    switch_tool(:pen) if btnp(:key_b) || btnp(:key_1)
    switch_tool(:fill) if btnp(:key_f) || btnp(:key_2)
    switch_tool(:picker) if btnp(:key_i) || btnp(:key_3)
    switch_tool(:eraser) if btnp(:key_e) || btnp(:key_4)
    switch_tool(:select) if btnp(:key_m) || btnp(:key_5)

    if btnp(:key_g)
      $show_grid = !$show_grid
      sfx(:select, -1, 0.15)
    end
    if btnp(:key_x)
      if $current_col.nil?
        $current_col = $prev_col.nil? ? 8 : $prev_col
      else
        $prev_col = $current_col
        $current_col = nil
      end
      sfx(:select, -1, 0.15)
    end
    flip_active(true) if btnp(:key_h)
    flip_active(false) if btnp(:key_v)
    rotate_active_cw if btnp(:key_r)
    clear_active if btnp(:delete) || btnp(:backspace)
    clear_rect_selection(true) if btnp(:escape) && $rect_sel

    shift_active(-1, 0) if btnp(:left)
    shift_active(1, 0) if btnp(:right)
    shift_active(0, -1) if btnp(:up)
    shift_active(0, 1) if btnp(:down)

    sp = current_sprite
    if sp && sp[:frames].size > 1
      if btnp(:key_space)
        $anim_playing = !$anim_playing
        $anim_timer = 0
      elsif btnp(:comma) || btnp(:pageup)
        commit_floating_selection(false) if $floating_pixels
        $frame_idx = ($frame_idx - 1 + sp[:frames].size) % sp[:frames].size
        $anim_playing = false
      elsif btnp(:period) || btnp(:pagedown)
        commit_floating_selection(false) if $floating_pixels
        $frame_idx = ($frame_idx + 1) % sp[:frames].size
        $anim_playing = false
      end
    end
  end

  # アニメーションプレビュー再生
  sp = current_sprite
  if $anim_playing && sp && sp[:frames].size > 1
    $anim_timer += 1
    step = 60 / $anim_fps
    step = 1 if step < 1
    if $anim_timer >= step
      $anim_timer = 0
      $frame_idx = ($frame_idx + 1) % sp[:frames].size
    end
  end

  # 2. トップバーボタンクリック
  if btnp(:mouse_left)
    return if hit?(mx, my, 360, 3, 58, 15) && (save_dirty_sprites; true)
    if hit?(mx, my, 422, 3, 46, 15)
      perform_undo
      return
    end
    if hit?(mx, my, 472, 3, 46, 15)
      perform_redo
      return
    end
    if hit?(mx, my, 522, 3, 52, 15)
      revert_current_sprite
      return
    end
    if hit?(mx, my, 578, 3, 54, 15)
      $show_grid = !$show_grid
      sfx(:select, -1, 0.15)
      return
    end
  end

  # 3. 左側スプライトリスト
  if hit?(mx, my, LIST_X, LIST_Y, LIST_W, LIST_H)
    wheel = mouse_wheel
    if wheel != 0
      max_scroll = $sprites.size > LIST_VISIBLE_ROWS ? $sprites.size - LIST_VISIBLE_ROWS : 0
      $list_scroll -= wheel > 0 ? 1 : -1
      $list_scroll = 0 if $list_scroll < 0
      $list_scroll = max_scroll if $list_scroll > max_scroll
    end
    if btnp(:mouse_left)
      rel_y = my - (LIST_Y + 18)
      if rel_y >= 0
        row = rel_y / LIST_ROW_H
        idx = $list_scroll + row
        select_sprite(idx) if idx >= 0 && idx < $sprites.size
      end
    end
  end

  # 4. 右側パネル (フレーム切替・ツール・変形・パレット)
  if btnp(:mouse_left)
    # フレームボタン (最大6個表示)
    if sp && sp[:frames].size > 1
      # Play/Pause ボタン
      if hit?(mx, my, RIGHT_X + 128, 30, 52, 14)
        $anim_playing = !$anim_playing
        $anim_timer = 0
        return
      end
      f = 0
      while f < sp[:frames].size && f < 6
        fx = RIGHT_X + 104 + (f % 3) * 26
        fy = 50 + (f / 3) * 16
        if hit?(mx, my, fx, fy, 24, 14)
          commit_floating_selection(false) if $floating_pixels
          $frame_idx = f
          $anim_playing = false
          sfx(:select, -1, 0.15)
          return
        end
        f += 1
      end
    end

    # ツールボタン (5個)
    tools = [:pen, :fill, :picker, :eraser, :select]
    ti = 0
    while ti < tools.size
      bx = RIGHT_X + 6 + ti * 36
      by = 148
      if hit?(mx, my, bx, by, 33, 16)
        switch_tool(tools[ti])
        return
      end
      ti += 1
    end

    # 変形・シフトボタン (2行)
    return if hit?(mx, my, RIGHT_X + 6, 170, 40, 14) && (flip_active(true); true)
    return if hit?(mx, my, RIGHT_X + 50, 170, 40, 14) && (flip_active(false); true)
    return if hit?(mx, my, RIGHT_X + 94, 170, 40, 14) && (rotate_active_cw; true)
    return if hit?(mx, my, RIGHT_X + 138, 170, 44, 14) && (clear_active; true)

    return if hit?(mx, my, RIGHT_X + 6, 188, 40, 14) && (shift_active(-1, 0); true)
    return if hit?(mx, my, RIGHT_X + 50, 188, 40, 14) && (shift_active(1, 0); true)
    return if hit?(mx, my, RIGHT_X + 94, 188, 40, 14) && (shift_active(0, -1); true)
    return if hit?(mx, my, RIGHT_X + 138, 188, 44, 14) && (shift_active(0, 1); true)

    # パレット 16色 (4x4)
    c = 0
    while c < 16
      px = RIGHT_X + 8 + (c % 4) * 44
      py = 222 + (c / 4) * 22
      if hit?(mx, my, px, py, 40, 18)
        $current_col = c
        $prev_col = c
        $current_tool = :pen if $current_tool == :eraser || $current_tool == :picker
        sfx(:select, -1, 0.15)
        return
      end
      c += 1
    end

    # 透明色ボタン
    if hit?(mx, my, RIGHT_X + 8, 312, 172, 18)
      $current_col = nil
      sfx(:select, -1, 0.15)
      return
    end
  end

  # 5. 中央キャンバス操作
  $hover_canvas_pos = nil
  if sp
    cx, cy, cell, cw, ch = canvas_geometry(sp)
    if hit?(mx, my, cx, cy, cw, ch)
      lx = (mx - cx) / cell
      ly = (my - cy) / cell
      if lx >= 0 && lx < sp[:w] && ly >= 0 && ly < sp[:h]
        $hover_canvas_pos = [lx, ly]

        # 右クリックは常にスポイト
        if btnp(:mouse_right) || btn(:mouse_right)
          picked = current_grid[ly][lx]
          $current_col = picked
          $prev_col = picked if picked != nil
          sfx(:select, -1, 0.2) if btnp(:mouse_right)
        end

        if !$is_read_only
          if $current_tool == :select
            if btnp(:mouse_left)
              if $rect_sel && lx >= $rect_sel[0] && lx < $rect_sel[0] + $rect_sel[2] && ly >= $rect_sel[1] && ly < $rect_sel[1] + $rect_sel[3]
                lift_selection_to_floating if $floating_pixels.nil?
                $sel_drag_mode = :moving
                $move_offset = [lx - $rect_sel[0], ly - $rect_sel[1]]
              else
                commit_floating_selection(false) if $floating_pixels
                $sel_drag_mode = :creating
                $sel_anchor = [lx, ly]
                $rect_sel = [lx, ly, 1, 1]
              end
            elsif btn(:mouse_left)
              if $sel_drag_mode == :moving && $rect_sel
                $rect_sel[0] = lx - $move_offset[0]
                $rect_sel[1] = ly - $move_offset[1]
              elsif $sel_drag_mode == :creating
                x0 = $sel_anchor[0] < lx ? $sel_anchor[0] : lx
                y0 = $sel_anchor[1] < ly ? $sel_anchor[1] : ly
                x1 = $sel_anchor[0] > lx ? $sel_anchor[0] : lx
                y1 = $sel_anchor[1] > ly ? $sel_anchor[1] : ly
                $rect_sel = [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
              end
            end
          elsif $current_tool == :fill
            if btnp(:mouse_left)
              flood_fill(lx, ly, $current_col)
              sfx(:select, -1, 0.2)
            end
          elsif $current_tool == :picker
            if btnp(:mouse_left) || btn(:mouse_left)
              picked = current_grid[ly][lx]
              $current_col = picked
              $prev_col = picked if picked != nil
              sfx(:select, -1, 0.2) if btnp(:mouse_left)
            end
          else
            # :pen or :eraser
            draw_val = ($current_tool == :eraser) ? nil : $current_col
            if btnp(:mouse_left)
              $stroke_undo_pushed = false
            end
            if btn(:mouse_left)
              grid = current_grid
              if grid[ly][lx] != draw_val
                if !$stroke_undo_pushed
                  push_undo_state
                  $stroke_undo_pushed = true
                end
                grid[ly][lx] = draw_val
                refresh_dirty_flag(sp)
                sync_active_sprite_to_edit_bank
                sync_current_thumbnail
                $anim_playing = false
              end
            end
          end
        end
      end
    end
  end

  if !btn(:mouse_left)
    $sel_drag_mode = nil
    $stroke_undo_pushed = false
  end
end

# ------------------------------------------------------------------------------
# 描画 (draw)
# ------------------------------------------------------------------------------
def draw_btn(x, y, w, h, label, bg_col, border_col, text_col)
  rectfill(x, y, w, h, bg_col)
  rect(x, y, w, h, border_col)
  tx = x + (w - label.length * 6) / 2
  tx = x + 2 if tx < x + 2
  print_text(label, tx, y + (h - 8) / 2, text_col)
end

def draw_marching_rect(x, y, w, h, tick)
  col = ((tick / 6) % 2 == 0) ? 7 : 0
  rect(x, y, w, h, col)
end

def draw
  cls(0)

  # 1. トップバー
  rectfill(0, 0, 640, 20, 1)
  line(0, 20, 640, 20, 5)
  print_text("SPRITE EDITOR", 8, 6, 7)

  dirty = any_dirty?
  path_lbl = truncate_label($save_path, 26)
  path_lbl += "*" if dirty
  print_text(path_lbl, 108, 6, dirty ? 10 : 6)

  if $is_read_only
    draw_btn(360, 3, 58, 15, "READONLY", 2, 8, 8)
  elsif dirty
    draw_btn(360, 3, 58, 15, "SAVE ^S", 3, 11, 7)
  else
    draw_btn(360, 3, 58, 15, "SAVE ^S", 2, 5, 6)
  end

  draw_btn(422, 3, 46, 15, "UNDO", $undo_stack.empty? ? 1 : 2, $undo_stack.empty? ? 5 : 6, $undo_stack.empty? ? 5 : 7)
  draw_btn(472, 3, 46, 15, "REDO", $redo_stack.empty? ? 1 : 2, $redo_stack.empty? ? 5 : 6, $redo_stack.empty? ? 5 : 7)

  sp = current_sprite
  can_rev = sp && sp[:dirty] && !$is_read_only
  draw_btn(522, 3, 52, 15, "REVERT", can_rev ? 2 : 1, can_rev ? 9 : 5, can_rev ? 10 : 5)
  draw_btn(578, 3, 54, 15, $show_grid ? "GRID:ON" : "GRID:--", $show_grid ? 12 : 1, 6, 7)

  # 2. 左ペイン: スプライト一覧
  rectfill(LIST_X, LIST_Y, LIST_W, LIST_H, 1)
  rect(LIST_X, LIST_Y, LIST_W, LIST_H, 5)
  print_text("SPRITES (#{$sprites.size})", LIST_X + 6, LIST_Y + 5, 7)
  line(LIST_X, LIST_Y + 16, LIST_X + LIST_W, LIST_Y + 16, 5)

  if $sprites.empty?
    print_text("NO @SPRITE FOUND", LIST_X + 14, LIST_Y + 40, 8)
  else
    row = 0
    while row < LIST_VISIBLE_ROWS
      idx = $list_scroll + row
      break if idx >= $sprites.size
      item = $sprites[idx]
      ry = LIST_Y + 18 + row * LIST_ROW_H
      is_sel = (idx == $selected_idx)
      rectfill(LIST_X + 2, ry, LIST_W - 4, LIST_ROW_H - 1, is_sel ? 12 : (row % 2 == 0 ? 1 : 0))
      rect(LIST_X + 2, ry, LIST_W - 4, LIST_ROW_H - 1, 7) if is_sel

      # サムネイル (16x16)
      rectfill(LIST_X + 5, ry + 2, 16, 16, 0)
      if idx < 256
        blt(LIST_X + 5, ry + 2, THUMB_BANK, (idx % 16) * 16, (idx / 16) * 16, 16, 16, 0, 1.0, item[:pal])
      end

      lbl = truncate_label(item[:label], 13)
      print_text(lbl, LIST_X + 25, ry + 3, is_sel ? 7 : 6)
      meta = "#{item[:w]}x#{item[:h]} p#{item[:pal]}"
      meta += " #{item[:frames].size}f" if item[:frames].size > 1
      print_text(meta, LIST_X + 25, ry + 12, 5)
      print_text("*", LIST_X + LIST_W - 12, ry + 6, 10) if item[:dirty]
      row += 1
    end
  end

  # 3. 中央ペイン: ドット編集キャンバス
  rectfill(CANVAS_BOX_X - 2, CANVAS_BOX_Y - 2, CANVAS_BOX_SIZE + 4, CANVAS_BOX_SIZE + 4, 1)
  rect(CANVAS_BOX_X - 2, CANVAS_BOX_Y - 2, CANVAS_BOX_SIZE + 4, CANVAS_BOX_SIZE + 4, 5)

  if sp
    cx, cy, cell, cw, ch = canvas_geometry(sp)
    grid = current_grid
    pal_id = sp[:pal]

    y = 0
    while y < sp[:h]
      x = 0
      while x < sp[:w]
        px = cx + x * cell
        py = cy + y * cell
        c = grid[y][x]
        if c != nil
          rgb = palette_rgb(pal_id, c)
          rectfill_rgb(px, py, cell, cell, rgb[0], rgb[1], rgb[2])
        else
          # 市松模様の透過背景
          bg = ((x + y) % 2 == 0) ? 1 : 0
          rectfill(px, py, cell, cell, bg)
        end
        x += 1
      end
      y += 1
    end

    # フローティング選択中のプレビュー
    if $floating_pixels && $rect_sel
      rx, ry, rw, rh = $rect_sel
      y = 0
      while y < rh
        py = ry + y
        if py >= 0 && py < sp[:h]
          x = 0
          while x < rw
            px = rx + x
            if px >= 0 && px < sp[:w]
              fc = $floating_pixels[y][x]
              if fc != nil
                rgb = palette_rgb(pal_id, fc)
                rectfill_rgb(cx + px * cell, cy + py * cell, cell, cell, rgb[0], rgb[1], rgb[2])
              end
            end
            x += 1
          end
        end
        y += 1
      end
    end

    # グリッド線
    if $show_grid && cell >= 4
      gx = 0
      while gx <= sp[:w]
        line(cx + gx * cell, cy, cx + gx * cell, cy + ch, 5)
        gx += 1
      end
      gy = 0
      while gy <= sp[:h]
        line(cx, cy + gy * cell, cx + cw, cy + gy * cell, 5)
        gy += 1
      end
    end

    # 選択矩形
    if $rect_sel
      rx, ry, rw, rh = $rect_sel
      draw_marching_rect(cx + rx * cell, cy + ry * cell, rw * cell, rh * cell, $ui_tick)
    end

    # ホバーカーソル
    if $hover_canvas_pos
      hx, hy = $hover_canvas_pos
      rect(cx + hx * cell, cy + hy * cell, cell, cell, 7)
    end

    # キャンバス下情報
    info_y = CANVAS_BOX_Y + CANVAS_BOX_SIZE + 8
    info_str = "#{sp[:label]}  #{sp[:w]}x#{sp[:h]}  pal:#{sp[:pal]}"
    info_str += "  F#{$frame_idx + 1}/#{sp[:frames].size}" if sp[:frames].size > 1
    print_text(info_str, CANVAS_BOX_X, info_y, 7)

    if $hover_canvas_pos
      hx, hy = $hover_canvas_pos
      hc = grid[hy][hx]
      hstr = "POS:(#{hx},#{hy}) COL:#{hc.nil? ? '.' : "#{hc}(#{HEX_CHARS[hc]})"}"
      print_text(hstr, CANVAS_BOX_X, info_y + 12, 6)
    else
      print_text("L:DRAW  R:EYEDROPPER  CTRL+Z/Y:UNDO/REDO", CANVAS_BOX_X, info_y + 12, 5)
    end
  end

  # 4. 右ペイン: プレビュー・ツール・パレット
  rectfill(RIGHT_X, 24, RIGHT_W, 112, 1)
  rect(RIGHT_X, 24, RIGHT_W, 112, 5)
  print_text("PREVIEW", RIGHT_X + 6, 30, 7)

  if sp
    # 1x / 2x プレビュー
    rectfill(RIGHT_X + 8, 44, 48, 48, 0)
    rect(RIGHT_X + 8, 44, 48, 48, 5)
    rectfill(RIGHT_X + 62, 44, 36, 36, 0)
    rect(RIGHT_X + 62, 44, 36, 36, 5)

    src_x = ($frame_idx % 4) * 64
    scale_2x = (sp[:w] <= 24 && sp[:h] <= 24) ? 2.0 : 1.0
    blt(RIGHT_X + 8, 44, EDIT_BANK, src_x, 0, sp[:w], sp[:h], 0, scale_2x, sp[:pal])
    blt(RIGHT_X + 62, 44, EDIT_BANK, src_x, 0, sp[:w], sp[:h], 0, 1.0, sp[:pal])

    if sp[:frames].size > 1
      draw_btn(RIGHT_X + 128, 30, 52, 14, $anim_playing ? "PAUSE" : "PLAY", $anim_playing ? 8 : 3, 6, 7)
      f = 0
      while f < sp[:frames].size && f < 6
        fx = RIGHT_X + 104 + (f % 3) * 26
        fy = 50 + (f / 3) * 16
        is_f = (f == $frame_idx)
        draw_btn(fx, fy, 24, 14, "F#{f + 1}", is_f ? 12 : 2, is_f ? 7 : 5, 7)
        f += 1
      end
    else
      print_text("SINGLE FRAME", RIGHT_X + 104, 54, 5)
    end
  end

  # ツールボタン
  rectfill(RIGHT_X, 140, RIGHT_W, 68, 1)
  rect(RIGHT_X, 140, RIGHT_W, 68, 5)
  tool_defs = [
    [:pen, "PEN"],
    [:fill, "FILL"],
    [:picker, "PICK"],
    [:eraser, "ERAS"],
    [:select, "SEL"]
  ]
  ti = 0
  while ti < tool_defs.size
    tid = tool_defs[ti][0]
    tlbl = tool_defs[ti][1]
    bx = RIGHT_X + 6 + ti * 36
    active = ($current_tool == tid)
    draw_btn(bx, 148, 33, 16, tlbl, active ? 12 : 2, active ? 7 : 5, 7)
    ti += 1
  end

  draw_btn(RIGHT_X + 6, 170, 40, 14, "FLIPH", 2, 5, 6)
  draw_btn(RIGHT_X + 50, 170, 40, 14, "FLIPV", 2, 5, 6)
  draw_btn(RIGHT_X + 94, 170, 40, 14, "ROT90", 2, 5, 6)
  draw_btn(RIGHT_X + 138, 170, 44, 14, "CLEAR", 2, 8, 7)

  draw_btn(RIGHT_X + 6, 188, 40, 14, "<-", 2, 5, 6)
  draw_btn(RIGHT_X + 50, 188, 40, 14, "->", 2, 5, 6)
  draw_btn(RIGHT_X + 94, 188, 40, 14, "^", 2, 5, 6)
  draw_btn(RIGHT_X + 138, 188, 44, 14, "v", 2, 5, 6)

  # パレット (読み込み専用)
  pal_id = sp ? sp[:pal] : 0
  rectfill(RIGHT_X, 210, RIGHT_W, 126, 1)
  rect(RIGHT_X, 210, RIGHT_W, 126, 5)
  print_text("PALETTE #{pal_id}", RIGHT_X + 8, 213, 7)
  c = 0
  while c < 16
    px = RIGHT_X + 8 + (c % 4) * 44
    py = 222 + (c / 4) * 22
    rgb = palette_rgb(pal_id, c)
    rectfill_rgb(px, py, 40, 18, rgb[0], rgb[1], rgb[2])
    is_cur = ($current_col == c)
    rect(px, py, 40, 18, is_cur ? 7 : 0)
    rect(px - 1, py - 1, 42, 20, 10) if is_cur
    c += 1
  end
  draw_btn(RIGHT_X + 8, 312, 172, 18, "TRANSPARENT (.) [X]", $current_col.nil? ? 8 : 2, $current_col.nil? ? 7 : 5, 7)

  # 5. 下部ステータスバー
  rectfill(0, 340, 640, 20, 1)
  line(0, 340, 640, 340, 5)
  if $notify_timer > 0 && $notify_msg.length > 0
    print_text($notify_msg, 10, 346, 11)
  elsif $is_read_only
    print_text("READ-ONLY: Direct PNG reference (view-only).", 10, 346, 10)
  else
    col_desc = $current_col.nil? ? "TRANSPARENT (.)" : "#{$current_col} #{COLOR_NAMES[$current_col]}"
    print_text("COL: #{col_desc}  |  B:Pen F:Fill I:Pick E:Eraser M:Select G:Grid", 10, 346, 6)
  end
end

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
CHECKER_PALETTE = 99

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
  $clipboard = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
  $clipboard_w = $edit_w
  $clipboard_h = $edit_h
  sfx(:coin)
  notify("COPIED #{$edit_w}x#{$edit_h}")
end

def paste_selection
  return unless $clipboard
  push_undo
  if $clipboard_w == $edit_w && $clipboard_h == $edit_h
    update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, $clipboard)
  else
    cur = get_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h)
    pw = [$clipboard_w, $edit_w].min
    ph = [$clipboard_h, $edit_h].min
    ph.times do |y|
      pw.times do |x|
        cur[y * $edit_w + x] = $clipboard[y * $clipboard_w + x]
      end
    end
    update_bank_rect($current_bank, $sel_x, $sel_y, $edit_w, $edit_h, cur)
  end
  sfx(:powerup)
  notify("PASTED")
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

# パレット管理
$current_pal = 0
$available_palettes = [0]
$sprite_palettes = {}

def sync_sprite_default_palette
  cur_spr_id = ($sel_x / 16) + ($sel_y / 16) * 16
  def_pal = $sprite_palettes ? $sprite_palettes[cur_spr_id] : nil
  if def_pal
    if $current_pal != def_pal
      $current_pal = def_pal
      notify("PALETTE: P#{$current_pal} (AUTO)")
    end
  end
end

def reload_palettes(source)
  pals = load_resource_palettes(source)
  if pals && !pals.empty?
    $available_palettes = pals
    $current_pal = pals[0] unless $available_palettes.include?($current_pal)
  end
  $sprite_palettes = load_resource_sprite_palettes(source) || {}
  sync_sprite_default_palette
end

def set_selection(gx, gy)
  gx = [[gx, 0].max, 256 - $edit_w].min
  gy = [[gy, 0].max, 256 - $edit_h].min
  if $sel_x != gx || $sel_y != gy
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
  sfx(:click)
  notify("PALETTE: P#{$current_pal}")
end

reload_palettes(load_source)

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

  if save_resource_bank($save_path, $current_bank)
    $last_target_mtime = file_mtime($save_path)
    sfx(:powerup)
    notify("SAVED BANK #{$current_bank} TO #{$save_path}!")
  else
    sfx(:boom)
    notify("ERROR: FAILED TO SAVE #{$save_path}")
  end
end

def export_all
  text = export_bank_sprites_text($save_path, $current_bank)
  puts "\n# =================================================="
  puts "# 🐰 USAKAME BANK DATA (Bank #{$current_bank})"
  puts "# =================================================="
  puts text
  puts "# ==================================================\n"
  sfx(:powerup)
  notify("EXPORTED @SPRITE DATA TO CONSOLE!")
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

# 反転 (選択領域 $edit_w x $edit_h 内)
def flip_canvas(horizontal)
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
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

# 90度回転 (正方形 $edit_w == $edit_h 時のみ)
def rotate_canvas
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
    return
  end
  if $edit_w != $edit_h
    sfx(:boom)
    notify("ROTATE: Square only (#{$edit_w}x#{$edit_h})")
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

# シフト移動 (dx, dy on $edit_w x $edit_h)
def shift_canvas(dx, dy)
  if $is_read_only
    sfx(:boom)
    notify("READ ONLY: Cannot edit PNG-backed bank in editor!")
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
  # --- 外部更新（ホットリロード）の検知 ---
  if $save_path
    cur_mtime = file_mtime($save_path)
    if cur_mtime > 0 && cur_mtime != $last_target_mtime
      $last_target_mtime = cur_mtime
      loaded = load_resource_bank($save_path, $current_bank)
      if loaded && loaded.size == BANK_SIZE * BANK_SIZE
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
  export_all if btnp(:x)
  clear_canvas if btnp(:c) && !btn(:ctrl)
  cycle_size_mode if btnp(:tab)
  toggle_anim if btnp(:space)
  flip_canvas(true) if btnp(:h)
  flip_canvas(false) if btnp(:v)
  rotate_canvas if btnp(:r)
  toggle_onion if btnp(:o)
  cycle_anim_frames(-1) if btnp(:"[")
  cycle_anim_frames(1) if btnp(:"]")

  # Ctrl+C (コピー) / Ctrl+V (貼り付け)
  if btn(:ctrl)
    if btnp(:c)
      copy_selection
    elsif btnp(:v)
      paste_selection
    end
  end

  # パレット切り替え (P / Shift+P)
  if btnp(:p)
    cycle_palette(btn(:shift) ? -1 : 1)
  end

  # ツールショートカット
  $current_tool = :pen if btnp(:b)
  $current_tool = :fill if btnp(:f)
  $current_tool = :eraser if btnp(:e)

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
    gx = ((mx - $minimap_x) / 8) * 16
    gy = ((my - $minimap_y) / 8) * 16
    gx = [[gx, 0].max, 256 - $edit_w].min
    gy = [[gy, 0].max, 256 - $edit_h].min
    set_selection(gx, gy)
  end

  # --- ボタンクリック判定 (mouse_l / mouse_r) ---
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
        spawn_editor("map", $target_path) if respond_to?(:spawn_editor)
        sfx(:click)
      elsif mx >= 392 && mx <= 434 # [ONION]
        toggle_onion
      elsif mx >= 440 && mx <= 476 # [CODE]
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

    # 2.5 パレット切り替え [< P0 >] (y: 66..82)
    if my >= 66 && my <= 82
      if mx >= 266 && mx <= 282 # [<]
        cycle_palette(-1)
      elsif mx >= 310 && mx <= 328 # [>]
        cycle_palette(1)
      end
    end

    # 3. パレットカラー選択 (4x4, x: 220..320, y: 88..188)
    if mx >= 220 && mx < 320 && my >= 88 && my < 188
      col_idx = (mx - 220) / 25
      row_idx = (my - 88) / 25
      if col_idx >= 0 && col_idx < 4 && row_idx >= 0 && row_idx < 4
        $current_col = row_idx * 4 + col_idx
        $current_tool = :pen if $current_tool == :eraser
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

  # --- キャンバス内での描画 & スポイト操作 ---
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + CANVAS_GRID * $cell_size &&
               my >= $canvas_y && my < $canvas_y + CANVAS_GRID * $cell_size)

  if in_canvas
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
              $current_tool = :pen
              sfx(:pickup)
              notify("PICKED: #{picked ? COLOR_NAMES[picked] : 'TRANS'}")
            end
          end
        end
      end
    end
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

  # 背景市松模様
  pal_bank(CHECKER_PALETTE)
  rectfill($canvas_x, $canvas_y, 192, 192, 0)
  8.times do |cy|
    8.times do |cx|
      if (cx + cy) % 2 == 1
        rectfill($canvas_x + cx * 24, $canvas_y + cy * 24, 24, 24, 1)
      end
    end
  end
  pal_bank(0)

  # バンクテクスチャ描画
  blt($canvas_x, $canvas_y, $current_bank, $sel_x, $sel_y, 32, 32, 0, 6.0, $current_pal)

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
  rectfill(190, 224, 24, 18, 1)
  rect(190, 224, 24, 18, 8)
  print_text("CLR", 193, 229, 8)

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

  # パレットヘッダー & [< P0 >] 切替ボタン (y: 66..82)
  print_text("PALETTE", 220, 70, 6)

  # [<] ボタン
  rectfill(268, 66, 14, 14, 2)
  rect(268, 66, 14, 14, 6)
  print_text("<", 273, 69, 7)

  # [P#{$current_pal}] 表示バッジ
  rectfill(284, 66, 26, 14, 1)
  rect(284, 66, 26, 14, 5)
  print_text("P#{$current_pal}", 288, 69, 10)

  # [>] ボタン
  rectfill(312, 66, 14, 14, 2)
  rect(312, 66, 14, 14, 6)
  print_text(">", 317, 69, 7)

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

  # 5. 右ペイン: 256x256 バンクミニマップ (x: 342, y: 38, 幅128x高128)
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
  print_text("Pos:(#{$sel_x},#{$sel_y})  Sprite ##{cur_spr_id} (#{$edit_w}x#{$edit_h})", 342, 172, 10)
  print_text("Right-Click: Eyedropper (Pick Color)", 342, 186, 11)
  print_text("Tab: Size  P: Pal  O: Onion  Space: Anim", 342, 200, 5)
  print_text("Ctrl+C/V: Copy/Paste  H/V: Flip  R: Rot", 342, 214, 5)
  print_text("Ctrl+Arrows: Move  Arrows: Shift px", 342, 228, 5)

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
    print_text("--- SPRITE DATA PREVIEW (Click anywhere to close) ---", 40, 28, 10)
    preview_text = export_bank_sprites_text($save_path, $current_bank)
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
# @PALETTE 99: 市松模様背景用 (Aseprite / EDGE 風ライトグレー)
# 黒のアウトラインや濃色の視認性を高め、PICO-8カラーと衝突しない無彩色グレー
@PALETTE 99
0: #C0C0C0
1: #E0E0E0

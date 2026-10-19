# ==============================================================================
# 🐰 Usakame Sample: High-Resolution Tilemap Editor (タイルマップエディタ) 🐢
# ------------------------------------------------------------------------------
# 32x32 のタイルマップを直感的に作成・編集・保存できる高解像度ツールです。
#
# 【特徴】
# - 高解像度UI (480x270): 広々とした 320x240 キャンバスと使いやすい右側パネル
# - 外部ファイル自動連携:
#     uk run examples/tilemap_editor.rb -- game.rb
#     uk run examples/tilemap_editor.rb -- game.map
# - 安全な非破壊保存:
#     game.rb を指定した場合でも、game.rb 本体を壊さず自動的に game.map を生成・保存。
#     ゲーム側（uk run game.rb）が自動でホットリロードされ、リアルタイムに反映！
# - スプライトエディタとの相互同期:
#     スプライトエディタで game.spr を保存すると、タイルマップエディタが自動検知して
#     タイルスプライトをリアルタイム更新！
# - [SAVE] (Ctrl+S / S): ターゲットファイルに即座に書き込み
# ==============================================================================

config(
  width: 480,
  height: 270,
  window_scale: 2.0,
  title: "Usakame Tilemap Editor"
)

# OS 標準マウスカーソルを非表示にし、ゲーム内カーソルを使用
show_mouse(false)

# ------------------------------------------------------------------------------
# 定数 & 初期設定
# ------------------------------------------------------------------------------
MAP_WIDTH  = 32
MAP_HEIGHT = 32
NUM_TILES  = 16

# キャンバス表示領域 (320 x 240 px)
VIEW_X = 8
VIEW_Y = 22
VIEW_W = 320
VIEW_H = 240

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
$rect_drag = nil   # 矩形ツールのドラッグ始点 [start_tx, start_ty, rect_tid]

$undo_stack = []   # アンドゥ用履歴スタック
$notify_msg = ""   # 通知メッセージ
$notify_timer = 0

$show_code_modal = false
$modal_tab = :map  # :map, :sprite, :all
$modal_scroll = 0
$cached_export_text = ""

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
  suf = $target_path[tlen - 3, 3]
  if suf == ".rb"
    $save_path = $target_path[0, tlen - 3] + ".map"
  end
end

$spr_path = nil
if tlen >= 3
  suf = $target_path[tlen - 3, 3]
  if suf == ".rb"
    $spr_path = $target_path[0, tlen - 3] + ".spr"
  elsif suf == "map"
    $spr_path = $target_path[0, tlen - 4] + ".spr"
  end
end

$custom_sprites = Array.new(NUM_TILES, nil)
$last_spr_mtime = 0

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

# 外部スプライトの再読み込み
def reload_custom_sprites
  return if $spr_path.nil?
  cur_mtime = file_mtime($spr_path)
  return if cur_mtime == 0
  $last_spr_mtime = cur_mtime

  slots = load_resource_sprites($spr_path, NUM_TILES)
  count = 0
  slots.each_with_index do |sgrid, sid|
    if sgrid
      $custom_sprites[sid] = sgrid
      count += 1
    end
  end
  if count > 0
    notify("SYNCED #{count} SPRITES FROM #{$spr_path}")
  end
end

# サンプルマップ初期化（見本ダンジョン）
def init_sample_map
  MAP_HEIGHT.times do |y|
    MAP_WIDTH.times do |x|
      if x == 0 || x == MAP_WIDTH - 1 || y == 0 || y == MAP_HEIGHT - 1
        $map[y * MAP_WIDTH + x] = 1 # レンガ壁
      end
    end
  end

  10.times { |i| $map[8 * MAP_WIDTH + (5 + i)] = 1 }
  8.times  { |i| $map[(8 + i) * MAP_WIDTH + 14] = 1 }
  $map[8 * MAP_WIDTH + 10] = 13 # 扉

  (12..16).each do |y|
    (3..7).each do |x|
      $map[y * MAP_WIDTH + x] = 4
    end
  end

  (2..6).each do |y|
    (20..28).each do |x|
      $map[y * MAP_WIDTH + x] = 3
    end
  end
  $map[3 * MAP_WIDTH + 22] = 6
  $map[4 * MAP_WIDTH + 26] = 6
  $map[5 * MAP_WIDTH + 23] = 6

  (18..24).each do |y|
    (18..26).each do |x|
      $map[y * MAP_WIDTH + x] = 5
    end
  end

  (10..22).each { |y| $map[y * MAP_WIDTH + 10] = 7 }
  (10..18).each { |x| $map[22 * MAP_WIDTH + x] = 7 }

  (12..15).each { |y| $map[y * MAP_WIDTH + 14] = 9 }

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

# 起動時の読み込み
load_source = ($save_path != $target_path && read_file($save_path)) ? $save_path : $target_path
loaded_tiles = load_resource_map(load_source, MAP_WIDTH, MAP_HEIGHT)

if loaded_tiles && loaded_tiles.size == MAP_WIDTH * MAP_HEIGHT
  $map = loaded_tiles
  notify("LOADED MAP FROM #{load_source}")
else
  init_sample_map
  notify("TARGET: #{$target_path} (SAMPLE MAP)")
end

# スプライトの初期ロード
reload_custom_sprites

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
# テキストエクスポート & 保存
# ------------------------------------------------------------------------------
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

def save_map_file
  content = generate_map_text + "\n"
  if save_file($save_path, content)
    sfx(:powerup)
    notify("SAVED TO #{$save_path}")
    puts "[Tilemap Editor] Successfully saved map to #{$save_path}"
  else
    sfx(:boom)
    notify("ERROR SAVING TO #{$save_path}")
  end
end

def export_map_only
  puts "\n# =================================================="
  puts "# 🐰 USAKAME @MAP DATA (Copy & paste below __END__)"
  puts "# =================================================="
  puts generate_map_text
  puts "# ==================================================\n"
  sfx(:pickup)
  notify("EXPORTED @MAP TO CONSOLE!")
end

# ------------------------------------------------------------------------------
# タイルドット描画 (カスタムスプライトまたは内蔵スプライト)
# ------------------------------------------------------------------------------
def draw_tile_at(tid, px, py, scale = 1.0)
  return if tid <= 0
  custom = $custom_sprites[tid]
  if custom
    # カスタムスプライト配列 (256要素) から描画
    if scale == 1.0
      16.times do |sy|
        16.times do |sx|
          c = custom[sy * 16 + sx]
          pset(px + sx, py + sy, c) if c
        end
      end
    else
      # 8x8 縮小表示
      8.times do |sy|
        8.times do |sx|
          c = custom[(sy * 2) * 16 + (sx * 2)]
          pset(px + sx, py + sy, c) if c
        end
      end
    end
  else
    # 内蔵スプライト
    spr(tid, px, py, false, false, 0, scale)
  end
end

# ------------------------------------------------------------------------------
# 更新処理 (update)
# ------------------------------------------------------------------------------
def update
  mx = mouse_x
  my = mouse_y

  $notify_timer = [$notify_timer - 1, 0].max

  # 外部スプライトの更新チェック (60フレームごと等にタイムスタンプを監視)
  if $spr_path && ($notify_timer % 30 == 0)
    cur_mtime = file_mtime($spr_path)
    if cur_mtime > 0 && cur_mtime != $last_spr_mtime
      reload_custom_sprites
    end
  end

  # --- キーボードショートカット ---
  # 保存: Ctrl+S または S (モーダル外)
  if (btn(:ctrl) && btnp(:s)) || (!btn(:ctrl) && btnp(:s) && !$show_code_modal)
    save_map_file
  end

  perform_undo if btnp(:z)
  export_map_only if btnp(:e)
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
  $current_tool = :pen    if btnp(:key_1)
  $current_tool = :rect   if btnp(:key_2)
  $current_tool = :fill   if btnp(:key_3)
  $current_tool = :picker if btnp(:key_4)

  # スクロール (矢印キー / WASD)
  scroll_speed = ($cell_size == 16) ? 1 : 2
  $cam_x -= scroll_speed if btn(0) # left
  $cam_x += scroll_speed if btn(1) # right
  $cam_y -= scroll_speed if btn(2) # up
  $cam_y += scroll_speed if btn(3) # down

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
      # 閉じるボタン (x: 430..460, y: 16..30)
      if mx >= 430 && mx <= 460 && my >= 16 && my <= 30
        $show_code_modal = false
        sfx(:click)
      # [EXPORT TO CONSOLE] (x: 32..160, y: 236..252)
      elsif mx >= 32 && mx <= 160 && my >= 236 && my <= 252
        export_map_only
      # [SAVE] (x: 168..240, y: 236..252)
      elsif mx >= 168 && mx <= 240 && my >= 236 && my <= 252
        save_map_file
      # モーダル外クリックで閉じる
      elsif mx < 20 || mx > 460 || my < 12 || my > 256
        $show_code_modal = false
      end
    end

    if wheel > 0.2
      $modal_scroll = [$modal_scroll - 3, 0].max
    elsif wheel < -0.2
      $modal_scroll += 3
    end
    return
  end

  # --- UI クリック判定 ---
  if btnp(:mouse_l)
    # 1. タイルパレット (x: 336..464, y: 96..192) - 4x4 グリッド (各 32x24 px)
    if mx >= 336 && mx < 464 && my >= 96 && my < 192
      col = ((mx - 336) / 32).to_i
      row = ((my - 96) / 24).to_i
      if col >= 0 && col < 4 && row >= 0 && row < 4
        tid = row * 4 + col
        if tid < NUM_TILES
          $selected_tile = tid
          sfx(:select)
        end
      end
    end

    # 2. ミニマップクリック (x: 336..400, y: 24..88) -> カメラジャンプ
    if mx >= 336 && mx < 400 && my >= 24 && my < 88
      jump_tx = ((mx - 336) / 2).to_i
      jump_ty = ((my - 24) / 2).to_i
      $cam_x = jump_tx - (max_tiles_x / 2)
      $cam_y = jump_ty - (max_tiles_y / 2)
      $cam_x = [[$cam_x, 0].max, MAP_WIDTH - max_tiles_x].min
      $cam_y = [[$cam_y, 0].max, MAP_HEIGHT - max_tiles_y].min
      sfx(:cursor)
    end

    # 3. ツールボタン 行1 (y: 200..216)
    if my >= 200 && my <= 216
      # [PEN] (x: 336..356)
      if mx >= 336 && mx <= 356
        $current_tool = :pen; sfx(:click)
      # [RECT] (x: 360..382)
      elsif mx >= 360 && mx <= 382
        $current_tool = :rect; sfx(:click)
      # [FILL] (x: 386..408)
      elsif mx >= 386 && mx <= 408
        $current_tool = :fill; sfx(:click)
      # [PICK] (x: 412..434)
      elsif mx >= 412 && mx <= 434
        $current_tool = :picker; sfx(:click)
      # [ZOOM] (x: 438..472)
      elsif mx >= 438 && mx <= 472
        $cell_size = ($cell_size == 16) ? 8 : 16
        sfx(:click)
        notify("ZOOM: #{$cell_size}px")
      end
    end

    # 4. アクションボタン 行2 (y: 222..238)
    if my >= 222 && my <= 238
      # [SAVE] (x: 336..368)
      if mx >= 336 && mx <= 368
        save_map_file
      # [UNDO] (x: 372..400)
      elsif mx >= 372 && mx <= 400
        perform_undo
      # [GRID] (x: 404..434)
      elsif mx >= 404 && mx <= 434
        $show_grid = !$show_grid
        sfx(:click)
        notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
      # [CODE] (x: 438..472)
      elsif mx >= 438 && mx <= 472
        $show_code_modal = true
        $modal_scroll = 0
        sfx(:click)
      end
    end

    # 5. アクションボタン 行3 (y: 244..258)
    if my >= 244 && my <= 258
      # [EXP] (x: 336..376)
      if mx >= 336 && mx <= 376
        export_map_only
      # [CLEAR] (x: 382..422)
      elsif mx >= 382 && mx <= 422
        clear_map
      # [RELOAD SPR] (x: 426..472)
      elsif mx >= 426 && mx <= 472
        reload_custom_sprites
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
          stx = $rect_drag[0]
          sty = $rect_drag[1]
          rect_tid = $rect_drag[2]
          apply_rect(stx, sty, tx, ty, rect_tid)
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

  # --- 1. ヘッダーバー (y: 0..18) ---
  rectfill(0, 0, 480, 18, 1)
  line(0, 18, 480, 18, 5)
  print_text("🗺️ USAKAME TILEMAP EDITOR", 8, 5, 10)

  cur_info = TILE_INFO[$selected_tile]
  print_text("TILE:#{$selected_tile}:#{cur_info[1]}", 170, 5, 7)
  print_text("CAM:(#{$cam_x},#{$cam_y})", 260, 5, 6)
  print_text("TARGET: #{$save_path}", 340, 5, 11)

  # --- 2. メインタイルマップキャンバス (320x240) ---
  rectfill(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 0)
  rect(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 5)

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
        draw_tile_at(tid, draw_px, draw_py, scale)
      else
        half = $cell_size / 2
        rectfill(draw_px, draw_py, half, half, 0)
        rectfill(draw_px + half, draw_py, half, half, 1)
        rectfill(draw_px, draw_py + half, half, half, 1)
        rectfill(draw_px + half, draw_py + half, half, half, 0)
      end

      if $show_grid
        line(draw_px, draw_py + $cell_size - 1, draw_px + $cell_size - 1, draw_py + $cell_size - 1, 0)
        line(draw_px + $cell_size - 1, draw_py, draw_px + $cell_size - 1, draw_py + $cell_size - 1, 0)
      end
    end
  end

  # 矩形プレビュー枠
  if $rect_drag
    stx = $rect_drag[0]
    sty = $rect_drag[1]
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
    rect(rx, ry, rw, rh, 10)
  end

  # マウスカーソル枠
  mx = mouse_x
  my = mouse_y
  if mx >= VIEW_X && mx < VIEW_X + VIEW_W && my >= VIEW_Y && my < VIEW_Y + VIEW_H
    htx = ((mx - VIEW_X) / $cell_size).to_i
    hty = ((my - VIEW_Y) / $cell_size).to_i
    hx = VIEW_X + htx * $cell_size
    hy = VIEW_Y + hty * $cell_size
    rect(hx, hy, $cell_size, $cell_size, 7)
  end

  clip()

  # --- 3. 右側パネル: ミニマップ & タイルパレット ---
  # ミニマップ (x: 336, y: 24, w: 64, h: 64)
  rectfill(335, 23, 66, 66, 1)
  rect(335, 23, 66, 66, 5)

  MAP_HEIGHT.times do |my_tile|
    MAP_WIDTH.times do |mx_tile|
      tid = get_tile(mx_tile, my_tile)
      col = TILE_INFO[tid][2]
      rectfill(336 + mx_tile * 2, 24 + my_tile * 2, 2, 2, col)
    end
  end

  # ミニマップ上のカメラ表示枠
  cam_vw = (VIEW_W / $cell_size).to_i * 2
  cam_vh = (VIEW_H / $cell_size).to_i * 2
  rect(336 + $cam_x * 2, 24 + $cam_y * 2, cam_vw, cam_vh, 7)

  # パレットヘッダー
  print_text("TILES (4x4)", 336, 92, 6)

  # 4x4 タイルグリッド (x: 336..464, y: 102..192) - 各 32x22 px
  4.times do |row|
    4.times do |col|
      tid = row * 4 + col
      bx = 336 + col * 32
      by = 104 + row * 22
      rectfill(bx, by, 30, 20, 1)

      if tid == 0
        rect(bx + 1, by + 1, 14, 14, 5)
        line(bx + 3, by + 3, bx + 11, by + 11, 8)
        line(bx + 3, by + 11, bx + 11, by + 3, 8)
      else
        draw_tile_at(tid, bx + 1, by + 2, 1.0)
      end

      # ID表示
      print_text(tid.to_s, bx + 18, by + 6, (tid == $selected_tile) ? 10 : 6)

      # 選択ハイライト枠
      if tid == $selected_tile
        rect(bx - 1, by - 1, 32, 22, 10)
      else
        rect(bx - 1, by - 1, 32, 22, 5)
      end
    end
  end

  # --- 4. ツールボタン & アクションボタン ---
  # 行1: ツール [PEN] [RECT] [FILL] [PICK] [ZOOM]
  tool_buttons = [
    [:pen,    "PEN",  336, 200, 22],
    [:rect,   "RCT",  360, 200, 24],
    [:fill,   "FIL",  386, 200, 24],
    [:picker, "PCK",  412, 200, 24]
  ]
  tool_buttons.each do |tb|
    t_id = tb[0]
    t_name = tb[1]
    t_x = tb[2]
    t_y = tb[3]
    t_w = tb[4]
    active = ($current_tool == t_id)
    rectfill(t_x, t_y, t_w, 14, active ? 8 : 1)
    rect(t_x, t_y, t_w, 14, active ? 7 : 5)
    print_text(t_name, t_x + 3, t_y + 3, active ? 7 : 6)
  end

  # [ZOOM] (x: 438..472)
  rectfill(438, 200, 34, 14, ($cell_size == 8) ? 9 : 1)
  rect(438, 200, 34, 14, ($cell_size == 8) ? 10 : 5)
  print_text(($cell_size == 16) ? "16P" : "8PX", 442, 203, 7)

  # 行2: アクション [SAVE] [UNDO] [GRID] [CODE]
  # [SAVE]
  rectfill(336, 220, 34, 16, 11)
  rect(336, 220, 34, 16, 7)
  print_text("SAVE", 340, 224, 0)

  # [UNDO]
  rectfill(372, 220, 30, 16, 1)
  rect(372, 220, 30, 16, 5)
  print_text("UNDO", 375, 224, 7)

  # [GRID]
  rectfill(404, 220, 30, 16, $show_grid ? 3 : 1)
  rect(404, 220, 30, 16, $show_grid ? 11 : 5)
  print_text("GRID", 408, 224, 7)

  # [CODE]
  rectfill(438, 220, 34, 16, 1)
  rect(438, 220, 34, 16, 5)
  print_text("CODE", 442, 224, 7)

  # 行3: [EXP] [CLEAR] [SYNC]
  rectfill(336, 242, 38, 14, 1)
  rect(336, 242, 38, 14, 5)
  print_text("EXP", 346, 245, 7)

  rectfill(378, 242, 38, 14, 1)
  rect(378, 242, 38, 14, 5)
  print_text("CLR", 388, 245, 8)

  rectfill(420, 242, 52, 14, 1)
  rect(420, 242, 52, 14, 5)
  print_text("SYNC", 432, 245, 12)

  # --- 5. 通知メッセージ ---
  if $notify_timer > 0
    nw = $notify_msg.size * 6 + 12
    nx = 8
    ny = 246
    rectfill(nx, ny, nw, 14, 0)
    rect(nx, ny, nw, 14, 10)
    print_text($notify_msg, nx + 6, ny + 3, 10)
  end

  # --- 6. コードプレビューモーダル ---
  if $show_code_modal
    rectfill(20, 10, 440, 250, 0)
    rect(20, 10, 440, 250, 7)
    rect(22, 12, 436, 246, 1)

    print_text("📋 CODE PREVIEW - @MAP DATA", 32, 18, 10)

    # 閉じるボタン
    rectfill(430, 16, 22, 12, 8)
    rect(430, 16, 22, 12, 7)
    print_text("X", 438, 18, 7)

    # コード表示ボックス
    rectfill(30, 34, 420, 196, 0)
    rect(30, 34, 420, 196, 5)

    clip(32, 36, 416, 192)
    export_lines = generate_map_text.split("\n")
    start_line = $modal_scroll
    visible_count = 19
    visible_count.times do |i|
      idx = start_line + i
      if idx < export_lines.size
        print_text(export_lines[idx], 36, 38 + i * 10, 7)
      end
    end
    clip()

    # モーダル下部ボタン
    rectfill(32, 236, 120, 16, 1)
    rect(32, 236, 120, 16, 7)
    print_text("EXPORT CONSOLE", 38, 240, 7)

    rectfill(160, 236, 80, 16, 11)
    rect(160, 236, 80, 16, 7)
    print_text("SAVE MAP", 172, 240, 0)
  end

  # --- 7. マウスカーソル ---
  cx = mouse_x
  cy = mouse_y
  line(cx, cy, cx + 6, cy + 6, 7)
  line(cx, cy, cx, cy + 8, 7)
  line(cx, cy, cx + 8, cy, 7)
  pset(cx, cy, 0)
end

__END__
# 1: レンガ壁
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

# 2: 土
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

# 3: 草
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

# 4: 水
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

# 5: 石畳
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

# 6: 木
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

# 7: 砂
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

# 8: トゲ
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

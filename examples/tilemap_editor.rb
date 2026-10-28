# ==============================================================================
# 🐰 Usakame Sample: High-Resolution Tilemap Editor (タイルマップエディタ) 🐢
# ------------------------------------------------------------------------------
# 32x32 のタイルマップを直感的に作成・編集・保存できる高解像度ツールです。
#
# 【特徴】
# - 高解像度UI (480x270): 広々とした 320x240 キャンバスと使いやすい右側パネル
# - 256x256 バンク完全対応:
#     16x16 (計256個) のタイルスプライトを右側パレットに常時一覧表示・ドラッグ選択可能！
# - 超高速レンダリング (60 FPS):
#     ミニマップのテクスチャキャッシュ化・背景市松模様 & グリッドの一括描画により
#     描画負荷を極小化し常時 60 FPS を維持。
# - 外部ファイル自動連携:
#     uk run examples/tilemap_editor.rb -- game.rb
#     uk run examples/tilemap_editor.rb -- game.map
# - 安全な非破壊保存:
#     game.rb を指定した場合でも、game.rb 本体を壊さず自動的に game.map を生成・保存。
#     ゲーム側（uk run game.rb）が自動でホットリロードされ、リアルタイムに反映！
# - スプライトエディタとの相互同期:
#     スプライトエディタで保存すると、タイルマップエディタが自動検知して
#     タイルスプライトをリアルタイム更新！
# - [SAVE] (Ctrl+S): ターゲットファイルに即座に書き込み
# ==============================================================================

config(
  width: 640,
  height: 360,
  scale: 2.0,
  text_size: 8,
  title: "Usakame Tilemap Editor"
)

# OS 標準マウスカーソルを使用
show_mouse(true)

# ------------------------------------------------------------------------------
# 定数 & 初期設定
# ------------------------------------------------------------------------------
MAP_WIDTH  = 32
MAP_HEIGHT = 32
MINIMAP_BANK = 127 # ミニマップ高速描画用バンク

# キャンバス表示領域 (352 x 320 px = 22 x 20 タイル)
VIEW_X = 8
VIEW_Y = 22
VIEW_W = 352
VIEW_H = 320

# パレット表示領域の最大寸法 (等倍 16x16 px)
PAL_X = 368
PAL_Y = 96
PAL_MAX_W = 256
PAL_MAX_H = 192

# タイル情報定義 [ID, 名前, 代表色] (デフォルト16種)
TILE_INFO = [
  [0,  "TILE_0", 1],
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

# オブジェクトモード時の背景地形減光パレット (16色それぞれの暗色対応テーブル)
TERRAIN_DIM_PAL = [0, 0, 1, 1, 2, 1, 5, 5, 2, 4, 4, 3, 1, 1, 2, 4]

def tile_name(tid)
  if tid.nil? || tid < 0
    "EMPTY"
  elsif tid < TILE_INFO.size && TILE_INFO[tid]
    TILE_INFO[tid][1]
  else
    "T_#{tid}"
  end
end

def tile_color(tid)
  if tid.nil? || tid < 0
    0
  elsif tid < TILE_INFO.size && TILE_INFO[tid]
    TILE_INFO[tid][2]
  else
    (tid % 15) + 1
  end
end

# ------------------------------------------------------------------------------
# グローバル状態
# ------------------------------------------------------------------------------
$map = Array.new(MAP_WIDTH * MAP_HEIGHT, nil)
$objects = []         # オブジェクト一覧 [{ type: "apple", x: 48, y: 48, spr: "🍎", ... }]
$minimap_dirty = true # ミニマップ再生成フラグ

$current_mode = :terrain    # :terrain or :objects
$grid_snap = 16            # 16, 8, 1 (FREE)
$selected_obj_idx = nil    # 選択中の配置済みオブジェクト
$dragging_obj_idx = nil    # ドラッグ中のオブジェクト
$drag_offset_x = 0
$drag_offset_y = 0
$drag_start_x = 0
$drag_start_y = 0
$drag_moved = false

$obj_palette_tab = :chip   # :chip or :emoji (デフォルトは :chip)

# 絵文字パレット 256選 (4カテゴリ × 64個 = 256個)
# 注意: mrubyedge のリテラルプール上限 (256) を超えて EXT2 命令が出力されるのを防ぐため、
# カテゴリ毎の文字列を split して構築します。
_EMOJI_CAT1 = (
  "🌲 🌳 🌴 🌵 🌾 🌿 ☘️ 🍀 🍁 🍂 🍃 🍄 🌰 🌸 🌺 🌻 " \
  "🌱 🪵 🪨 🧱 🏔️ ⛰️ 🌋 🏕️ 🏖️ 🏜️ 🏝️ 🏞️ 🌊 💧 🔥 ✨ " \
  "🏠 🏡 🏢 🏣 🏥 🏦 🏨 🏪 🏫 🏭 🏯 🏰 💒 🗼 ⛪ ⛩️ " \
  "☀️ 🌤️ ⛅ ☁️ 🌧️ ⛈️ 🌩️ 🌨️ ❄️ ⛄ ⚡ 🌈 🌌 🌙 ⭐ 🌍"
)
_EMOJI_CAT2 = (
  "🚪 🪟 🪜 🛤️ 🛣️ 🌉 ⛲ 🗿 ⛺ 🎪 💈 🏛️ 🏗️ 🏚️ ⚓ ♨️ " \
  "🪑 🛏️ 🛋️ 🪞 🧰 🏺 ⚱️ 📦 🎁 📜 📖 📚 🏷️ ✉️ 🧺 🪔 " \
  "🕯️ 💡 🏮 🔦 🧭 ⌛ ⏳ ⏰ 🔔 🚩 🏁 🎌 🏴 🏳️ 🛑 🚧 " \
  "💬 💭 🗯️ ⚠️ ⛔ 🚫 ❓ ❗ 💤 💢 💥 🎯 🎲 ♟️ 🏆 🎖️"
)
_EMOJI_CAT3 = (
  "💎 💍 👑 🪙 💰 💴 💵 💶 🗝️ 🔑 🔮 🧿 📿 🥇 🥈 🥉 " \
  "🗡️ ⚔️ 🏹 🛡️ 🪓 ⛏️ 🔨 🔧 🪚 🪛 💣 🧨 🔫 🧲 🪄 🥊 " \
  "🧪 🧫 🧬 🩺 💊 🩹 ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🌟 💫 " \
  "🍎 🍏 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🍒 🍑 🍍 🥥 🥝 🍅 🥕"
)
_EMOJI_CAT4 = (
  "🐰 🐢 🐱 🐶 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 " \
  "🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 " \
  "🕷️ 🦂 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐊 " \
  "👤 🧝 🧙 🧛 🧟 🧞 🧜 🧚 👼 👾 🤖 👻 💀 👹 👺 🤡"
)
EMOJI_PALETTE = (_EMOJI_CAT1 + " " + _EMOJI_CAT2 + " " + _EMOJI_CAT3 + " " + _EMOJI_CAT4).split(" ")
$selected_emoji_idx = 0 # デフォルト "🌲"

$sheet_w = 256
$sheet_h = 256
$sheet_cols = 16
$sheet_rows = 16
$num_tiles = 256
$pal_scroll_y = 0     # パレットの縦スクロールオフセット (px)

$cam_x = 0           # カメラ原点 (タイル単位)
$cam_y = 0
$selected_tile = 0       # 地形モード選択中タイルID (0..255)
$selected_obj_chip = 10  # オブジェクトモード選択中チップID (0..255)
$current_tool = :pen # :pen, :rect, :fill, :picker
$cell_size = 16      # 16 or 8
$show_grid = true    # グリッド線の表示
$rect_drag = nil     # 矩形ツールのドラッグ始点 [start_tx, start_ty, rect_tid]

$undo_stack = []     # アンドゥ用履歴スタック
$notify_msg = ""     # 通知メッセージ
$notify_timer = 0

$show_code_modal = false
$modal_scroll = 0

def update_bank_dimensions
  sz = bank_size($ref_bank)
  if sz && sz.size >= 2
    $sheet_w = sz[0].to_i
    $sheet_h = sz[1].to_i
  else
    $sheet_w = 256
    $sheet_h = 256
  end
  $sheet_cols = [($sheet_w / 16).to_i, 1].max
  $sheet_rows = [($sheet_h / 16).to_i, 1].max
  $num_tiles = $sheet_cols * $sheet_rows
  $pal_scroll_y = 0
end

# ------------------------------------------------------------------------------
# ターゲットファイル検出 & 初期ロード
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
$ref_bank = 0

if ARGV && ARGV.size > 0 && ARGV[0]
  if is_numeric_arg?(ARGV[0])
    $ref_bank = ARGV[0].to_i
  else
    $target_path = ARGV[0]
  end
end
if ARGV && ARGV.size > 1 && ARGV[1]
  $ref_bank = ARGV[1].to_i
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

$last_spr_mtime = 0

def snap_floor(v, step)
  return v if step <= 1
  (v / step).to_i * step
end

def notify(msg)
  $notify_msg = msg
  $notify_timer = 120
end

def clone_objects_list(list)
  return [] if list.nil?
  list.map { |o| o.dup }
end

def format_obj_props(obj, include_spr = true)
  return "" if obj.nil?
  parts = []
  obj.each do |k, v|
    next if k == :type || k == :x || k == :y
    next if !include_spr && k == :spr
    next if v.nil?
    if v.is_a?(String)
      parts << "#{k}=\"#{v}\""
    else
      parts << "#{k}=#{v}"
    end
  end
  parts.join(" ")
end

def push_undo
  $undo_stack << {
    map: $map.dup,
    objects: clone_objects_list($objects)
  }
  $undo_stack.shift if $undo_stack.size > 20
end

def sync_tilemap_to_engine
  MAP_HEIGHT.times do |y|
    MAP_WIDTH.times do |x|
      mset(x, y, get_tile(x, y))
    end
  end
end

def perform_undo
  return if $undo_stack.empty?
  state = $undo_stack.pop
  if state.is_a?(Hash)
    $map = state[:map]
    $objects = clone_objects_list(state[:objects])
  else
    $map = state
  end
  $selected_obj_idx = nil
  $dragging_obj_idx = nil
  sync_tilemap_to_engine
  $minimap_dirty = true
  sfx(:click)
  notify("UNDO")
end

def get_tile(tx, ty)
  return nil if tx < 0 || tx >= MAP_WIDTH || ty < 0 || ty >= MAP_HEIGHT
  $map[ty * MAP_WIDTH + tx]
end

def set_tile(tx, ty, tid)
  return if tx < 0 || tx >= MAP_WIDTH || ty < 0 || ty >= MAP_HEIGHT
  idx = ty * MAP_WIDTH + tx
  if $map[idx] != tid
    $map[idx] = tid
    mset(tx, ty, tid)
    $minimap_dirty = true
  end
end

# タイルIDを1文字表記に変換 (空/nil/負数: '.', 0..9: '0'..'9', 10..15: 'A'..'F')
def tile_to_char(tid)
  if tid.nil? || tid < 0
    "."
  elsif tid < 10
    tid.to_s
  elsif tid < 16
    ("A".ord + (tid - 10)).chr
  else
    "?"
  end
end

# ミニマップテクスチャ更新 (変更時のみ一括更新)
def update_minimap_cache
  return unless $minimap_dirty
  $minimap_dirty = false
  pixels = Array.new(MAP_WIDTH * MAP_HEIGHT)
  MAP_HEIGHT.times do |my|
    MAP_WIDTH.times do |mx|
      tid = get_tile(mx, my)
      pixels[my * MAP_WIDTH + mx] = tile_color(tid)
    end
  end
  update_bank_rect(MINIMAP_BANK, 0, 0, MAP_WIDTH, MAP_HEIGHT, pixels)
end

# 外部スプライト／バンクの再読み込み (減色処理を行わずフルカラーRGBAのままバンクへ直接ロード)
def reload_custom_sprites
  if $spr_path && read_file($spr_path)
    cur_mtime = file_mtime($spr_path)
    if cur_mtime > 0
      $last_spr_mtime = cur_mtime
    end
  end

  src = ($spr_path && read_file($spr_path)) ? $spr_path : $target_path
  if load_bank($ref_bank, src)
    notify("SYNCED BANK #{$ref_bank} FROM #{src}")
  end
  update_bank_dimensions
  $minimap_dirty = true
end

def switch_ref_bank(bank_id)
  return if bank_id < 0
  $ref_bank = bank_id
  spr_bank($ref_bank)
  map_bank($ref_bank)
  reload_custom_sprites
  notify("SWITCHED TO BANK #{$ref_bank}")
end

# サンプルマップ初期化（見本ダンジョン）
def init_sample_map
  $map = Array.new(MAP_WIDTH * MAP_HEIGHT, nil)
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
  $minimap_dirty = true
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

loaded_objs = load_resource_objects(load_source)
if loaded_objs && !loaded_objs.empty?
  $objects = loaded_objs
  first_chip = $objects.find { |o| o[:spr].is_a?(Integer) && o[:spr] > 0 }
  $selected_obj_chip = first_chip[:spr] if first_chip
end
sync_tilemap_to_engine
$minimap_dirty = true

# スプライト & バンクの初期ロード
spr_bank($ref_bank)
map_bank($ref_bank)
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
  $minimap_dirty = true
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
  $minimap_dirty = true
  sfx(:click)
end

# マップ全消去
def clear_map
  push_undo
  $map = Array.new(MAP_WIDTH * MAP_HEIGHT, nil)
  sync_tilemap_to_engine
  $minimap_dirty = true
  sfx(:boom)
  notify("CLEARED MAP")
end

# ------------------------------------------------------------------------------
# テキストエクスポート & 保存
# ------------------------------------------------------------------------------
def generate_map_text
  has_large_tiles = $map.any? { |tid| tid && tid >= 16 }
  lines = ["@MAP 0 0"]
  MAP_HEIGHT.times do |y|
    row_tokens = []
    MAP_WIDTH.times do |x|
      tid = get_tile(x, y)
      if has_large_tiles
        row_tokens << (tid.nil? ? "." : tid.to_s)
      else
        row_tokens << tile_to_char(tid)
      end
    end
    lines << (has_large_tiles ? row_tokens.join(" ") : row_tokens.join(""))
  end

  if $objects && !$objects.empty?
    lines << ""
    lines << "@OBJECTS"
    lines << "# type x y [properties]"
    $objects.each do |obj|
      line_parts = [obj[:type].to_s, obj[:x].to_i.to_s, obj[:y].to_i.to_s]
      obj.each do |k, v|
        next if k == :type || k == :x || k == :y
        next if v.nil?
        v_str = v.to_s
        if v.is_a?(String)
          line_parts << "#{k}=\"#{v_str}\""
        else
          line_parts << "#{k}=#{v_str}"
        end
      end
      lines << line_parts.join(" ")
    end
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
# タイル描画 (バンクテクスチャから直接転送)
# ------------------------------------------------------------------------------
def draw_tile_at(tid, px, py, scale = 1.0)
  return if tid.nil? || tid < 0
  cols = ($sheet_cols && $sheet_cols > 0) ? $sheet_cols : 16
  u = (tid % cols) * 16
  v = (tid / cols) * 16
  blt(px, py, $ref_bank, u, v, 16, 16, 0, scale)
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
  # 保存: Ctrl+S (モーダル外)
  if btn(:ctrl) && btnp(:s) && !$show_code_modal
    save_map_file
  end

  # アンドゥ: Ctrl+Z (モーダル外)
  if btn(:ctrl) && btnp(:z) && !$show_code_modal
    perform_undo
  end

  # Tab: モード切替 (TERRAIN ⇔ OBJECTS)
  if btnp(:tab)
    $current_mode = ($current_mode == :terrain) ? :objects : :terrain
    sfx(:select)
    notify("MODE: #{$current_mode.to_s.upcase}")
  end

  # Delete / Backspace: 選択中オブジェクトの削除
  if (btnp(:del) || btnp(:backspace)) && $current_mode == :objects && $selected_obj_idx
    push_undo
    $objects.delete_at($selected_obj_idx)
    $selected_obj_idx = nil
    $dragging_obj_idx = nil
    sfx(:boom)
    notify("DELETED OBJECT")
  end

  # 1..4: ツール切り替え (地形モード時)
  if $current_mode == :terrain
    $current_tool = :pen    if btnp(:key_1)
    $current_tool = :rect   if btnp(:key_2)
    $current_tool = :fill   if btnp(:key_3)
    $current_tool = :picker if btnp(:key_4)
  end

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

  cur_sheet_w = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 256 : $sheet_w
  cur_sheet_h = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 256 : $sheet_h
  cur_cols = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 16 : $sheet_cols
  cur_rows = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 16 : $sheet_rows
  pal_w = [cur_sheet_w, PAL_MAX_W].min
  pal_h = [cur_sheet_h, PAL_MAX_H].min
  max_pal_scroll = [cur_sheet_h - pal_h, 0].max

  in_palette = (mx >= PAL_X && mx < PAL_X + pal_w && my >= PAL_Y && my < PAL_Y + pal_h)

  # マウスホイール: パレット上ならパレット縦スクロール、それ以外はタイル/チップ切り替え
  wheel = mouse_wheel
  if in_palette && max_pal_scroll > 0
    if wheel > 0.2
      $pal_scroll_y = [$pal_scroll_y - 16, 0].max
      sfx(:cursor)
    elsif wheel < -0.2
      $pal_scroll_y = [$pal_scroll_y + 16, max_pal_scroll].min
      sfx(:cursor)
    end
  elsif wheel > 0.2
    if $current_mode == :terrain
      $selected_tile = ($selected_tile - 1) % $num_tiles
    elsif $obj_palette_tab == :chip
      $selected_obj_chip = ($selected_obj_chip - 1) % $num_tiles
    else
      $selected_emoji_idx = ($selected_emoji_idx - 1) % EMOJI_PALETTE.size
    end
    sfx(:cursor)
  elsif wheel < -0.2
    if $current_mode == :terrain
      $selected_tile = ($selected_tile + 1) % $num_tiles
    elsif $obj_palette_tab == :chip
      $selected_obj_chip = ($selected_obj_chip + 1) % $num_tiles
    else
      $selected_emoji_idx = ($selected_emoji_idx + 1) % EMOJI_PALETTE.size
    end
    sfx(:cursor)
  end

  # --- コードモーダル表示中の操作 ---
  if $show_code_modal
    if btnp(:mouse_l)
      # 閉じるボタン (x: 580..610, y: 16..30)
      if mx >= 580 && mx <= 610 && my >= 16 && my <= 30
        $show_code_modal = false
        sfx(:click)
      # [EXPORT TO CONSOLE] (x: 32..160, y: 310..328)
      elsif mx >= 32 && mx <= 160 && my >= 310 && my <= 328
        export_map_only
      # [SAVE] (x: 168..240, y: 310..328)
      elsif mx >= 168 && mx <= 240 && my >= 310 && my <= 328
        save_map_file
      # モーダル外クリックで閉じる
      elsif mx < 20 || mx > 620 || my < 12 || my > 346
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

  # --- パレット上でのドラッグ・クリック選択 (等倍 16x16 px) ---
  if in_palette && (btn(:mouse_l) || btn(:mouse_r))
    col = ((mx - PAL_X) / 16).to_i
    row = ((my - PAL_Y + $pal_scroll_y) / 16).to_i
    if col >= 0 && col < cur_cols && row >= 0 && row < cur_rows
      if $current_mode == :terrain
        tid = row * cur_cols + col
        if tid < $num_tiles && $selected_tile != tid
          $selected_tile = tid
          sfx(:select)
        end
      elsif $current_mode == :objects && $obj_palette_tab == :chip
        tid = row * cur_cols + col
        if tid < $num_tiles && ($selected_obj_chip != tid || !$selected_obj_idx.nil?)
          $selected_obj_chip = tid
          $selected_obj_idx = nil
          sfx(:select)
        end
      elsif $current_mode == :objects && $obj_palette_tab == :emoji
        eidx = row * 16 + col
        if eidx >= 0 && eidx < EMOJI_PALETTE.size && ($selected_emoji_idx != eidx || !$selected_obj_idx.nil?)
          $selected_emoji_idx = eidx
          $selected_obj_idx = nil
          sfx(:select)
          notify("EMOJI: #{EMOJI_PALETTE[eidx]}")
        end
      end
    end
  end

  # パレットスクロールバーのクリック/ドラッグ判定
  if max_pal_scroll > 0 && btn(:mouse_l)
    sb_x = PAL_X + pal_w + 3
    if mx >= sb_x && mx <= sb_x + 8 && my >= PAL_Y && my <= PAL_Y + pal_h
      ratio = (my - PAL_Y).to_f / pal_h.to_f
      $pal_scroll_y = (ratio * max_pal_scroll).to_i.clamp(0, max_pal_scroll)
    end
  end

  # --- UI クリック判定 ---
  if btnp(:mouse_l)
    # ヘッダーバーでのモード切替 & スナップ切替 (y: 2..16)
    if my >= 2 && my <= 16
      # [TERRAIN] (x: 80..136)
      if mx >= 80 && mx <= 136
        $current_mode = :terrain
        sfx(:click)
        notify("MODE: TERRAIN")
      # [OBJECTS] (x: 142..198)
      elsif mx >= 142 && mx <= 198
        $current_mode = :objects
        sfx(:click)
        notify("MODE: OBJECTS")
      # [GRID] (地形) または [SNAP] (オブジェクト) (x: 204..264)
      elsif mx >= 204 && mx <= 264
        if $current_mode == :terrain
          $show_grid = !$show_grid
          sfx(:click)
          notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
        else
          $grid_snap = ($grid_snap == 16) ? 8 : (($grid_snap == 8) ? 1 : 16)
          sfx(:click)
          notify("SNAP: #{$grid_snap == 1 ? 'FREE' : "#{$grid_snap}PX"}")
        end
      # [SPR] スプライトエディタ起動 (x: 520..568)
      elsif mx >= 520 && mx <= 568
        spawn_editor("spr", $target_path) if respond_to?(:spawn_editor)
        sfx(:click)
        notify("OPENED SPRITE EDITOR")
      end
    end

    # 0. バンク切替ボタン (x: 442..500, y: 64..78)
    if my >= 64 && my <= 78
      if mx >= 442 && mx <= 458
        switch_ref_bank([$ref_bank - 1, 0].max)
        sfx(:click)
      elsif mx >= 484 && mx <= 500
        switch_ref_bank($ref_bank + 1)
        sfx(:click)
      end
    end

    # 1. ミニマップクリック (x: 368..434, y: 22..88) -> カメラジャンプ
    if mx >= 368 && mx < 434 && my >= 22 && my < 88
      jump_tx = ((mx - 368) / 2).to_i
      jump_ty = ((my - 22) / 2).to_i
      $cam_x = jump_tx - (max_tiles_x / 2)
      $cam_y = jump_ty - (max_tiles_y / 2)
      $cam_x = [[$cam_x, 0].max, MAP_WIDTH - max_tiles_x].min
      $cam_y = [[$cam_y, 0].max, MAP_HEIGHT - max_tiles_y].min
      sfx(:cursor)
    end

    # 2. 地形モード時: ツールボタン 行1 (y: 300..314)
    if $current_mode == :terrain && my >= 300 && my <= 314
      # [PEN] (x: 368..390)
      if mx >= 368 && mx <= 390
        $current_tool = :pen; sfx(:click)
      # [RECT] (x: 394..416)
      elsif mx >= 394 && mx <= 416
        $current_tool = :rect; sfx(:click)
      # [FILL] (x: 420..442)
      elsif mx >= 420 && mx <= 442
        $current_tool = :fill; sfx(:click)
      # [PICK] (x: 446..468)
      elsif mx >= 446 && mx <= 468
        $current_tool = :picker; sfx(:click)
      # [ZOOM] (x: 472..500)
      elsif mx >= 472 && mx <= 500
        $cell_size = ($cell_size == 16) ? 8 : 16
        sfx(:click)
        notify("ZOOM: #{$cell_size}px")
      end
    end

    # 2-B. オブジェクトモード時のパレット・インスペクタ操作
    if $current_mode == :objects
      # パレットタブ切替 (y: 80..92)
      if my >= 80 && my <= 92
        if mx >= 368 && mx <= 430
          $obj_palette_tab = :chip; sfx(:click)
        elsif mx >= 434 && mx <= 500
          $obj_palette_tab = :emoji; sfx(:click)
        end
      end

      # インスペクタ行の [DEL] ボタン操作 (y: 300..314)
      if $selected_obj_idx && $selected_obj_idx < $objects.size
        if my >= 300 && my <= 314 && mx >= 368 && mx <= 390
          push_undo
          $objects.delete_at($selected_obj_idx)
          $selected_obj_idx = nil
          $dragging_obj_idx = nil
          sfx(:boom)
          notify("DELETED OBJECT")
        end
      end
    end

    # 3. アクションボタン 行2 (y: 320..334)
    if my >= 320 && my <= 334
      # [SAVE] (x: 368..390)
      if mx >= 368 && mx <= 390
        save_map_file
      # [UNDO] (x: 394..418)
      elsif mx >= 394 && mx <= 418
        perform_undo
      # [GRID] (x: 422..444)
      elsif mx >= 422 && mx <= 444
        if $current_mode == :objects
          $grid_snap = ($grid_snap == 16) ? 8 : (($grid_snap == 8) ? 1 : 16)
          sfx(:click)
          notify("SNAP: #{$grid_snap == 1 ? 'FREE' : "#{$grid_snap}PX"}")
        else
          $show_grid = !$show_grid
          sfx(:click)
          notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
        end
      # [CODE] (x: 448..470)
      elsif mx >= 448 && mx <= 470
        $show_code_modal = true
        $modal_scroll = 0
        sfx(:click)
      # [CLR] (x: 474..500)
      elsif mx >= 474 && mx <= 500
        if $current_mode == :objects
          if !$objects.empty?
            push_undo
            $objects.clear
            $selected_obj_idx = nil
            sfx(:boom)
            notify("CLEARED OBJECTS")
          end
        else
          clear_map
        end
      end
    end
  end

  # --- キャンバス内での描画 & 操作 ---
  in_canvas = (mx >= VIEW_X && mx < VIEW_X + VIEW_W &&
               my >= VIEW_Y && my < VIEW_Y + VIEW_H)

  if in_canvas
    scale = ($cell_size == 16) ? 1.0 : 0.5
    world_x = ($cam_x * 16 + (mx - VIEW_X) / scale).to_i
    world_y = ($cam_y * 16 + (my - VIEW_Y) / scale).to_i

    if $current_mode == :terrain
      tx = $cam_x + ((mx - VIEW_X) / $cell_size).to_i
      ty = $cam_y + ((my - VIEW_Y) / $cell_size).to_i

      if tx >= 0 && tx < MAP_WIDTH && ty >= 0 && ty < MAP_HEIGHT
        case $current_tool
        when :pen
          is_l = btn(:mouse_l)
          is_r = btn(:mouse_r)
          if is_l || is_r
            draw_tid = is_l ? $selected_tile : nil
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
            $rect_drag = [tx, ty, btnp(:mouse_l) ? $selected_tile : nil]
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
            flood_fill_tile(tx, ty, nil)
          end

        when :picker
          if btnp(:mouse_l) || btnp(:mouse_r)
            picked = get_tile(tx, ty)
            if picked && picked >= 0
              $selected_tile = picked
              $current_tool = :pen
              sfx(:select)
              notify("PICKED TILE: #{picked}")
            end
          end
        end
      end

    elsif $current_mode == :objects
      # マウスボタン解放時: ドラッグ終了
      if !btn(:mouse_l) && $dragging_obj_idx
        $dragging_obj_idx = nil
        $drag_moved = false
      end

      # オブジェクトモード時の操作
      # スナップ座標の計算 (常にセル左上基準の snap_floor に統一)
      snap_x = snap_floor(world_x, $grid_snap)
      snap_y = snap_floor(world_y, $grid_snap)

      # 1. 左クリック押下時: オブジェクト選択 または 新規配置
      if btnp(:mouse_l)
        hit_idx = nil
        i = $objects.size - 1
        while i >= 0
          o = $objects[i]
          ow = o[:w] || 16
          oh = o[:h] || 16
          if world_x >= o[:x] && world_x < o[:x] + ow && world_y >= o[:y] && world_y < o[:y] + oh
            hit_idx = i
            break
          end
          i -= 1
        end

        if hit_idx
          $selected_obj_idx = hit_idx
          $dragging_obj_idx = hit_idx
          if $grid_snap > 1
            $drag_offset_x = snap_x - snap_floor($objects[hit_idx][:x], $grid_snap)
            $drag_offset_y = snap_y - snap_floor($objects[hit_idx][:y], $grid_snap)
          else
            $drag_offset_x = world_x - $objects[hit_idx][:x]
            $drag_offset_y = world_y - $objects[hit_idx][:y]
          end
          $drag_start_x = snap_x
          $drag_start_y = snap_y
          $drag_moved = false
          sfx(:select)
          notify("SEL: #{$objects[hit_idx][:type].to_s.upcase}")
        else
          # 空白クリックで新規オブジェクト配置
          push_undo
          new_obj = nil
          if $obj_palette_tab == :chip
            new_obj = { type: "chip_#{$selected_obj_chip}", x: snap_x, y: snap_y, spr: $selected_obj_chip }
          else
            emoji_ch = EMOJI_PALETTE[$selected_emoji_idx]
            new_obj = { type: "obj", x: snap_x, y: snap_y, spr: emoji_ch }
          end

          if new_obj
            $objects << new_obj
            $selected_obj_idx = $objects.size - 1
            $dragging_obj_idx = $selected_obj_idx
            $drag_offset_x = 0
            $drag_offset_y = 0
            $drag_start_x = snap_x
            $drag_start_y = snap_y
            $drag_moved = true
            sfx(:jump)
            notify("PLACED #{new_obj[:type].to_s.upcase}")
          end
        end

      # 2. ドラッグ移動中 (クリックしたセルから実際に動いたときのみ座標を更新)
      elsif btn(:mouse_l) && $dragging_obj_idx && $dragging_obj_idx < $objects.size
        if !$drag_moved && (snap_x != $drag_start_x || snap_y != $drag_start_y)
          push_undo
          $drag_moved = true
        end
        if $drag_moved
          tx = snap_x - $drag_offset_x
          ty = snap_y - $drag_offset_y
          tx = [[tx, 0].max, MAP_WIDTH * 16 - 16].min
          ty = [[ty, 0].max, MAP_HEIGHT * 16 - 16].min
          $objects[$dragging_obj_idx][:x] = tx
          $objects[$dragging_obj_idx][:y] = ty
        end

      # 3. 右クリック押下時: オブジェクト削除
      elsif btnp(:mouse_r)
        hit_idx = nil
        i = $objects.size - 1
        while i >= 0
          o = $objects[i]
          ow = o[:w] || 16
          oh = o[:h] || 16
          if world_x >= o[:x] && world_x < o[:x] + ow && world_y >= o[:y] && world_y < o[:y] + oh
            hit_idx = i
            break
          end
          i -= 1
        end
        if hit_idx
          push_undo
          $objects.delete_at(hit_idx)
          $selected_obj_idx = nil
          $dragging_obj_idx = nil
          sfx(:boom)
          notify("DELETED OBJECT")
        end
      end
    end
  else
    if !btn(:mouse_l) && !btn(:mouse_r) && $rect_drag
      $rect_drag = nil
    end
    if !btn(:mouse_l) && $dragging_obj_idx
      $dragging_obj_idx = nil
    end
  end
end

# ------------------------------------------------------------------------------
# 描画処理 (draw)
# ------------------------------------------------------------------------------
def draw
  cls(0)

  # --- 1. ヘッダーバー (y: 0..18, 幅 640) ---
  rectfill(0, 0, 640, 18, 1)
  line(0, 18, 640, 18, 5)
  print_text("🗺️ USAKAME", 8, 5, 10)

  # [TERRAIN] / [OBJECTS] モード切替タブ
  is_terr = ($current_mode == :terrain)
  rectfill(80, 3, 56, 12, is_terr ? 11 : 2)
  rect(80, 3, 56, 12, is_terr ? 7 : 5)
  print_text("TERRAIN", 86, 5, is_terr ? 0 : 6)

  rectfill(142, 3, 56, 12, !is_terr ? 10 : 2)
  rect(142, 3, 56, 12, !is_terr ? 7 : 5)
  print_text("OBJECTS", 148, 5, !is_terr ? 0 : 6)

  # [GRID] (地形) または [SNAP] (オブジェクト) ボタン
  if is_terr
    grid_label = $show_grid ? "GRID:ON" : "GRID:OFF"
    rectfill(204, 3, 60, 12, $show_grid ? 3 : 1)
    rect(204, 3, 60, 12, $show_grid ? 11 : 5)
    print_text(grid_label, 212, 5, $show_grid ? 7 : 6)
  else
    snap_label = ($grid_snap == 1) ? "FREE" : "#{$grid_snap}PX"
    rectfill(204, 3, 60, 12, ($grid_snap > 1) ? 3 : 2)
    rect(204, 3, 60, 12, ($grid_snap > 1) ? 11 : 5)
    print_text("S:#{snap_label}", 212, 5, 7)
  end

  print_text("CAM:(#{$cam_x},#{$cam_y})", 274, 5, 6)
  print_text("TARGET: #{$save_path}", 360, 5, 11)

  # [SPR] スプライトエディタ起動ボタン
  rectfill(520, 3, 48, 12, 12)
  rect(520, 3, 48, 12, 7)
  print_text("SPRITE", 526, 5, 7)

  print_text("FPS:#{fps}", 580, 5, 10)

  # --- 2. メインタイルマップキャンバス (352x320) ---
  rectfill(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 0)
  rect(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 5)

  clip(VIEW_X, VIEW_Y, VIEW_W, VIEW_H)

  tiles_x = (VIEW_W / $cell_size).to_i + 1
  tiles_y = (VIEW_H / $cell_size).to_i + 1
  scale = ($cell_size == 16) ? 1.0 : 0.5

  # 背景の市松模様を一括描画 (オブジェクトモード時は一段暗くする)
  checker_col = ($current_mode == :objects) ? 0 : 1
  if checker_col > 0
    11.times do |cy|
      by = VIEW_Y + cy * 30
      12.times do |cx|
        if (cx + cy) % 2 == 1
          rectfill(VIEW_X + cx * 32, by, 32, 30, checker_col)
        end
      end
    end
  end

  # タイル描画 (フルカラーテクスチャを保持するため減色パレット変換を行わず直接描画)
  if $cell_size == 16
    map($cam_x, $cam_y, VIEW_X, VIEW_Y, tiles_x, tiles_y, $ref_bank)
  else
    tiles_y.times do |dy|
      ty = $cam_y + dy
      next if ty >= MAP_HEIGHT
      draw_py = VIEW_Y + dy * $cell_size
      tiles_x.times do |dx|
        tx = $cam_x + dx
        next if tx >= MAP_WIDTH

        tid = get_tile(tx, ty)
        if tid
          draw_tile_at(tid, VIEW_X + dx * $cell_size, draw_py, scale)
        end
      end
    end
  end

  # グリッド線の一括描画
  if $show_grid
    (tiles_x + 1).times do |dx|
      gx = VIEW_X + dx * $cell_size
      line(gx, VIEW_Y, gx, VIEW_Y + VIEW_H, 0)
    end
    (tiles_y + 1).times do |dy|
      gy = VIEW_Y + dy * $cell_size
      line(VIEW_X, gy, VIEW_X + VIEW_W, gy, 0)
    end
  end

  # --- オブジェクトレイヤー描画 ---
  if $objects
    $objects.each_with_index do |obj, idx|
      ox = VIEW_X + ((obj[:x] - $cam_x * 16) * scale).to_i
      oy = VIEW_Y + ((obj[:y] - $cam_y * 16) * scale).to_i
      ow = ((obj[:w] || 16) * scale).to_i
      oh = ((obj[:h] || 16) * scale).to_i

      next if ox + ow < VIEW_X || ox > VIEW_X + VIEW_W || oy + oh < VIEW_Y || oy > VIEW_Y + VIEW_H

      is_selected = ($current_mode == :objects && $selected_obj_idx == idx)

      if obj[:spr].is_a?(Integer) && obj[:spr] >= 0
        draw_tile_at(obj[:spr], ox, oy, scale)
      elsif obj[:spr].is_a?(String) && !obj[:spr].empty?
        spr(obj[:spr], ox, oy, false, false, 0, scale)
      else
        # スプライトなし（ゾーンやポイント）
        rectfill(ox, oy, ow, oh, 1)
        rect(ox, oy, ow, oh, 9)
        lbl = obj[:type].to_s[0, 4].upcase
        print_text(lbl, ox + 2, oy + 2, 10)
      end

      # 選択ハイライト枠 & オブジェクト目印枠
      if is_selected
        rect(ox - 1, oy - 1, ow + 2, oh + 2, 10)
        rect(ox - 2, oy - 2, ow + 4, oh + 4, 7)
      elsif $current_mode == :objects
        rect(ox, oy, ow, oh, 9)
        rectfill(ox, oy, 3, 3, 10)
      else
        c_len = [ow / 4, 3].max
        line(ox, oy, ox + c_len, oy, 9)
        line(ox, oy, ox, oy + c_len, 9)
        line(ox + ow - 1 - c_len, oy, ox + ow - 1, oy, 9)
        line(ox + ow - 1, oy, ox + ow - 1, oy + c_len, 9)
        line(ox, oy + oh - 1 - c_len, ox, oy + oh - 1, 9)
        line(ox, oy + oh - 1, ox + c_len, oy + oh - 1, 9)
        line(ox + ow - 1 - c_len, oy + oh - 1, ox + ow - 1, oy + oh - 1, 9)
        line(ox + ow - 1, oy + oh - 1 - c_len, ox + ow - 1, oy + oh - 1, 9)
      end
    end
  end

  # 地形モード時の矩形プレビュー枠
  if $current_mode == :terrain && $rect_drag
    stx = $rect_drag[0]
    sty = $rect_drag[1]
    cur_mx = mouse_x
    cur_my = mouse_y
    cur_tx = $cam_x + ((cur_mx - VIEW_X) / $cell_size).to_i
    cur_ty = $cam_y + ((cur_my - VIEW_Y) / $cell_size).to_i
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
  cur_mx = mouse_x
  cur_my = mouse_y
  if cur_mx >= VIEW_X && cur_mx < VIEW_X + VIEW_W && cur_my >= VIEW_Y && cur_my < VIEW_Y + VIEW_H
    if $current_mode == :terrain
      htx = ((cur_mx - VIEW_X) / $cell_size).to_i
      hty = ((cur_my - VIEW_Y) / $cell_size).to_i
      hx = VIEW_X + htx * $cell_size
      hy = VIEW_Y + hty * $cell_size
      rect(hx, hy, $cell_size, $cell_size, 7)
    else
      world_x = ($cam_x * 16 + (cur_mx - VIEW_X) / scale).to_i
      world_y = ($cam_y * 16 + (cur_my - VIEW_Y) / scale).to_i
      snap_x = snap_floor(world_x, $grid_snap)
      snap_y = snap_floor(world_y, $grid_snap)
      shx = VIEW_X + ((snap_x - $cam_x * 16) * scale).to_i
      shy = VIEW_Y + ((snap_y - $cam_y * 16) * scale).to_i
      rect(shx, shy, (16 * scale).to_i, (16 * scale).to_i, 11)
    end
  end

  clip()

  # --- 3. 右側パネル: ミニマップ & プレビュー (y: 22..88) ---
  # ミニマップ (x: 368, y: 22, w: 66, h: 66)
  rectfill(367, 21, 66, 66, 1)
  rect(367, 21, 66, 66, 5)

  update_minimap_cache
  blt(368, 22, MINIMAP_BANK, 0, 0, 32, 32, 0, 2.0)

  cam_vw = (VIEW_W / $cell_size).to_i * 2
  cam_vh = (VIEW_H / $cell_size).to_i * 2
  rect(368 + $cam_x * 2, 22 + $cam_y * 2, cam_vw, cam_vh, 7)

  # プレビュー枠 (32x32)
  rectfill(442, 21, 36, 36, 1)
  rect(442, 21, 36, 36, 5)
  if $current_mode == :terrain
    if $selected_tile < 0
      rectfill(444, 23, 32, 32, 0)
      line(448, 27, 472, 51, 8)
      line(448, 51, 472, 27, 8)
    else
      draw_tile_at($selected_tile, 444, 23, 2.0)
    end
    print_text("ID:#{$selected_tile}", 486, 22, 10)
    u_pos = ($selected_tile % $sheet_cols) * 16
    v_pos = ($selected_tile / $sheet_cols) * 16
    print_text("U:#{u_pos} V:#{v_pos}", 486, 34, 6)
    print_text("SHEET:#{$sheet_w}x#{$sheet_h}", 486, 46, 7)
  else
    if $selected_obj_idx && $selected_obj_idx < $objects.size
      sel_o = $objects[$selected_obj_idx]
      if sel_o[:spr].is_a?(Integer) && sel_o[:spr] >= 0
        draw_tile_at(sel_o[:spr], 444, 23, 2.0)
      elsif sel_o[:spr].is_a?(String)
        spr(sel_o[:spr], 452, 31)
      else
        print_text("BOX", 450, 35, 10)
      end
      print_text("#{sel_o[:type].to_s[0, 5]}", 486, 22, 10)
      print_text("X:#{sel_o[:x]} Y:#{sel_o[:y]}", 486, 34, 7)
      print_text("SHEET:#{$sheet_w}x#{$sheet_h}", 486, 46, 7)
    else
      if $obj_palette_tab == :chip
        draw_tile_at($selected_obj_chip, 444, 23, 2.0)
        print_text("CHIP ID:#{$selected_obj_chip}", 486, 22, 10)
        print_text("SHEET:#{$sheet_w}x#{$sheet_h}", 486, 34, 7)
      else
        spr(EMOJI_PALETTE[$selected_emoji_idx], 452, 31)
        print_text("EMOJI ##{$selected_emoji_idx}", 486, 22, 10)
        print_text("256 EMOJIS", 486, 34, 7)
      end
    end
  end

  # バンク切替ボタン (y: 64..78)
  rectfill(442, 64, 16, 14, 2)
  rect(442, 64, 16, 14, 6)
  print_text("<", 447, 67, 7)

  rectfill(460, 64, 22, 14, 1)
  rect(460, 64, 22, 14, 5)
  print_text("B#{$ref_bank}", 463, 67, 10)

  rectfill(484, 64, 16, 14, 2)
  rect(484, 64, 16, 14, 6)
  print_text(">", 489, 67, 7)

  # --- 4. パレット領域 (等倍 16x16 px、枠寸法はシートサイズに追従) ---
  cur_sheet_w = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 256 : $sheet_w
  cur_sheet_h = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 256 : $sheet_h
  cur_cols = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 16 : $sheet_cols
  cur_rows = ($current_mode == :objects && $obj_palette_tab == :emoji) ? 16 : $sheet_rows
  pal_w = [cur_sheet_w, PAL_MAX_W].min
  pal_h = [cur_sheet_h, PAL_MAX_H].min
  max_pal_scroll = [cur_sheet_h - pal_h, 0].max

  if $current_mode == :terrain
    print_text("BANK #{$ref_bank} TILES (#{$sheet_w}x#{$sheet_h}, 16x16)", PAL_X, 82, 6)
  else
    # タブ (y: 80..92)
    rectfill(PAL_X, 80, 62, 12, ($obj_palette_tab == :chip) ? 10 : 1)
    rect(PAL_X, 80, 62, 12, ($obj_palette_tab == :chip) ? 7 : 5)
    print_text("CHIP", PAL_X + 16, 82, ($obj_palette_tab == :chip) ? 0 : 6)

    rectfill(PAL_X + 66, 80, 64, 12, ($obj_palette_tab == :emoji) ? 10 : 1)
    rect(PAL_X + 66, 80, 64, 12, ($obj_palette_tab == :emoji) ? 7 : 5)
    print_text("EMOJI", PAL_X + 80, 82, ($obj_palette_tab == :emoji) ? 0 : 6)
  end

  # パレット外枠
  rectfill(PAL_X - 1, PAL_Y - 1, pal_w + 2, pal_h + 2, 1)
  rect(PAL_X - 1, PAL_Y - 1, pal_w + 2, pal_h + 2, 5)

  clip(PAL_X, PAL_Y, pal_w, pal_h)

  if $current_mode == :terrain || $obj_palette_tab == :chip
    # 等倍 (scale = 1.0) でバンク画像を描画
    blt(PAL_X, PAL_Y - $pal_scroll_y, $ref_bank, 0, 0, cur_sheet_w, cur_sheet_h, 0, 1.0)

    # 選択タイル枠
    cur_sel_tid = ($current_mode == :terrain) ? $selected_tile : $selected_obj_chip
    if cur_sel_tid < $num_tiles
      sel_col = cur_sel_tid % cur_cols
      sel_row = cur_sel_tid / cur_cols
      bx = PAL_X + sel_col * 16
      by = PAL_Y + sel_row * 16 - $pal_scroll_y
      rect(bx - 1, by - 1, 18, 18, 10)
      rect(bx, by, 16, 16, 7)
    end
  else
    # オブジェクトモード: 絵文字パレット (等倍 16x16 で一括描画)
    rectfill(PAL_X, PAL_Y, 256, 256, 0)
    EMOJI_PALETTE.each_with_index do |em, i|
      col = i % 16
      row = i / 16
      ex = PAL_X + col * 16
      ey = PAL_Y + row * 16 - $pal_scroll_y
      next if ey + 16 < PAL_Y || ey > PAL_Y + pal_h
      spr(em, ex, ey)
    end

    sel_col = $selected_emoji_idx % 16
    sel_row = $selected_emoji_idx / 16
    bx = PAL_X + sel_col * 16
    by = PAL_Y + sel_row * 16 - $pal_scroll_y
    rect(bx - 1, by - 1, 18, 18, 10)
    rect(bx, by, 16, 16, 7)
  end

  clip()

  # パレット縦スクロールバー表示
  if max_pal_scroll > 0
    sb_x = PAL_X + pal_w + 3
    sb_y = PAL_Y
    sb_w = 6
    sb_h = pal_h
    rectfill(sb_x, sb_y, sb_w, sb_h, 1)
    rect(sb_x, sb_y, sb_w, sb_h, 5)

    thumb_h = [(pal_h * pal_h / cur_sheet_h).to_i, 16].max
    thumb_y = sb_y + ($pal_scroll_y * (sb_h - thumb_h) / max_pal_scroll).to_i
    rectfill(sb_x + 1, thumb_y, sb_w - 2, thumb_h, 6)
  end

  # --- 5. ツールボタン & アクションボタン (y: 300..336) ---
  if $current_mode == :terrain
    # ツールボタン 行1 (y: 300..314)
    tool_buttons = [
      [:pen,    "PEN",  368, 22],
      [:rect,   "RCT",  394, 22],
      [:fill,   "FIL",  420, 22],
      [:picker, "PCK",  446, 22]
    ]
    tool_buttons.each do |tb|
      t_id = tb[0]
      t_name = tb[1]
      t_x = tb[2]
      t_w = tb[3]
      active = ($current_tool == t_id)
      rectfill(t_x, 300, t_w, 14, active ? 8 : 1)
      rect(t_x, 300, t_w, 14, active ? 7 : 5)
      print_text(t_name, t_x + 3, 303, active ? 7 : 6)
    end

    # [ZOOM]
    rectfill(472, 300, 28, 14, ($cell_size == 8) ? 9 : 1)
    rect(472, 300, 28, 14, ($cell_size == 8) ? 10 : 5)
    print_text(($cell_size == 16) ? "16P" : "8PX", 476, 303, 7)
  else
    # オブジェクトモード: インスペクタ / DEL
    if $selected_obj_idx && $selected_obj_idx < $objects.size
      sel_o = $objects[$selected_obj_idx]
      rectfill(368, 300, 22, 14, 8)
      rect(368, 300, 22, 14, 7)
      print_text("DEL", 371, 303, 7)

      rectfill(393, 300, 137, 14, 0)
      rect(393, 300, 137, 14, 5)
      extra_props = format_obj_props(sel_o, false)
      insp_text = extra_props.empty? ? format_obj_props(sel_o, true) : extra_props
      insp_text = "NO PROPS" if insp_text.empty?
      clip(395, 301, 133, 12)
      print_text(insp_text, 396, 303, 10)
      clip()
    else
      rectfill(368, 300, 162, 14, 0)
      rect(368, 300, 162, 14, 5)
      if $obj_palette_tab == :chip
        print_text("STAMP CHIP #{$selected_obj_chip}", 374, 303, 6)
      else
        print_text("STAMP #{EMOJI_PALETTE[$selected_emoji_idx]}", 374, 303, 6)
      end
    end
  end

  # アクションボタン 行2 (y: 320..334)
  rectfill(368, 320, 22, 14, 11)
  rect(368, 320, 22, 14, 7)
  print_text("SV", 373, 323, 0)

  rectfill(394, 320, 24, 14, 1)
  rect(394, 320, 24, 14, 5)
  print_text("UND", 397, 323, 7)

  if $current_mode == :objects
    snap_btn = ($grid_snap == 1) ? "FR" : "#{$grid_snap}"
    rectfill(422, 320, 22, 14, 3)
    rect(422, 320, 22, 14, 11)
    print_text(snap_btn, 426, 323, 7)
  else
    rectfill(422, 320, 22, 14, $show_grid ? 3 : 1)
    rect(422, 320, 22, 14, $show_grid ? 11 : 5)
    print_text("GR", 426, 323, 7)
  end

  rectfill(448, 320, 22, 14, 1)
  rect(448, 320, 22, 14, 5)
  print_text("CD", 452, 323, 7)

  rectfill(474, 320, 26, 14, 1)
  rect(474, 320, 26, 14, 8)
  print_text("CLR", 479, 323, 8)

  # --- 6. 通知メッセージ または 選択中オブジェクト詳細バー ---
  if $notify_timer > 0
    nw = $notify_msg.size * 6 + 12
    nx = 8
    ny = 344
    rectfill(nx, ny, nw, 14, 0)
    rect(nx, ny, nw, 14, 10)
    print_text($notify_msg, nx + 6, ny + 3, 10)
  elsif $current_mode == :objects && $selected_obj_idx && $selected_obj_idx < $objects.size
    sel_o = $objects[$selected_obj_idx]
    props_str = format_obj_props(sel_o, true)
    info_line = "##{$selected_obj_idx} #{sel_o[:type]} (#{sel_o[:x]},#{sel_o[:y]}) #{props_str}"
    rectfill(VIEW_X + 2, VIEW_Y + VIEW_H - 15, VIEW_W - 4, 13, 0)
    rect(VIEW_X + 2, VIEW_Y + VIEW_H - 15, VIEW_W - 4, 13, 9)
    clip(VIEW_X + 4, VIEW_Y + VIEW_H - 14, VIEW_W - 8, 11)
    print_text(info_line, VIEW_X + 6, VIEW_Y + VIEW_H - 12, 7)
    clip()
  end

  # --- 7. コードプレビューモーダル (640x360 画面用) ---
  if $show_code_modal
    rectfill(20, 10, 600, 336, 0)
    rect(20, 10, 600, 336, 7)
    rect(22, 12, 596, 332, 1)

    print_text("📋 CODE PREVIEW - @MAP DATA", 32, 18, 10)

    # 閉じるボタン
    rectfill(580, 16, 22, 12, 8)
    rect(580, 16, 22, 12, 7)
    print_text("X", 588, 18, 7)

    # コード表示ボックス
    rectfill(30, 34, 580, 268, 0)
    rect(30, 34, 580, 268, 5)

    clip(32, 36, 576, 264)
    export_lines = generate_map_text.split("\n")
    start_line = $modal_scroll
    visible_count = 26
    visible_count.times do |i|
      idx = start_line + i
      if idx < export_lines.size
        print_text(export_lines[idx], 36, 38 + i * 10, 7)
      end
    end
    clip()

    # モーダル下部ボタン
    rectfill(32, 310, 120, 16, 1)
    rect(32, 310, 120, 16, 7)
    print_text("EXPORT CONSOLE", 38, 314, 7)

    rectfill(160, 310, 80, 16, 11)
    rect(160, 310, 80, 16, 7)
    print_text("SAVE MAP", 172, 314, 0)
  end
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

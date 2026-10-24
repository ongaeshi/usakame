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
# - [SAVE] (Ctrl+S / S): ターゲットファイルに即座に書き込み
# ==============================================================================

config(
  width: 480,
  height: 270,
  window_scale: 2.0,
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
NUM_TILES  = 256
MINIMAP_BANK = 127 # ミニマップ高速描画用バンク

# キャンバス表示領域 (320 x 240 px)
VIEW_X = 8
VIEW_Y = 22
VIEW_W = 320
VIEW_H = 240

# タイル情報定義 [ID, 名前, 代表色] (デフォルト16種)
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

# オブジェクトモード時の背景地形減光パレット (16色それぞれの暗色対応テーブル)
TERRAIN_DIM_PAL = [0, 0, 1, 1, 2, 1, 5, 5, 2, 4, 4, 3, 1, 1, 2, 4]

def tile_name(tid)
  if tid == 0
    "EMPTY"
  elsif tid < TILE_INFO.size && TILE_INFO[tid]
    TILE_INFO[tid][1]
  else
    "T_#{tid}"
  end
end

def tile_color(tid)
  if tid == 0
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
$map = Array.new(MAP_WIDTH * MAP_HEIGHT, 0)
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

$cam_x = 0           # カメラ原点 (タイル単位)
$cam_y = 0
$selected_tile = 1       # 地形モード選択中タイルID (0..255)
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

$custom_sprites = Array.new(16, nil)
$has_custom_sprites = false
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
  return 0 if tx < 0 || tx >= MAP_WIDTH || ty < 0 || ty >= MAP_HEIGHT
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

# タイルIDを1文字表記に変換 (0: '.', 1..9: '1'..'9', 10..15: 'A'..'F')
def tile_to_char(tid)
  if tid <= 0
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

# 外部スプライト／バンクの再読み込み
def reload_custom_sprites
  src = ($spr_path && read_file($spr_path)) ? $spr_path : $target_path

  # 1. 256x256 バンクデータの読み込み (減色せずフルカラーRGBAテクスチャを直接ロード)
  if load_bank($ref_bank, src)
    notify("SYNCED BANK #{$ref_bank} FROM #{src}")
  else
    bank_pixels = load_resource_bank(src, $ref_bank)
    if bank_pixels && bank_pixels.size == 256 * 256
      update_bank($ref_bank, bank_pixels)
      notify("SYNCED BANK #{$ref_bank} FROM #{src}")
    end
  end

  # 2. 旧形式の個別スプライトもフォールバック読み込み
  if $spr_path && read_file($spr_path)
    cur_mtime = file_mtime($spr_path)
    if cur_mtime > 0
      $last_spr_mtime = cur_mtime
    end
    slots = load_resource_sprites($spr_path, 16)
    count = 0
    slots.each_with_index do |sgrid, sid|
      if sgrid
        $custom_sprites[sid] = sgrid
        count += 1
      end
    end
    $has_custom_sprites = (count > 0)
    notify("SYNCED #{count} SPRITES FROM #{$spr_path}") if count > 0 && !bank_pixels
  end
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
  $map = Array.new(MAP_WIDTH * MAP_HEIGHT, 0)
  sync_tilemap_to_engine
  $minimap_dirty = true
  sfx(:boom)
  notify("CLEARED MAP")
end

# ------------------------------------------------------------------------------
# テキストエクスポート & 保存
# ------------------------------------------------------------------------------
def generate_map_text
  has_large_tiles = $map.any? { |tid| tid >= 16 }
  lines = ["@MAP 0 0"]
  MAP_HEIGHT.times do |y|
    row_tokens = []
    MAP_WIDTH.times do |x|
      tid = get_tile(x, y)
      if has_large_tiles
        row_tokens << (tid <= 0 ? "." : tid.to_s)
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
# タイルドット描画 (カスタムスプライトまたはバンクテクスチャ)
# ------------------------------------------------------------------------------
def draw_tile_at(tid, px, py, scale = 1.0)
  return if tid <= 0
  if $has_custom_sprites && tid < $custom_sprites.size && $custom_sprites[tid]
    spr($custom_sprites[tid], px, py, false, false, 0, scale)
  else
    u = (tid % 16) * 16
    v = (tid / 16) * 16
    blt(px, py, $ref_bank, u, v, 16, 16, 0, scale)
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

  # FキーでFPS通知
  if btnp(:f)
    puts "[TilemapEditor] FPS: #{fps}"
    notify("FPS: #{fps}")
  end

  perform_undo if btnp(:z)
  export_map_only if btnp(:e)
  clear_map if btnp(:c)

  # G: グリッドトグル (地形) または スナップ切替 (オブジェクト)
  if btnp(:g)
    if $current_mode == :objects
      $grid_snap = ($grid_snap == 16) ? 8 : (($grid_snap == 8) ? 1 : 16)
      sfx(:click)
      notify("SNAP: #{$grid_snap == 1 ? 'FREE' : "#{$grid_snap}PX"}")
    else
      $show_grid = !$show_grid
      sfx(:click)
      notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
    end
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

  # マウスホイールでタイル/チップ切り替え (0..255)
  wheel = mouse_wheel
  if wheel > 0.2
    if $current_mode == :terrain
      $selected_tile = ($selected_tile - 1) % NUM_TILES
    elsif $obj_palette_tab == :chip
      $selected_obj_chip = ($selected_obj_chip - 1) % NUM_TILES
    else
      $selected_emoji_idx = ($selected_emoji_idx - 1) % EMOJI_PALETTE.size
    end
    sfx(:cursor)
  elsif wheel < -0.2
    if $current_mode == :terrain
      $selected_tile = ($selected_tile + 1) % NUM_TILES
    elsif $obj_palette_tab == :chip
      $selected_obj_chip = ($selected_obj_chip + 1) % NUM_TILES
    else
      $selected_emoji_idx = ($selected_emoji_idx + 1) % EMOJI_PALETTE.size
    end
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

  # --- バンクビュー / 絵文字ビュー上でのドラッグ選択 (x: 336..464, y: 98..226) ---
  if $current_mode == :terrain
    if (btn(:mouse_l) || btn(:mouse_r)) && (mx >= 336 && mx < 464 && my >= 98 && my < 226)
      col = ((mx - 336) / 8).to_i
      row = ((my - 98) / 8).to_i
      if col >= 0 && col < 16 && row >= 0 && row < 16
        tid = row * 16 + col
        if $selected_tile != tid
          $selected_tile = tid
          sfx(:select)
        end
      end
    end
  elsif $current_mode == :objects && $obj_palette_tab == :chip
    if (btn(:mouse_l) || btn(:mouse_r)) && (mx >= 336 && mx < 464 && my >= 98 && my < 226)
      col = ((mx - 336) / 8).to_i
      row = ((my - 98) / 8).to_i
      if col >= 0 && col < 16 && row >= 0 && row < 16
        tid = row * 16 + col
        if $selected_obj_chip != tid
          $selected_obj_chip = tid
          sfx(:select)
        end
      end
    end
  elsif $current_mode == :objects && $obj_palette_tab == :emoji
    if (btn(:mouse_l) || btn(:mouse_r)) && (mx >= 336 && mx < 464 && my >= 98 && my < 226)
      col = ((mx - 336) / 8).to_i
      row = ((my - 98) / 8).to_i
      if col >= 0 && col < 16 && row >= 0 && row < 16
        eidx = row * 16 + col
        if eidx >= 0 && eidx < EMOJI_PALETTE.size && $selected_emoji_idx != eidx
          $selected_emoji_idx = eidx
          sfx(:select)
          notify("EMOJI: #{EMOJI_PALETTE[eidx]}")
        end
      end
    end
  end

  # --- UI クリック判定 ---
  if btnp(:mouse_l)
    # ヘッダーバーでのモード切替 & スナップ切替 (y: 2..16)
    if my >= 2 && my <= 16
      # [TERRAIN] (x: 76..128)
      if mx >= 76 && mx <= 128
        $current_mode = :terrain
        sfx(:click)
        notify("MODE: TERRAIN")
      # [OBJECTS] (x: 132..184)
      elsif mx >= 132 && mx <= 184
        $current_mode = :objects
        sfx(:click)
        notify("MODE: OBJECTS")
      # [SNAP] (x: 188..246)
      elsif mx >= 188 && mx <= 246
        $grid_snap = ($grid_snap == 16) ? 8 : (($grid_snap == 8) ? 1 : 16)
        sfx(:click)
        notify("SNAP: #{$grid_snap == 1 ? 'FREE' : "#{$grid_snap}PX"}")
      end
    end

    # 0. バンク切替ボタン (x: 406..472, y: 64..78)
    if my >= 64 && my <= 78
      if mx >= 406 && mx <= 422
        switch_ref_bank([$ref_bank - 1, 0].max)
        sfx(:click)
      elsif mx >= 456 && mx <= 472
        switch_ref_bank($ref_bank + 1)
        sfx(:click)
      end
    end

    # 1. ミニマップクリック (x: 336..400, y: 24..88) -> カメラジャンプ
    if mx >= 336 && mx < 400 && my >= 24 && my < 88
      jump_tx = ((mx - 336) / 2).to_i
      jump_ty = ((my - 24) / 2).to_i
      $cam_x = jump_tx - (max_tiles_x / 2)
      $cam_y = jump_ty - (max_tiles_y / 2)
      $cam_x = [[$cam_x, 0].max, MAP_WIDTH - max_tiles_x].min
      $cam_y = [[$cam_y, 0].max, MAP_HEIGHT - max_tiles_y].min
      sfx(:cursor)
    end

    # 2. 地形モード時: ツールボタン 行1 (y: 230..244)
    if $current_mode == :terrain && my >= 230 && my <= 244
      # [PEN] (x: 336..358)
      if mx >= 336 && mx <= 358
        $current_tool = :pen; sfx(:click)
      # [RECT] (x: 362..384)
      elsif mx >= 362 && mx <= 384
        $current_tool = :rect; sfx(:click)
      # [FILL] (x: 388..410)
      elsif mx >= 388 && mx <= 410
        $current_tool = :fill; sfx(:click)
      # [PICK] (x: 414..436)
      elsif mx >= 414 && mx <= 436
        $current_tool = :picker; sfx(:click)
      # [ZOOM] (x: 440..468)
      elsif mx >= 440 && mx <= 468
        $cell_size = ($cell_size == 16) ? 8 : 16
        sfx(:click)
        notify("ZOOM: #{$cell_size}px")
      end
    end

    # 2-B. オブジェクトモード時のパレット・プロパティ操作
    if $current_mode == :objects
      # パレットタブ切替 (y: 84..96)
      if my >= 84 && my <= 96
        if mx >= 336 && mx <= 398
          $obj_palette_tab = :chip; sfx(:click)
        elsif mx >= 402 && mx <= 468
          $obj_palette_tab = :emoji; sfx(:click)
        end
      end

      # プロパティパネル操作 (y: 230..244)
      if $selected_obj_idx && $selected_obj_idx < $objects.size
        cur_obj = $objects[$selected_obj_idx]
        if my >= 230 && my <= 244
          # [DEL] (x: 336..358)
          if mx >= 336 && mx <= 358
            push_undo
            $objects.delete_at($selected_obj_idx)
            $selected_obj_idx = nil
            $dragging_obj_idx = nil
            sfx(:boom)
            notify("DELETED OBJECT")
          # [+HP] (x: 362..384)
          elsif mx >= 362 && mx <= 384
            push_undo
            cur_obj[:hp] = ((cur_obj[:hp] || 0) + 10)
            sfx(:click)
            notify("HP: #{cur_obj[:hp]}")
          # [+SC] (x: 388..410)
          elsif mx >= 388 && mx <= 410
            push_undo
            cur_obj[:score] = ((cur_obj[:score] || 0) + 50)
            sfx(:click)
            notify("SCORE: #{cur_obj[:score]}")
          # [+W] (x: 414..434)
          elsif mx >= 414 && mx <= 434
            push_undo
            cur_obj[:w] = ((cur_obj[:w] || 16) == 16) ? 32 : (((cur_obj[:w] == 32) ? 48 : 16))
            cur_obj[:h] = cur_obj[:w]
            sfx(:click)
            notify("SIZE: #{cur_obj[:w]}x#{cur_obj[:h]}")
          # [SET] (x: 438..464)
          elsif mx >= 438 && mx <= 464
            push_undo
            new_spr = ($obj_palette_tab == :emoji) ? EMOJI_PALETTE[$selected_emoji_idx] : $selected_obj_chip
            cur_obj[:spr] = new_spr
            sfx(:powerup)
            notify("UPDATED SPR: #{new_spr}")
          end
        end
      end
    end

    # 3. アクションボタン 行2 (y: 248..262)
    if my >= 248 && my <= 262
      # [SAVE] (x: 336..358)
      if mx >= 336 && mx <= 358
        save_map_file
      # [UNDO] (x: 362..386)
      elsif mx >= 362 && mx <= 386
        perform_undo
      # [GRID] (x: 390..412)
      elsif mx >= 390 && mx <= 412
        if $current_mode == :objects
          $grid_snap = ($grid_snap == 16) ? 8 : (($grid_snap == 8) ? 1 : 16)
          sfx(:click)
          notify("SNAP: #{$grid_snap == 1 ? 'FREE' : "#{$grid_snap}PX"}")
        else
          $show_grid = !$show_grid
          sfx(:click)
          notify("GRID: #{$show_grid ? 'ON' : 'OFF'}")
        end
      # [CODE] (x: 416..438)
      elsif mx >= 416 && mx <= 438
        $show_code_modal = true
        $modal_scroll = 0
        sfx(:click)
      # [CLR] (x: 442..468)
      elsif mx >= 442 && mx <= 468
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

  # --- 1. ヘッダーバー (y: 0..18) ---
  rectfill(0, 0, 480, 18, 1)
  line(0, 18, 480, 18, 5)
  print_text("🗺️ USAKAME", 8, 5, 10)

  # [TERRAIN] / [OBJECTS] モード切替タブ
  is_terr = ($current_mode == :terrain)
  rectfill(76, 3, 52, 12, is_terr ? 11 : 2)
  rect(76, 3, 52, 12, is_terr ? 7 : 5)
  print_text("TERRAIN", 81, 5, is_terr ? 0 : 6)

  rectfill(132, 3, 52, 12, !is_terr ? 10 : 2)
  rect(132, 3, 52, 12, !is_terr ? 7 : 5)
  print_text("OBJECTS", 137, 5, !is_terr ? 0 : 6)

  # [SNAP] ボタン
  snap_label = ($grid_snap == 1) ? "FREE" : "#{$grid_snap}PX"
  rectfill(188, 3, 58, 12, ($grid_snap > 1) ? 3 : 2)
  rect(188, 3, 58, 12, ($grid_snap > 1) ? 11 : 5)
  print_text("S:#{snap_label}", 196, 5, 7)

  print_text("CAM:(#{$cam_x},#{$cam_y})", 252, 5, 6)
  print_text("TARGET: #{$save_path}", 322, 5, 11)
  print_text("FPS:#{fps}", 434, 5, 10)

  # --- 2. メインタイルマップキャンバス (320x240) ---
  rectfill(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 0)
  rect(VIEW_X - 1, VIEW_Y - 1, VIEW_W + 2, VIEW_H + 2, 5)

  clip(VIEW_X, VIEW_Y, VIEW_W, VIEW_H)

  tiles_x = (VIEW_W / $cell_size).to_i + 1
  tiles_y = (VIEW_H / $cell_size).to_i + 1
  scale = ($cell_size == 16) ? 1.0 : 0.5

  # 背景の市松模様を一括描画 (オブジェクトモード時は一段暗くする)
  checker_col = ($current_mode == :objects) ? 0 : 1
  if checker_col > 0
    8.times do |cy|
      by = VIEW_Y + cy * 30
      8.times do |cx|
        if (cx + cy) % 2 == 1
          rectfill(VIEW_X + cx * 40, by, 40, 30, checker_col)
        end
      end
    end
  end

  # タイル描画 (オブジェクトモード時はパレット減光で地形を暗く表示)
  pal(TERRAIN_DIM_PAL) if $current_mode == :objects
  if $cell_size == 16 && !$has_custom_sprites
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
        if tid > 0
          draw_tile_at(tid, VIEW_X + dx * $cell_size, draw_py, scale)
        end
      end
    end
  end
  pal() if $current_mode == :objects

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

      if obj[:spr].is_a?(Integer) && obj[:spr] > 0
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
        # TERRAINモード中もオブジェクトと地形を区別できるよう四隅に目印枠を表示
        c_len = [ow / 4, 3].max
        # 左上
        line(ox, oy, ox + c_len, oy, 9)
        line(ox, oy, ox, oy + c_len, 9)
        # 右上
        line(ox + ow - 1 - c_len, oy, ox + ow - 1, oy, 9)
        line(ox + ow - 1, oy, ox + ow - 1, oy + c_len, 9)
        # 左下
        line(ox, oy + oh - 1 - c_len, ox, oy + oh - 1, 9)
        line(ox, oy + oh - 1, ox + c_len, oy + oh - 1, 9)
        # 右下
        line(ox + ow - 1 - c_len, oy + oh - 1, ox + ow - 1, oy + oh - 1, 9)
        line(ox + ow - 1, oy + oh - 1 - c_len, ox + ow - 1, oy + oh - 1, 9)
      end
    end
  end

  # 地形モード時の矩形プレビュー枠
  if $current_mode == :terrain && $rect_drag
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
    if $current_mode == :terrain
      htx = ((mx - VIEW_X) / $cell_size).to_i
      hty = ((my - VIEW_Y) / $cell_size).to_i
      hx = VIEW_X + htx * $cell_size
      hy = VIEW_Y + hty * $cell_size
      rect(hx, hy, $cell_size, $cell_size, 7)
    else
      # オブジェクトモード時のスナップ枠
      world_x = ($cam_x * 16 + (mx - VIEW_X) / scale).to_i
      world_y = ($cam_y * 16 + (my - VIEW_Y) / scale).to_i
      snap_x = snap_floor(world_x, $grid_snap)
      snap_y = snap_floor(world_y, $grid_snap)
      shx = VIEW_X + ((snap_x - $cam_x * 16) * scale).to_i
      shy = VIEW_Y + ((snap_y - $cam_y * 16) * scale).to_i
      rect(shx, shy, (16 * scale).to_i, (16 * scale).to_i, 11)
    end
  end

  clip()

  # --- 3. 右側パネル: ミニマップ & プレビュー ---
  # ミニマップ (x: 336, y: 24, w: 64, h: 64)
  rectfill(335, 23, 66, 66, 1)
  rect(335, 23, 66, 66, 5)

  update_minimap_cache
  blt(336, 24, MINIMAP_BANK, 0, 0, 32, 32, 0, 2.0)

  # ミニマップ上のカメラ表示枠
  cam_vw = (VIEW_W / $cell_size).to_i * 2
  cam_vh = (VIEW_H / $cell_size).to_i * 2
  rect(336 + $cam_x * 2, 24 + $cam_y * 2, cam_vw, cam_vh, 7)

  # ミニマップ横: プレビュー (32x32)
  rectfill(406, 23, 36, 36, 1)
  rect(406, 23, 36, 36, 5)
  if $current_mode == :terrain
    if $selected_tile == 0
      rectfill(408, 25, 32, 32, 0)
      line(412, 29, 436, 53, 8)
      line(412, 53, 436, 29, 8)
    else
      draw_tile_at($selected_tile, 408, 25, 2.0)
    end
    print_text("ID:#{$selected_tile}", 446, 24, 10)
    u_pos = ($selected_tile % 16) * 16
    v_pos = ($selected_tile / 16) * 16
    print_text("U:#{u_pos}", 446, 36, 6)
    print_text("V:#{v_pos}", 446, 48, 6)
  else
    # オブジェクトプレビュー
    if $selected_obj_idx && $selected_obj_idx < $objects.size
      sel_o = $objects[$selected_obj_idx]
      if sel_o[:spr].is_a?(Integer) && sel_o[:spr] > 0
        draw_tile_at(sel_o[:spr], 408, 25, 2.0)
      elsif sel_o[:spr].is_a?(String)
        spr(sel_o[:spr], 416, 33)
      else
        print_text("BOX", 414, 37, 10)
      end
      print_text("OBJ", 446, 24, 10)
      print_text("#{sel_o[:type].to_s[0, 5]}", 446, 36, 7)
    else
      # 配置予定のチップ/絵文字
      if $obj_palette_tab == :chip
        draw_tile_at($selected_obj_chip, 408, 25, 2.0)
        print_text("CHIP", 446, 24, 10)
        print_text("ID:#{$selected_obj_chip}", 446, 36, 7)
      else
        spr(EMOJI_PALETTE[$selected_emoji_idx], 416, 33)
        print_text("EMOJI", 446, 24, 10)
        print_text("##{$selected_emoji_idx}", 446, 36, 7)
      end
    end
  end

  # バンク切替ボタン (y: 64..78)
  rectfill(406, 64, 16, 14, 2)
  rect(406, 64, 16, 14, 6)
  print_text("<", 411, 67, 7)

  rectfill(424, 64, 30, 14, 1)
  rect(424, 64, 30, 14, 5)
  print_text("B#{$ref_bank}", 429, 67, 10)

  rectfill(456, 64, 16, 14, 2)
  rect(456, 64, 16, 14, 6)
  print_text(">", 461, 67, 7)

  # --- 4. パレット領域 (y: 84..226) ---
  if $current_mode == :terrain
    # 地形モード: バンク全体表示 (128x128)
    print_text("BANK #{$ref_bank} TILES (16x16)", 336, 88, 6)

    rectfill(335, 97, 130, 130, 1)
    rect(335, 97, 130, 130, 5)

    blt(336, 98, $ref_bank, 0, 0, 256, 256, 0, 0.5)

    rect(336, 98, 8, 8, 8)
    line(337, 99, 342, 104, 8)
    line(337, 104, 342, 99, 8)

    sel_col = $selected_tile % 16
    sel_row = $selected_tile / 16
    bx = 336 + sel_col * 8
    by = 98 + sel_row * 8
    rect(bx - 1, by - 1, 10, 10, 10)
    rect(bx, by, 8, 8, 7)

    # ツールボタン 行1 (y: 230..244)
    tool_buttons = [
      [:pen,    "PEN",  336, 22],
      [:rect,   "RCT",  362, 22],
      [:fill,   "FIL",  388, 22],
      [:picker, "PCK",  414, 22]
    ]
    tool_buttons.each do |tb|
      t_id = tb[0]
      t_name = tb[1]
      t_x = tb[2]
      t_w = tb[3]
      active = ($current_tool == t_id)
      rectfill(t_x, 230, t_w, 14, active ? 8 : 1)
      rect(t_x, 230, t_w, 14, active ? 7 : 5)
      print_text(t_name, t_x + 3, 233, active ? 7 : 6)
    end

    # [ZOOM]
    rectfill(440, 230, 28, 14, ($cell_size == 8) ? 9 : 1)
    rect(440, 230, 28, 14, ($cell_size == 8) ? 10 : 5)
    print_text(($cell_size == 16) ? "16P" : "8PX", 444, 233, 7)

  else
    # オブジェクトモード: [CHIP] / [EMOJI] パレット & インスペクタ
    # タブ (y: 84..95)
    rectfill(336, 84, 62, 12, ($obj_palette_tab == :chip) ? 10 : 1)
    rect(336, 84, 62, 12, ($obj_palette_tab == :chip) ? 7 : 5)
    print_text("CHIP (256)", 342, 86, ($obj_palette_tab == :chip) ? 0 : 6)

    rectfill(402, 84, 64, 12, ($obj_palette_tab == :emoji) ? 10 : 1)
    rect(402, 84, 64, 12, ($obj_palette_tab == :emoji) ? 7 : 5)
    print_text("EMOJI (256)", 406, 86, ($obj_palette_tab == :emoji) ? 0 : 6)

    # パレット中央領域 (y: 97..227, 128x128px)
    rectfill(335, 97, 130, 130, 1)
    rect(335, 97, 130, 130, 5)

    if $obj_palette_tab == :chip
      blt(336, 98, $ref_bank, 0, 0, 256, 256, 0, 0.5)

      rect(336, 98, 8, 8, 8)
      line(337, 99, 342, 104, 8)
      line(337, 104, 342, 99, 8)

      sel_col = $selected_obj_chip % 16
      sel_row = $selected_obj_chip / 16
      bx = 336 + sel_col * 8
      by = 98 + sel_row * 8
      rect(bx - 1, by - 1, 10, 10, 10)
      rect(bx, by, 8, 8, 7)

    else
      # 256個の絵文字 (16列 × 16行 = 256) を 8x8 で一括描画
      rectfill(336, 98, 128, 128, 0)
      EMOJI_PALETTE.each_with_index do |em, i|
        col = i % 16
        row = i / 16
        ex = 336 + col * 8
        ey = 98 + row * 8
        spr(em, ex, ey, false, false, 0, 0.5)
      end

      sel_col = $selected_emoji_idx % 16
      sel_row = $selected_emoji_idx / 16
      bx = 336 + sel_col * 8
      by = 98 + sel_row * 8
      rect(bx - 1, by - 1, 10, 10, 10)
      rect(bx, by, 8, 8, 7)
    end

    # 行1: 選択中オブジェクトのインスペクタ / クイック操作 (y: 230..244)
    if $selected_obj_idx && $selected_obj_idx < $objects.size
      sel_o = $objects[$selected_obj_idx]
      # [DEL]
      rectfill(336, 230, 22, 14, 8)
      rect(336, 230, 22, 14, 7)
      print_text("DEL", 339, 233, 7)

      # [+HP]
      rectfill(362, 230, 22, 14, 1)
      rect(362, 230, 22, 14, 5)
      print_text("+HP", 364, 233, 7)

      # [+SC]
      rectfill(388, 230, 22, 14, 1)
      rect(388, 230, 22, 14, 5)
      print_text("+SC", 390, 233, 7)

      # [+W]
      rectfill(414, 230, 20, 14, 1)
      rect(414, 230, 20, 14, 5)
      print_text("+W", 417, 233, 7)

      # [SET]
      rectfill(438, 230, 26, 14, 3)
      rect(438, 230, 26, 14, 11)
      print_text("SET", 443, 233, 7)
    else
      if $obj_palette_tab == :chip
        print_text("STAMP CHIP #{$selected_obj_chip}", 344, 233, 6)
      else
        print_text("STAMP #{EMOJI_PALETTE[$selected_emoji_idx]} (##{$selected_emoji_idx})", 344, 233, 6)
      end
    end
  end

  # --- 5. アクションボタン 行2 (y: 248..262) ---
  # [SAVE]
  rectfill(336, 248, 22, 14, 11)
  rect(336, 248, 22, 14, 7)
  print_text("SV", 341, 251, 0)

  # [UNDO]
  rectfill(362, 248, 24, 14, 1)
  rect(362, 248, 24, 14, 5)
  print_text("UND", 365, 251, 7)

  # [SNAP] / [GRID]
  if $current_mode == :objects
    snap_btn = ($grid_snap == 1) ? "FR" : "#{$grid_snap}"
    rectfill(390, 248, 22, 14, 3)
    rect(390, 248, 22, 14, 11)
    print_text(snap_btn, 394, 251, 7)
  else
    rectfill(390, 248, 22, 14, $show_grid ? 3 : 1)
    rect(390, 248, 22, 14, $show_grid ? 11 : 5)
    print_text("GR", 394, 251, 7)
  end

  # [CODE]
  rectfill(416, 248, 22, 14, 1)
  rect(416, 248, 22, 14, 5)
  print_text("CD", 420, 251, 7)

  # [CLR]
  rectfill(442, 248, 26, 14, 1)
  rect(442, 248, 26, 14, 8)
  print_text("CLR", 447, 251, 8)

  # --- 6. 通知メッセージ ---
  if $notify_timer > 0
    nw = $notify_msg.size * 6 + 12
    nx = 8
    ny = 246
    rectfill(nx, ny, nw, 14, 0)
    rect(nx, ny, nw, 14, 10)
    print_text($notify_msg, nx + 6, ny + 3, 10)
  end

  # --- 7. コードプレビューモーダル ---
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

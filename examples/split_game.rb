# ==============================================================================
# 🐰 Usakame Sample: Split Resource & Hot-Reload Demo (分離リソースデモ) 🐢
# ------------------------------------------------------------------------------
# このスクリプト本体にはリソース（スプライト/マップ/サウンド）を一切含みません。
# 以下の外部ファイルが自動的に検出・オーバーレイされて動作します:
#   - examples/split_game.spr  (スプライト定義)
#   - examples/split_game.map  (タイルマップ定義)
#   - examples/split_game.sfx  (効果音・BGM定義)
#
# 【ホットリロードの実験方法】
# 本スクリプトを実行したまま (uk run examples/split_game.rb):
#
# 1. 🎨 スプライトのホットリロード:
#    別ターミナルでスプライトエディタを起動し、保存(Ctrl+S)すると
#    ゲーム内のうさぎやオブジェクトの見た目がその場で即座に更新されます！
#      uk run examples/sprite_editor.rb -- examples/split_game.rb
#
# 2. 🗺️ タイルマップのホットリロード:
#    別ターミナルでタイルマップエディタを起動し、保存(Ctrl+S)すると
#    ゲーム内の島の地形やコイン配置がリアルタイムに更新されます！
#      uk run examples/tilemap_editor.rb -- examples/split_game.rb
#
# 3. 🎵 サウンドのホットリロード:
#    VSCode等で examples/split_game.sfx の音階やスピードを書き換えて保存すると
#    BGMやSEがその場でシームレスに更新されます！
#
# 4. 📦 1ファイルパック化の実験:
#    配布用に単一ファイルにまとめたいときは:
#      uk pack examples/split_game.rb -o split_game_packed.rb
# ==============================================================================

config(
  width: 256,
  height: 256,
  window_scale: 2.0,
  title: "Usakame - Split Resource Demo"
)

# プレイヤー状態 (ホットリロード時も保持されます)
$px = 160
$py = 160
$pdir = :right
$pwalk = 0
$coins = 0
$msg = "Explore the island & try hot-reload!"
$msg_timer = 180

# BGM 再生開始
music(0)

def update
  # --- プレイヤー移動 (矢印キー / WASD) ---
  dx = 0
  dy = 0

  dx -= 2 if btn(0) # left
  dx += 2 if btn(1) # right
  dy -= 2 if btn(2) # up
  dy += 2 if btn(3) # down

  if dx != 0 || dy != 0
    $pdir = (dx < 0) ? :left : :right if dx != 0
    $pwalk += 1
    # 10フレームごとに足音再生 (sfx 1)
    sfx(1) if ($pwalk % 10 == 0)
  else
    $pwalk = 0
  end

  # 仮移動とマップ範囲クランプ (タイル 32x32 = 512x512)
  new_x = [[$px + dx, 24].max, 480].min
  new_y = [[$py + dy, 24].max, 480].min

  # 中心タイル座標
  ctx = (new_x + 8) / 16
  cty = (new_y + 12) / 16

  tile_at = mget(ctx, cty)

  # 水(3)や木(4)は通行不可（簡易コリジョン）
  if tile_at != 3 && tile_at != 4
    $px = new_x
    $py = new_y
  end

  # コイン(5)取得判定
  if tile_at == 5
    mset(ctx, cty, 2) # コインを草(2)に置き換え
    $coins += 1
    sfx(0) # コインSE再生
    $msg = "Coin get! Total: #{$coins}"
    $msg_timer = 90
  end

  $msg_timer = [$msg_timer - 1, 0].max
end

def draw
  cls(0)

  # プレイヤー中心にカメラ追従
  cam_x = $px - 120
  cam_y = $py - 120
  camera(cam_x, cam_y)

  # タイルマップ描画 (0, 0 から 32x32 タイル)
  map(0, 0, 0, 0, 32, 32)

  # プレイヤースプライト描画
  # アニメーション: 歩行中は 0 と 1 を交互に切り替え
  anim_id = ($pwalk > 0 && ($pwalk / 8) % 2 == 1) ? 1 : 0
  flip_x = ($pdir == :left)
  spr(anim_id, $px, $py, flip_x, false)

  # UI描画のためカメラリセット
  camera(0, 0)

  # --- ヘッダーUI ---
  rectfill(0, 0, 256, 18, 1)
  line(0, 18, 256, 18, 5)
  print_text("🐰 SPLIT-RESOURCE DEMO", 4, 5, 10)
  print_text("COINS: #{$coins}", 180, 5, 11)

  # --- メッセージ / ガイドバー ---
  if $msg_timer > 0
    rectfill(0, 238, 256, 18, 0)
    line(0, 238, 256, 238, 5)
    print_text($msg, 8, 243, 10)
  else
    rectfill(0, 240, 256, 16, 1)
    print_text("Move: Arrows/WASD | Hot-reload active!", 8, 244, 6)
  end
end

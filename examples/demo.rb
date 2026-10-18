# ==============================================================================
# usakame Presentation Demo (うさかめプレゼンテーションデモ)
# 実行コマンド: uk run examples/demo.rb
# ==============================================================================
# 操作:
#   Z / Space / Enter / 左クリック : メッセージ送り / リプレイ
#   マウス移動 / クリック          : 「キーボードとマウス入力」シーンで反応
# ==============================================================================

STATE_WALK_IN = 0
STATE_TALK    = 1
STATE_FADEOUT = 2

# パレット暗転テーブル（画面全体がスーッと黒く吸い込まれるレトロフェード）
$FADE_PALS = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], # 0: 通常
  [0, 1, 1, 3, 2, 1, 5, 6, 2, 4,  9,  3,  1,  1,  2, 14], # 1: 暗め1
  [0, 0, 1, 1, 1, 1, 1, 5, 1, 2,  4,  1,  1,  1,  1,  2], # 2: 暗め2
  [0, 0, 0, 0, 0, 0, 0, 1, 0, 1,  2,  0,  0,  0,  0,  1], # 3: ほぼ黒
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,  0,  0,  0,  0,  0]  # 4: 完全黒
]

# 全セリフ一覧 [話者(:usagi / :kame / :both), 行1, 行2, 演出ID]
$DIALOGS = [
  [:usagi, "こんにちは！わたしはうさぎ。", nil, :greet_usagi],
  [:kame,  "わたしは亀です。", nil, :greet_kame],
  [:usagi, "これは", nil, :none],
  [:kame,  "今開発中の USAKAME GAME ENGINE のデモです。", nil, :logo],
  [:usagi, "ピクセルスタイルの", "キャラクターの描画と移動", :move],
  [:kame,  "タイルマップによる", "配置とスクロール", :scroll],
  [:usagi, "キーボードとマウス入力", nil, :input],
  [:kame,  "効果音とサウンドの再生", nil, :sound],
  [:usagi, "日本語フォントに標準対応", nil, :font],
  [:kame,  "絵文字をスプライトとして表示", "🎃⭐🩻", :emoji],
  [:usagi, "などの機能があります。", nil, :nod],
  [:kame,  "他のファンタジーコンソールと比べて一番の特徴は", nil, :light],
  [:usagi, "コードとリソースを含めて", "すべて1つのファイルで表現することです。", :singlefile],
  [:kame,  "なのでファイルさえ渡せば", nil, :handover],
  [:usagi, "usakame エンジンがあれば", "100%確実に動作します", :works],
  [:kame,  "そこから改造するのもとっても簡単です", nil, :edit],
  [:usagi, "もちろん", nil, :none],
  [:kame,  "作成したプログラムを", ".exe形式で配布したり", :exe],
  [:usagi, "ブラウザ上で動かすこともできます", nil, :browser],
  [:kame,  "興味がある人は", nil, :curious],
  [:both,  "ぜひいいね😻をお願いします！", nil, :cheer]
]

# --- 状態変数初期化 ---
def init_demo
  $state = STATE_WALK_IN
  $t = 0
  $usagi_x = -32
  $usagi_y = 102
  $kame_x = 260
  $kame_y = 106
  $target_usagi_x = 68
  $target_kame_x = 156
  $usagi_facing_front = false
  $kame_facing_front = false
  $dialog_index = 0
  $dialog_timer = 0
  $fade_step = 0
  $fade_timer = 0
  $cam_scroll_x = 0
  $particles = []
  $click_stars = []
  $prev_act = false
  $prev_click = false
  $arrived_timer = 0
  music(0)
end

init_demo

# パーティクル追加 (x, y, vx, vy, col, life, kind)
def add_particle(x, y, vx, vy, col, life, kind = :circle)
  $particles << [x, y, vx, vy, col, life, kind]
end

def update
  $t += 1

  # 入力判定 (Z, Space, Enter, 左クリック)
  act_pressed = btn(4) || btn(5) || btn(6)
  trigger_act = act_pressed && !$prev_act
  $prev_act = act_pressed

  # マウスクリックでの星エフェクト（いつでも可能）
  if btn(6) && !$prev_click
    i = 0
    while i < 6
      ang = (i * 60)
      # 簡易ベクトル
      vx = (ang == 0 || ang == 60 || ang == 300) ? 2 : -2
      vy = (ang == 60 || ang == 120) ? -2 : 2
      $click_stars << [mouse_x, mouse_y, vx, vy, 10, 16]
      i += 1
    end
    sfx(0)
  end
  $prev_click = btn(6)

  # クリック星の更新
  i = 0
  while i < $click_stars.size
    p = $click_stars[i]
    p[0] += p[2]
    p[1] += p[3]
    p[5] -= 1
    if p[5] <= 0
      $click_stars.delete_at(i)
    else
      i += 1
    end
  end

  # パーティクルの更新
  i = 0
  while i < $particles.size
    p = $particles[i]
    p[0] += p[2]
    p[1] += p[3]
    p[5] -= 1
    if p[5] <= 0
      $particles.delete_at(i)
    else
      i += 1
    end
  end

  # ============================================================================
  # 状態別の処理
  # ============================================================================
  case $state
  when STATE_WALK_IN
    # 1. 左からうさぎ、右から亀がでてくる
    if $usagi_x < $target_usagi_x
      $usagi_x += 2
      if $t % 10 == 0
        add_particle($usagi_x + 8, $usagi_y + 30, -1, 0, 6, 8, :dust)
      end
    end

    if $kame_x > $target_kame_x
      $kame_x -= 1
      if $t % 14 == 0
        add_particle($kame_x + 24, $kame_y + 30, 1, 0, 6, 8, :dust)
      end
    end

    # 2. 真ん中まで移動したら前を向く
    if $usagi_x >= $target_usagi_x && $kame_x <= $target_kame_x
      $usagi_facing_front = true
      $kame_facing_front = true
      $arrived_timer += 1
      if $arrived_timer == 1
        sfx(1) # ピロリン！
      end
      # 少しの間をおいて会話開始
      if $arrived_timer > 30 || trigger_act
        $state = STATE_TALK
        $dialog_index = 0
        $dialog_timer = 0
      end
    end

  when STATE_TALK
    $dialog_timer += 1

    cur = $DIALOGS[$dialog_index]
    scene = cur[3]

    # シーンごとの特殊インタラクション・演出
    case scene
    when :scroll
      # タイルマップスクロール
      $cam_scroll_x += 2
    when :sound
      # 効果音デモ（ポロロンと鳴らす）
      if $dialog_timer == 15
        sfx(2)
      end
      if $dialog_timer % 12 == 0
        add_particle(128 + (($t * 13) % 40) - 20, 90, 0, -1, 14, 25, :note)
      end
    when :move
      # キャラクター移動・ジャンプデモ
      if $dialog_timer % 16 == 0
        add_particle($usagi_x + 16, $usagi_y + 30, 0, 0, 7, 10, :dust)
        add_particle($kame_x + 16, $kame_y + 30, 0, 0, 7, 10, :dust)
      end
    when :cheer
      # いいね花火
      if $dialog_timer == 1
        sfx(3)
      end
      if $dialog_timer % 6 == 0
        rx = 20 + (($t * 37) % 216)
        ry = 30 + (($t * 53) % 100)
        col = (($t % 4) == 0) ? 8 : ((($t % 4) == 1) ? 10 : 14)
        add_particle(rx, ry, 0, -1, col, 30, :heart)
      end
    end

    # メッセージ送り判定 (一定時間経過、またはボタン押下)
    # 通常のセリフは140フレーム(約2.3秒)、短いのは100フレーム
    max_wait = (scene == :cheer) ? 180 : (cur[1].size > 15 ? 150 : 110)
    if trigger_act || $dialog_timer >= max_wait
      $dialog_index += 1
      $dialog_timer = 0
      sfx(0) # ピッ

      # 最後のセリフ（24. いいね）終了後 -> 25. 画面が黒く暗転
      if $dialog_index >= $DIALOGS.size
        $state = STATE_FADEOUT
        $fade_step = 0
        $fade_timer = 0
      end
    end

  when STATE_FADEOUT
    # 25. 画面が黒く暗転
    $fade_timer += 1
    if $fade_timer % 12 == 0 && $fade_step < 4
      $fade_step += 1
    end

    # 完全に暗転した後、ボタン押下で最初からリプレイ
    if $fade_step >= 4 && trigger_act
      init_demo
    end
  end
end

# ==============================================================================
# 描画処理
# ==============================================================================
def draw
  # パレット暗転適用
  pal()
  if $state == STATE_FADEOUT
    pal_table = $FADE_PALS[$fade_step]
    if pal_table
      pal(pal_table)
    end
  end

  cls(12) # 青空背景 (水色 12)

  # 遠景: 雲
  cloud_x1 = (($t / 3) + 20) % 320 - 40
  cloud_x2 = (($t / 4) + 160) % 320 - 40
  draw_cloud(cloud_x1, 28)
  draw_cloud(cloud_x2, 48)

  # 遠景: 丘
  circfill(40, 160, 90, 3)
  circfill(180, 170, 110, 3)
  circfill(250, 160, 80, 11)

  # 地面タイルマップ (スクロール演出対応)
  map_offset_x = ($cam_scroll_x % 16)
  map_cel_x = ($cam_scroll_x / 16)
  map(map_cel_x, 0, -map_offset_x, 136, 18, 8)

  # ============================================================================
  # 各シーン固有の背景・上部ギミック描画
  # ============================================================================
  if $state == STATE_TALK
    cur = $DIALOGS[$dialog_index]
    scene = cur[3]

    case scene
    when :logo
      # usakame ロゴ看板
      rectfill(38, 20, 188, 52, 0)
      rect(38, 20, 188, 52, 10)
      rect(40, 22, 186, 50, 7)
      print_text("🐰 usakame game engine 🐢", 46, 26, 10)
      print_text("RETRO 256x256 ENGINE", 62, 38, 12)

    when :font
      # 日本語フォント看板
      rectfill(30, 22, 196, 52, 1)
      rect(30, 22, 196, 52, 7)
      print_text("美咲フォント内蔵 (8x8)", 48, 26, 10)
      print_text("漢字・ひらがな・カタカナOK", 40, 38, 7)

    when :emoji
      # 絵文字スプライトが中央で大きく舞う
      rot = ($t * 4) % 360
      scale = 2.0
      spr("🎃", 64, 40, false, false, rot, scale)
      spr("⭐", 120, 36, false, false, -rot, scale)
      spr("🩻", 176, 40, false, false, rot, scale)

    when :singlefile
      # 1ファイル完結アイコン
      rectfill(40, 18, 170, 54, 0)
      rect(40, 18, 170, 54, 11)
      print_text("📄 game.rb (1 FILE ONLY!)", 50, 24, 11)
      print_text("Code + Sprites + BGM + Map", 44, 38, 7)

    when :works
      # 100% 動作スタンプ
      rectfill(56, 20, 144, 50, 8)
      rect(58, 22, 144, 48, 7)
      print_text("💯 100% 確実に動作！", 66, 30, 7)

    when :edit
      # 改造も簡単
      rectfill(44, 20, 170, 50, 4)
      rect(44, 20, 170, 50, 9)
      print_text("🔧 エディタで即改造＆即反映", 50, 30, 10)

    when :exe
      # .exe 配布
      rectfill(40, 20, 170, 50, 1)
      rect(40, 20, 170, 50, 12)
      print_text("💻 uk build -> my_game.exe", 46, 30, 12)

    when :browser
      # ブラウザ実行
      rectfill(30, 20, 196, 50, 1)
      rect(30, 20, 196, 50, 10)
      print_text("🌐 uk browser -> WebAssembly!", 44, 30, 10)

    when :input
      # 入力ギミックのガイド
      rectfill(40, 20, 170, 50, 0)
      rect(40, 20, 170, 50, 14)
      print_text("⌨️ KEYBOARD & 🖱️ MOUSE", 54, 25, 14)
      print_text("画面をクリックしてみてね！", 50, 37, 7)

    when :light
      # 注目！💡
      spr("💡", 120, 28, false, false, 0, 1.8)
    end
  end

  # ============================================================================
  # パーティクル描画
  # ============================================================================
  i = 0
  while i < $particles.size
    p = $particles[i]
    px = p[0]
    py = p[1]
    col = p[4]
    kind = p[6]
    case kind
    when :circle
      circfill(px, py, 2, col)
    when :dust
      circfill(px, py, 2, 7)
      circfill(px - 1, py + 1, 1, 6)
    when :note
      spr("🎵", px, py, false, false, 0, 1.0)
    when :heart
      spr("❤️", px, py, false, false, 0, 1.0)
    end
    i += 1
  end

  # クリック星描画
  i = 0
  while i < $click_stars.size
    p = $click_stars[i]
    spr("⭐", p[0] - 6, p[1] - 6, false, false, ($t * 8) % 360, 1.0)
    i += 1
  end

  # ============================================================================
  # うさぎと亀の描画
  # ============================================================================
  u_bounce = 0
  k_bounce = 0

  # 会話中の話者アクション
  if $state == STATE_TALK
    cur = $DIALOGS[$dialog_index]
    speaker = cur[0]
    scene = cur[3]

    if speaker == :usagi || speaker == :both
      u_bounce = (($t / 6) % 2 == 0) ? -4 : 0
    end
    if speaker == :kame || speaker == :both
      k_bounce = (($t / 8) % 2 == 0) ? -2 : 0
    end
    if scene == :move
      # 移動デモでは大きくジャンプ
      u_bounce = -8 + ((($t % 20) - 10).abs)
      k_bounce = -4 + ((($t % 16) - 8).abs)
    end
  elsif $state == STATE_WALK_IN
    # 歩行中のピョンピョン跳ね
    u_bounce = (($t / 6) % 2 == 0) ? -5 : 0
    k_bounce = (($t / 8) % 2 == 0) ? -2 : 0
  end

  # うさぎの影と本体
  ovalfill($usagi_x + 16, $usagi_y + 31, 12, 4, 0)
  if $usagi_facing_front
    spr(0, $usagi_x, $usagi_y + u_bounce, false, false, 0, 2.0)
  else
    # 横向き走りアニメーション (スプライト 2 と 3)
    sp_u = (($t / 6) % 2 == 0) ? 2 : 3
    spr(sp_u, $usagi_x, $usagi_y + u_bounce, false, false, 0, 2.0)
  end

  # 亀の影と本体
  ovalfill($kame_x + 16, $kame_y + 31, 12, 4, 0)
  if $kame_facing_front
    spr(1, $kame_x, $kame_y + k_bounce, false, false, 0, 2.0)
  else
    # 横向き歩きアニメーション (スプライト 4 と 5、左向きなので flip_x=false)
    sp_k = (($t / 8) % 2 == 0) ? 4 : 5
    spr(sp_k, $kame_x, $kame_y + k_bounce, false, false, 0, 2.0)
  end

  # 到着直後の「！」マーク
  if $state == STATE_WALK_IN && $usagi_facing_front && $arrived_timer < 30
    spr("❗", $usagi_x + 8, $usagi_y - 12)
    spr("❗", $kame_x + 8, $kame_y - 12)
  end

  # マウスカーソル（入力デモ時はカスタム星カーソル）
  if $state == STATE_TALK && $DIALOGS[$dialog_index][3] == :input
    spr("👆", mouse_x, mouse_y)
  end

  # ============================================================================
  # 会話ウィンドウ描画 (3. 下に会話ウィンドウ)
  # ============================================================================
  if $state == STATE_TALK
    cur = $DIALOGS[$dialog_index]
    speaker = cur[0]
    line1 = cur[1]
    line2 = cur[2]

    # ウィンドウ外枠・背景 (x: 10, y: 168, w: 236, h: 78)
    rectfill(10, 168, 236, 236, 1) # 濃紺 1
    rect(10, 168, 236, 236, 7)     # 白枠 7
    rect(12, 170, 232, 232, 5)     # 暗灰内枠 5

    # 話者ネームプレート
    plate_w = (speaker == :both) ? 80 : 30
    rectfill(20, 158, 20 + plate_w, 15, 0) # 黒背景
    case speaker
    when :usagi
      rect(20, 158, 20 + plate_w, 15, 14)   # ピンク枠
      print_text("🐰 うさぎ", 24, 161, 14)
    when :kame
      rect(20, 158, 20 + plate_w, 15, 11)   # 緑枠
      print_text("🐢 かめ", 24, 161, 11)
    when :both
      rect(20, 158, 20 + plate_w, 15, 10)   # 黄枠
      print_text("🐰 うさぎ ＆ 🐢 かめ", 24, 161, 10)
    end

    # セリフ描画
    if line1
      print_text(line1, 22, 182, 7)
    end
    if line2
      print_text(line2, 22, 198, 7)
    end

    # 次へ促すカーソル点滅 (▼)
    if ($t / 15) % 2 == 0
      print_text("▼", 232, 232, 10)
    end

    # 操作ガイド（小さく下部に表示）
    print_text("[Z/Space/Click] 次へ", 24, 232, 6)
  end

  # ============================================================================
  # 暗転完了後の終了画面
  # ============================================================================
  if $state == STATE_FADEOUT && $fade_step >= 4
    # 完全な暗転
    rectfill(0, 0, 255, 255, 0)
    print_text("✨ DEMO FINISHED ✨", 64, 100, 10)
    print_text("usakame game engine", 68, 120, 7)
    print_text("[Z / Space / Click] to Replay", 40, 150, 6)
  end
end

# 雲を描画するヘルパー
def draw_cloud(x, y)
  ovalfill(x + 16, y + 8, 16, 8, 7)
  ovalfill(x + 28, y + 10, 12, 6, 7)
  ovalfill(x + 6, y + 10, 10, 5, 7)
end

__END__
# ==============================================================================
# スプライト定義
# ==============================================================================

# 0: 🐰 ウサギ (正面)
@SPRITE 0
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777...
...7777777777...
..888888888888..
.77707777770777.
.77707777770777.
.777777EE777777.
..777777777777..
...8888AA8888...
..778888888877..
..77.777777.77..
....777..777....
...777....777...
................

# 1: 🐢 カメ (正面)
@SPRITE 1
................
.....BBBBBB.....
...BB333333BB...
..B33BBBBBB33B..
.B3BB33BB33BB3B.
.B3B333BB333B3B.
77B3BBBBBBBB3B77
70B333BBBB333B07
77BBBB3333BBBB77
.77999999999977.
..99AA9999AA99..
...BB999999BB...
..BBBB....BBBB..
..B33B....B33B..
................
................

# 2: 🐰 ウサギ (右向き横走り 1)
@SPRITE 2
....77..........
...7EE7.........
...7EE7.........
....777777......
...88888888.....
..7777777707....
..7777777707....
...777777EE7....
....7777777.....
.....8888AA.....
....77888887....
....77.7777.....
...77...777.....
...77....777....
................
................

# 3: 🐰 ウサギ (右向き横走り 2)
@SPRITE 3
....77..........
...7EE7.........
...7EE7.........
....777777......
...88888888.....
..7777777707....
..7777777707....
...777777EE7....
....7777777.....
.....8888AA.....
....77888887....
.....77..77.....
.....777.777....
......77..77....
................
................

# 4: 🐢 カメ (左向き横歩き 1)
@SPRITE 4
................
.......BBBBBB...
.....BB333333B..
...BB33BBBBBB33.
.77B3BB33BB33BB.
.70B3B333BB333B.
777B3BBBBBBBB3B.
.7779999999999B.
..99AA9999AA99..
...BB999999BB...
..BBBB....BBBB..
..B33B....B33B..
................
................
................
................

# 5: 🐢 カメ (左向き横歩き 2)
@SPRITE 5
................
.......BBBBBB...
.....BB333333B..
...BB33BBBBBB33.
.77B3BB33BB33BB.
.70B3B333BB333B.
777B3BBBBBBBB3B.
.7779999999999B.
..99AA9999AA99..
...BB999999BB...
...BBBB..BBBB...
...B33B..B33B...
................
................
................
................

# 6: 草原の地面タイル
@SPRITE 6
BBBBBBBBBBBBBBBB
BBBBBBBBBBBBBBBB
3333333333333333
4444444444444444
4494444444494444
4444449444444444
4444444444444444
4449444444449444
4444444444444444
4444444944444444
4494444444494444
4444444444444444
4444449444444444
4444444444444444
4449444444449444
4444444444444444

# 7: 地中の土タイル
@SPRITE 7
4444444444444444
4494444444494444
4444449444444444
4444444444444444
4449444444449444
4444444444444444
4444444944444444
4494444444494444
4444444444444444
4444449444444444
4444444444444444
4449444444449444
4444444444444444
4444444944444444
4494444444494444
4444444444444444

# 8: お花
@SPRITE 8
................
................
.....AAAA.......
....AAEEAA......
....AAEEAA......
.....AAAA.......
......BB........
.....BBB........
......BB........
......BB........
................
................
................
................
................
................

# 9: レンガ
@SPRITE 9
5555555055555550
6666665066666650
6777765067777650
6755565067555650
6666665066666650
5555555055555550
0000000000000000
5550555555505555
6650666666506666
7650677776506777
5650675556506755
6650666666506666
5550555555505555
0000000000000000
5555555055555550
6666665066666650

# タイルマップ (32x8)
@MAP 0 0
................................
................................
..8......8............8......8..
66666666666666666666666666666666
77777777777777777777777777777777
77777777777777777777777777777777
77777777777777777777777777777777
77777777777777777777777777777777

# ==============================================================================
# 効果音 (@SFX) & BGM (@MUSIC)
# ==============================================================================
# 0: セリフ送り音
@SFX 0 wave=pulse speed=1 c4:fade

# 1: 登場・前向き音
@SFX 1 wave=square speed=2 c3 e3 g3 c4:fade

# 2: サウンド紹介
@SFX 2 wave=pulse speed=2 c3 e3 g3 b3 c4:arp:fade

# 3: いいねファンファーレ
@SFX 3 wave=square speed=3 c3 e3 g3 c4 e4 g4 c5:arp:fade

# 0: ほのぼのBGM
@MUSIC 0
ch0 wave=pulse vol=3 T120 L8 O4 c e g > c < b g a f  e g > c < g e g f d  c e g > c < b > d c < b  a f g b > c2
ch1 wave=tri   vol=5 T120 L4 O3 c e f g  c e f g  c e f g  c g c2

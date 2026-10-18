# ==============================================================================
# USAKAME VGA / PC-98 Retro Resolution Demo
#
# このデモでは、usakame の高解像度 (640x480 VGA) 対応と、
# 16x16 東雲ゴシックフォント、16x16 Twemoji、グローバル sprite_scale: 2
# による PC-98 / 90年代レトロPC風の表現を実演します。
#
# 起動:
#   uk run examples/resolution.rb
# ==============================================================================

config(
  width: 640,
  height: 480,
  scale: 1.5,
  sprite_scale: 2.0,
  text_size: 16,
  title: "USAKAME - 640x480 VGA / PC-98 Mode"
)

# 定数・パレット風カラー
COL_BG       = 1   # 濃紺
COL_PANEL    = 0   # 黒
COL_BORDER   = 6   # 明るいグレー
COL_WHITE    = 7   # 白
COL_YELLOW   = 10  # 黄
COL_GREEN    = 11  # 緑
COL_CYAN     = 12  # 水色
COL_PURPLE   = 13  # 紫
COL_PINK     = 14  # ピンク
COL_ORANGE   = 9   # 橙

$frame = 0
$px = 80
$py = 80
$msg_page = 0

MESSAGES = [
  "【長老ウサギ】🐰\n「よくぞ参られた、旅の冒険者よ。\nここは解像度 640x480 の新世界・うさかめ王国じゃ。\n16x16 の東雲ゴシックと絵文字が美しく並んでおるじゃろ？」",
  "【カメ騎士】🐢\n「sprite_scale が 2.0 に設定されているため、\nスプライトやタイルマップも自動的に2倍（32x32px）\nで大きくドット感を保ったまま描画されますぞ！」",
  "【案内人】⭐\n「text_size はデフォルトで 16px (東雲ゴシック) になりますが、\nprint_text の size: 8 オプションを使えば、\n従来の 8x8 美咲フォントも自由に混在表示可能です！」"
]

def update
  $frame += 1

  # カーソルキーでプレイヤー移動
  speed = 3
  if btn(:left) || btn("a")
    $px -= speed
  end
  if btn(:right) || btn("d")
    $px += speed
  end
  if btn(:up) || btn("w")
    $py -= speed
  end
  if btn(:down) || btn("s")
    $py += speed
  end

  # 画面内に制限 (歩行可能エリア)
  $px = 24 if $px < 24
  $px = 616 if $px > 616
  $py = 56 if $py < 56
  $py = 310 if $py > 310

  # メッセージ送り (Space / Z / Click)
  if btnp(4) || btnp(5) || btnp(:mouse_l)
    $msg_page = ($msg_page + 1) % MESSAGES.size
    sfx(0) if respond_to?(:sfx)
  end
end

def draw
  # 背景クリア
  cls(COL_BG)

  # 1. タイルマップ（sprite_scale: 2 により 32x32px グリッドで描画）
  map(0, 0, 16, 48, 20, 10)

  # 2. プレイヤー（ウサギ 🐰）と カメ (🐢)
  # スプライト 1, 2 を描画（グローバル scale 2.0 が適用される）
  spr(1, $px - 16, $py - 16)
  spr(2, 480, 140)

  # 3. 上部ステータスバー (PC-98 / DOS 風)
  rectfill(0, 0, 640, 36, COL_PANEL)
  line(0, 36, 640, 36, COL_BORDER)
  line(0, 38, 640, 38, COL_BORDER)

  # 16px フォントでタイトル
  print_text("USAKAME PC-98 ARCHITECTURE  [640x480 VGA]", 16, 10, COL_YELLOW)

  # 8px フォントで詳細システム情報（混在表示の検証）
  print_text("SPRITE_SCALE: 2.0x  |  SYS_MEM: 640KB  |  FPS: 60", 390, 8, COL_WHITE, size: 8)
  print_text("FONT: SHINONOME 16 + MISAKI 8 + TWEMOJI", 390, 20, COL_CYAN, size: 8)

  # 4. 下部メッセージウィンドウ
  draw_window(16, 340, 608, 124, "MESSAGE / 会話")

  # メッセージ本文（16px 東雲ゴシック + Twemoji）
  cur_msg = MESSAGES[$msg_page]
  lines = cur_msg.split("\n")
  lines.each_with_index do |line_str, idx|
    col = (idx == 0) ? COL_YELLOW : COL_WHITE
    print_text(line_str, 32, 368 + idx * 22, col, size: 16)
  end

  # ページ送り案内
  guide_text = "[ SPACE / Z / クリック で次へ (#{$msg_page + 1}/#{MESSAGES.size}) ]"
  print_text(guide_text, 360, 442, COL_PINK, size: 8)

  # 5. サイドミニ情報
  print_text("POS: (#{$px}, #{$py})", 24, 322, COL_GREEN, size: 8)
end

# 枠線付きウィンドウ描画ヘルパー
def draw_window(x, y, w, h, title = "")
  # 背景
  rectfill(x, y, w, h, COL_PANEL)
  # 外枠
  rect(x, y, w, h, COL_BORDER)
  rect(x + 2, y + 2, w - 4, h - 4, COL_BORDER)

  # タイトルバー
  if title != ""
    title_w = title.length * 8 + 16
    rectfill(x + 16, y - 4, title_w, 14, COL_PANEL)
    print_text(title, x + 20, y - 3, COL_CYAN, size: 8)
  end
end

__END__
@SPRITE 1 16 16
................
..3333....3333..
.377773..377773.
.37ee73..37ee73.
.37ee73..37ee73.
.377773..377773.
..333333333333..
.3777777777773..
.3707777770773..
.37077ee770773..
.37777ee777773..
..37777777773...
...333333333....
....33....33....
...3773..3773...
....33....33....
@SPRITE 2 16 16
................
.....333333.....
....3bbbbbb3....
...3b3bbbb3b3...
...3b0bbbb0b3...
...3bbbbbbbb3...
..333333333333..
.3bbbbbbbbbbbb3.
.3b3333333333b3.
.3b3bbbbbbbb3b3.
.3b3bbbbbbbb3b3.
.3b3333333333b3.
..333333333333..
...33......33...
..3bb3....3bb3..
...33......33...
@SPRITE 3 16 16
3333333333333333
3dddddddddddddd3
3d............d3
3d.4444444444.d3
3d.4555555554.d3
3d.45dddddd54.d3
3d.45dddddd54.d3
3d.45dddddd54.d3
3d.45dddddd54.d3
3d.45dddddd54.d3
3d.45dddddd54.d3
3d.4555555554.d3
3d.4444444444.d3
3d............d3
3dddddddddddddd3
3333333333333333
@MAP 0 0
33333333333333333333
3..................3
3..................3
3..................3
3..................3
3..................3
3..................3
3..................3
33333333333333333333

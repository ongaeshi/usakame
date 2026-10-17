# Sound Demo (sfx / music / @SFX / @MUSIC)
# 上下キー: 効果音を選択   Z / Space: 再生
# X / Enter: BGM 再生 / 停止
#
# サウンドはすべてこのスクリプト内（__END__ 以降の @SFX / @MUSIC）で定義されています。

$items = [
  [:jump,      "preset :jump"],
  [:coin,      "preset :coin"],
  [:laser,     "preset :laser"],
  [:explosion, "preset :explosion"],
  [:hit,       "preset :hit"],
  [:powerup,   "preset :powerup"],
  [:select,    "preset :select"],
  [:gameover,  "preset :gameover"],
  [0,          "@SFX 0 (square arpeggio)"],
  [1,          "@SFX 1 (slide up)"],
  [2,          "@SFX 2 (noise drum)"],
  [3,          "@SFX 3 (jump pitch=1.5)"],
  ["tri c3 e3 g3 c4:fade", "inline string"]
]
$cursor = 0
$playing_bgm = false
$prev_up = false
$prev_down = false
$prev_z = false
$prev_x = false
$flash = 0
$t = 0

def update
  $t += 1
  $flash -= 1 if $flash > 0

  up = btn(2)
  down = btn(3)
  z = btn(4)
  x = btn(5)

  if up && !$prev_up
    $cursor = ($cursor - 1) % $items.size
    sfx(:click)
  end
  if down && !$prev_down
    $cursor = ($cursor + 1) % $items.size
    sfx(:click)
  end
  if z && !$prev_z
    sfx($items[$cursor][0])
    $flash = 8
  end
  if x && !$prev_x
    if $playing_bgm
      stop_music
    else
      music(0)
    end
    $playing_bgm = !$playing_bgm
  end

  $prev_up = up
  $prev_down = down
  $prev_z = z
  $prev_x = x
end

def draw
  cls(1)
  print_text("SOUND DEMO", 8, 8, 10)
  print_text("UP/DOWN: select  Z: play", 8, 20, 6)
  print_text("X: BGM " + ($playing_bgm ? "ON " : "OFF"), 8, 30, $playing_bgm ? 11 : 6)

  i = 0
  while i < $items.size
    y = 48 + i * 12
    if i == $cursor
      rectfill(4, y - 2, 251, y + 8, $flash > 0 ? 8 : 2)
      print_text(">", 8, y, 7)
    end
    print_text($items[i][1], 18, y, 7)
    i += 1
  end

  # BGM 再生中は簡易イコライザ風アニメーション
  if $playing_bgm
    k = 0
    while k < 16
      h = ((($t / 4) + k * 7) % 11) + 2
      rectfill(8 + k * 15, 250 - h, 18 + k * 15, 250, 12)
      k += 1
    end
  end
end

__END__
# ---- 効果音 ----
# 書式: @SFX <id> [wave=... speed=...] 音符...
#   音符: c d e f g a b (+ # で半音上げ, - で半音下げ) + オクターブ数字 (c2 = C4)
#   r / . は休符、 :fade :slide :vib :drop :arp でノート単位のエフェクト
@SFX 0
wave square
speed 4
c3 e3 g3 c4 g3 e3 c3:fade

@SFX 1 wave=pulse speed=3 c2 c4:slide

@SFX 2 wave=noise speed=3 c4 r c2:fade

# プリセットにパラメータを付けて別IDとして登録
@SFX 3 :jump pitch=1.5

# ---- BGM ----
# ch0..ch3 に MML (T=テンポ, L=デフォルト音長, O=オクターブ, < > でオクターブ移動) を記述
@MUSIC 0
ch0 wave=square vol=4 T140 L8 O4 c e g > c < g e c e  d f a > d < a f d f  e g b > e < b g e g  c e g > c4 < c4
ch1 wave=tri vol=6 T140 L4 O3 c c g g  d d a a  e e b b  c g c2
ch2 wave=noise vol=3 T140 L8 O6 c r c c  c r c c  c r c c  c r c c  c r c c  c r c c  c r c c  c r c c

# 名前付き @SFX / @MUSIC ・ シンセレシピ ・ プリセット効果音サンプル
# 操作:
#   上下キー: 項目選択
#   Z / Enter / Space: SFX 再生
#   X: BGM 切替 (:field_theme <-> :boss_theme <-> 停止)

config(width: 256, height: 256, scale: 2, title: "Sound Recipe & Named Symbols")

$items = [
  [:laser_up,  "Custom @SFX :laser_up (recipe)"],
  [:explode,   "Custom @SFX :explode (recipe)"],
  [:jump,      "Overridden :jump (@SFX :jump)"],
  [:confirm,   "Preset :confirm"],
  [:cancel,    "Preset :cancel"],
  [:slash,     "Preset :slash"],
  [:splash,    "Preset :splash"],
  [:clear,     "Preset :clear"],
  [:heal,      "Preset :heal"],
  [:inline,    "Inline recipe sfx(...)"]
]

$cursor = 0
$bgm_mode = 0
$last_msg = "Press Z to play SFX, X to toggle BGM"

def play_selected
  entry = $items[$cursor]
  sym = entry[0]
  if sym == :inline
    sfx("wave:saw freq:220->880->330 dur:0.22 env:punch vol:0.8")
    $last_msg = "Played inline synth recipe"
  else
    sfx(sym)
    $last_msg = "Played :#{sym}"
  end
end

def toggle_bgm
  $bgm_mode = ($bgm_mode + 1) % 3
  if $bgm_mode == 1
    music(:field_theme, true, 0.6)
    $last_msg = "BGM: :field_theme"
  elsif $bgm_mode == 2
    music(:boss_theme, true, 0.6)
    $last_msg = "BGM: :boss_theme"
  else
    music(nil)
    $last_msg = "BGM: stopped"
  end
end

def update
  if btnp(:up)
    $cursor = ($cursor - 1 + $items.size) % $items.size
    sfx(:select)
  elsif btnp(:down)
    $cursor = ($cursor + 1) % $items.size
    sfx(:select)
  end

  if btnp(:a) || btnp(:enter) || btnp(:space)
    play_selected
  end

  if btnp(:b)
    toggle_bgm
  end
end

def draw
  cls(1)
  print_text("SOUND RECIPE & NAMED SFX", 128, 12, 7, align: :center)
  print_text("UP/DOWN: Select  Z: Play  X: BGM", 128, 26, 6, align: :center)

  y = 46
  i = 0
  while i < $items.size
    label = $items[i][1]
    col = (i == $cursor) ? 10 : 7
    prefix = (i == $cursor) ? "> " : "  "
    print_text(prefix + label, 16, y, col)
    y += 16
    i += 1
  end

  rectfill(8, 224, 240, 22, 0)
  print_text($last_msg, 16, 231, 11)
end

__END__
@SFX :laser_up
wave:square freq:440->880 dur:0.15 env:decay vol:0.8

@SFX :explode
wave:noise freq:240->55 dur:0.32 env:decay vol:0.9

@SFX :jump
wave:pulse freq:240->720 dur:0.14 env:decay vol:0.85

@MUSIC :field_theme
ch0 T132 L8 O4 c e g > c < g e c4
ch1 T132 L4 O3 c g e g

@MUSIC :boss_theme
ch0 T156 L8 O4 e f# g b a g f# d
ch1 T156 L8 O3 e e b b e e d d

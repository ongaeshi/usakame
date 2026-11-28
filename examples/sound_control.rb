# Sound Control Demo (tone / pitch / music(nil) / volumes / cooldown)
# UP/DOWN: Select action or volume bar
# LEFT/RIGHT: Adjust volume or pitch
# Z: Trigger selected action
# X: Toggle BGM (music(0) / music(nil))

$cursor = 0
$bgm_on = true
$combo = 0
$tone_wave_idx = 0
$waves = [:square, :pulse, :triangle, :saw, :noise, :sine]
$flash = 0
$t = 0

$prev_up = false
$prev_down = false
$prev_left = false
$prev_right = false
$prev_z = false
$prev_x = false

music(0, true, 0.7)

def clamp01(v)
  return 0.0 if v < 0.0
  return 1.0 if v > 1.0
  v
end

def update
  $t += 1
  $flash -= 1 if $flash > 0

  up = btn(:up)
  down = btn(:down)
  left = btn(:left)
  right = btn(:right)
  z = btn(1)
  x = btn(2)

  if up && !$prev_up
    $cursor = ($cursor - 1) % 7
    sfx(:click)
  end
  if down && !$prev_down
    $cursor = ($cursor + 1) % 7
    sfx(:click)
  end

  if left && !$prev_left
    if $cursor == 4
      master_vol(clamp01(master_vol - 0.1))
    elsif $cursor == 5
      sfx_vol(clamp01(sfx_vol - 0.1))
    elsif $cursor == 6
      music_vol(clamp01(music_vol - 0.1))
    end
  end

  if right && !$prev_right
    if $cursor == 4
      master_vol(clamp01(master_vol + 0.1))
    elsif $cursor == 5
      sfx_vol(clamp01(sfx_vol + 0.1))
    elsif $cursor == 6
      music_vol(clamp01(music_vol + 0.1))
    end
  end

  if z && !$prev_z
    $flash = 8
    if $cursor == 0
      # tone(freq, dur, wave, vol, slide)
      w = $waves[$tone_wave_idx]
      tone(330, 0.18, w, 0.6, 330.0)
      $tone_wave_idx = ($tone_wave_idx + 1) % $waves.size
    elsif $cursor == 1
      # sfx pitch combo
      p = 0.8 + ($combo % 8) * 0.15
      sfx(:coin, -1, 0.9, p)
      $combo += 1
    elsif $cursor == 2
      # Cooldown & voice-stealing stress test (12 calls in 1 frame)
      i = 0
      while i < 12
        sfx(:laser, -1, 0.7, 0.8 + (i % 5) * 0.15)
        i += 1
      end
    elsif $cursor == 3
      if $bgm_on
        music(nil)
      else
        music(0, true, 0.7)
      end
      $bgm_on = !$bgm_on
    end
  end

  if x && !$prev_x
    if $bgm_on
      music(nil)
    else
      music(0, true, 0.7)
    end
    $bgm_on = !$bgm_on
  end

  $prev_up = up
  $prev_down = down
  $prev_left = left
  $prev_right = right
  $prev_z = z
  $prev_x = x
end

def draw_vol_bar(label, val, y, selected)
  col = selected ? 10 : 7
  print_text(label, 14, y, col)
  rectfill(110, y + 1, 210, y + 7, 2)
  w = (val * 100).to_i
  rectfill(110, y + 1, 110 + w, y + 7, selected ? 11 : 12) if w > 0
  pct = (val * 100).round.to_s + "%"
  print_text(pct, 216, y, col)
end

def draw
  cls(1)
  print_text("SOUND CONTROL DEMO", 8, 8, 10)
  print_text("Z: Trigger  X: BGM  L/R: Vol", 8, 20, 6)

  labels = [
    "1. tone() slide [" + $waves[$tone_wave_idx].to_s + "]",
    "2. sfx() pitch combo (" + $combo.to_s + ")",
    "3. sfx() 12x spam guard",
    "4. music(nil) toggle: " + ($bgm_on ? "ON" : "OFF")
  ]

  i = 0
  while i < labels.size
    y = 42 + i * 16
    if i == $cursor
      rectfill(6, y - 2, 249, y + 10, $flash > 0 ? 8 : 2)
      print_text(">", 8, y, 10)
    end
    print_text(labels[i], 18, y, 7)
    i += 1
  end

  draw_vol_bar("5. master_vol", master_vol, 116, $cursor == 4)
  draw_vol_bar("6. sfx_vol", sfx_vol, 134, $cursor == 5)
  draw_vol_bar("7. music_vol", music_vol, 152, $cursor == 6)

  if $bgm_on
    k = 0
    while k < 16
      h = ((($t / 4) + k * 5) % 10) + 2
      rectfill(8 + k * 15, 246 - h, 18 + k * 15, 246, 12)
      k += 1
    end
  end
end

__END__
@MUSIC 0
ch0 T132 L8 O2 wave=square vol=0.45 c e g c3 b g e g
ch1 T132 L4 O1 wave=triangle vol=0.60 c g a g

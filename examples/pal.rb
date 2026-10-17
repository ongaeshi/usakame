# Color Palette & Transparency Sample (pal / palt)
# 矢印キー左右: 下部ミニシーンのパレットプリセット切替 (NORMAL / NIGHT / SUNSET / RETRO GB)
# Z / Space: ダメージ白フラッシュ演出 (全色 -> 7:White)
# X / Enter: palt デモの透過色切替

$t = 0
$scene_mode = 0
$prev_left = false
$prev_right = false

# 16色パレット置換テーブル (シーン全体の雰囲気をガラリと変える)
$SCENE_PALETTES = [
  # 0: NORMAL (デフォルト)
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  # 1: NIGHT (夜・寒色系シフト)
  [0, 0, 1, 1, 2, 1, 13, 12, 2, 4, 12, 3, 1, 5, 13, 6],
  # 2: SUNSET (夕焼け・暖色系シフト)
  [2, 2, 4, 4, 9, 4, 15, 10, 8, 9, 10, 9, 14, 2, 9, 10],
  # 3: RETRO MONO (緑モノクロ 4階調風)
  [0, 0, 3, 3, 3, 3, 11, 10, 3, 11, 10, 11, 11, 3, 11, 10]
]
$SCENE_NAMES = ["0:NORMAL", "1:NIGHT", "2:SUNSET", "3:MONO-GB"]

def update
  $t += 1

  left = btn(0)
  right = btn(1)
  if left && ($prev_left == false)
    $scene_mode = ($scene_mode - 1) % 4
  elsif right && ($prev_right == false)
    $scene_mode = ($scene_mode + 1) % 4
  end
  $prev_left = left
  $prev_right = right
end

def draw
  pal()
  cls(0)

  # ヘッダ
  rectfill(0, 0, 256, 14, 1)
  print_text("PAL & PALT DEMO (COLOR SWAP)", 8, 4, 10)

  # ========================================================
  # 1. pal(c0, c1): 同一スプライトから色違いキャラ・状態異常を描画
  # ========================================================
  print_text("1. SPRITE COLOR VARIANTS (pal)", 8, 18, 7)
  rect(6, 28, 244, 52, 5)

  flash_all = btn(4) || (($t / 30) % 4 == 3 && ($t % 6 < 3))

  # (A) 1P Default (Red)
  pal()
  spr(0, 16, 34, false, false, 0, 1.5)
  print_text("1P RED", 12, 64, 8)

  # (B) 2P Blue (赤8->青12, ピンク14->水色6, 茶4->紺1)
  pal()
  pal(8, 12)
  pal(14, 6)
  pal(4, 1)
  spr(0, 62, 34, false, false, 0, 1.5)
  print_text("2P BLU", 58, 64, 12)

  # (C) 3P Green (赤8->緑11, ピンク14->黄10, 黄10->白7)
  pal()
  pal(8, 11)
  pal(14, 10)
  pal(10, 7)
  spr(0, 108, 34, false, false, 0, 1.5)
  print_text("3P GRN", 104, 64, 11)

  # (D) Poison (毒状態: 肌15->紫13, 赤8->紫2, 黄10->ピンク14)
  pal()
  pal(15, 13)
  pal(8, 2)
  pal(10, 14)
  spr(0, 154, 34, false, false, 0, 1.5)
  print_text("POISON", 150, 64, 14)

  # (E) Damage Flash / Star Rainbow (白フラッシュ or 無敵レインボー)
  pal()
  if flash_all
    c = 0
    while c < 16
      pal(c, 7)
      c += 1
    end
  else
    cycle = [8, 9, 10, 11, 12, 14][($t / 4) % 6]
    pal(8, cycle)
    pal(14, (cycle + 2) % 16)
  end
  spr(0, 204, 34, false, false, 0, 1.5)
  print_text(flash_all ? "FLASH!" : "STAR", 202, 64, flash_all ? 7 : 10)

  pal()

  # ========================================================
  # 2. palt(col, t): 特定パレット色の透過オン/オフ
  # ========================================================
  print_text("2. TRANSPARENCY CONTROL (palt)", 8, 86, 7)
  rect(6, 96, 244, 52, 5)

  # 背面チェッカーボード（透過確認用）
  cy = 100
  while cy < 136
    cx = 14
    while cx < 242
      col = (((cx / 6) + (cy / 6)) % 2 == 0) ? 5 : 13
      rectfill(cx, cy, 6, 6, col)
      cx += 6
    end
    cy += 6
  end

  # 左: palt リセット (背景色 1:Dark Blue と 11:Green がそのまま不透明で描画される)
  palt()
  spr(1, 28, 102, false, false, 0, 1.5)
  rectfill(14, 136, 68, 9, 0)
  print_text("palt() OFF", 18, 137, 6)

  # 中央: palt(1, true) で外枠背景の 1:Dark Blue だけ透過
  palt()
  palt(1, true)
  spr(1, 112, 102, false, false, 0, 1.5)
  rectfill(92, 136, 76, 9, 0)
  print_text("palt(1,true)", 96, 137, 12)

  # 右: palt(1, true) + palt(11, true) (または X ボタンで切替)
  palt()
  palt(1, true)
  if btn(5) == false
    palt(11, true)
  end
  spr(1, 196, 102, false, false, 0, 1.5)
  rectfill(174, 136, 72, 9, 0)
  print_text(btn(5) ? "HOLD X:1" : "palt(1&11)", 178, 137, 11)

  pal()

  # ========================================================
  # 3. シーン全体のパレット一括変換 (図形・スプライト・テキスト共通)
  # ========================================================
  print_text("3. SCENE PALETTE: #{$SCENE_NAMES[$scene_mode]}", 8, 154, 10)

  # ミニシーン領域にクリッピングしてパレット適用
  clip(6, 164, 244, 72)
  pal($SCENE_PALETTES[$scene_mode])

  # 空と太陽・月
  rectfill(6, 164, 244, 72, 12)
  ovalfill(200, 182, 16, 10, 10)
  circfill(200, 182, 7, 7)

  # 遠景の山々と地面
  trifill(20, 220, 75, 174, 130, 220, 3)
  trifill(95, 220, 155, 170, 220, 220, 3)
  rectfill(6, 218, 244, 18, 11)
  line(6, 218, 250, 218, 7)

  # ミニシーン内を走るキャラと絵文字
  hx = 24 + (($t * 2) % 196)
  spr(0, hx, 204, ($t / 12) % 2 == 1, false, 0, 1.0)
  spr("🌲", 48, 202)
  spr("🏠", 140, 202)
  print_text("WORLD PALETTE!", 16, 170, 7)

  # クリッピングとパレットを元に戻して枠線とフッタを描画
  pal()
  clip()
  rect(6, 164, 244, 72, 7)

  print_text("<-/->:SCENE PAL  Z:FLASH  X:PALT", 10, 242, 6)
end

__END__
@SPRITE 0
....88888888....
...8888888888...
..88EEEEEEEE88..
..888888888888..
...FFF71FF71F...
...FFF70FF70F...
...FFFFFFFFFF...
....FFFF88FF....
...8888AA8888...
..8888AAAA8888..
..FF88888888FF..
..FF.CCCCCC.FF..
.....CC..CC.....
....CC....CC....
...444....444...
...444....444...
@SPRITE 1
1111111111111111
1bbbbbbbbbbbbbb1
1bbbbb8888bbbbB1
1bbbb88aa88bbbb1
1bbb88a77a88bbb1
1bb88a7777a88bb1
1bb8aa7777aa8bb1
1bb8aa7777aa8bb1
1bb88a7777a88bb1
1bbb88a77a88bbb1
1bbbb88aa88bbbb1
1bBbbbb88bbbbbB1
1bbbbbbbbbbbbbb1
1111111111111111
1111111111111111
1111111111111111

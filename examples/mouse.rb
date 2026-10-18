# ==========================================
# Usakame Sample: Mouse & Cursor Interactive Demo
# 実行コマンド: uk run examples/mouse.rb
# ==========================================

# OS のマウスカーソルを非表示にし、ゲーム内カスタムカーソルを描画
show_mouse(false)

# ペイントキャンバスと描画状態
$canvas_w = 224
$canvas_h = 160
$canvas_x = 16
$canvas_y = 56

# キャンバスのピクセルデータ（16x16のグリッドではなくドット配列）
# 軽量にするため、スタンプ/ドットの履歴リストとして管理
$dots = []
$current_col = 8    # 初期描画色 (赤)
$pen_size = 2       # ペンサイズ (1〜5)
$cursor_mode = 0    # 0: 絵文字カーソル (👆/✏️), 1: スプライトレトロ矢印
$click_effect_t = 0
$click_fx = 0
$click_fy = 0

# パレット選択肢 (PICO-8 カラー)
$palette_choices = [8, 9, 10, 11, 12, 14, 7, 0]

def update
  mx = mouse_x
  my = mouse_y

  # 1. ホイールでペンサイズ変更 (上スクロールで拡大、下スクロールで縮小)
  wheel = mouse_wheel
  if wheel > 0.2
    $pen_size = [$pen_size + 1, 6].min
    sfx(:cursor)
  elsif wheel < -0.2
    $pen_size = [$pen_size - 1, 1].max
    sfx(:cursor)
  end

  # 2. クリックエフェクトのタイマー減少
  $click_effect_t = [$click_effect_t - 1, 0].max

  # 3. パレットUIボタンのクリック判定
  if btnp(:mouse_l)
    # パレットボタン行 (y: 28〜44)
    if my >= 28 && my <= 44
      $palette_choices.each_with_index do |col, i|
        bx = 16 + i * 20
        if mx >= bx && mx < bx + 16
          $current_col = col
          sfx(:select)
        end
      end

      # クリアボタン (x: 184〜216)
      if mx >= 184 && mx <= 216
        $dots = []
        sfx(:boom)
      end

      # カーソル切り替えボタン (x: 224〜240)
      if mx >= 224 && mx <= 240
        $cursor_mode = 1 - $cursor_mode
        sfx(:click)
      end
    end
  end

  # 4. キャンバス内での描画 (左ドラッグで描画、右クリックで消しゴム)
  in_canvas = (mx >= $canvas_x && mx < $canvas_x + $canvas_w &&
               my >= $canvas_y && my < $canvas_y + $canvas_h)

  if in_canvas
    if btnp(:mouse_l)
      $click_effect_t = 8
      $click_fx = mx
      $click_fy = my
      sfx(:click)
    end

    if btn(:mouse_l)
      # ペンドット追加（多すぎたら古いものから削除）
      $dots << [mx, my, $current_col, $pen_size]
      $dots.shift if $dots.size > 800
    elsif btn(:mouse_r)
      # 右クリックで消しゴム（黒で上書き）
      $dots << [mx, my, 0, $pen_size * 2]
      $dots.shift if $dots.size > 800
    end
  end
end

def draw
  cls(1) # 濃紺で背景クリア

  # --- ヘッダーUI ---
  rectfill(0, 0, 256, 24, 0)
  line(0, 24, 255, 24, 12)
  print_text("MOUSE & CURSOR DEMO 🎨✨", 10, 4, 10)
  print_text("L:Draw  R:Erase  Wheel:Size", 10, 14, 6)

  # --- パレット & ツールバー (y: 28〜46) ---
  $palette_choices.each_with_index do |col, i|
    bx = 16 + i * 20
    rectfill(bx, 28, 16, 16, col)
    if col == $current_col
      rect(bx - 1, 27, 18, 18, 7) # 選択枠
    else
      rect(bx, 28, 16, 16, 5)
    end
  end

  # [CLR] ボタン
  rectfill(184, 28, 32, 16, 2)
  rect(184, 28, 32, 16, 8)
  print_text("CLR", 192, 33, 7)

  # カーソル切り替えボタン
  rectfill(224, 28, 18, 16, 3)
  rect(224, 28, 18, 16, 11)
  print_text($cursor_mode == 0 ? "👆" : "🏹", 226, 33, 7)

  # --- ペイントキャンバス ---
  rectfill($canvas_x - 2, $canvas_y - 2, $canvas_w + 4, $canvas_h + 4, 5)
  rectfill($canvas_x, $canvas_y, $canvas_w, $canvas_h, 0)
  rect($canvas_x - 1, $canvas_y - 1, $canvas_w + 2, $canvas_h + 2, 6)

  # クリッピングを設定してキャンバス外にはみ出さないように描画
  clip($canvas_x, $canvas_y, $canvas_w, $canvas_h)
  $dots.each do |dot|
    x = dot[0]
    y = dot[1]
    col = dot[2]
    sz = dot[3]
    if sz <= 1
      pset(x, y, col)
    else
      circfill(x, y, sz, col)
    end
  end
  clip # クリッピング解除

  # クリック時の波紋エフェクト
  if $click_effect_t > 0
    radius = (9 - $click_effect_t) * 3
    circ($click_fx, $click_fy, radius, 7)
  end

  # --- ステータスバー (y: 224〜255) ---
  rectfill(0, 224, 256, 32, 0)
  line(0, 224, 255, 224, 12)
  mx = mouse_x
  my = mouse_y
  print_text("POS:(#{mx},#{my})  SIZE:#{$pen_size}", 16, 230, 7)
  print_text("BTN: #{btn(:mouse_l) ? 'L_DOWN' : 'UP'} #{btn(:mouse_r) ? 'R_DOWN' : ''}", 16, 240, 11)

  # --- ゲーム内カスタムカーソルの描画 ---
  if $cursor_mode == 0
    # 絵文字カーソル
    if btn(:mouse_l)
      print_text("✏️", mx - 2, my - 10)
    elsif btn(:mouse_r)
      print_text("🧹", mx - 2, my - 8)
    else
      print_text("👆", mx, my)
    end
  else
    # レトロスプライト矢印カーソル
    spr(0, mx, my)
  end
end

__END__
@SPRITE 0
7777............
788877..........
78888877........
7888888877......
788888888877....
78888888888877..
788888777777777.
7888887.........
78877887........
77..77887.......
....77887.......
.....77887......
......77887.....
.......77887....
........7777....
................

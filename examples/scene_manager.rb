# ==============================================================================
# 🎭 Usakame Object-Oriented Scene Management Showcase
# ==============================================================================
# 【概要】
# Usakame のオブジェクト指向シーン管理 API (run / scene) と入力判定 API (btnp)
# を活用した、実践的かつ拡張性の高いゲームシーンアーキテクチャのサンプルです。
#
# 【主な機能とパターン】
# 1. クラスベースのシーン構造:
#    - 各シーン（TitleScene, PlayScene, ClearScene）が独立したクラスとして
#      update / draw を実装。グローバル変数を排除し状態を完全カプセル化。
# 2. ポーズ画面（ラッパーシーン方式）:
#    - PauseScene.new(self) で現在のゲームシーンインスタンスを丸ごと保持。
#    - 背後に @game_scene.draw を描画しながら走査線暗幕＋モーダルUIをオーバーレイ。
#    - 「ゲーム再開」時に run(@game_scene, reset_state: false) でプレイヤー位置や
#      コイン状態を 1 バイトも失わずにシームレス復帰。
# 3. 汎用トランジションシーン (TransitionScene):
#    - シーン間を安全に繋ぐアニメーションラッパー。
#    - 3 種類のレトロ演出（Curtain: シャッター, Blinds: ブラインド, Dissolve: モザイク消去）。
# 4. モーダルダイアログ (HelpModalScene):
#    - 親シーンを維持したまま開閉するスタック型ダイアログ。
# 5. チャタリングのない快適な操作感 (btnp):
#    - メニューカーソル移動、ポーズ開閉、シーン遷移時のボタン押しっぱなし誤判定を防止。
#
# 【操作方法】
#   - 方向キー (矢印 / WASD): メニュー選択 / プレイヤー移動
#   - Z / Space (btn: 4): 決定 / アクション
#   - X / Enter (btn: 5): ポーズ画面の開閉 (PlayScene中) / キャンセル
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🎭 OOP Scene Management Showcase - Usakame"
)

# ------------------------------------------------------------------------------
# 共通 UI ヘルパー関数
# ------------------------------------------------------------------------------

# レトロ調ドロップシャドウ付き二重枠ウィンドウ
def draw_panel(x, y, w, h, bg_col = 1, border_col = 7)
  rectfill(x + 2, y + 2, w, h, 0)       # ドロップシャドウ
  rectfill(x, y, w, h, bg_col)          # 背景
  rect(x, y, w, h, border_col)          # 外枠
  rect(x + 2, y + 2, w - 4, h - 4, 13)  # 内枠アクセント
end

# 画面全体にレトロ走査線（暗幕ディザ）をかける
def draw_scanline_overlay
  y = 0
  while y < 256
    line(0, y, 256, y, 0)
    y += 2
  end
end

# ------------------------------------------------------------------------------
# 1. 汎用トランジションシーン (TransitionScene)
# ------------------------------------------------------------------------------
# 前のシーンから次のシーンへ、指定したエフェクトでスムーズに遷移するラッパー
class TransitionScene
  STYLES = [:curtain, :blinds, :dissolve]
  STYLE_NAMES = ["1. CURTAIN SHUTTER", "2. VENETIAN BLINDS", "3. MOSAIC DISSOLVE"]

  def self.transition(from_scene, to_scene, style = :curtain, duration = 24)
    run TransitionScene.new(from_scene, to_scene, style, duration)
  end

  def initialize(from_scene, to_scene, style = :curtain, duration = 24)
    @from_scene = from_scene
    @to_scene = to_scene
    @style = style
    @duration = duration > 0 ? duration : 24
    @half_duration = @duration / 2
    @timer = 0
    @phase = :out # :out (暗転へ) -> :in (明転へ)
  end

  def update
    @timer += 1
    if @phase == :out
      if @timer >= @half_duration
        @phase = :in
        @timer = 0
      end
    else
      if @timer >= @half_duration
        # トランジション完了: 次のシーンへ本遷移
        run @to_scene
      end
    end
  end

  def draw
    # 進行度 (0.0 .. 1.0)
    progress = @timer.to_f / @half_duration.to_f
    progress = 1.0 if progress > 1.0

    if @phase == :out
      @from_scene.draw if @from_scene
      draw_effect(progress, true)
    else
      @to_scene.draw if @to_scene
      draw_effect(1.0 - progress, false)
    end
  end

  def draw_effect(ratio, is_closing)
    case @style
    when :curtain
      # 上下から中央へ閉じる／開くシャッター
      h = (128.0 * ratio).to_i
      if h > 0
        rectfill(0, 0, 256, h, 0)
        rectfill(0, 256 - h, 256, h, 0)
        line(0, h, 256, h, 7) if h < 128
        line(0, 256 - h, 256, 256 - h, 7) if h < 128
      end

    when :blinds
      # 8本の水平ブラインドバー
      band_h = 32
      step = (band_h.to_f * ratio).to_i
      if step > 0
        (0..7).each do |i|
          y = i * band_h
          rectfill(0, y, 256, step, 0)
          line(0, y + step, 256, y + step, 13) if step < band_h
        end
      end

    when :dissolve
      # 16x16 のモザイクタイルによる順次ディザ消去
      threshold = (16.0 * ratio).to_i
      (0..15).each do |by|
        (0..15).each do |bx|
          weight = (bx * 7 + by * 13 + 3) % 16
          if weight < threshold
            rectfill(bx * 16, by * 16, 16, 16, 0)
          end
        end
      end
    end
  end
end

# ------------------------------------------------------------------------------
# 2. タイトルシーン (TitleScene)
# ------------------------------------------------------------------------------
class TitleScene
  def initialize(selected_style_idx = 0)
    @frame = 0
    @cursor = 0
    @style_idx = selected_style_idx % TransitionScene::STYLES.size
    @stars = []
    (0..24).each do
      @stars << { x: rand(256), y: rand(256), spd: 0.5 + rand() * 1.5, col: 5 + rand(3) }
    end
  end

  def update
    @frame += 1

    # 背景スター移動
    @stars.each do |s|
      s[:y] += s[:spd]
      s[:y] = 0.0 if s[:y] > 256.0
    end

    # メニュー操作 (btnp で快適に1段ずつ移動)
    if btnp(:up) || btnp(2)
      @cursor = (@cursor - 1) % 3
    elsif btnp(:down) || btnp(3)
      @cursor = (@cursor + 1) % 3
    end

    # 決定アクション (Z / Space)
    if btnp(:a) || btnp(4)
      case @cursor
      when 0
        # ゲームスタート (トランジション付き)
        style = TransitionScene::STYLES[@style_idx]
        TransitionScene.transition(self, PlayScene.new(@style_idx), style)
      when 1
        # トランジション演出の切り替え
        @style_idx = (@style_idx + 1) % TransitionScene::STYLES.size
      when 2
        # 操作説明モーダルを開く (現在のシーンを保持して背後描画)
        run HelpModalScene.new(self), reset_state: false
      end
    end
  end

  def draw
    cls(1) # 深い紺色背景

    # 背景の星
    @stars.each do |s|
      pset(s[:x].to_i, s[:y].to_i, s[:col])
    end

    # タイトルロゴ演出
    float_y = (sin(@frame * 0.05) * 4.0).to_i
    draw_panel(28, 36 + float_y, 200, 52, 0, 10)
    print_text("USAKAME ENGINE", 74, 46 + float_y, 11)
    print_text("OOP SCENE SHOWCASE", 58, 62 + float_y, 7)
    spr("🐰", 36, 48 + float_y)
    spr("✨", 204, 48 + float_y)

    # メインメニュー
    draw_panel(36, 116, 184, 86, 0, 6)

    # カーソルとメニュー項目
    menu_items = [
      "START GAME",
      "STYLE: #{TransitionScene::STYLE_NAMES[@style_idx]}",
      "HOW TO PLAY / HELP"
    ]

    menu_items.each_with_index do |text, i|
      y = 128 + i * 20
      if i == @cursor
        # 選択中の強調
        rectfill(44, y - 2, 168, 14, 2)
        spr("⭐", 46, y - 3)
        print_text(text, 64, y + 1, 10)
      else
        print_text(text, 64, y + 1, 6)
      end
    end

    # フッター案内
    print_text("UP/DOWN: SELECT   Z: DECIDE", 48, 222, 5)
  end
end

# ------------------------------------------------------------------------------
# 3. ゲームプレイシーン (PlayScene)
# ------------------------------------------------------------------------------
class PlayScene
  def initialize(style_idx = 0)
    @style_idx = style_idx
    @frame = 0
    @score = 0
    @px = 120.0
    @py = 120.0
    @speed = 2.0
    @flip_x = false

    # 回収対象のスターコイン配置 (8個)
    @coins = []
    points = [
      [32, 48], [120, 40], [208, 48],
      [48, 120],            [192, 120],
      [32, 192], [120, 200], [208, 192]
    ]
    points.each do |pt|
      @coins << { x: pt[0], y: pt[1], collected: false }
    end

    # きらめきパーティクル
    @particles = []
  end

  def update
    @frame += 1

    # プレイヤー移動 (btn)
    dx = 0.0
    dy = 0.0
    dx -= @speed if btn(:left)  || btn(0)
    dx += @speed if btn(:right) || btn(1)
    dy -= @speed if btn(:up)    || btn(2)
    dy += @speed if btn(:down)  || btn(3)

    @flip_x = true if dx < 0
    @flip_x = false if dx > 0

    @px = (@px + dx).clamp(8.0, 232.0)
    @py = (@py + dy).clamp(24.0, 232.0)

    # コインとの当たり判定
    @coins.each do |c|
      next if c[:collected]
      dist_x = (@px - c[:x]).abs
      dist_y = (@py - c[:y]).abs
      if dist_x < 12.0 && dist_y < 12.0
        c[:collected] = true
        @score += 100
        # パーティクル発生
        (0..7).each do
          angle = rand() * 6.28
          spd = 1.0 + rand() * 2.0
          @particles << {
            x: c[:x] + 8,
            y: c[:y] + 8,
            vx: cos(angle) * spd,
            vy: sin(angle) * spd,
            life: 18,
            col: [9, 10, 7][rand(3)]
          }
        end
      end
    end

    # パーティクル更新
    @particles.each do |p|
      p[:x] += p[:vx]
      p[:y] += p[:vy]
      p[:life] -= 1
    end
    @particles.reject! { |p| p[:life] <= 0 }

    # クリア判定: すべてのコインを集めたら ClearScene へ遷移
    all_collected = @coins.all? { |c| c[:collected] }
    if all_collected
      style = TransitionScene::STYLES[@style_idx]
      TransitionScene.transition(self, ClearScene.new(@score, @frame, @style_idx), style)
      return
    end

    # ポーズ画面の起動 (X / Enter または btn: 5)
    # ※ btnp なので 1 回の押し下げで確実に 1 回だけ起動
    if btnp(:b) || btnp(5)
      run PauseScene.new(self), reset_state: false
    end
  end

  def draw
    cls(3) # フィールドグリーン背景

    # フィールド装飾パターン
    (0..15).each do |gx|
      (0..15).each do |gy|
        pset(gx * 16 + 8, gy * 16 + 8, 11) if (gx + gy) % 4 == 0
      end
    end

    # コイン描画 (未回収のみ)
    remain_count = 0
    @coins.each do |c|
      if !c[:collected]
        remain_count += 1
        bob = (sin((@frame + c[:x]) * 0.1) * 2.0).to_i
        spr("🪙", c[:x], c[:y] + bob)
      end
    end

    # パーティクル描画
    @particles.each do |p|
      pset(p[:x].to_i, p[:y].to_i, p[:col])
    end

    # プレイヤー (うさぎ) 描画
    spr("🐰", @px.to_i, @py.to_i, @flip_x)

    # 上部ステータスバー
    rectfill(0, 0, 256, 18, 0)
    line(0, 18, 256, 18, 7)
    print_text("SCORE: #{@score}", 8, 5, 10)
    print_text("LEFT: #{remain_count}/#{@coins.size}", 110, 5, 7)
    print_text("X: PAUSE", 192, 5, 12)
  end
end

# ------------------------------------------------------------------------------
# 4. ポーズ画面 (PauseScene - ラッパー方式)
# ------------------------------------------------------------------------------
# 前のゲームシーン (@game_scene) を保持し、背面にそのまま描画しながら
# 半透明暗幕とモーダルウィンドウを重ねる。再開時は一切の状態を失わず復帰。
class PauseScene
  def initialize(game_scene)
    @game_scene = game_scene
    @cursor = 0
  end

  def update
    # カーソル移動 (btnp)
    if btnp(:up) || btnp(2)
      @cursor = (@cursor - 1) % 3
    elsif btnp(:down) || btnp(3)
      @cursor = (@cursor + 1) % 3
    end

    # X / Enter をもう一度押しても即座にゲーム再開
    if btnp(:b) || btnp(5)
      resume_game
      return
    end

    # 決定 (Z / Space)
    if btnp(:a) || btnp(4)
      case @cursor
      when 0
        resume_game
      when 1
        # ステージ最初からやり直す (トランジション付き)
        TransitionScene.transition(self, PlayScene.new, :curtain)
      when 2
        # タイトルへ戻る (トランジション付き)
        TransitionScene.transition(self, TitleScene.new, :curtain)
      end
    end
  end

  def resume_game
    # 描画ステートを引き継いで元のゲームシーンへ復帰
    run @game_scene, reset_state: false
  end

  def draw
    # 1. 背面に現在のゲームシーンを静止描画
    @game_scene.draw

    # 2. 走査線による暗幕オーバーレイ
    draw_scanline_overlay

    # 3. ポーズモーダルウィンドウ
    draw_panel(56, 68, 144, 116, 0, 10)
    print_text("=== PAUSED ===", 78, 80, 10)

    options = ["RESUME GAME", "RESTART STAGE", "TITLE SCREEN"]
    options.each_with_index do |opt, i|
      y = 104 + i * 22
      if i == @cursor
        rectfill(64, y - 2, 128, 14, 2)
        spr("⭐", 66, y - 3)
        print_text(opt, 84, y + 1, 10)
      else
        print_text(opt, 84, y + 1, 6)
      end
    end

    print_text("PRESS X OR Z TO RESUME", 60, 196, 7)
  end
end

# ------------------------------------------------------------------------------
# 5. 操作説明モーダルシーン (HelpModalScene)
# ------------------------------------------------------------------------------
# TitleScene の上に重なって操作説明を表示するモーダル
class HelpModalScene
  def initialize(parent_scene)
    @parent_scene = parent_scene
  end

  def update
    # Z または X で閉じて親シーンに戻る
    if btnp(:a) || btnp(:b) || btnp(4) || btnp(5)
      run @parent_scene, reset_state: false
    end
  end

  def draw
    @parent_scene.draw
    draw_scanline_overlay

    draw_panel(28, 48, 200, 156, 0, 11)
    print_text("HOW TO PLAY", 96, 60, 10)
    line(40, 72, 216, 72, 11)

    print_text("- ARROW / WASD : MOVE RABBIT", 40, 84, 7)
    print_text("- COLLECT ALL 8 COINS TO WIN", 40, 102, 7)
    print_text("- X / ENTER    : PAUSE GAME", 40, 120, 12)
    print_text("- Z / SPACE    : CONFIRM / SELECT", 40, 138, 7)

    rectfill(52, 166, 152, 18, 2)
    rect(52, 166, 152, 18, 7)
    print_text("PRESS Z / X TO CLOSE", 64, 172, 10)
  end
end

# ------------------------------------------------------------------------------
# 6. クリア・リザルトシーン (ClearScene)
# ------------------------------------------------------------------------------
class ClearScene
  def initialize(score, total_frames, style_idx = 0)
    @score = score
    @total_frames = total_frames
    @style_idx = style_idx
    @frame = 0
    @confetti = []
    (0..36).each do
      @confetti << {
        x: rand(256),
        y: rand(256),
        vy: 1.0 + rand() * 2.0,
        col: [8, 9, 10, 11, 12, 14][rand(6)]
      }
    end
  end

  def update
    @frame += 1

    # 紙吹雪アニメーション
    @confetti.each do |c|
      c[:y] += c[:vy]
      c[:y] = 0 if c[:y] > 256
    end

    # Z または X でタイトルへ戻る
    if btnp(:a) || btnp(4)
      style = TransitionScene::STYLES[@style_idx]
      TransitionScene.transition(self, TitleScene.new(@style_idx), style)
    end
  end

  def draw
    cls(0)

    # 紙吹雪
    @confetti.each do |c|
      rectfill(c[:x], c[:y].to_i, 2, 2, c[:col])
    end

    # トロフィーと結果パネル
    draw_panel(36, 44, 184, 160, 1, 10)
    spr("🏆", 120, 60)
    print_text("STAGE CLEAR!!", 84, 84, 10)

    # タイムとスコア表示 (60fps 換算)
    seconds = (@total_frames.to_f / 60.0).to_i
    print_text("SCORE: #{@score}", 60, 116, 7)
    print_text("TIME : #{seconds} SECONDS", 60, 134, 7)

    rectfill(48, 164, 160, 18, 2)
    rect(48, 164, 160, 18, 10)
    print_text("PRESS Z TO RETURN", 68, 170, 7)
  end
end

# ------------------------------------------------------------------------------
# エントリポイント: 最初のシーンを起動
# ------------------------------------------------------------------------------
run TitleScene.new

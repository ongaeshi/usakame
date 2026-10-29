# ==============================================================================
# 🪟 Scene Transitions, RPG Dialogue & Command UI (画面遷移・会話枠・UIレシピ集)
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/scene_ui.rb
#
# 【AIエージェント・開発者向けレシピ】
# ゲーム全体の骨格となる「シーン遷移」「会話ウィンドウ」「コマンド選択UI」の定石実装集です。
#   1. シーン管理ステートマシン (:title -> :dialogue -> :battle -> :result)
#   2. 画面ワイプ遷移エフェクト (start_scene_transition / draw_transition)
#   3. 1文字ずつ表示されるタイプライター風 RPG メッセージ枠 & 選択肢分岐
#   4. 汎用レトロウィンドウ描画 (draw_window) & HP/MP ゲージバー (draw_bar)
#   5. ドラクエ風コマンド選択式ターンバトル UI
#
# 【操作方法】
#   - 上下左右キー (WASD): カーソル移動
#   - Z / Space: 決定・メッセージ送り・文字スキップ
#   - X / Enter: キャンセル・タイトルへ戻る
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🪟 Scene, Dialogue & Command UI Cookbook"
)

# --- 1. 汎用 UI 描画ヘルパー ---

# レトロRPG風の二重枠ウィンドウを描画
def draw_window(x, y, w, h, title = nil, border_col = 7, bg_col = 1)
  rectfill(x + 2, y + 2, w, h, 0)         # ドロップシャドウ
  rectfill(x, y, w, h, bg_col)            # 背景塗り
  rect(x, y, w, h, border_col)            # 外枠
  rect(x + 2, y + 2, w - 4, h - 4, 13)    # 内枠アクセント

  if title
    tw = title.length * 7 + 12
    tx = x + 8
    ty = y - 5
    rectfill(tx, ty, tw, 11, bg_col)
    rect(tx, ty, tw, 11, border_col)
    print_text(title, tx + 6, ty + 2, 10)
  end
end

# HP / MP などのゲージバーを描画
def draw_bar(x, y, w, h, current, max_val, fill_col, back_col = 5)
  rectfill(x, y, w, h, 0)
  rect(x, y, w, h, 6)
  ratio = max_val > 0 ? (current.to_f / max_val.to_f).clamp(0.0, 1.0) : 0.0
  fill_w = ((w - 2).to_f * ratio).to_i
  rectfill(x + 1, y + 1, fill_w, h - 2, fill_col) if fill_w > 0
end

# --- 2. シーン遷移 & 画面ワイプ管理 ---

$t = 0
$scene = :title
$title_cursor = 0

$trans = {
  active: false,
  phase: :out,      # :out (暗転へ) または :in (明転へ)
  progress: 0.0,
  target_scene: :title
}

def start_scene_transition(next_scene)
  return if $trans[:active]
  sfx(0)
  $trans[:active] = true
  $trans[:phase] = :out
  $trans[:progress] = 0.0
  $trans[:target_scene] = next_scene
end

def update_transition
  return false unless $trans[:active]

  $trans[:progress] += 0.08
  if $trans[:progress] >= 1.0
    if $trans[:phase] == :out
      # 暗転完了時にシーンを切り替えて初期化フックを呼ぶ
      $scene = $trans[:target_scene]
      on_enter_scene($scene)
      $trans[:phase] = :in
      $trans[:progress] = 0.0
    else
      $trans[:active] = false
    end
  end
  true
end

# 水平ブラインドシャッターによる画面ワイプ描画
def draw_transition
  return unless $trans[:active]

  ratio = $trans[:phase] == :out ? $trans[:progress] : (1.0 - $trans[:progress])
  band_h = 32
  fill_h = (band_h.to_f * ratio.clamp(0.0, 1.0)).to_i
  return if fill_h <= 0

  (0..7).each do |i|
    by = i * band_h
    rectfill(0, by, 256, fill_h, 0)
  end
end

# --- 3. タイプライター会話システム ---

$dlg = {
  active: false,
  speaker: "うさぎ長老",
  emoji: "🐰",
  pages: [],
  page_idx: 0,
  char_idx: 0,
  timer: 0,
  choices: nil,
  choice_cursor: 0
}

def start_dialogue(speaker, emoji, pages, choices = nil)
  $dlg[:active] = true
  $dlg[:speaker] = speaker
  $dlg[:emoji] = emoji
  $dlg[:pages] = pages
  $dlg[:page_idx] = 0
  $dlg[:char_idx] = 0
  $dlg[:timer] = 0
  $dlg[:choices] = choices
  $dlg[:choice_cursor] = 0
end

def update_dialogue
  return unless $dlg[:active]

  current_text = $dlg[:pages][$dlg[:page_idx]] || ""
  chars = current_text.chars
  total_chars = chars.size

  if $dlg[:char_idx] < total_chars
    $dlg[:timer] += 1
    if $dlg[:timer] % 2 == 0
      $dlg[:char_idx] += 1
      sfx(2) if $dlg[:char_idx] % 3 == 0
    end
    # ボタン押下で一括表示スキップ
    if btnp(:btn_a)
      $dlg[:char_idx] = total_chars
    end
  else
    # 全文字表示完了後
    is_last_page = ($dlg[:page_idx] >= $dlg[:pages].size - 1)
    if is_last_page && $dlg[:choices]
      if btnp(:up) || btnp(:left)
        $dlg[:choice_cursor] = ($dlg[:choice_cursor] - 1) % $dlg[:choices].size
        sfx(2)
      elsif btnp(:down) || btnp(:right)
        $dlg[:choice_cursor] = ($dlg[:choice_cursor] + 1) % $dlg[:choices].size
        sfx(2)
      elsif btnp(:btn_a)
        selected = $dlg[:choice_cursor]
        $dlg[:active] = false
        on_dialogue_choice(selected)
      end
    else
      if btnp(:btn_a)
        if !is_last_page
          $dlg[:page_idx] += 1
          $dlg[:char_idx] = 0
          sfx(0)
        else
          $dlg[:active] = false
          start_scene_transition(:battle)
        end
      end
    end
  end
end

def on_dialogue_choice(choice_idx)
  if choice_idx == 0
    start_scene_transition(:battle)
  else
    start_dialogue(
      "カメ魔王",
      "🐢",
      [
        "フハハ！逃げることは許さんぞ！",
        "いざ、尋常に勝負せよ！！"
      ],
      nil
    )
  end
end

# --- 4. コマンド選択式ターンバトルシステム ---

$btl = {
  state: :command, # :command, :message, :enemy_turn
  cursor: 0,
  commands: ["⚔️たたかう", "🔥まほう", "🥕どうぐ", "💨にげる"],
  hero_hp: 120,
  hero_max_hp: 120,
  hero_mp: 30,
  hero_max_mp: 30,
  boss_hp: 180,
  boss_max_hp: 180,
  boss_hurt: 0,
  screen_shake: 0,
  msg: "カメ魔王があらわれた！",
  wait_timer: 0,
  win: false
}

def reset_battle
  $btl[:state] = :command
  $btl[:cursor] = 0
  $btl[:hero_hp] = 120
  $btl[:hero_mp] = 30
  $btl[:boss_hp] = 180
  $btl[:boss_hurt] = 0
  $btl[:screen_shake] = 0
  $btl[:msg] = "カメ魔王 があらわれた！ コマンド？"
  $btl[:wait_timer] = 0
  $btl[:win] = false
end

def update_battle
  $btl[:boss_hurt] -= 1 if $btl[:boss_hurt] > 0
  $btl[:screen_shake] -= 1 if $btl[:screen_shake] > 0

  if $btl[:state] == :command
    if btnp(:up)
      $btl[:cursor] = ($btl[:cursor] - 1) % 4
      sfx(2)
    elsif btnp(:down)
      $btl[:cursor] = ($btl[:cursor] + 1) % 4
      sfx(2)
    elsif btnp(:btn_a)
      execute_hero_command($btl[:cursor])
    end
  elsif $btl[:state] == :message
    $btl[:wait_timer] -= 1
    if $btl[:wait_timer] <= 0 || btnp(:btn_a)
      if $btl[:boss_hp] <= 0
        $btl[:win] = true
        start_scene_transition(:result)
      elsif $btl[:hero_hp] <= 0
        $btl[:win] = false
        start_scene_transition(:result)
      else
        $btl[:state] = :enemy_turn
        $btl[:wait_timer] = 45
        dmg = 18 + rand(14)
        $btl[:hero_hp] = ($btl[:hero_hp] - dmg).clamp(0, $btl[:hero_max_hp])
        $btl[:screen_shake] = 10
        $btl[:msg] = "カメ魔王の攻撃！ 勇者に #{dmg} のダメージ！"
        sfx(1)
      end
    end
  elsif $btl[:state] == :enemy_turn
    $btl[:wait_timer] -= 1
    if $btl[:wait_timer] <= 0 || btnp(:btn_a)
      if $btl[:hero_hp] <= 0
        $btl[:win] = false
        start_scene_transition(:result)
      else
        $btl[:state] = :command
        $btl[:msg] = "どうする？"
      end
    end
  end
end

def execute_hero_command(cmd_idx)
  if cmd_idx == 0
    dmg = 35 + rand(15)
    $btl[:boss_hp] = ($btl[:boss_hp] - dmg).clamp(0, $btl[:boss_max_hp])
    $btl[:boss_hurt] = 14
    $btl[:msg] = "うさぎ勇者の斬撃！ #{dmg} のダメージ！"
    sfx(0)
  elsif cmd_idx == 1
    if $btl[:hero_mp] >= 10
      $btl[:hero_mp] -= 10
      dmg = 65 + rand(20)
      $btl[:boss_hp] = ($btl[:boss_hp] - dmg).clamp(0, $btl[:boss_max_hp])
      $btl[:boss_hurt] = 20
      $btl[:msg] = "紅蓮のフレア！ 魔王に #{dmg} の大ダメージ！"
      sfx(0)
    else
      $btl[:msg] = "MP が足りない！"
      sfx(1)
      return
    end
  elsif cmd_idx == 2
    heal = 50
    $btl[:hero_hp] = ($btl[:hero_hp] + heal).clamp(0, $btl[:hero_max_hp])
    $btl[:msg] = "黄金の人参を食べた！ HPが #{heal} 回復！"
    sfx(0)
  else
    start_scene_transition(:title)
    return
  end

  $btl[:state] = :message
  $btl[:wait_timer] = 45
end

# --- 5. シーン初期化フック & メインループ ---

def on_enter_scene(sc)
  if sc == :dialogue
    start_dialogue(
      "うさぎ長老",
      "🐰",
      [
        "よくぞ参られた、若きうさぎの勇者よ！\nこの先はカメ魔王の城じゃ。",
        "ウィンドウUIや会話テキスト送りは、\nこのようにステート管理で簡単に作れるぞ。",
        "準備はよいかな？\n今すぐカメ魔王との決戦へ向かうかい？"
      ],
      ["はい、戦います！", "いいえ、まだ心の準備が…"]
    )
  elsif sc == :battle
    reset_battle
  end
end

def update
  $t += 1
  return if update_transition

  if $scene == :title
    if btnp(:up)
      $title_cursor = ($title_cursor - 1) % 2
      sfx(2)
    elsif btnp(:down)
      $title_cursor = ($title_cursor + 1) % 2
      sfx(2)
    elsif btnp(:btn_a)
      if $title_cursor == 0
        start_scene_transition(:dialogue)
      else
        start_scene_transition(:battle)
      end
    end
  elsif $scene == :dialogue
    update_dialogue
    start_scene_transition(:title) if btnp(:btn_b)
  elsif $scene == :battle
    update_battle
  elsif $scene == :result
    if btnp(:btn_a) || btnp(:btn_b)
      start_scene_transition(:title)
    end
  end
end

# --- 6. シーン別描画処理 ---

def draw_title_scene
  cls(1)
  # 星空背景
  (0..24).each do |i|
    sx = (i * 47 + $t / 3) % 256
    sy = (i * 31) % 140
    pset(sx, sy, (i % 2 == 0) ? 7 : 6)
  end

  # ロゴウィンドウ
  draw_window(24, 28, 208, 68, "USAKAME UI SAMPLE", 10, 2)
  spr("🏰", 40, 48, false, false, 0, 1.5)
  print_text("RPG SCENE & UI", 76, 44, 7)
  print_text("COOKBOOK DEMO", 80, 58, 10)
  print_text("Scene / Window / Typewriter", 44, 76, 14)

  # メニュー選択枠
  draw_window(52, 124, 152, 64, "SELECT MODE", 7, 1)
  items = ["💬 ストーリー会話デモ", "⚔️ コマンド戦闘デモ"]
  items.each_with_index do |label, idx|
    iy = 142 + idx * 20
    if $title_cursor == idx
      rectfill(60, iy - 2, 136, 13, 12)
      print_text("▶ " + label, 64, iy, 0)
    else
      print_text("  " + label, 64, iy, 7)
    end
  end

  if ($t / 20) % 2 == 0
    print_text("- PRESS Z / SPACE TO SELECT -", 42, 216, 10)
  end
end

# 先頭から count 文字分を切り出す（mrubyedge では Array#[start, len] が単一要素参照になるためループで安全に結合）
def take_chars(str, count)
  chars = str.chars
  limit = count.clamp(0, chars.size)
  out = ""
  i = 0
  while i < limit
    out = out + chars[i]
    i += 1
  end
  out
end

def draw_dialogue_scene
  cls(3)
  # 背景フィールド風
  rectfill(0, 0, 256, 96, 12)
  circfill(210, 32, 16, 10)
  rectfill(0, 96, 256, 160, 3)

  # キャラクター立ち絵演出
  bob = (sin($t.to_f * 0.1) * 3.0).to_i
  draw_window(96, 48 + bob, 64, 64, nil, 7, 1)
  spr($dlg[:emoji], 120, 72 + bob, false, false, 0, 2.5)

  # メッセージウィンドウ
  draw_window(12, 144, 232, 96, $dlg[:speaker], 7, 1)

  current_text = $dlg[:pages][$dlg[:page_idx]] || ""
  visible_str = take_chars(current_text, $dlg[:char_idx])

  lines = visible_str.split("\n")
  lines.each_with_index do |ln, idx|
    print_text(ln, 24, 162 + idx * 14, 7)
  end

  # 選択肢ウィンドウまたは次ページ促しアイコン
  total_chars = current_text.chars.size
  if $dlg[:char_idx] >= total_chars
    is_last = ($dlg[:page_idx] >= $dlg[:pages].size - 1)
    if is_last && $dlg[:choices]
      draw_window(112, 100, 132, 42, "CHOICE", 10, 2)
      $dlg[:choices].each_with_index do |ch, idx|
        cy = 112 + idx * 13
        prefix = ($dlg[:choice_cursor] == idx) ? "▶" : " "
        col = ($dlg[:choice_cursor] == idx) ? 10 : 7
        print_text("#{prefix}#{ch}", 120, cy, col)
      end
    else
      if ($t / 12) % 2 == 0
        print_text("▼", 228, 224, 10)
      end
    end
  end
end

def draw_battle_scene
  if $btl[:screen_shake] > 0
    camera(rand(-3..3), rand(-3..3))
  else
    camera(0, 0)
  end

  cls(0)
  # バトル背景
  rectfill(12, 42, 232, 110, 1)
  rect(12, 42, 232, 110, 13)

  # 上部ステータスウィンドウ
  draw_window(12, 6, 232, 32, nil, 7, 1)
  print_text("🐰勇者 HP:#{$btl[:hero_hp]}/#{$btl[:hero_max_hp]}", 20, 12, 7)
  draw_bar(20, 23, 96, 8, $btl[:hero_hp], $btl[:hero_max_hp], 11)

  print_text("MP:#{$btl[:hero_mp]}/#{$btl[:hero_max_mp]}", 136, 12, 7)
  draw_bar(136, 23, 96, 8, $btl[:hero_mp], $btl[:hero_max_mp], 12)

  # ボス描画
  if $btl[:boss_hp] > 0
    if $btl[:boss_hurt] % 2 == 0
      spr("🐢", 118, 78, false, false, 0, 2.5)
    end
    print_text("🐢カメ魔王", 96, 50, 10)
    draw_bar(84, 62, 88, 6, $btl[:boss_hp], $btl[:boss_max_hp], 8)
  end

  # 下部コマンド & メッセージウィンドウ
  if $btl[:state] == :command
    draw_window(12, 158, 92, 88, "COMMAND", 10, 1)
    $btl[:commands].each_with_index do |cmd, idx|
      cy = 172 + idx * 17
      if $btl[:cursor] == idx
        rectfill(18, cy - 2, 80, 13, 7)
        print_text("▶" + cmd, 20, cy, 0)
      else
        print_text(" " + cmd, 20, cy, 7)
      end
    end

    draw_window(110, 158, 134, 88, "LOG", 7, 1)
    print_text($btl[:msg], 118, 176, 7)
  else
    draw_window(12, 168, 232, 76, "BATTLE LOG", 7, 1)
    print_text($btl[:msg], 22, 192, 10)
    print_text("[Z] 次へ", 190, 226, 6)
  end

  camera(0, 0)
end

def draw_result_scene
  cls(1)
  title = $btl[:win] ? "🎉 VICTORY!!" : "💀 GAME OVER"
  col = $btl[:win] ? 10 : 8
  draw_window(32, 64, 192, 120, title, col, 2)

  emoji = $btl[:win] ? "🏆" : "👻"
  spr(emoji, 120, 96, false, false, 0, 2.5)

  msg = $btl[:win] ? "カメ魔王を討伐した！" : "勇者は力尽きてしまった…"
  print_text(msg, 64, 132, 7)
  print_text("Press Z to Return Title", 58, 158, 11)
end

def draw
  if $scene == :title
    draw_title_scene
  elsif $scene == :dialogue
    draw_dialogue_scene
  elsif $scene == :battle
    draw_battle_scene
  else
    draw_result_scene
  end

  draw_transition
end

__END__
@SFX 0
T200 L32 O5 C E G > C
@SFX 1
T160 L16 O3 G D < B G
@SFX 2
T240 L64 O6 C

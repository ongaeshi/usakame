# ==============================================================================
# 🃏 Rabbit Spire: Deckbuilding Card Roguelite (デッキ構築型カードバトル) 🐉
# ------------------------------------------------------------------------------
# 実行コマンド: uk run examples/card_roguelite.rb
#
# 【AIエージェント・開発者向けレシピ】
# デッキ構築型ローグライト（Slay the Spire 風）のコア仕組みを凝縮した実装例です。
#   1. 山札（Deck）・手札（Hand）・捨て札（Discard）の循環とリシャッフル処理
#   2. マウスホバー＆クリック操作と、キーボード／パッド操作のハイブリッドUI
#   3. 選択中カードの滑らかな浮き上がりアニメーション (lerp)
#   4. 敵の次回行動予告（Intent: 攻撃／防御／バフ）とシールド（Block）計算
#   5. 階層（Floor）進行と勝利時の報酬カード獲得
#
# 【操作方法】
#   - 左右キー または マウス移動: 手札カードの選択
#   - Z / Space または マウス左クリック: 選択中のカードを使用
#   - X / Enter または [END TURN] クリック: ターン終了
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2.0,
  title: "🃏 Rabbit Spire - Card Roguelite"
)

# --- 1. mrubyedge 互換ヘルパー ---

def array_shuffle!(arr)
  i = arr.size - 1
  while i > 0
    j = rand(i + 1)
    tmp = arr[i]
    arr[i] = arr[j]
    arr[j] = tmp
    i -= 1
  end
  arr
end

def lerp(a, b, t)
  a + (b - a) * t
end

# --- 2. カード・敵データベース ---

CARD_DB = [
  { id: :strike,   name: "STRIKE",   emoji: "⚔️", cost: 1, col: 8,  desc: "Deal 8 DMG" },
  { id: :defend,   name: "GUARD",    emoji: "🛡️", cost: 1, col: 12, desc: "Gain 7 Block" },
  { id: :bash,     name: "HEAVY",    emoji: "🔨", cost: 2, col: 9,  desc: "Deal 16 DMG" },
  { id: :carrot,   name: "CARROT",   emoji: "🥕", cost: 0, col: 11, desc: "+1⚡ & Draw 1" },
  { id: :flurry,   name: "TWIN HIT", emoji: "⚡", cost: 1, col: 10, desc: "Deal 5x2 DMG" },
  { id: :fireball, name: "METEOR",   emoji: "🔥", cost: 2, col: 14, desc: "22 DMG +3🛡️" }
]

ENEMY_FLOORS = [
  { name: " Forest Slime", emoji: "👾", hp: 42,  atk: 8  },
  { name: "Dark Knight",   emoji: "💀", hp: 68,  atk: 12 },
  { name: "Elder Dragon",  emoji: "🐉", hp: 110, atk: 16 }
]

$t = 0
$popups = []
$particles = []
$shake = 0
$last_mouse_x = -1
$last_mouse_y = -1

def spawn_popup(x, y, text, col)
  $popups << {
    x: x.to_f,
    y: y.to_f,
    text: text.to_s,
    col: col,
    age: 0,
    max_age: 40
  }
end

def spawn_burst(x, y, col)
  14.times do
    ang = rand() * 6.283185
    spd = 0.8 + rand() * 2.8
    $particles << {
      x: x.to_f,
      y: y.to_f,
      vx: cos(ang) * spd,
      vy: sin(ang) * spd,
      col: col,
      age: 0,
      max_age: 18
    }
  end
end

# --- 3. ゲーム・バトル進行管理 ---

def make_card_instance(template)
  {
    id: template[:id],
    name: template[:name],
    emoji: template[:emoji],
    cost: template[:cost],
    col: template[:col],
    desc: template[:desc],
    lift_y: 0.0
  }
end

def init_run
  $floor = 0
  $hero = {
    hp: 60,
    max_hp: 60,
    block: 0,
    energy: 3,
    max_energy: 3,
    hurt: 0
  }

  # 初期デッキ構築 (10枚)
  $master_deck = [
    CARD_DB[0], CARD_DB[0], CARD_DB[0], CARD_DB[0],
    CARD_DB[1], CARD_DB[1], CARD_DB[1],
    CARD_DB[2], CARD_DB[3], CARD_DB[4]
  ]

  start_floor_battle
end

def start_floor_battle
  tmpl = ENEMY_FLOORS[$floor % ENEMY_FLOORS.size]
  scale = 1 + ($floor / ENEMY_FLOORS.size)
  max_hp = tmpl[:hp] * scale

  $enemy = {
    name: tmpl[:name],
    emoji: tmpl[:emoji],
    hp: max_hp,
    max_hp: max_hp,
    base_atk: tmpl[:atk] + ($floor * 2),
    block: 0,
    hurt: 0,
    intent: :attack,
    intent_val: tmpl[:atk]
  }

  $deck = []
  $master_deck.each { |c| $deck << make_card_instance(c) }
  array_shuffle!($deck)
  $hand = []
  $discard = []
  $cursor = 0
  $state = :player_turn # :player_turn, :enemy_turn, :reward, :gameover
  $turn_timer = 0

  start_player_turn
end

def roll_enemy_intent
  r = rand(100)
  if r < 65
    $enemy[:intent] = :attack
    $enemy[:intent_val] = $enemy[:base_atk] + rand(-2..3)
  elsif r < 85
    $enemy[:intent] = :atk_def
    $enemy[:intent_val] = ($enemy[:base_atk] * 2) / 3
  else
    $enemy[:intent] = :heavy
    $enemy[:intent_val] = ($enemy[:base_atk] * 3) / 2
  end
end

# 山札から n 枚ドロー（山札が尽きたら捨て札をシャッフルして補充）
def draw_cards(count)
  count.times do
    return if $hand.size >= 6
    if $deck.empty?
      return if $discard.empty?
      $discard.each { |c| $deck << c }
      $discard.clear
      array_shuffle!($deck)
    end
    card = $deck.pop
    if card
      card[:lift_y] = 0.0
      $hand << card
    end
  end
  $cursor = $cursor.clamp(0, ($hand.size - 1).clamp(0, 10))
end

def start_player_turn
  $state = :player_turn
  $hero[:block] = 0
  $hero[:energy] = $hero[:max_energy]
  roll_enemy_intent
  draw_cards(5)
end

def deal_damage_to_enemy(dmg)
  blocked = dmg < $enemy[:block] ? dmg : $enemy[:block]
  $enemy[:block] -= blocked
  rem = dmg - blocked
  if rem > 0
    $enemy[:hp] = ($enemy[:hp] - rem).clamp(0, $enemy[:max_hp])
    $enemy[:hurt] = 12
    $shake = 6
    spawn_popup(184, 72, "-#{rem}", 8)
    spawn_burst(192, 92, 8)
  else
    spawn_popup(184, 72, "BLOCKED", 12)
  end
end

def play_card_at(idx)
  return if idx < 0 || idx >= $hand.size
  card = $hand[idx]
  if $hero[:energy] < card[:cost]
    spawn_popup(64, 140, "NO ENERGY!", 8)
    sfx(2)
    return
  end

  $hero[:energy] -= card[:cost]
  $hand.delete_at(idx)
  $discard << card
  $cursor = $cursor.clamp(0, ($hand.size - 1).clamp(0, 10))
  sfx(0)

  case card[:id]
  when :strike
    deal_damage_to_enemy(8)
  when :defend
    $hero[:block] += 7
    spawn_popup(56, 72, "+7 🛡️", 12)
    spawn_burst(64, 96, 12)
  when :bash
    deal_damage_to_enemy(16)
  when :carrot
    $hero[:energy] += 1
    draw_cards(1)
    spawn_popup(56, 72, "+1⚡ DRAW!", 11)
  when :flurry
    deal_damage_to_enemy(5)
    deal_damage_to_enemy(5)
  when :fireball
    deal_damage_to_enemy(22)
    $hero[:block] += 3
  end

  if $enemy[:hp] <= 0
    sfx(1)
    $state = :reward
    $reward_cards = [
      CARD_DB[2 + rand(4)],
      CARD_DB[rand(CARD_DB.size)],
      CARD_DB[rand(CARD_DB.size)]
    ]
    $reward_cursor = 0
  end
end

def end_player_turn
  # 手札をすべて捨て札へ送る
  $hand.each { |c| $discard << c }
  $hand.clear
  $state = :enemy_turn
  $turn_timer = 32
  sfx(2)
end

def execute_enemy_turn
  $enemy[:block] = 0
  val = $enemy[:intent_val]
  if $enemy[:intent] == :atk_def
    $enemy[:block] += 8
  end

  # プレイヤーへの攻撃処理
  blocked = val < $hero[:block] ? val : $hero[:block]
  $hero[:block] -= blocked
  rem = val - blocked
  if rem > 0
    $hero[:hp] = ($hero[:hp] - rem).clamp(0, $hero[:max_hp])
    $hero[:hurt] = 14
    $shake = 10
    spawn_popup(56, 72, "-#{rem}", 8)
    spawn_burst(64, 96, 8)
    sfx(1)
  else
    spawn_popup(56, 72, "BLOCKED!", 12)
    sfx(0)
  end

  if $hero[:hp] <= 0
    $state = :gameover
  else
    start_player_turn
  end
end

init_run

# --- 4. カード矩形計算 & メイン更新ループ ---

def card_rect(idx, total)
  card_w = 44
  card_h = 62
  gap = 4
  total_w = total * card_w + (total - 1) * gap
  start_x = (256 - total_w) / 2
  cx = start_x + idx * (card_w + gap)
  cy = 182
  [cx, cy, card_w, card_h]
end

def update
  $t += 1
  $shake -= 1 if $shake > 0
  $hero[:hurt] -= 1 if $hero[:hurt] > 0
  $enemy[:hurt] -= 1 if $enemy[:hurt] > 0

  $particles.each do |pt|
    pt[:age] += 1
    pt[:x] += pt[:vx]
    pt[:y] += pt[:vy]
  end
  $particles.reject! { |pt| pt[:age] >= pt[:max_age] }

  $popups.each do |pop|
    pop[:age] += 1
    pop[:y] -= 0.5
  end
  $popups.reject! { |pop| pop[:age] >= pop[:max_age] }

  mx = mouse_x
  my = mouse_y
  mouse_moved = (mx != $last_mouse_x || my != $last_mouse_y)
  $last_mouse_x = mx
  $last_mouse_y = my

  if $state == :player_turn
    # キーボードでのカード選択
    if !$hand.empty?
      if btnp(:left)
        $cursor = ($cursor - 1) % $hand.size
      elsif btnp(:right)
        $cursor = ($cursor + 1) % $hand.size
      end
    end

    # マウスホバー判定
    hovered_idx = nil
    $hand.each_with_index do |c, idx|
      rx, ry, rw, rh = card_rect(idx, $hand.size)
      top_y = ry - c[:lift_y].to_i
      if mx >= rx && mx <= rx + rw && my >= top_y && my <= ry + rh
        hovered_idx = idx
      end
    end
    $cursor = hovered_idx if hovered_idx && mouse_moved

    # 選択中カードの浮き上がりイージング更新
    $hand.each_with_index do |c, idx|
      target_lift = (idx == $cursor) ? 12.0 : 0.0
      c[:lift_y] = lerp(c[:lift_y], target_lift, 0.3)
    end

    # カード使用またはターン終了
    if btnp(:btn_a)
      if !$hand.empty?
        play_card_at($cursor)
      else
        end_player_turn
      end
    elsif btnp(:btn_b)
      end_player_turn
    elsif btnp(:mouse_l)
      if hovered_idx
        play_card_at(hovered_idx)
      elsif mx >= 188 && mx <= 248 && my >= 146 && my <= 166
        end_player_turn
      end
    end

  elsif $state == :enemy_turn
    $turn_timer -= 1
    if $turn_timer <= 0
      execute_enemy_turn
    end

  elsif $state == :reward
    if btnp(:left)
      $reward_cursor = ($reward_cursor - 1) % 3
    elsif btnp(:right)
      $reward_cursor = ($reward_cursor + 1) % 3
    elsif btnp(:btn_a) || btnp(:mouse_l)
      chosen = $reward_cards[$reward_cursor]
      $master_deck << chosen if chosen
      $floor += 1
      $hero[:hp] = ($hero[:hp] + 12).clamp(0, $hero[:max_hp])
      start_floor_battle
    elsif btnp(:btn_b)
      $floor += 1
      start_floor_battle
    end

  elsif $state == :gameover
    if btnp(:btn_a) || btnp(:mouse_l)
      init_run
    end
  end
end

# --- 5. 描画処理 ---

def draw_unit_panel(x, y, emoji, name, hp, max_hp, block, hurt)
  if hurt % 2 == 0
    spr(emoji, x + 16, y + 12, false, false, 0, 2.2)
  end
  print_text(name, x, y + 36, 7)

  # HP バー
  rectfill(x, y + 46, 56, 7, 0)
  rect(x, y + 46, 56, 7, 6)
  ratio = max_hp > 0 ? (hp.to_f / max_hp.to_f).clamp(0.0, 1.0) : 0.0
  fw = (54.0 * ratio).to_i
  rectfill(x + 1, y + 47, fw, 5, 8) if fw > 0
  print_text("#{hp}/#{max_hp}", x + 4, y + 55, 7)

  if block > 0
    rectfill(x + 42, y + 2, 24, 12, 12)
    print_text("🛡️#{block}", x + 43, y + 4, 0)
  end
end

def draw
  if $shake > 0
    camera(rand(-3..3), rand(-3..3))
  else
    camera(0, 0)
  end

  cls(1)

  # ダンジョン背景壁＆床
  rectfill(0, 22, 256, 118, 2)
  line(0, 140, 256, 140, 13)

  # 上部ヘッダー
  rectfill(0, 0, 256, 22, 0)
  line(0, 22, 256, 22, 10)
  print_text("🃏 RABBIT SPIRE  FLOOR #{$floor + 1}", 6, 7, 10)
  print_text("Deck:#{$deck.size} Disc:#{$discard.size}", 156, 7, 6)

  # ヒーロー & 敵の描画
  draw_unit_panel(36, 68, "🐰", "Hero", $hero[:hp], $hero[:max_hp], $hero[:block], $hero[:hurt])
  draw_unit_panel(164, 68, $enemy[:emoji], $enemy[:name], $enemy[:hp], $enemy[:max_hp], $enemy[:block], $enemy[:hurt])

  # 敵の次回行動予告 (Intent)
  intent_label = ($enemy[:intent] == :atk_def) ? "⚔️#{$enemy[:intent_val]}+🛡️" : "⚔️ATK #{$enemy[:intent_val]}"
  rectfill(162, 48, 64, 14, 0)
  rect(162, 48, 64, 14, 8)
  print_text(intent_label, 166, 51, 10)

  # エナジー表示 & END TURN ボタン
  circfill(24, 156, 12, 10)
  circ(24, 156, 12, 7)
  print_text("⚡#{$hero[:energy]}", 14, 152, 0)
  print_text("[←/→]Select [Z]Play", 46, 152, 7)

  rectfill(188, 146, 60, 18, 8)
  rect(188, 146, 60, 18, 7)
  print_text("END[X]", 196, 151, 7)

  # 手札カードの描画
  $hand.each_with_index do |c, idx|
    rx, ry, rw, rh = card_rect(idx, $hand.size)
    cy = ry - c[:lift_y].to_i
    selected = (idx == $cursor)
    can_play = ($hero[:energy] >= c[:cost])

    rectfill(rx + 2, cy + 2, rw, rh, 0)
    rectfill(rx, cy, rw, rh, selected ? 7 : 0)
    rect(rx, cy, rw, rh, can_play ? c[:col] : 5)

    # コストバッジ
    rectfill(rx + 2, cy + 2, 10, 10, can_play ? 10 : 5)
    print_text(c[:cost].to_s, rx + 4, cy + 3, 0)

    print_text(c[:name], rx + 4, cy + 15, selected ? 0 : 7)
    spr(c[:emoji], rx + 14, cy + 25)
    print_text(c[:desc], rx + 2, cy + 46, selected ? 1 : 6)
  end

  # パーティクル & ポップアップ
  $particles.each do |pt|
    circfill(pt[:x].to_i, pt[:y].to_i, 2, pt[:col])
  end
  $popups.each do |pop|
    print_text(pop[:text], pop[:x].to_i + 1, pop[:y].to_i + 1, 0)
    print_text(pop[:text], pop[:x].to_i, pop[:y].to_i, pop[:col])
  end

  # 報酬カード選択オーバーレイ
  if $state == :reward
    rectfill(16, 44, 224, 152, 0)
    rect(16, 44, 224, 152, 10)
    print_text("🎉 VICTORY! CHOOSE A CARD REWARD:", 28, 54, 10)

    $reward_cards.each_with_index do |rc, idx|
      bx = 28 + idx * 68
      by = 76
      sel = (idx == $reward_cursor)
      rectfill(bx, by, 60, 84, sel ? 1 : 0)
      rect(bx, by, 60, 84, sel ? 10 : 6)
      print_text("Cost:#{rc[:cost]}", bx + 6, by + 6, 10)
      spr(rc[:emoji], bx + 22, by + 22, false, false, 0, 1.5)
      print_text(rc[:name], bx + 6, by + 48, 7)
      print_text(rc[:desc], bx + 4, by + 64, 11)
    end
    print_text("[Z] Take Card   [X] Skip", 56, 174, 7)
  elsif $state == :gameover
    rectfill(44, 88, 168, 64, 0)
    rect(44, 88, 168, 64, 8)
    print_text("💀 DEFEATED ON FLOOR #{$floor + 1}", 56, 104, 8)
    print_text("Press Z to New Run", 72, 128, 7)
  end

  camera(0, 0)
end

__END__
@SFX 0
T220 L32 O5 C G > C
@SFX 1
T160 L16 O3 G D < B
@SFX 2
T200 L32 O4 E C

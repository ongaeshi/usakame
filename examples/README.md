# Usakame (`uk`) サンプル集 (Examples)

このディレクトリには、Usakame エンジンの機能別サンプルコードおよび実践的なゲームサンプルが収録されています。
`uk examples` コマンドまたは `uk new <dir> --with-refs` を実行することで展開されます。

---

## 🎮 ゲームサンプル (Game Demos)

| サンプル名 | ファイル | 概要・学べるポイント |
|:---|:---|:---|
| **うさかめアドベンチャー** | [`platformer.rb`](platformer.rb) | 2D横スクロールアクション。可変サイズスプライト（人参で16x32に変身、巨大32x32ボス）、パレット置換、外部背景画像連携（[`platformer_bg.png`](platformer_bg.png)）。 |
| **Rabbit Knight** | [`rabbit_knight.rb`](rabbit_knight.rb) | 見下ろし型アクションRPG。剣撃アクション、HP・ハートUI、敵AI（スライム／コウモリ）、外部マップ（[`rabbit_knight.map`](rabbit_knight.map)）。 |
| **うさかめサバイバー** | [`survivors.rb`](survivors.rb) | 全方位弾幕・サバイバー系アクション。大量の敵群AI、レベルアップ＆武器強化選択UI、パーティクルエフェクト。 |
| **Tiny Dungeon** | [`tiny_dungeon.rb`](tiny_dungeon.rb) | ダンジョン探索アクション。外部スプライト（[`tiny_dungeon.spr`](tiny_dungeon.spr)）とタイルマップ（[`tiny_dungeon.map`](tiny_dungeon.map)）の連携。 |

---

## 🛠️ 内蔵エディタ & 分離フォーマット

| ツール / サンプル名 | ファイル | 概要 |
|:---|:---|:---|
| **スプライトエディタ** | [`sprite_editor.rb`](sprite_editor.rb) | `uk edit spr` で起動するドット絵エディタ。ペン、消しゴム、塗りつぶし、カラーパレット選択。 |
| **タイルマップエディタ** | [`tilemap_editor.rb`](tilemap_editor.rb) | `uk edit map` で起動するタイルマップエディタ。マップチップ選択、タイル配置、右クリック消去。 |
| **分離フォーマットサンプル** | [`split_game.rb`](split_game.rb) | ゲームコードと外部リソース（[`split_game.spr`](split_game.spr), [`split_game.map`](split_game.map), [`split_game.sfx`](split_game.sfx)）を分けて管理するサンプル。 |

---

## 💡 機能別サンプル (Feature Showcases)

| サンプル名 | ファイル | 主な機能・API |
|:---|:---|:---|
| **総合機能デモ** | [`demo.rb`](demo.rb) | 描画プリミティブ、アニメーション、テキスト表示のショーケース。 |
| **サウンド・音楽デモ** | [`sound.rb`](sound.rb) | MML 音楽再生（`music`）、効果音（`sfx`）、音階再生（`play`）。 |
| **タイルマップ描画** | [`tilemap.rb`](tilemap.rb) | `map()` を使ったタイルマップ描画とスクロール。 |
| **マウス入力** | [`mouse.rb`](mouse.rb) | マウス座標（`mouse_x`, `mouse_y`）とクリック判定（`btn(BTN_MOUSE_LEFT)`）。 |
| **パレット切り替え** | [`pal.rb`](pal.rb) | `pal()` による色置換、`palt()` による透過色指定。 |
| **カメラ & クリップ** | [`camera_clip.rb`](camera_clip.rb) | `camera()` による視点追従と `clip()` による描画範囲制限。 |
| **解像度切り替え** | [`resolution.rb`](resolution.rb) | `config()` による画面サイズ・スケール指定。 |
| **プリミティブ・物理** | [`oval.rb`](oval.rb), [`big_ball.rb`](big_ball.rb), [`duck.rb`](duck.rb) | 楕円描画、ボール跳ね返り物理、アニメーション。 |

---

## 🚀 実行・検証方法

### 1. ゲームの実行（GUI）
```bash
uk run examples/platformer.rb
# またはエディタを同時に起動して編集:
uk run_with_edit examples/rabbit_knight.rb
```

### 2. 高速ヘッドレス検証
```bash
uk check examples/survivors.rb
```

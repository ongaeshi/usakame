# Usakame (`uk`) サンプル集 (Examples)

このディレクトリには、Usakame エンジンの機能別サンプルコードおよび実践的なゲームサンプルが収録されています。
`uk examples` コマンドまたは `uk new <dir> --with-refs` を実行することで展開されます。

---

## 🎮 ゲームサンプル (Game Demos)

| サンプル名 | ファイル | 概要・学べるポイント |
|:---|:---|:---|
| **うさかめアドベンチャー** | [`platformer.rb`](platformer.rb) | 2D横スクロールアクション。可変サイズスプライト（人参で16x32に変身、巨大32x32ボス）、パレット置換、外部背景画像連携（[`platformer_bg.png`](platformer_bg.png)）。 |
| **Rabbit Knight** | [`rabbit_knight.rb`](rabbit_knight.rb) | 見下ろし型アクションRPG。剣撃アクション、HP・ハートUI、敵AI（スライム／コウモリ）、オブジェクト配置（@OBJECTS）。 |
| **うさかめサバイバー** | [`survivors.rb`](survivors.rb) | 全方位弾幕・サバイバー系アクション。大量の敵群AI、レベルアップ＆武器強化選択UI、パーティクルエフェクト。 |
| **弾幕シューティング** | [`shooter.rb`](shooter.rb) | 縦スクロール弾幕STG。多重スクロール星空、ホーミング＆拡散ショット、敵編隊パターン、ボスラッシュ（多段階フェーズ・回転弾幕）。 |
| **落ち物連鎖パズル** | [`puzzle.rb`](puzzle.rb) | フルーツ連鎖パズル。ペア落下・回転、重力落下、Flood-fill による3個以上連結判定、連鎖（Chain）コンボ演出。 |
| **デッキ構築ローグライト** | [`card_roguelite.rb`](card_roguelite.rb) | デッキ構築型カードバトル。手札ドロー・捨て札・山札循環、マナコスト、シールドブロック、敵の行動予兆（Intent）システム、マウス操作。 |
| **ワンボタンランナー** | [`flappy_runner.rb`](flappy_runner.rb) | 1ボタン障害物ジャンプ＆フラップ滑空エンドレスランナー。地形パイプ生成、コイン収集、スコア・ハイスコア、死亡リトライ。 |
| **Tiny Dungeon** | [`tiny_dungeon.rb`](tiny_dungeon.rb) | ダンジョン探索アクション。外部スプライト（[`tiny_dungeon.spr`](tiny_dungeon.spr)）とタイルマップ（[`tiny_dungeon.map`](tiny_dungeon.map)）の連携。 |

---

## 💡 クックブック & 実践ユーティリティ (Cookbooks & Utils)

AI コード生成や高度なゲーム制作で頻出する、mrubyedge に最適化された実装パターン集です。

| サンプル名 | ファイル | 概要・収録テクニック |
|:---|:---|:---|
| **パーティクル・ジューシー演出** | [`particles.rb`](particles.rb) | 画面シェイク（振動減衰）、ヒットストップ、ダメージポップアップ（跳ね上がり）、リング衝撃波、火花・爆発、イージング関数。 |
| **シーン遷移 & 会話UI** | [`scene_ui.rb`](scene_ui.rb) | ステートマシン画面遷移、ブラインドワイプ暗転演出、RPG風タイプライター会話ダイアログ、コマンドバトル選択UI。 |
| **プロシージャル生成 & アルゴリズム** | [`procgen_utils.rb`](procgen_utils.rb) | Fisher-Yates 配列シャッフル、重み付きランダム抽選、穴掘り法迷路自動生成、幅優先探索（BFS）による最短経路探索。 |

---

## 🛠️ 内蔵エディタ & 分離フォーマット

| ツール / サンプル名 | ファイル | 概要 |
|:---|:---|:---|
| **スプライトエディタ** | [`sprite_editor.rb`](sprite_editor.rb) | `uk edit spr` で起動するドット絵エディタ。可変サイズ（16x16 / 16x32 / 32x16 / 32x32）、右クリックスポイト、アニメプレビュー＆オニオンスキン、パレット切替、コピペ、反転・回転対応。 |
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
| **楕円・プリミティブ** | [`oval.rb`](oval.rb) | `oval()` / `ovalfill()` による楕円描画デモ。 |

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

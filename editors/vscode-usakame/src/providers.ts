import * as vscode from 'vscode';
import {
  DEFAULT_PALETTE_RGBA,
  encodeRgbaToScaledPngDataUri,
  extractBank0RegionRgba,
  findNextFreeSpriteId,
  PALETTE_COLOR_NAMES,
  ParsedUsakameDocument,
  rgbaToHex,
} from './parser';

export interface UsakameApiSpec {
  name: string;
  signature: string;
  params: { label: string; doc: string }[];
  summary: string;
  snippet: string;
}

export const USAKAME_API_LIST: UsakameApiSpec[] = [
  {
    name: 'spr',
    signature: 'spr(id_or_emoji, x = 0, y = 0, flip_x = false, flip_y = false, rotate = 0, scale = 1.0)',
    params: [
      { label: 'id_or_emoji', doc: 'スプライト番号 (0..255) または絵文字文字列 ("🐰" 等)' },
      { label: 'x = 0', doc: '描画先の左上 X 座標' },
      { label: 'y = 0', doc: '描画先の左上 Y 座標' },
      { label: 'flip_x = false', doc: 'true で左右反転' },
      { label: 'flip_y = false', doc: 'true で上下反転' },
      { label: 'rotate = 0', doc: '回転角 (度数法 0..360、時計回り)' },
      { label: 'scale = 1.0', doc: '拡大縮小率 (1.0 = 等倍)' },
    ],
    summary: 'スプライト番号 `id` または絵文字を座標 `(x, y)` に描画します。`@SPRITE` で定義されたサイズ（16x16, 32x32 等）や `pal:<id>` が自動適用されます。',
    snippet: 'spr(${1:0}, ${2:x}, ${3:y})',
  },
  {
    name: 'blt',
    signature: 'blt(x = 0, y = 0, bank = 0, u = 0, v = 0, w = 16, h = 16, rotate = 0, scale = 1.0, pal = nil)',
    params: [
      { label: 'x = 0', doc: '画面上の描画先 X 座標' },
      { label: 'y = 0', doc: '画面上の描画先 Y 座標' },
      { label: 'bank = 0', doc: '転送元バンク番号 (通常は 0)' },
      { label: 'u = 0', doc: 'バンク上の切り出し左上 X (U) 座標 (px)' },
      { label: 'v = 0', doc: 'バンク上の切り出し左上 Y (V) 座標 (px)' },
      { label: 'w = 16', doc: '切り出し幅 (px)。負の値で左右反転' },
      { label: 'h = 16', doc: '切り出し高さ (px)。負の値で上下反転' },
      { label: 'rotate = 0', doc: '回転角 (度数法 0..360)' },
      { label: 'scale = 1.0', doc: '拡大縮小率' },
      { label: 'pal = nil', doc: '上書き適用する @PALETTE 番号 (0, 1, 2...、色違い描画用)' },
    ],
    summary: 'バンク `bank` の矩形領域 `(u, v, w, h)` を画面座標 `(x, y)` にピクセル転送描画します。第10引数 `pal` でパレットスワップも可能です。',
    snippet: 'blt(${1:x}, ${2:y}, ${3:0}, ${4:0}, ${5:0}, ${6:16}, ${7:16})',
  },
  {
    name: 'cls',
    signature: 'cls(col = 0)',
    params: [{ label: 'col = 0', doc: '塗りつぶすパレット色番号 (0..15)' }],
    summary: '仮想画面全体を指定したパレット色 `col` でクリアします。',
    snippet: 'cls(${1:0})',
  },
  {
    name: 'pal',
    signature: 'pal(c0 = nil, c1 = nil)',
    params: [
      { label: 'c0 = nil', doc: '元の色番号 (0..15)、または16要素の配列。引数なしでリセット' },
      { label: 'c1 = nil', doc: '置換後の色番号 (0..15) または "#RRGGBB"' },
    ],
    summary: 'パレット色 `c0` を `c1` に置き換えます。引数なし `pal()` でパレット置換・透過設定をすべてリセットします。',
    snippet: 'pal(${1:c0}, ${2:c1})',
  },
  {
    name: 'pal_bank',
    signature: 'pal_bank(id = 0)',
    params: [{ label: 'id = 0', doc: '@PALETTE で定義したパレットバンク番号 (0 で標準 PICO-8 パレットにリセット)' }],
    summary: '以降の描画で使用するパレットバンクを `@PALETTE <id>` に切り替えます。',
    snippet: 'pal_bank(${1:1})',
  },
  {
    name: 'palt',
    signature: 'palt(col = nil, t = true)',
    params: [
      { label: 'col = nil', doc: 'パレット色番号 (0..15)。引数なしでリセット' },
      { label: 't = true', doc: 'true で透明、false で不透明' },
    ],
    summary: 'スプライト描画時に特定パレット色 `col` を透明/不透明として扱うか設定します。',
    snippet: 'palt(${1:0}, ${2:true})',
  },
  {
    name: 'map',
    signature: 'map(cel_x = 0, cel_y = 0, sx = 0, sy = 0, cel_w = map.width, cel_h = map.height)',
    params: [
      { label: 'cel_x = 0', doc: 'マップ上の開始セル X' },
      { label: 'cel_y = 0', doc: 'マップ上の開始セル Y' },
      { label: 'sx = 0', doc: '画面上の描画左上 X 座標 (px)' },
      { label: 'sy = 0', doc: '画面上の描画左上 Y 座標 (px)' },
      { label: 'cel_w', doc: '描画するセル幅' },
      { label: 'cel_h', doc: '描画するセル高さ' },
    ],
    summary: '`@MAP` のタイル領域を画面座標 `(sx, sy)` に一括描画します (1セル = 16x16 px)。',
    snippet: 'map(${1:0}, ${2:0}, ${3:0}, ${4:0})',
  },
  {
    name: 'mget',
    signature: 'mget(cel_x = 0, cel_y = 0)',
    params: [
      { label: 'cel_x = 0', doc: 'セル X 座標' },
      { label: 'cel_y = 0', doc: 'セル Y 座標' },
    ],
    summary: '指定セルのタイル番号（整数）を返します。空マスは `nil` を返します（`if mget(x, y)` で判定可能）。',
    snippet: 'mget(${1:cx}, ${2:cy})',
  },
  {
    name: 'mset',
    signature: 'mset(cel_x = 0, cel_y = 0, val = nil)',
    params: [
      { label: 'cel_x = 0', doc: 'セル X 座標' },
      { label: 'cel_y = 0', doc: 'セル Y 座標' },
      { label: 'val = nil', doc: '設定するタイル番号 (0以上) または消去用の nil (※ -1 はエラーになります)' },
    ],
    summary: '指定セルにタイル番号を設定します。消去する場合は `nil` または `mdel(x, y)` を使用してください。',
    snippet: 'mset(${1:cx}, ${2:cy}, ${3:tile_id})',
  },
  {
    name: 'mdel',
    signature: 'mdel(cel_x = 0, cel_y = 0)',
    params: [
      { label: 'cel_x = 0', doc: 'セル X 座標' },
      { label: 'cel_y = 0', doc: 'セル Y 座標' },
    ],
    summary: '指定セルのタイルを消去（空マス化）します。',
    snippet: 'mdel(${1:cx}, ${2:cy})',
  },
  {
    name: 'btn',
    signature: 'btn(id = 0)',
    params: [{ label: 'id = 0', doc: '0:左, 1:右, 2:上, 3:下, 4:Z/Space(A), 5:X/Enter(B)' }],
    summary: '指定したボタン `id` が現在押されているか返します。',
    snippet: 'btn(${1:0})',
  },
  {
    name: 'btnp',
    signature: 'btnp(id = 0)',
    params: [{ label: 'id = 0', doc: '0:左, 1:右, 2:上, 3:下, 4:Z/Space(A), 5:X/Enter(B)' }],
    summary: '指定したボタン `id` が押された瞬間（エッジ判定）のみ `true` を返します。',
    snippet: 'btnp(${1:4})',
  },
  {
    name: 'print_text',
    signature: 'print_text(text = "", x = 0, y = 0, col = 7)',
    params: [
      { label: 'text', doc: '描画する文字列（日本語・美咲フォント対応）' },
      { label: 'x = 0', doc: '左上 X 座標' },
      { label: 'y = 0', doc: '左上 Y 座標' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '文字列を1-bitドット絵フォント（日本語・ASCII対応）でくっきり描画します。',
    snippet: 'print_text(${1:"HELLO"}, ${2:x}, ${3:y}, ${4:7})',
  },
  {
    name: 'rect',
    signature: 'rect(x = 0, y = 0, w = 16, h = 16, col = 7)',
    params: [
      { label: 'x', doc: '左上 X 座標' },
      { label: 'y', doc: '左上 Y 座標' },
      { label: 'w', doc: '幅' },
      { label: 'h', doc: '高さ' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '枠線のみの矩形を描画します。',
    snippet: 'rect(${1:x}, ${2:y}, ${3:16}, ${4:16}, ${5:7})',
  },
  {
    name: 'rectfill',
    signature: 'rectfill(x = 0, y = 0, w = 16, h = 16, col = 7)',
    params: [
      { label: 'x', doc: '左上 X 座標' },
      { label: 'y', doc: '左上 Y 座標' },
      { label: 'w', doc: '幅' },
      { label: 'h', doc: '高さ' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '塗りつぶし矩形を描画します。',
    snippet: 'rectfill(${1:x}, ${2:y}, ${3:16}, ${4:16}, ${5:7})',
  },
  {
    name: 'circ',
    signature: 'circ(x = 0, y = 0, r = 4, col = 7)',
    params: [
      { label: 'x', doc: '中心 X 座標' },
      { label: 'y', doc: '中心 Y 座標' },
      { label: 'r', doc: '半径' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '枠線のみの円を描画します。',
    snippet: 'circ(${1:x}, ${2:y}, ${3:4}, ${4:7})',
  },
  {
    name: 'circfill',
    signature: 'circfill(x = 0, y = 0, r = 4, col = 7)',
    params: [
      { label: 'x', doc: '中心 X 座標' },
      { label: 'y', doc: '中心 Y 座標' },
      { label: 'r', doc: '半径' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '塗りつぶし円を描画します。',
    snippet: 'circfill(${1:x}, ${2:y}, ${3:4}, ${4:7})',
  },
  {
    name: 'line',
    signature: 'line(x0 = 0, y0 = 0, x1 = 0, y1 = 0, col = 7)',
    params: [
      { label: 'x0', doc: '始点 X' },
      { label: 'y0', doc: '始点 Y' },
      { label: 'x1', doc: '終点 X' },
      { label: 'y1', doc: '終点 Y' },
      { label: 'col = 7', doc: 'パレット色番号 (0..15)' },
    ],
    summary: '始点から終点まで直線を1px幅で描画します。',
    snippet: 'line(${1:x0}, ${2:y0}, ${3:x1}, ${4:y1}, ${5:7})',
  },
  {
    name: 'sfx',
    signature: 'sfx(id_or_preset, channel = -1)',
    params: [
      { label: 'id_or_preset', doc: '@SFX の番号 (0, 1...) またはプリセット名 (:jump, :coin, :hit, :explosion 等)' },
      { label: 'channel = -1', doc: '再生チャンネル (-1 で自動選択)' },
    ],
    summary: '`@SFX` で定義した効果音または内蔵プリセット効果音を再生します。',
    snippet: 'sfx(${1:0})',
  },
  {
    name: 'music',
    signature: 'music(id = 0, loop = true)',
    params: [
      { label: 'id = 0', doc: '@MUSIC の番号 (-1 で停止)' },
      { label: 'loop = true', doc: 'ループ再生するかどうか' },
    ],
    summary: '`@MUSIC` で定義した BGM パターンを再生します。',
    snippet: 'music(${1:0})',
  },
  {
    name: 'camera',
    signature: 'camera(x = 0, y = 0)',
    params: [
      { label: 'x = 0', doc: 'カメラオフセット X' },
      { label: 'y = 0', doc: 'カメラオフセット Y' },
    ],
    summary: '以降の描画座標から `(x, y)` を減算します。引数なし `camera()` で `(0, 0)` にリセット。',
    snippet: 'camera(${1:x}, ${2:y})',
  },
];

function generateDotsBlock(w: number, h: number): string {
  const row = '.'.repeat(w);
  return Array.from({ length: h }, () => row).join('\n');
}

export class UsakameCompletionProvider implements vscode.CompletionItemProvider {
  constructor(private getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument) {}

  public provideCompletionItems(
    document: vscode.TextDocument,
    position: vscode.Position
  ): vscode.CompletionItem[] | vscode.CompletionList {
    const parsed = this.getParsedDoc(document);
    const lineText = document.lineAt(position.line).text;
    const linePrefix = lineText.slice(0, position.character);
    const isResourceSection =
      document.languageId === 'usakame-spr' ||
      document.languageId === 'usakame-map' ||
      (parsed.hasEndMarker && position.line > parsed.endMarkerLine);

    if (isResourceSection) {
      return this.provideResourceCompletions(document, position, linePrefix, parsed);
    }

    return this.provideCodeCompletions(document, position, linePrefix, parsed);
  }

  private provideResourceCompletions(
    document: vscode.TextDocument,
    position: vscode.Position,
    linePrefix: string,
    parsed: ParsedUsakameDocument
  ): vscode.CompletionItem[] {
    const items: vscode.CompletionItem[] = [];
    const trimmed = linePrefix.trim();

    // Detect custom @SPRITE with size / id typed on the line, e.g. "@SPRITE", "@SPRITE size32x32", "@SPRITE 4 32x32 pal:1"
    if (trimmed.startsWith('@') || /^@(?:S|SP|SPR|SPRI|SPRIT|SPRITE|P|PA|PAL|M|MA|MAP|SF|SFX)/i.test(trimmed)) {
      const replaceRange = new vscode.Range(
        position.line,
        linePrefix.indexOf('@') >= 0 ? linePrefix.indexOf('@') : 0,
        position.line,
        position.character
      );

      // Parse user-typed dimensions if any (e.g. "@SPRITE size32x32" or "@SPRITE 4 32x32")
      const dimMatch = /(?:size:?)?(\d+)x(\d+)/i.exec(trimmed);
      const idMatch = /^@SPRITE\s+(\d+)\b/i.exec(trimmed);
      const palMatch = /(?:pal|p)[:=](\d+)/i.exec(trimmed);

      const customW = dimMatch ? Math.min(64, Math.max(1, parseInt(dimMatch[1], 10))) : 16;
      const customH = dimMatch ? Math.min(64, Math.max(1, parseInt(dimMatch[2], 10))) : 16;
      const nextId = idMatch ? parseInt(idMatch[1], 10) : findNextFreeSpriteId(parsed, customW, customH);
      const palSuffix = palMatch ? ` pal:${palMatch[1]}` : parsed.defaultPaletteId > 0 ? ` pal:${parsed.defaultPaletteId}` : '';

      // 1. Dynamic @SPRITE matching whatever size user typed (or 16x16 by default)
      if (dimMatch) {
        const dynamicItem = new vscode.CompletionItem(
          `@SPRITE ${nextId} ${customW}x${customH}${palSuffix} (${customW}×${customH} 展開)`,
          vscode.CompletionItemKind.Snippet
        );
        dynamicItem.filterText = trimmed;
        dynamicItem.sortText = '00_dynamic_sprite';
        dynamicItem.detail = `Usakame ${customW}×${customH} 空スプライトテンプレートを展開`;
        dynamicItem.range = replaceRange;
        dynamicItem.insertText = new vscode.SnippetString(
          `@SPRITE \${1:${nextId}} ${customW}x${customH}${palSuffix}\n${generateDotsBlock(customW, customH)}`
        );
        dynamicItem.command = {
          command: 'usakame.openSpriteEditor',
          title: 'Open Inline Sprite Editor',
          arguments: [document.uri, nextId],
        };
        items.push(dynamicItem);
      }

      // 2. Standard preset @SPRITE sizes
      const presets: { label: string; w: number; h: number; sort: string; desc: string }[] = [
        { label: '@SPRITE (16x16)', w: 16, h: 16, sort: '01_spr16', desc: '標準 16×16 スプライト (1タイル)' },
        { label: '@SPRITE size32x32 (32x32)', w: 32, h: 32, sort: '02_spr32', desc: '大型 32×32 スプライト (2×2タイル)' },
        { label: '@SPRITE size16x32 (16x32)', w: 16, h: 32, sort: '03_spr16x32', desc: '縦長 16×32 スプライト (1×2タイル)' },
        { label: '@SPRITE size24x24 (24x24)', w: 24, h: 24, sort: '04_spr24', desc: '中型 24×24 スプライト' },
        { label: '@SPRITE size48x48 (48x48)', w: 48, h: 48, sort: '05_spr48', desc: '特大 48×48 ボススプライト (3×3タイル)' },
      ];

      for (const preset of presets) {
        const freeId = idMatch ? parseInt(idMatch[1], 10) : findNextFreeSpriteId(parsed, preset.w, preset.h);
        const sizeToken = preset.w === 16 && preset.h === 16 ? '' : ` ${preset.w}x${preset.h}`;
        const item = new vscode.CompletionItem(preset.label, vscode.CompletionItemKind.Snippet);
        item.filterText = `@SPRITE ${preset.w}x${preset.h} size${preset.w}x${preset.h}`;
        item.sortText = preset.sort;
        item.detail = `${preset.desc} (次の空きID: ${freeId})`;
        item.range = replaceRange;
        item.insertText = new vscode.SnippetString(
          `@SPRITE \${1:${freeId}}${sizeToken}${palSuffix}\n${generateDotsBlock(preset.w, preset.h)}`
        );
        items.push(item);
      }

      // 3. @PALETTE template
      let nextPalId = 1;
      while (parsed.palettes.has(nextPalId)) {
        nextPalId++;
      }
      const palItem = new vscode.CompletionItem(
        `@PALETTE ${nextPalId} (カスタムパレット定義)`,
        vscode.CompletionItemKind.Color
      );
      palItem.filterText = '@PALETTE';
      palItem.sortText = '06_palette';
      palItem.detail = 'ベースパレット(PICO-8)からのピンポイント色上書き定義';
      palItem.range = replaceRange;
      palItem.insertText = new vscode.SnippetString(
        `@PALETTE \${1:${nextPalId}}\n` +
          `1: #\${2:1D2B53}  # 深い影色\n` +
          `3: #\${3:008751}  # 中間色\n` +
          `B: #\${4:00E436}  # ハイライト色\n` +
          `7: #\${5:FFF1E8}  # 白・アクセント`
      );
      items.push(palItem);

      // 4. @MAP template
      const mapItem = new vscode.CompletionItem('@MAP 0 0 (16x16 タイルマップ)', vscode.CompletionItemKind.Snippet);
      mapItem.filterText = '@MAP';
      mapItem.sortText = '07_map';
      mapItem.detail = '16×16 セルのタイルマップ定義を展開';
      mapItem.range = replaceRange;
      const mapRows = [
        '1'.repeat(16),
        ...Array.from({ length: 14 }, () => '1' + '.'.repeat(14) + '1'),
        '1'.repeat(16),
      ].join('\n');
      mapItem.insertText = new vscode.SnippetString(`@MAP \${1:0} \${2:0}\n${mapRows}`);
      items.push(mapItem);

      // 5. @SFX & @MUSIC templates
      const sfxItem = new vscode.CompletionItem('@SFX 0 (効果音定義)', vscode.CompletionItemKind.Snippet);
      sfxItem.filterText = '@SFX';
      sfxItem.sortText = '08_sfx';
      sfxItem.detail = '8-bit シンセ効果音定義 (MML / ノート記法)';
      sfxItem.range = replaceRange;
      sfxItem.insertText = new vscode.SnippetString(`@SFX \${1:0}\nwave \${2|square,pulse,pulse12,triangle,saw,noise,organ,phaser|} speed \${3:4}\n\${4:c2 e2 g2 c3:fade}`);
      items.push(sfxItem);

      const musicItem = new vscode.CompletionItem('@MUSIC 0 (BGM定義)', vscode.CompletionItemKind.Snippet);
      musicItem.filterText = '@MUSIC';
      musicItem.sortText = '09_music';
      musicItem.detail = 'マルチトラック BGM パターン定義';
      musicItem.range = replaceRange;
      musicItem.insertText = new vscode.SnippetString(
        `@MUSIC \${1:0} tempo=140\n` +
          `ch0 wave=pulse12 vol=6 L8 O4 c e g > c < g e c4\n` +
          `ch1 wave=triangle vol=7 L4 O3 c g c g`
      );
      items.push(musicItem);
    }

    // Also allow typing `pal:` on @SPRITE header line to pick from defined palettes
    if (trimmed.startsWith('@SPRITE') && /(?:pal|p)[:=]?\d*$/i.test(linePrefix)) {
      for (const [pid, pal] of parsed.palettes.entries()) {
        const pItem = new vscode.CompletionItem(
          `pal:${pid}`,
          vscode.CompletionItemKind.Color
        );
        pItem.detail = pid === 0 ? '標準 PICO-8 16色パレット' : `カスタムパレット #${pid}`;
        const md = new vscode.MarkdownString();
        md.appendMarkdown(`**Palette ${pid}**\n\n`);
        for (let i = 0; i < 16; i++) {
          md.appendMarkdown(`\`${i.toString(16).toUpperCase()}: ${rgbaToHex(pal[i])}\` `);
          if (i % 4 === 3) {
            md.appendMarkdown('  \n');
          }
        }
        pItem.documentation = md;
        items.push(pItem);
      }
    }

    return items;
  }

  private provideCodeCompletions(
    document: vscode.TextDocument,
    position: vscode.Position,
    linePrefix: string,
    parsed: ParsedUsakameDocument
  ): vscode.CompletionItem[] {
    const items: vscode.CompletionItem[] = [];

    // 1. If inside spr(|) first argument, offer defined sprites with visual preview!
    if (/\bspr\s*\(\s*\d*$/.test(linePrefix)) {
      for (const [id, sp] of parsed.sprites.entries()) {
        const item = new vscode.CompletionItem(
          `${id}`,
          vscode.CompletionItemKind.Value
        );
        item.sortText = `00_${id.toString().padStart(3, '0')}`;
        item.detail = `Sprite #${id} (${sp.width}×${sp.height}px, pal:${sp.paletteId})`;
        if (!sp.emoji) {
          const scale = sp.width <= 16 ? 5 : 3;
          const pngUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, scale, { checkerboard: true });
          const md = new vscode.MarkdownString();
          md.appendMarkdown(`**@SPRITE ${id}** (\`${sp.width}×${sp.height}\`, \`pal:${sp.paletteId}\`)\n\n`);
          md.appendMarkdown(`![Sprite ${id}](${pngUri})\n`);
          item.documentation = md;
        }
        items.push(item);
      }
      return items;
    }

    // 2. If inside blt(x, y, bank, |) 4th argument (u, v, w, h), offer quick region snippets for each defined sprite!
    if (/\bblt\s*\(\s*[^,]+,\s*[^,]+,\s*0\s*,\s*\d*$/.test(linePrefix)) {
      for (const [id, sp] of parsed.sprites.entries()) {
        const u = (id % 16) * 16;
        const v = Math.floor(id / 16) * 16;
        const item = new vscode.CompletionItem(
          `${u}, ${v}, ${sp.width}, ${sp.height} (Sprite #${id})`,
          vscode.CompletionItemKind.Snippet
        );
        item.insertText = `${u}, ${v}, ${sp.width}, ${sp.height}`;
        item.sortText = `00_${id.toString().padStart(3, '0')}`;
        item.detail = `Sprite #${id} のバンク領域 (u=${u}, v=${v}, w=${sp.width}, h=${sp.height})`;
        if (!sp.emoji) {
          const scale = sp.width <= 16 ? 5 : 3;
          const pngUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, scale, { checkerboard: true });
          const md = new vscode.MarkdownString();
          md.appendMarkdown(`**Sprite #${id}** — Bank 0 \`(u=${u}, v=${v}, w=${sp.width}, h=${sp.height})\`\n\n`);
          md.appendMarkdown(`![Sprite ${id}](${pngUri})\n`);
          item.documentation = md;
        }
        items.push(item);
      }
      return items;
    }

    // 3. __END__ section generator snippet at top-level
    if ('__END__'.startsWith(linePrefix.trim()) && linePrefix.trim().length > 0) {
      const endItem = new vscode.CompletionItem('__END__ (Usakame リソース領域を作成)', vscode.CompletionItemKind.Snippet);
      endItem.insertText = new vscode.SnippetString(
        `__END__\n@PALETTE 1\n1: #1D2B53\n3: #008751\nB: #00E436\n7: #FFF1E8\n\n@SPRITE 0 16x16 pal:1\n${generateDotsBlock(16, 16)}\n`
      );
      endItem.detail = '__END__ と初期 @PALETTE / @SPRITE ブロックを挿入';
      items.push(endItem);
    }

    // 4. All Usakame Engine API methods
    for (const api of USAKAME_API_LIST) {
      const item = new vscode.CompletionItem(api.name, vscode.CompletionItemKind.Function);
      item.detail = api.signature;
      item.insertText = new vscode.SnippetString(api.snippet);
      const md = new vscode.MarkdownString();
      md.appendCodeblock(api.signature, 'ruby');
      md.appendMarkdown(api.summary);
      item.documentation = md;
      items.push(item);
    }

    return items;
  }
}

/**
 * Displays rich Sprite & Bank 0 region previews directly above the cursor (top-right popup)
 * while typing arguments inside `spr(...)` or `blt(...)`!
 */
export class UsakameSignatureHelpProvider implements vscode.SignatureHelpProvider {
  constructor(private getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument) {}

  public provideSignatureHelp(
    document: vscode.TextDocument,
    position: vscode.Position
  ): vscode.SignatureHelp | null {
    const parsed = this.getParsedDoc(document);
    if (parsed.hasEndMarker && position.line >= parsed.endMarkerLine) {
      return null;
    }

    const lineText = document.lineAt(position.line).text;
    const prefix = lineText.slice(0, position.character);

    // Find the innermost open function call `funcName(` before cursor
    const callInfo = this.findActiveFunctionCall(prefix, lineText);
    if (!callInfo) {
      return null;
    }

    const apiSpec = USAKAME_API_LIST.find((a) => a.name === callInfo.funcName);
    if (!apiSpec) {
      return null;
    }

    const sigHelp = new vscode.SignatureHelp();
    const sigInfo = new vscode.SignatureInformation(apiSpec.signature);
    sigInfo.parameters = apiSpec.params.map(
      (p) => new vscode.ParameterInformation(p.label, new vscode.MarkdownString(p.doc))
    );

    const md = new vscode.MarkdownString();
    md.isTrusted = true;

    // Special visual preview for spr(...) and blt(...) right in the SignatureHelp popup!
    if (callInfo.funcName === 'spr') {
      const firstArg = callInfo.allArgs[0]?.trim();
      if (firstArg && /^\d+$/.test(firstArg)) {
        const spId = parseInt(firstArg, 10);
        const sp = parsed.sprites.get(spId);
        if (sp && !sp.emoji) {
          const scale = sp.width <= 16 ? 5 : sp.width <= 32 ? 3 : 2;
          const pngUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, scale, { checkerboard: true });
          const slotX = (spId % 16) * 16;
          const slotY = Math.floor(spId / 16) * 16;
          md.appendMarkdown(
            `![Sprite ${spId}](${pngUri})  \n` +
              `**@SPRITE ${spId}** — サイズ: \`${sp.width}×${sp.height}px\` / パレット: \`pal:${sp.paletteId}\` / Bank0座標: \`(${slotX}, ${slotY})\`\n\n---\n`
          );
        } else {
          md.appendMarkdown(`*(Sprite #${spId} は \`__END__\` 内にまだ定義されていません)*\n\n---\n`);
        }
      } else if (parsed.sprites.size > 0) {
        // Show quick catalog of available sprites when typing the 1st argument
        md.appendMarkdown(`**定義済みスプライト一覧**: `);
        for (const [id, sp] of Array.from(parsed.sprites.entries()).slice(0, 8)) {
          if (!sp.emoji) {
            const miniUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, 2, { checkerboard: true });
            md.appendMarkdown(`\`#${id}\` ![#${id}](${miniUri}) `);
          }
        }
        md.appendMarkdown(`\n\n---\n`);
      }
    } else if (callInfo.funcName === 'blt') {
      const parseNumArg = (idx: number, fallback: number): number => {
        const raw = callInfo.allArgs[idx]?.trim();
        if (raw && /^-?\d+$/.test(raw)) {
          return parseInt(raw, 10);
        }
        return fallback;
      };
      const bankId = parseNumArg(2, 0);
      const u = parseNumArg(3, 0);
      const v = parseNumArg(4, 0);
      const w = parseNumArg(5, 16);
      const h = parseNumArg(6, 16);
      const palOverride =
        callInfo.allArgs[9] && /^\d+$/.test(callInfo.allArgs[9].trim())
          ? parseInt(callInfo.allArgs[9].trim(), 10)
          : null;

      if (bankId === 0 && parsed.sprites.size > 0) {
        const absW = Math.max(1, Math.min(256, Math.abs(w)));
        const absH = Math.max(1, Math.min(256, Math.abs(h)));
        const regionRgba = extractBank0RegionRgba(parsed, u, v, w, h, palOverride);
        const scale = absW <= 16 && absH <= 16 ? 5 : absW <= 32 && absH <= 32 ? 3 : 2;
        const regionUri = encodeRgbaToScaledPngDataUri(regionRgba, absW, absH, scale, { checkerboard: true });

        // Also render a surrounding context crop of Bank 0 (e.g. 64x64 around u,v) with red highlight box!
        const ctxW = Math.min(256, Math.max(64, absW + 32));
        const ctxH = Math.min(256, Math.max(64, absH + 32));
        const ctxX = Math.max(0, Math.min(256 - ctxW, u - 16));
        const ctxY = Math.max(0, Math.min(256 - ctxH, v - 16));
        const ctxRgba = extractBank0RegionRgba(parsed, ctxX, ctxY, ctxW, ctxH, palOverride);
        const ctxUri = encodeRgbaToScaledPngDataUri(ctxRgba, ctxW, ctxH, 2, {
          checkerboard: true,
          highlightRect: { x: u - ctxX, y: v - ctxY, w: absW, h: absH },
        });

        md.appendMarkdown(
          `**切り出しプレビュー** \`(u=${u}, v=${v}, w=${w}, h=${h}${palOverride !== null ? `, pal=${palOverride}` : ''})\` & **Bank 0 領域**:  \n` +
            `![Region](${regionUri}) &nbsp;&nbsp; ![BankContext](${ctxUri})\n\n---\n`
        );
      }
    }

    md.appendMarkdown(apiSpec.summary);
    sigInfo.documentation = md;

    sigHelp.signatures = [sigInfo];
    sigHelp.activeSignature = 0;
    sigHelp.activeParameter = Math.min(callInfo.argIndex, sigInfo.parameters.length - 1);
    return sigHelp;
  }

  private findActiveFunctionCall(
    prefix: string,
    fullLine: string
  ): { funcName: string; argIndex: number; allArgs: string[] } | null {
    let depth = 0;
    let openParenPos = -1;
    for (let i = prefix.length - 1; i >= 0; i--) {
      const ch = prefix[i];
      if (ch === ')') {
        depth++;
      } else if (ch === '(') {
        if (depth === 0) {
          openParenPos = i;
          break;
        }
        depth--;
      }
    }
    if (openParenPos === -1) {
      return null;
    }

    const beforeParen = prefix.slice(0, openParenPos);
    const fnMatch = /\b([a-zA-Z_]\w*)\s*$/.exec(beforeParen);
    if (!fnMatch) {
      return null;
    }
    const funcName = fnMatch[1];

    // Count commas at depth 0 between openParenPos and cursor
    let argIndex = 0;
    let innerDepth = 0;
    for (let i = openParenPos + 1; i < prefix.length; i++) {
      const ch = prefix[i];
      if (ch === '(' || ch === '[' || ch === '{') {
        innerDepth++;
      } else if (ch === ')' || ch === ']' || ch === '}') {
        innerDepth = Math.max(0, innerDepth - 1);
      } else if (ch === ',' && innerDepth === 0) {
        argIndex++;
      }
    }

    // Extract all args on this call up to matching ')' or end of line
    let closeParenPos = fullLine.length;
    innerDepth = 0;
    for (let i = openParenPos + 1; i < fullLine.length; i++) {
      const ch = fullLine[i];
      if (ch === '(' || ch === '[' || ch === '{') {
        innerDepth++;
      } else if (ch === ')' || ch === ']' || ch === '}') {
        if (innerDepth === 0 && ch === ')') {
          closeParenPos = i;
          break;
        }
        innerDepth = Math.max(0, innerDepth - 1);
      }
    }
    const argsStr = fullLine.slice(openParenPos + 1, closeParenPos);
    const allArgs = argsStr.split(',');

    return { funcName, argIndex, allArgs };
  }
}

export class UsakameHoverProvider implements vscode.HoverProvider {
  constructor(private getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument) {}

  public provideHover(document: vscode.TextDocument, position: vscode.Position): vscode.Hover | null {
    const parsed = this.getParsedDoc(document);
    const lineText = document.lineAt(position.line).text;

    // 1. Hover inside __END__ resource section
    if (parsed.hasEndMarker && position.line > parsed.endMarkerLine) {
      // Check if hovering on or inside a @SPRITE block
      for (const sp of parsed.sprites.values()) {
        if (position.line >= sp.headerLine && position.line <= sp.endLine && !sp.emoji) {
          const scale = sp.width <= 16 ? 6 : sp.width <= 32 ? 4 : 3;
          const pngUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, scale, { checkerboard: true });
          const md = new vscode.MarkdownString();
          md.isTrusted = true;
          const editCmdUri = vscode.Uri.parse(
            `command:usakame.openSpriteEditor?${encodeURIComponent(JSON.stringify([document.uri, sp.id]))}`
          );
          md.appendMarkdown(
            `### 🎨 @SPRITE ${sp.id} (\`${sp.width}×${sp.height}\`, \`pal:${sp.paletteId}\`) — [インラインエディタを開く](${editCmdUri})\n\n`
          );
          md.appendMarkdown(`![Sprite ${sp.id}](${pngUri})\n`);
          return new vscode.Hover(md);
        }
      }

      // Check if hovering on or inside a @PALETTE block
      for (const palBlock of parsed.paletteBlocks.values()) {
        if (position.line >= palBlock.headerLine && position.line <= palBlock.endLine) {
          const md = new vscode.MarkdownString();
          md.isTrusted = true;
          const editCmdUri = vscode.Uri.parse(
            `command:usakame.openPaletteEditor?${encodeURIComponent(JSON.stringify([document.uri, palBlock.id]))}`
          );
          md.appendMarkdown(`### 🌈 @PALETTE ${palBlock.id} — [パレットエディタを開く](${editCmdUri})\n\n`);
          // Render 16x1 color strip image
          const stripRgba = new Uint8Array(16 * 4 * 4);
          for (let y = 0; y < 4; y++) {
            for (let x = 0; x < 16; x++) {
              const c = palBlock.colors[x];
              const off = (y * 16 + x) * 4;
              stripRgba[off] = c[0];
              stripRgba[off + 1] = c[1];
              stripRgba[off + 2] = c[2];
              stripRgba[off + 3] = 255;
            }
          }
          const stripUri = encodeRgbaToScaledPngDataUri(stripRgba, 16, 4, 12, { checkerboard: false });
          md.appendMarkdown(`![Palette ${palBlock.id}](${stripUri})\n\n`);
          for (let i = 0; i < 16; i++) {
            const hex = rgbaToHex(palBlock.colors[i]);
            const isOverridden = palBlock.overriddenIndices.includes(i);
            md.appendMarkdown(
              `- \`${i.toString(16).toUpperCase()}\` (${i}): \`${hex}\` ${PALETTE_COLOR_NAMES[i]}${isOverridden ? ' **(カスタム上書き)**' : ''}\n`
            );
          }
          return new vscode.Hover(md);
        }
      }
    }

    // 2. Hover on spr(...) or blt(...) in Ruby code
    const sprMatch = /\bspr\s*\(\s*(\d+)\b/.exec(lineText);
    if (sprMatch) {
      const id = parseInt(sprMatch[1], 10);
      const sp = parsed.sprites.get(id);
      if (sp && !sp.emoji) {
        const scale = sp.width <= 16 ? 6 : 4;
        const pngUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, scale, { checkerboard: true });
        const editCmdUri = vscode.Uri.parse(
          `command:usakame.openSpriteEditor?${encodeURIComponent(JSON.stringify([document.uri, sp.id]))}`
        );
        const md = new vscode.MarkdownString();
        md.isTrusted = true;
        md.appendMarkdown(
          `### 🎨 Sprite #${id} (\`${sp.width}×${sp.height}\`, \`pal:${sp.paletteId}\`) — [スプライトを編集](${editCmdUri})\n\n`
        );
        md.appendMarkdown(`![Sprite ${id}](${pngUri})\n`);
        return new vscode.Hover(md);
      }
    }

    const bltMatch =
      /\bblt\s*\(\s*([^,]+),\s*([^,]+),\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*(-?\d+)\s*,\s*(-?\d+))?(?:\s*,\s*[^,]+,\s*[^,]+,\s*(\d+))?/.exec(
        lineText
      );
    if (bltMatch) {
      const bankId = parseInt(bltMatch[3], 10);
      if (bankId === 0) {
        const u = parseInt(bltMatch[4], 10);
        const v = parseInt(bltMatch[5], 10);
        const w = bltMatch[6] !== undefined ? parseInt(bltMatch[6], 10) : 16;
        const h = bltMatch[7] !== undefined ? parseInt(bltMatch[7], 10) : 16;
        const palOverride = bltMatch[8] !== undefined ? parseInt(bltMatch[8], 10) : null;
        const absW = Math.max(1, Math.min(256, Math.abs(w)));
        const absH = Math.max(1, Math.min(256, Math.abs(h)));
        const regionRgba = extractBank0RegionRgba(parsed, u, v, w, h, palOverride);
        const scale = absW <= 16 && absH <= 16 ? 6 : 4;
        const pngUri = encodeRgbaToScaledPngDataUri(regionRgba, absW, absH, scale, { checkerboard: true });
        const md = new vscode.MarkdownString();
        md.isTrusted = true;
        md.appendMarkdown(
          `### 🖼️ blt Bank 0 領域 \`(u=${u}, v=${v}, w=${w}, h=${h}${palOverride !== null ? `, pal=${palOverride}` : ''})\`\n\n`
        );
        md.appendMarkdown(`![blt region](${pngUri})\n`);
        return new vscode.Hover(md);
      }
    }

    return null;
  }
}

export class UsakameCodeLensProvider implements vscode.CodeLensProvider {
  private _onDidChangeCodeLenses = new vscode.EventEmitter<void>();
  public readonly onDidChangeCodeLenses = this._onDidChangeCodeLenses.event;

  constructor(private getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument) {}

  public refresh(): void {
    this._onDidChangeCodeLenses.fire();
  }

  public provideCodeLenses(document: vscode.TextDocument): vscode.CodeLens[] {
    const parsed = this.getParsedDoc(document);
    if (!parsed.hasEndMarker) {
      return [];
    }

    const lenses: vscode.CodeLens[] = [];

    // __END__ line lens to quickly add @SPRITE / @PALETTE
    if (parsed.endMarkerLine >= 0 && parsed.endMarkerLine < document.lineCount) {
      const endRange = new vscode.Range(parsed.endMarkerLine, 0, parsed.endMarkerLine, 7);
      lenses.push(
        new vscode.CodeLens(endRange, {
          title: '🎨 スプライトエディタを起動',
          command: 'usakame.openSpriteEditor',
          arguments: [document.uri, 0],
        }),
        new vscode.CodeLens(endRange, {
          title: '🌈 パレットエディタを起動',
          command: 'usakame.openPaletteEditor',
          arguments: [document.uri, 1],
        })
      );
    }

    for (const sp of parsed.sprites.values()) {
      if (sp.headerLine < document.lineCount) {
        const range = new vscode.Range(sp.headerLine, 0, sp.headerLine, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: `🎨 ドット絵を編集 (@SPRITE ${sp.id}: ${sp.width}×${sp.height}, pal:${sp.paletteId})`,
            command: 'usakame.openSpriteEditor',
            arguments: [document.uri, sp.id],
          })
        );
      }
    }

    for (const palBlock of parsed.paletteBlocks.values()) {
      if (palBlock.headerLine < document.lineCount) {
        const range = new vscode.Range(palBlock.headerLine, 0, palBlock.headerLine, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: `🌈 パレット #${palBlock.id} を編集 (${palBlock.overriddenIndices.length}色カスタム)`,
            command: 'usakame.openPaletteEditor',
            arguments: [document.uri, palBlock.id],
          })
        );
      }
    }

    for (let i = 0; i < parsed.mapBlocks.length; i++) {
      const mapBlock = parsed.mapBlocks[i];
      if (mapBlock.headerLine < document.lineCount) {
        const range = new vscode.Range(mapBlock.headerLine, 0, mapBlock.headerLine, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: `🗺️ タイルマップを編集 (@MAP ${mapBlock.offsetX} ${mapBlock.offsetY})`,
            command: 'usakame.openMapEditor',
            arguments: [document.uri, i],
          })
        );
      }
    }

    for (const sfx of parsed.sfxBlocks) {
      if (sfx.headerLine < document.lineCount) {
        const range = new vscode.Range(sfx.headerLine, 0, sfx.headerLine, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: `🔊 サウンドを編集・試聴 (@${sfx.kind} ${sfx.id})`,
            command: 'usakame.openSoundEditor',
            arguments: [document.uri, sfx.id, sfx.kind],
          })
        );
      }
    }

    return lenses;
  }
}

/**
 * Checks for mrubyedge forbidden CRuby methods & sprite slot overlaps
 */
export function updateUsakameDiagnostics(
  document: vscode.TextDocument,
  parsed: ParsedUsakameDocument,
  collection: vscode.DiagnosticCollection
): void {
  const config = vscode.workspace.getConfiguration('usakame');
  if (!config.get<boolean>('enableMrubyedgeLinter', true)) {
    collection.delete(document.uri);
    return;
  }

  const diags: vscode.Diagnostic[] = [];
  const codeEndLine = parsed.hasEndMarker ? parsed.endMarkerLine : document.lineCount;

  const forbiddenRules: { regex: RegExp; message: string }[] = [
    {
      regex: /\.sample\b/,
      message: 'mrubyedge には Array#sample が存在しません。`array[rand(array.size)]` を使用してください。',
    },
    {
      regex: /\.shuffle!?/,
      message: 'mrubyedge には Array#shuffle が存在しません。ランダムスワップ処理を自前で実装してください。',
    },
    {
      regex: /\.(?:even|odd)\?/,
      message: 'mrubyedge には Integer#even? / odd? が存在しません。`n % 2 == 0` / `n % 2 != 0` を使用してください。',
    },
    {
      regex: /\.(?:upto|downto)\s*\(/,
      message: 'mrubyedge には Integer#upto / downto が存在しません。`(n..m).each` または `while` ループを使用してください。',
    },
    {
      regex: /\.(?:gsub|sub)!?\s*\(/,
      message: 'mrubyedge には String#gsub / sub が存在しません。`split(pat).join(rep)` 等で代替してください。',
    },
    {
      regex: /\bmset\s*\([^,]+,[^,]+,\s*-\d+\s*\)/,
      message: 'mset に負数 (-1 等) を渡すと ArgumentError が発生します。タイルの消去には `mdel(x, y)` または `mset(x, y, nil)` を使用してください。',
    },
  ];

  for (let lineNum = 0; lineNum < codeEndLine && lineNum < document.lineCount; lineNum++) {
    const lineText = document.lineAt(lineNum).text;
    if (lineText.trim().startsWith('#')) {
      continue;
    }
    for (const rule of forbiddenRules) {
      const m = rule.regex.exec(lineText);
      if (m) {
        const range = new vscode.Range(lineNum, m.index, lineNum, m.index + m[0].length);
        const diag = new vscode.Diagnostic(range, rule.message, vscode.DiagnosticSeverity.Warning);
        diag.source = 'usakame (mrubyedge)';
        diags.push(diag);
      }
    }
  }

  // Check @SPRITE multi-tile slot overlaps in Bank 0
  for (const ov of parsed.bank0.overlaps) {
    if (ov.line < document.lineCount) {
      const lineText = document.lineAt(ov.line).text;
      const range = new vscode.Range(ov.line, 0, ov.line, lineText.length);
      const diag = new vscode.Diagnostic(
        range,
        `@SPRITE ${ov.id} が Bank 0 のタイルスロット (${ov.tx}, ${ov.ty}) で @SPRITE ${ov.prevId} と重複しています。空きスロットに配置してください。`,
        vscode.DiagnosticSeverity.Warning
      );
      diag.source = 'usakame (bank0)';
      diags.push(diag);
    }
  }

  collection.set(document.uri, diags);
}

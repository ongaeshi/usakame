import * as vscode from 'vscode';
import {
  DEFAULT_PALETTE_RGBA,
  findNextFreeSpriteId,
  PALETTE_COLOR_NAMES,
  parseHexColor,
  ParsedUsakameDocument,
  rgbaToHex,
} from './parser';

export type EditorTabKind = 'sprite' | 'palette' | 'map' | 'sound';

export class UsakameEditorPanel {
  public static currentPanel: UsakameEditorPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private targetUri: vscode.Uri;
  private disposables: vscode.Disposable[] = [];
  private isApplyingEdit = false;
  private undoStack: string[] = [];
  private redoStack: string[] = [];

  public static createOrShow(
    extensionUri: vscode.Uri,
    targetUri: vscode.Uri,
    getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument,
    initialTab: EditorTabKind,
    initialId = 0,
    initialSubKind = 'SFX'
  ): void {
    const activeEditor = vscode.window.activeTextEditor;
    const column = activeEditor?.viewColumn ?? vscode.ViewColumn.One;

    if (UsakameEditorPanel.currentPanel) {
      UsakameEditorPanel.currentPanel.targetUri = targetUri;
      UsakameEditorPanel.currentPanel.panel.reveal(column, false);
      UsakameEditorPanel.currentPanel.sendStateToWebview(initialTab, initialId, initialSubKind);
      return;
    }

    const fileName = targetUri.path.split(/[\\/]/).pop() || 'game.rb';
    const panel = vscode.window.createWebviewPanel(
      'usakameEditor',
      `Usakame Studio: ${fileName}`,
      { viewColumn: column, preserveFocus: false },
      {
        enableScripts: true,
        retainContextWhenHidden: true,
      }
    );

    UsakameEditorPanel.currentPanel = new UsakameEditorPanel(
      panel,
      extensionUri,
      targetUri,
      getParsedDoc,
      initialTab,
      initialId,
      initialSubKind
    );
  }

  private constructor(
    panel: vscode.WebviewPanel,
    private readonly extensionUri: vscode.Uri,
    targetUri: vscode.Uri,
    private readonly getParsedDoc: (doc: vscode.TextDocument) => ParsedUsakameDocument,
    initialTab: EditorTabKind,
    initialId: number,
    initialSubKind: string
  ) {
    this.panel = panel;
    this.targetUri = targetUri;
    this.panel.webview.html = this.getHtmlForWebview();

    this.panel.onDidDispose(() => this.dispose(), null, this.disposables);

    this.panel.webview.onDidReceiveMessage(
      async (msg) => {
        await this.handleWebviewMessage(msg);
      },
      null,
      this.disposables
    );

    vscode.workspace.onDidChangeTextDocument(
      (e) => {
        if (this.isApplyingEdit) {
          return;
        }
        if (e.document.uri.toString() === this.targetUri.toString()) {
          this.sendStateToWebview();
        }
      },
      null,
      this.disposables
    );

    setTimeout(() => {
      this.sendStateToWebview(initialTab, initialId, initialSubKind);
    }, 100);
  }

  public dispose(): void {
    UsakameEditorPanel.currentPanel = undefined;
    this.panel.dispose();
    while (this.disposables.length) {
      const d = this.disposables.pop();
      if (d) {
        d.dispose();
      }
    }
  }

  private async getTargetDocument(): Promise<vscode.TextDocument | null> {
    try {
      return await vscode.workspace.openTextDocument(this.targetUri);
    } catch {
      return vscode.window.activeTextEditor?.document || null;
    }
  }

  public async saveDocument(): Promise<void> {
    const doc = await this.getTargetDocument();
    if (!doc) {
      return;
    }
    const saved = await doc.save();
    this.panel.webview.postMessage({ type: 'saveResult', success: saved });
  }

  public recordUndoSnapshot(doc: vscode.TextDocument): void {
    const currentText = doc.getText();
    if (this.undoStack.length > 0 && this.undoStack[this.undoStack.length - 1] === currentText) {
      return;
    }
    this.undoStack.push(currentText);
    if (this.undoStack.length > 100) {
      this.undoStack.shift();
    }
    this.redoStack = [];
  }

  public async triggerUndo(): Promise<void> {
    const doc = await this.getTargetDocument();
    if (!doc || this.undoStack.length === 0) {
      return;
    }
    const previousText = this.undoStack.pop()!;
    this.redoStack.push(doc.getText());
    await this.replaceDocumentText(doc, previousText);
  }

  public async triggerRedo(): Promise<void> {
    const doc = await this.getTargetDocument();
    if (!doc || this.redoStack.length === 0) {
      return;
    }
    const nextText = this.redoStack.pop()!;
    this.undoStack.push(doc.getText());
    await this.replaceDocumentText(doc, nextText);
  }

  private async replaceDocumentText(doc: vscode.TextDocument, newText: string): Promise<void> {
    const fullRange = new vscode.Range(
      doc.positionAt(0),
      doc.positionAt(doc.getText().length)
    );
    const edit = new vscode.WorkspaceEdit();
    edit.replace(doc.uri, fullRange, newText);

    this.isApplyingEdit = true;
    await vscode.workspace.applyEdit(edit);
    this.isApplyingEdit = false;

    await this.sendStateToWebview();
  }

  public async sendStateToWebview(
    switchTab?: EditorTabKind,
    selectId?: number,
    subKind?: string
  ): Promise<void> {
    const doc = await this.getTargetDocument();
    if (!doc) {
      return;
    }
    const parsed = this.getParsedDoc(doc);

    const palettesObj: Record<number, { hexes: string[]; overridden: number[] }> = {};
    for (const [pid, pal] of parsed.palettes.entries()) {
      const block = parsed.paletteBlocks.get(pid);
      palettesObj[pid] = {
        hexes: pal.map(rgbaToHex),
        overridden: block ? block.overriddenIndices : [],
      };
    }

    const spritesArr = Array.from(parsed.sprites.values()).map((sp) => ({
      id: sp.id,
      width: sp.width,
      height: sp.height,
      explicitDims: sp.explicitDims,
      paletteId: sp.paletteId,
      emoji: sp.emoji || null,
      lines: sp.lines,
    }));

    const mapsArr = parsed.mapBlocks.map((m, idx) => {
      const cellsObj: Record<string, number> = {};
      for (const [k, v] of m.cells.entries()) {
        cellsObj[k] = v;
      }
      return {
        index: idx,
        offsetX: m.offsetX,
        offsetY: m.offsetY,
        width: m.width,
        height: m.height,
        cells: cellsObj,
      };
    });

    const sfxArr = parsed.sfxBlocks.map((s) => ({
      kind: s.kind,
      id: s.id,
      specText: s.specText,
    }));

    this.panel.webview.postMessage({
      type: 'syncDocument',
      fileName: doc.fileName.split(/[\\/]/).pop() || doc.fileName,
      defaultPaletteId: parsed.defaultPaletteId,
      colorNames: PALETTE_COLOR_NAMES,
      palettes: palettesObj,
      sprites: spritesArr,
      maps: mapsArr,
      sfxs: sfxArr,
      switchTab,
      selectId,
      subKind,
    });
  }

  private async handleWebviewMessage(msg: any): Promise<void> {
    const doc = await this.getTargetDocument();
    if (!doc) {
      return;
    }

    if (msg.type === 'requestSync') {
      await this.sendStateToWebview();
      return;
    }

    if (msg.type === 'save') {
      await this.saveDocument();
      return;
    }

    if (msg.type === 'undo') {
      await this.triggerUndo();
      return;
    }

    if (msg.type === 'redo') {
      await this.triggerRedo();
      return;
    }

    if (msg.type === 'updateSprite') {
      await this.applySpriteUpdate(
        doc,
        msg.id,
        msg.width,
        msg.height,
        msg.paletteId,
        msg.lines
      );
    } else if (msg.type === 'createNewSprite') {
      const parsed = this.getParsedDoc(doc);
      const w = msg.width || 16;
      const h = msg.height || 16;
      const palId = msg.paletteId ?? parsed.defaultPaletteId;
      const newId = msg.id !== undefined ? msg.id : findNextFreeSpriteId(parsed, w, h);
      const emptyLines = Array.from({ length: h }, () => '.'.repeat(w));
      await this.applySpriteUpdate(doc, newId, w, h, palId, emptyLines);
      await this.sendStateToWebview('sprite', newId);
    } else if (msg.type === 'updatePalette') {
      await this.applyPaletteUpdate(doc, msg.id, msg.entries);
    } else if (msg.type === 'updateMap') {
      await this.applyMapUpdate(doc, msg.mapIndex || 0, msg.offsetX || 0, msg.offsetY || 0, msg.rows);
    } else if (msg.type === 'updateSfx') {
      await this.applySfxUpdate(doc, msg.kind || 'SFX', msg.id || 0, msg.specText || '');
    }
  }

  private async ensureEndSection(doc: vscode.TextDocument): Promise<ParsedUsakameDocument> {
    let parsed = this.getParsedDoc(doc);
    if (!parsed.hasEndMarker && doc.languageId === 'ruby') {
      const edit = new vscode.WorkspaceEdit();
      const lastLine = doc.lineCount - 1;
      const lastChar = doc.lineAt(lastLine).text.length;
      const prefix = lastChar > 0 ? '\n\n__END__\n' : '__END__\n';
      edit.insert(doc.uri, new vscode.Position(lastLine, lastChar), prefix);
      this.isApplyingEdit = true;
      await vscode.workspace.applyEdit(edit);
      this.isApplyingEdit = false;
      parsed = this.getParsedDoc(doc);
    }
    return parsed;
  }

  private async applySpriteUpdate(
    doc: vscode.TextDocument,
    id: number,
    width: number,
    height: number,
    paletteId: number,
    lines: string[]
  ): Promise<void> {
    this.recordUndoSnapshot(doc);
    const parsed = await this.ensureEndSection(doc);
    const existing = parsed.sprites.get(id);
    const sizeStr = width === 16 && height === 16 && (!existing || !existing.explicitDims) ? '' : ` ${width}x${height}`;
    const palStr = paletteId > 0 ? ` pal:${paletteId}` : '';
    const newBlockText = `@SPRITE ${id}${sizeStr}${palStr}\n${lines.join('\n')}`;

    const edit = new vscode.WorkspaceEdit();
    if (existing) {
      const endLineLen = doc.lineAt(existing.endLine).text.length;
      const range = new vscode.Range(existing.headerLine, 0, existing.endLine, endLineLen);
      edit.replace(doc.uri, range, newBlockText);
    } else {
      const lastLine = doc.lineCount - 1;
      const lastChar = doc.lineAt(lastLine).text.length;
      const prefix = doc.lineAt(lastLine).text.trim().length > 0 ? '\n\n' : '';
      edit.insert(doc.uri, new vscode.Position(lastLine, lastChar), `${prefix}${newBlockText}\n`);
    }

    this.isApplyingEdit = true;
    await vscode.workspace.applyEdit(edit);
    this.isApplyingEdit = false;
  }

  private async applyPaletteUpdate(
    doc: vscode.TextDocument,
    palId: number,
    entries: { index: number; hex: string }[]
  ): Promise<void> {
    if (palId <= 0) {
      return;
    }
    this.recordUndoSnapshot(doc);
    const parsed = await this.ensureEndSection(doc);
    const existing = parsed.paletteBlocks.get(palId);

    const bodyLines = entries.map((e) => {
      const hexIdx = e.index.toString(16).toUpperCase();
      return `${hexIdx}: ${e.hex.toUpperCase()}  # ${PALETTE_COLOR_NAMES[e.index]}`;
    });
    const newBlockText = `@PALETTE ${palId}\n${bodyLines.join('\n')}`;

    const edit = new vscode.WorkspaceEdit();
    if (existing) {
      const endLineLen = doc.lineAt(existing.endLine).text.length;
      const range = new vscode.Range(existing.headerLine, 0, existing.endLine, endLineLen);
      edit.replace(doc.uri, range, newBlockText);
    } else {
      // Insert right after __END__ so @SPRITE blocks below it see it immediately
      const insertLine = parsed.endMarkerLine >= 0 ? parsed.endMarkerLine : 0;
      const lineLen = doc.lineAt(insertLine).text.length;
      edit.insert(doc.uri, new vscode.Position(insertLine, lineLen), `\n${newBlockText}\n`);
    }

    this.isApplyingEdit = true;
    await vscode.workspace.applyEdit(edit);
    this.isApplyingEdit = false;
  }

  private async applyMapUpdate(
    doc: vscode.TextDocument,
    mapIndex: number,
    offsetX: number,
    offsetY: number,
    rows: string[]
  ): Promise<void> {
    this.recordUndoSnapshot(doc);
    const parsed = await this.ensureEndSection(doc);
    const existing = parsed.mapBlocks[mapIndex];
    const newBlockText = `@MAP ${offsetX} ${offsetY}\n${rows.join('\n')}`;

    const edit = new vscode.WorkspaceEdit();
    if (existing) {
      const endLineLen = doc.lineAt(existing.endLine).text.length;
      const range = new vscode.Range(existing.headerLine, 0, existing.endLine, endLineLen);
      edit.replace(doc.uri, range, newBlockText);
    } else {
      const lastLine = doc.lineCount - 1;
      const lastChar = doc.lineAt(lastLine).text.length;
      const prefix = doc.lineAt(lastLine).text.trim().length > 0 ? '\n\n' : '';
      edit.insert(doc.uri, new vscode.Position(lastLine, lastChar), `${prefix}${newBlockText}\n`);
    }

    this.isApplyingEdit = true;
    await vscode.workspace.applyEdit(edit);
    this.isApplyingEdit = false;
  }

  private async applySfxUpdate(
    doc: vscode.TextDocument,
    kind: 'SFX' | 'MUSIC',
    id: number,
    specText: string
  ): Promise<void> {
    this.recordUndoSnapshot(doc);
    const parsed = await this.ensureEndSection(doc);
    const existing = parsed.sfxBlocks.find((s) => s.kind === kind && s.id === id);
    const newBlockText = `@${kind} ${id}\n${specText.trim()}`;

    const edit = new vscode.WorkspaceEdit();
    if (existing) {
      const endLineLen = doc.lineAt(existing.endLine).text.length;
      const range = new vscode.Range(existing.headerLine, 0, existing.endLine, endLineLen);
      edit.replace(doc.uri, range, newBlockText);
    } else {
      const lastLine = doc.lineCount - 1;
      const lastChar = doc.lineAt(lastLine).text.length;
      const prefix = doc.lineAt(lastLine).text.trim().length > 0 ? '\n\n' : '';
      edit.insert(doc.uri, new vscode.Position(lastLine, lastChar), `${prefix}${newBlockText}\n`);
    }

    this.isApplyingEdit = true;
    await vscode.workspace.applyEdit(edit);
    this.isApplyingEdit = false;
  }

  private getHtmlForWebview(): string {
    return /* html */ `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<style>
  :root {
    --bg: #181a20;
    --panel: #222630;
    --border: #363c4a;
    --accent: #29adff;
    --accent2: #ff004d;
    --text: #e8ecf2;
    --muted: #939bb0;
  }
  * { box-sizing: border-box; user-select: none; }
  body {
    margin: 0;
    padding: 10px 14px;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    font-size: 13px;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-bottom: 1px solid var(--border);
    padding-bottom: 8px;
    margin-bottom: 12px;
    gap: 8px;
    flex-wrap: wrap;
  }
  .tabs {
    display: flex;
    gap: 6px;
  }
  .tab-btn {
    background: var(--panel);
    color: var(--muted);
    border: 1px solid var(--border);
    padding: 5px 11px;
    border-radius: 5px;
    cursor: pointer;
    font-weight: 600;
    font-size: 12px;
  }
  .tab-btn.active {
    background: var(--accent);
    color: #000;
    border-color: var(--accent);
  }
  .section { display: none; }
  .section.active { display: block; }
  .toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
    background: var(--panel);
    padding: 8px 10px;
    border-radius: 6px;
    border: 1px solid var(--border);
    margin-bottom: 10px;
  }
  select, input[type="number"], input[type="text"], button {
    background: #14171d;
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 4px 8px;
    font-size: 12px;
  }
  button {
    cursor: pointer;
    background: #2b303c;
  }
  button:hover { border-color: var(--accent); }
  button.active-tool {
    background: var(--accent);
    color: #000;
    font-weight: bold;
  }
  .workspace-grid {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 14px;
    align-items: start;
  }
  .canvas-box {
    background: #111318;
    border: 2px solid var(--border);
    border-radius: 6px;
    padding: 6px;
    display: inline-block;
  }
  canvas {
    image-rendering: pixelated;
    cursor: crosshair;
    display: block;
  }
  .palette-grid {
    display: grid;
    grid-template-columns: repeat(9, 28px);
    gap: 4px;
    margin-bottom: 10px;
  }
  .swatch {
    width: 28px;
    height: 28px;
    border-radius: 4px;
    border: 2px solid #333;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
    font-weight: bold;
    text-shadow: 0 1px 2px #000, 0 0 2px #000;
    color: #fff;
  }
  .swatch.selected {
    border-color: #fff;
    box-shadow: 0 0 0 2px var(--accent2);
    transform: scale(1.08);
  }
  .sprite-catalog {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    max-height: 170px;
    overflow-y: auto;
    background: var(--panel);
    padding: 8px;
    border-radius: 6px;
    border: 1px solid var(--border);
    margin-top: 10px;
  }
  .catalog-item {
    background: #14171d;
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 4px;
    cursor: pointer;
    text-align: center;
    min-width: 44px;
  }
  .catalog-item.selected {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }
  .catalog-item span {
    display: block;
    font-size: 10px;
    color: var(--muted);
    margin-top: 2px;
  }
  .pal-editor-list {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 6px;
  }
  .pal-row {
    display: flex;
    align-items: center;
    gap: 6px;
    background: var(--panel);
    padding: 5px 8px;
    border-radius: 5px;
    border: 1px solid var(--border);
  }
  .pal-row.overridden {
    border-color: var(--accent);
  }
  .pal-row input[type="color"] {
    width: 28px;
    height: 24px;
    border: none;
    padding: 0;
    background: transparent;
    cursor: pointer;
  }
  textarea {
    width: 100%;
    min-height: 90px;
    background: #12151b;
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 8px;
    font-family: Consolas, monospace;
    font-size: 12px;
  }
  .badge {
    font-size: 11px;
    padding: 2px 6px;
    background: #2e3442;
    border-radius: 4px;
    color: var(--muted);
  }
  .piano-keys {
    display: flex;
    gap: 3px;
    margin: 8px 0;
    flex-wrap: wrap;
  }
  .piano-key {
    padding: 10px 7px;
    background: #eee;
    color: #111;
    font-weight: bold;
    border-radius: 0 0 4px 4px;
    cursor: pointer;
    font-size: 11px;
  }
  .piano-key.sharp {
    background: #2b2f3a;
    color: #fff;
  }
</style>
</head>
<body>
  <header>
    <div class="tabs">
      <button class="tab-btn active" data-tab="sprite">🎨 @SPRITE</button>
      <button class="tab-btn" data-tab="palette">🌈 @PALETTE</button>
      <button class="tab-btn" data-tab="map">🗺️ @MAP</button>
      <button class="tab-btn" data-tab="sound">🔊 @SFX / @MUSIC</button>
    </div>
    <div style="display:flex; align-items:center; gap:8px;">
      <button id="btn-global-undo" title="元に戻す (Ctrl+Z / Cmd+Z)" style="padding:4px 8px; font-size:12px;">↶ Undo</button>
      <button id="btn-global-redo" title="やり直し (Ctrl+Y / Cmd+Shift+Z)" style="padding:4px 8px; font-size:12px;">↷ Redo</button>
      <button id="btn-global-save" title="ファイルを保存 (Ctrl+S / Cmd+S)" style="padding:4px 10px; font-size:12px; font-weight:600; background:var(--accent); color:#000;">💾 Save</button>
      <span class="badge" id="file-badge">game.rb</span>
    </div>
  </header>

  <!-- ================= SPRITE EDITOR ================= -->
  <div id="tab-sprite" class="section active">
    <div class="toolbar">
      <label>ID:
        <select id="spr-select"></select>
      </label>
      <label>サイズ:
        <select id="spr-size">
          <option value="16x16">16×16</option>
          <option value="32x32">32×32</option>
          <option value="16x32">16×32</option>
          <option value="32x16">32×16</option>
          <option value="24x24">24×24</option>
          <option value="48x48">48×48</option>
        </select>
      </label>
      <label>Palette:
        <select id="spr-pal"></select>
      </label>
      <button id="btn-new-spr">＋ 新規スプライト</button>
    </div>

    <div class="toolbar">
      <button class="tool-btn active-tool" data-tool="pen">✏️ ペン</button>
      <button class="tool-btn" data-tool="fill">🪣 塗りつぶし</button>
      <button class="tool-btn" data-tool="rect">⬜ 矩形</button>
      <button class="tool-btn" data-tool="eyedrop" title="スポイト (右クリックでも取得可能)">💧 スポイト</button>
      <button id="btn-flip-h">↔ 左右反転</button>
      <button id="btn-flip-v">↕ 上下反転</button>
      <button id="btn-shift-l">←</button>
      <button id="btn-shift-r">→</button>
      <button id="btn-shift-u">↑</button>
      <button id="btn-shift-d">↓</button>
      <button id="btn-clear-spr">🗑️ クリア</button>
    </div>

    <div class="palette-grid" id="spr-palette-swatches"></div>

    <div class="workspace-grid">
      <div class="canvas-box">
        <canvas id="spr-canvas" width="256" height="256"></canvas>
      </div>
      <div>
        <div style="margin-bottom:6px; color:var(--muted);">1x / 2x プレビュー & スプライト一覧:</div>
        <div class="canvas-box" style="margin-bottom:8px;">
          <canvas id="spr-preview" width="64" height="64"></canvas>
        </div>
        <div style="font-size:11px; color:var(--muted);" id="spr-cursor-info">座標: (0, 0)</div>
      </div>
    </div>

    <div class="sprite-catalog" id="spr-catalog"></div>
  </div>

  <!-- ================= PALETTE EDITOR ================= -->
  <div id="tab-palette" class="section">
    <div class="toolbar">
      <label>編集パレット:
        <select id="pal-select"></select>
      </label>
      <button id="btn-new-pal">＋ 新規 @PALETTE を追加</button>
      <button id="btn-reset-pal">PICO-8 標準色にリセット</button>
    </div>
    <p style="margin: 0 0 8px 0; color: var(--muted); font-size: 12px;">
      色を変更すると <code>@PALETTE &lt;id&gt;</code> のピンポイント差分定義（<code>idx: #RRGGBB</code>）が即座に更新され、そのパレットを参照する <code>@SPRITE</code> の表示色も連動します。
    </p>
    <div class="pal-editor-list" id="pal-editor-list"></div>
  </div>

  <!-- ================= MAP EDITOR ================= -->
  <div id="tab-map" class="section">
    <div class="toolbar">
      <label>選択タイル: <span id="map-selected-tile-label">#1</span></label>
      <button id="btn-map-eraser">🧹 消しゴム (.)</button>
      <span style="color:var(--muted); font-size:11px;">下のスプライト一覧をクリックしてタイルを選択し、マップ上をドラッグして配置します。</span>
    </div>
    <div class="canvas-box">
      <canvas id="map-canvas" width="320" height="320"></canvas>
    </div>
    <div class="sprite-catalog" id="map-tile-catalog"></div>
  </div>

  <!-- ================= SOUND EDITOR ================= -->
  <div id="tab-sound" class="section">
    <div class="toolbar">
      <label>種別:
        <select id="sfx-kind">
          <option value="SFX">@SFX</option>
          <option value="MUSIC">@MUSIC</option>
        </select>
      </label>
      <label>ID:
        <input type="number" id="sfx-id" value="0" min="0" max="63" style="width:55px;">
      </label>
      <label>波形:
        <select id="sfx-wave">
          <option value="square">Square (矩形波 50%)</option>
          <option value="pulse">Pulse (パルス波 25%)</option>
          <option value="pulse12">Pulse12 (パルス波 12.5%)</option>
          <option value="triangle">Triangle (三角波)</option>
          <option value="saw">Saw (ノコギリ波)</option>
          <option value="noise">Noise (ノイズ)</option>
        </select>
      </label>
      <label>Speed:
        <input type="number" id="sfx-speed" value="4" min="1" max="30" style="width:50px;">
      </label>
      <button id="btn-play-sfx" style="background:var(--accent); color:#000; font-weight:bold;">▶ WebAudio 試聴</button>
    </div>

    <div style="font-size:11px; color:var(--muted); margin-bottom:4px;">ワンクリック・プリセット生成:</div>
    <div class="toolbar">
      <button class="sfx-preset" data-spec="wave square speed 3\nc2 e2 g2 c3:fade">🪙 コイン</button>
      <button class="sfx-preset" data-spec="wave square speed 4\nc2:slide g2:slide c3:fade">🦘 ジャンプ</button>
      <button class="sfx-preset" data-spec="wave noise speed 4\nc2:drop g1:fade">💥 ダメージ/爆発</button>
      <button class="sfx-preset" data-spec="wave pulse speed 2\ng3 c4 e4 g4:fade">✨ パワーアップ</button>
      <button class="sfx-preset" data-spec="wave saw speed 6\ng2 f#2 f2 e2*3:vib">💀 ゲームオーバー</button>
    </div>

    <div style="font-size:11px; color:var(--muted);">ピアノ鍵盤 (クリックでノート追記 & 試聴):</div>
    <div class="piano-keys" id="piano-keys"></div>

    <textarea id="sfx-spec-text" spellcheck="false" placeholder="wave square speed 4&#10;c2 e2 g2 c3:fade"></textarea>
  </div>

<script>
  const vscode = acquireVsCodeApi();

  let state = {
    defaultPaletteId: 0,
    colorNames: [],
    palettes: { 0: { hexes: ['#000000','#1D2B53','#7E2553','#008751','#AB5236','#5F574F','#C2C3C7','#FFF1E8','#FF004D','#FFA300','#FFEC27','#00E436','#29ADFF','#83769C','#FF77A8','#FFCCAA'], overridden: [] } },
    sprites: [],
    maps: [],
    sfxs: [],
    activeTab: 'sprite',
    currentSpriteId: 0,
    currentColor: 7, // -1 = transparent '.'
    currentTool: 'pen',
    currentPalEditId: 1,
    currentMapTile: 1,
  };

  // Tab switching
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      switchTab(btn.dataset.tab);
    });
  });

  function switchTab(tab) {
    state.activeTab = tab;
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    document.querySelectorAll('.section').forEach(s => s.classList.toggle('active', s.id === 'tab-' + tab));
    renderAll();
  }

  // Tool switching
  document.querySelectorAll('.tool-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      state.currentTool = btn.dataset.tool;
      document.querySelectorAll('.tool-btn').forEach(b => b.classList.toggle('active-tool', b === btn));
    });
  });

  function getActiveSprite() {
    let sp = state.sprites.find(s => s.id === state.currentSpriteId);
    if (!sp && state.sprites.length > 0) {
      sp = state.sprites[0];
      state.currentSpriteId = sp.id;
    }
    if (!sp) {
      sp = {
        id: state.currentSpriteId || 0,
        width: 16,
        height: 16,
        paletteId: state.defaultPaletteId || 0,
        lines: Array.from({ length: 16 }, () => '.'.repeat(16))
      };
    }
    // Normalize lines length
    while (sp.lines.length < sp.height) {
      sp.lines.push('.'.repeat(sp.width));
    }
    sp.lines = sp.lines.slice(0, sp.height).map(l => l.padEnd(sp.width, '.').slice(0, sp.width));
    return sp;
  }

  function getPaletteHexes(palId) {
    return (state.palettes[palId] && state.palettes[palId].hexes) || state.palettes[0].hexes;
  }

  function renderPaletteSwatches() {
    const sp = getActiveSprite();
    const hexes = getPaletteHexes(sp.paletteId);
    const container = document.getElementById('spr-palette-swatches');
    container.innerHTML = '';

    // Transparent '.' swatch
    const transEl = document.createElement('div');
    transEl.className = 'swatch' + (state.currentColor === -1 ? ' selected' : '');
    transEl.style.background = 'repeating-conic-gradient(#333 0% 25%, #555 0% 50%) 50% / 10px 10px';
    transEl.textContent = '.';
    transEl.title = '透明ピクセル (.)';
    transEl.onclick = () => { state.currentColor = -1; renderPaletteSwatches(); };
    container.appendChild(transEl);

    for (let i = 0; i < 16; i++) {
      const el = document.createElement('div');
      el.className = 'swatch' + (state.currentColor === i ? ' selected' : '');
      el.style.background = hexes[i];
      const hexChar = i.toString(16).toUpperCase();
      el.textContent = hexChar;
      el.title = hexChar + ': ' + hexes[i] + ' (' + (state.colorNames[i] || '') + ')';
      el.onclick = () => { state.currentColor = i; renderPaletteSwatches(); };
      container.appendChild(el);
    }
  }

  function drawSpriteToCanvas(sp, canvas, targetPx, showGrid) {
    const ctx = canvas.getContext('2d');
    canvas.width = targetPx;
    canvas.height = Math.round(targetPx * (sp.height / sp.width));
    const cellW = canvas.width / sp.width;
    const cellH = canvas.height / sp.height;
    const hexes = getPaletteHexes(sp.paletteId);

    for (let y = 0; y < sp.height; y++) {
      const row = sp.lines[y] || '';
      for (let x = 0; x < sp.width; x++) {
        const ch = row[x] || '.';
        if (ch === '.' || ch === ' ') {
          ctx.fillStyle = ((x + y) % 2 === 0) ? '#1f232c' : '#282d38';
        } else {
          const idx = parseInt(ch, 16);
          ctx.fillStyle = !isNaN(idx) ? hexes[idx & 15] : '#000';
        }
        ctx.fillRect(Math.floor(x * cellW), Math.floor(y * cellH), Math.ceil(cellW), Math.ceil(cellH));
      }
    }

    if (showGrid) {
      ctx.strokeStyle = 'rgba(255,255,255,0.12)';
      ctx.lineWidth = 1;
      for (let x = 0; x <= sp.width; x++) {
        ctx.beginPath();
        ctx.moveTo(Math.floor(x * cellW) + 0.5, 0);
        ctx.lineTo(Math.floor(x * cellW) + 0.5, canvas.height);
        ctx.stroke();
      }
      for (let y = 0; y <= sp.height; y++) {
        ctx.beginPath();
        ctx.moveTo(0, Math.floor(y * cellH) + 0.5);
        ctx.lineTo(canvas.width, Math.floor(y * cellH) + 0.5);
        ctx.stroke();
      }
      // 8px center guide lines
      ctx.strokeStyle = 'rgba(41,173,255,0.38)';
      for (let x = 8; x < sp.width; x += 8) {
        ctx.beginPath();
        ctx.moveTo(Math.floor(x * cellW) + 0.5, 0);
        ctx.lineTo(Math.floor(x * cellW) + 0.5, canvas.height);
        ctx.stroke();
      }
      for (let y = 8; y < sp.height; y += 8) {
        ctx.beginPath();
        ctx.moveTo(0, Math.floor(y * cellH) + 0.5);
        ctx.lineTo(canvas.width, Math.floor(y * cellH) + 0.5);
        ctx.stroke();
      }
    }
  }

  function renderSpriteEditor() {
    const sp = getActiveSprite();

    // Populate Sprite select dropdown
    const sel = document.getElementById('spr-select');
    sel.innerHTML = '';
    const ids = state.sprites.map(s => s.id);
    if (!ids.includes(sp.id)) ids.push(sp.id);
    ids.sort((a, b) => a - b);
    for (const id of ids) {
      const opt = document.createElement('option');
      opt.value = id;
      const item = state.sprites.find(s => s.id === id);
      opt.textContent = '#' + id + (item ? ' (' + item.width + 'x' + item.height + ')' : ' (新規)');
      if (id === sp.id) opt.selected = true;
      sel.appendChild(opt);
    }

    // Size dropdown
    const sizeSel = document.getElementById('spr-size');
    const dimKey = sp.width + 'x' + sp.height;
    if (![...sizeSel.options].some(o => o.value === dimKey)) {
      const o = document.createElement('option');
      o.value = dimKey;
      o.textContent = sp.width + '×' + sp.height;
      sizeSel.appendChild(o);
    }
    sizeSel.value = dimKey;

    // Palette dropdown
    const palSel = document.getElementById('spr-pal');
    palSel.innerHTML = '';
    const palIds = Object.keys(state.palettes).map(Number).sort((a, b) => a - b);
    for (const pid of palIds) {
      const opt = document.createElement('option');
      opt.value = pid;
      opt.textContent = pid === 0 ? '0 (標準 PICO-8)' : 'pal:' + pid;
      if (pid === sp.paletteId) opt.selected = true;
      palSel.appendChild(opt);
    }

    renderPaletteSwatches();
    drawSpriteToCanvas(sp, document.getElementById('spr-canvas'), 256, true);
    drawSpriteToCanvas(sp, document.getElementById('spr-preview'), 64, false);

    // Catalog
    const cat = document.getElementById('spr-catalog');
    cat.innerHTML = '';
    for (const item of state.sprites) {
      const card = document.createElement('div');
      card.className = 'catalog-item' + (item.id === sp.id ? ' selected' : '');
      const miniCanvas = document.createElement('canvas');
      drawSpriteToCanvas(item, miniCanvas, 32, false);
      const label = document.createElement('span');
      label.textContent = '#' + item.id + (item.paletteId ? ' p' + item.paletteId : '');
      card.appendChild(miniCanvas);
      card.appendChild(label);
      card.onclick = () => {
        state.currentSpriteId = item.id;
        renderSpriteEditor();
      };
      cat.appendChild(card);
    }
  }

  function commitSprite(sp) {
    vscode.postMessage({
      type: 'updateSprite',
      id: sp.id,
      width: sp.width,
      height: sp.height,
      paletteId: sp.paletteId,
      lines: sp.lines,
    });
  }

  // Canvas painting interaction
  const sprCanvas = document.getElementById('spr-canvas');
  let isDrawing = false;
  let isRightEyedropping = false;
  let sprDirtyStroke = false;
  let rectStart = null;

  function pickSpriteColorAt(sp, x, y) {
    if (x < 0 || x >= sp.width || y < 0 || y >= sp.height) return;
    const picked = sp.lines[y] && sp.lines[y][x];
    state.currentColor = (picked === '.' || picked === ' ' || !picked) ? -1 : parseInt(picked, 16);
    renderPaletteSwatches();
  }

  function getCanvasCell(e, sp) {
    const r = sprCanvas.getBoundingClientRect();
    const x = Math.floor(((e.clientX - r.left) / r.width) * sp.width);
    const y = Math.floor(((e.clientY - r.top) / r.height) * sp.height);
    return {
      x: Math.max(0, Math.min(sp.width - 1, x)),
      y: Math.max(0, Math.min(sp.height - 1, y)),
    };
  }

  function setPixelChar(sp, x, y, ch) {
    if (x < 0 || x >= sp.width || y < 0 || y >= sp.height) return false;
    const row = sp.lines[y];
    if (row[x] === ch) return false;
    sp.lines[y] = row.slice(0, x) + ch + row.slice(x + 1);
    return true;
  }

  function floodFill(sp, startX, startY, newCh) {
    const targetCh = sp.lines[startY][startX];
    if (targetCh === newCh) return;
    const stack = [[startX, startY]];
    while (stack.length > 0) {
      const [cx, cy] = stack.pop();
      if (cx < 0 || cx >= sp.width || cy < 0 || cy >= sp.height) continue;
      if (sp.lines[cy][cx] !== targetCh) continue;
      setPixelChar(sp, cx, cy, newCh);
      stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1]);
    }
  }

  sprCanvas.addEventListener('mousedown', (e) => {
    const sp = getActiveSprite();
    const { x, y } = getCanvasCell(e, sp);

    // 右クリックでスポイト
    if (e.button === 2) {
      isRightEyedropping = true;
      pickSpriteColorAt(sp, x, y);
      return;
    }

    const ch = (state.currentColor === -1)
      ? '.'
      : state.currentColor.toString(16).toUpperCase();

    if (state.currentTool === 'eyedrop') {
      pickSpriteColorAt(sp, x, y);
      state.currentTool = 'pen';
      document.querySelectorAll('.tool-btn').forEach(b => b.classList.toggle('active-tool', b.dataset.tool === 'pen'));
      return;
    }

    if (state.currentTool === 'fill') {
      floodFill(sp, x, y, ch);
      renderSpriteEditor();
      commitSprite(sp);
      return;
    }

    if (state.currentTool === 'rect') {
      rectStart = { x, y, ch };
      isDrawing = true;
      return;
    }

    isDrawing = true;
    sprDirtyStroke = false;
    if (setPixelChar(sp, x, y, ch)) {
      sprDirtyStroke = true;
      drawSpriteToCanvas(sp, sprCanvas, 256, true);
      drawSpriteToCanvas(sp, document.getElementById('spr-preview'), 64, false);
    }
  });

  sprCanvas.addEventListener('mousemove', (e) => {
    const sp = getActiveSprite();
    const { x, y } = getCanvasCell(e, sp);
    document.getElementById('spr-cursor-info').textContent = '座標: (' + x + ', ' + y + ')';

    // 右クリックドラッグ中のスポイト
    if (isRightEyedropping || (e.buttons === 2 && !isDrawing)) {
      pickSpriteColorAt(sp, x, y);
      return;
    }

    if (!isDrawing) return;

    if (state.currentTool === 'pen') {
      const ch = (state.currentColor === -1)
        ? '.'
        : state.currentColor.toString(16).toUpperCase();
      if (setPixelChar(sp, x, y, ch)) {
        sprDirtyStroke = true;
        drawSpriteToCanvas(sp, sprCanvas, 256, true);
        drawSpriteToCanvas(sp, document.getElementById('spr-preview'), 64, false);
      }
    }
  });

  window.addEventListener('mouseup', (e) => {
    isRightEyedropping = false;
    if (!isDrawing) return;
    isDrawing = false;
    if (state.currentTool === 'rect' && rectStart) {
      const sp = getActiveSprite();
      const { x, y } = getCanvasCell(e, sp);
      const x0 = Math.min(rectStart.x, x);
      const x1 = Math.max(rectStart.x, x);
      const y0 = Math.min(rectStart.y, y);
      const y1 = Math.max(rectStart.y, y);
      for (let ry = y0; ry <= y1; ry++) {
        for (let rx = x0; rx <= x1; rx++) {
          setPixelChar(sp, rx, ry, rectStart.ch);
        }
      }
      rectStart = null;
      renderSpriteEditor();
      commitSprite(sp);
      return;
    }
    if (sprDirtyStroke) {
      sprDirtyStroke = false;
      const sp = getActiveSprite();
      commitSprite(sp);
    }
  });

  sprCanvas.addEventListener('contextmenu', e => e.preventDefault());

  // Sprite controls
  document.getElementById('spr-select').addEventListener('change', (e) => {
    state.currentSpriteId = parseInt(e.target.value, 10);
    renderSpriteEditor();
  });

  document.getElementById('spr-size').addEventListener('change', (e) => {
    const sp = getActiveSprite();
    const [w, h] = e.target.value.split('x').map(Number);
    sp.width = w;
    sp.height = h;
    const newLines = [];
    for (let y = 0; y < h; y++) {
      const old = sp.lines[y] || '';
      newLines.push(old.padEnd(w, '.').slice(0, w));
    }
    sp.lines = newLines;
    renderSpriteEditor();
    commitSprite(sp);
  });

  document.getElementById('spr-pal').addEventListener('change', (e) => {
    const sp = getActiveSprite();
    sp.paletteId = parseInt(e.target.value, 10);
    renderSpriteEditor();
    commitSprite(sp);
  });

  document.getElementById('btn-new-spr').addEventListener('click', () => {
    const [w, h] = document.getElementById('spr-size').value.split('x').map(Number);
    const palId = parseInt(document.getElementById('spr-pal').value, 10) || 0;
    vscode.postMessage({ type: 'createNewSprite', width: w, height: h, paletteId: palId });
  });

  document.getElementById('btn-flip-h').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines = sp.lines.map(r => r.split('').reverse().join(''));
    renderSpriteEditor();
    commitSprite(sp);
  });

  document.getElementById('btn-flip-v').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines = [...sp.lines].reverse();
    renderSpriteEditor();
    commitSprite(sp);
  });

  document.getElementById('btn-shift-l').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines = sp.lines.map(r => r.slice(1) + r[0]);
    renderSpriteEditor();
    commitSprite(sp);
  });
  document.getElementById('btn-shift-r').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines = sp.lines.map(r => r[r.length - 1] + r.slice(0, -1));
    renderSpriteEditor();
    commitSprite(sp);
  });
  document.getElementById('btn-shift-u').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines.push(sp.lines.shift());
    renderSpriteEditor();
    commitSprite(sp);
  });
  document.getElementById('btn-shift-d').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines.unshift(sp.lines.pop());
    renderSpriteEditor();
    commitSprite(sp);
  });

  document.getElementById('btn-clear-spr').addEventListener('click', () => {
    const sp = getActiveSprite();
    sp.lines = Array.from({ length: sp.height }, () => '.'.repeat(sp.width));
    renderSpriteEditor();
    commitSprite(sp);
  });

  // ================= PALETTE EDITOR LOGIC =================
  function renderPaletteEditor() {
    const palSel = document.getElementById('pal-select');
    palSel.innerHTML = '';
    const palIds = Object.keys(state.palettes).map(Number).filter(id => id > 0).sort((a, b) => a - b);
    if (palIds.length === 0) palIds.push(1);
    if (!palIds.includes(state.currentPalEditId)) state.currentPalEditId = palIds[0];

    for (const pid of palIds) {
      const opt = document.createElement('option');
      opt.value = pid;
      opt.textContent = '@PALETTE ' + pid;
      if (pid === state.currentPalEditId) opt.selected = true;
      palSel.appendChild(opt);
    }

    const palObj = state.palettes[state.currentPalEditId] || {
      hexes: [...state.palettes[0].hexes],
      overridden: []
    };
    const list = document.getElementById('pal-editor-list');
    list.innerHTML = '';

    for (let i = 0; i < 16; i++) {
      const isOver = palObj.overridden.includes(i);
      const row = document.createElement('div');
      row.className = 'pal-row' + (isOver ? ' overridden' : '');

      const idxLabel = document.createElement('strong');
      idxLabel.style.width = '18px';
      idxLabel.textContent = i.toString(16).toUpperCase();

      const picker = document.createElement('input');
      picker.type = 'color';
      picker.value = palObj.hexes[i];

      const hexInput = document.createElement('input');
      hexInput.type = 'text';
      hexInput.value = palObj.hexes[i];
      hexInput.style.width = '76px';

      const nameSpan = document.createElement('span');
      nameSpan.style.fontSize = '11px';
      nameSpan.style.color = 'var(--muted)';
      nameSpan.textContent = state.colorNames[i] || '';

      const onColorChange = (newHex) => {
        if (!/^#[0-9a-fA-F]{6}$/.test(newHex)) return;
        palObj.hexes[i] = newHex.toUpperCase();
        if (!palObj.overridden.includes(i)) palObj.overridden.push(i);
        state.palettes[state.currentPalEditId] = palObj;
        syncPaletteToDoc(state.currentPalEditId, palObj);
        renderPaletteEditor();
      };

      picker.addEventListener('input', (e) => {
        hexInput.value = e.target.value.toUpperCase();
        onColorChange(e.target.value);
      });
      hexInput.addEventListener('change', (e) => {
        picker.value = e.target.value;
        onColorChange(e.target.value);
      });

      row.appendChild(idxLabel);
      row.appendChild(picker);
      row.appendChild(hexInput);
      row.appendChild(nameSpan);
      list.appendChild(row);
    }
  }

  function syncPaletteToDoc(palId, palObj) {
    const entries = palObj.overridden
      .slice()
      .sort((a, b) => a - b)
      .map(idx => ({ index: idx, hex: palObj.hexes[idx] }));
    vscode.postMessage({ type: 'updatePalette', id: palId, entries });
  }

  document.getElementById('pal-select').addEventListener('change', (e) => {
    state.currentPalEditId = parseInt(e.target.value, 10);
    renderPaletteEditor();
  });

  document.getElementById('btn-new-pal').addEventListener('click', () => {
    let nextId = 1;
    while (state.palettes[nextId]) nextId++;
    state.palettes[nextId] = {
      hexes: [...state.palettes[0].hexes],
      overridden: [1, 3, 11, 7]
    };
    state.currentPalEditId = nextId;
    syncPaletteToDoc(nextId, state.palettes[nextId]);
    renderPaletteEditor();
  });

  document.getElementById('btn-reset-pal').addEventListener('click', () => {
    const pid = state.currentPalEditId;
    state.palettes[pid] = {
      hexes: [...state.palettes[0].hexes],
      overridden: [0]
    };
    syncPaletteToDoc(pid, state.palettes[pid]);
    renderPaletteEditor();
  });

  // ================= MAP EDITOR LOGIC =================
  const mapCanvas = document.getElementById('map-canvas');
  let isMapDrawing = false;

  function getActiveMap() {
    if (state.maps.length === 0) {
      state.maps.push({ index: 0, offsetX: 0, offsetY: 0, width: 16, height: 16, cells: {} });
    }
    return state.maps[0];
  }

  function renderMapEditor() {
    const m = getActiveMap();
    const ctx = mapCanvas.getContext('2d');
    const cols = 16;
    const rows = 16;
    const cellPx = 20;
    mapCanvas.width = cols * cellPx;
    mapCanvas.height = rows * cellPx;

    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) {
        ctx.fillStyle = ((x + y) % 2 === 0) ? '#1a1e26' : '#222731';
        ctx.fillRect(x * cellPx, y * cellPx, cellPx, cellPx);
        const tid = m.cells[x + ',' + y];
        if (tid !== undefined && tid >= 0) {
          const sp = state.sprites.find(s => s.id === tid);
          if (sp) {
            const hexes = getPaletteHexes(sp.paletteId);
            const pScale = cellPx / 16;
            for (let py = 0; py < Math.min(16, sp.height); py++) {
              const rStr = sp.lines[py] || '';
              for (let px = 0; px < Math.min(16, sp.width); px++) {
                const ch = rStr[px];
                if (ch && ch !== '.' && ch !== ' ') {
                  const cIdx = parseInt(ch, 16);
                  if (!isNaN(cIdx)) {
                    ctx.fillStyle = hexes[cIdx & 15];
                    ctx.fillRect(x * cellPx + px * pScale, y * cellPx + py * pScale, Math.ceil(pScale), Math.ceil(pScale));
                  }
                }
              }
            }
          } else {
            ctx.fillStyle = '#29adff';
            ctx.font = '11px monospace';
            ctx.fillText(String(tid), x * cellPx + 4, y * cellPx + 14);
          }
        }
        ctx.strokeStyle = 'rgba(255,255,255,0.08)';
        ctx.strokeRect(x * cellPx, y * cellPx, cellPx, cellPx);
      }
    }

    // Tile catalog
    const cat = document.getElementById('map-tile-catalog');
    cat.innerHTML = '';
    for (const sp of state.sprites) {
      const card = document.createElement('div');
      card.className = 'catalog-item' + (state.currentMapTile === sp.id ? ' selected' : '');
      const mini = document.createElement('canvas');
      drawSpriteToCanvas(sp, mini, 28, false);
      const lbl = document.createElement('span');
      lbl.textContent = '#' + sp.id;
      card.appendChild(mini);
      card.appendChild(lbl);
      card.onclick = () => {
        state.currentMapTile = sp.id;
        document.getElementById('map-selected-tile-label').textContent = '#' + sp.id;
        renderMapEditor();
      };
      cat.appendChild(card);
    }
  }

  let mapDirtyStroke = false;

  function pickMapTileAt(m, cx, cy) {
    const key = cx + ',' + cy;
    const tid = m.cells[key];
    if (tid !== undefined && tid >= 0) {
      state.currentMapTile = tid;
      document.getElementById('map-selected-tile-label').textContent = '#' + tid;
    } else {
      state.currentMapTile = -1;
      document.getElementById('map-selected-tile-label').textContent = '消しゴム (.)';
    }
    renderMapEditor();
  }

  function paintMapCell(e) {
    const m = getActiveMap();
    const r = mapCanvas.getBoundingClientRect();
    const cx = Math.max(0, Math.min(15, Math.floor(((e.clientX - r.left) / r.width) * 16)));
    const cy = Math.max(0, Math.min(15, Math.floor(((e.clientY - r.top) / r.height) * 16)));
    const key = cx + ',' + cy;
    if (state.currentMapTile < 0) {
      if (m.cells[key] !== undefined) {
        delete m.cells[key];
        mapDirtyStroke = true;
      }
    } else {
      if (m.cells[key] !== state.currentMapTile) {
        m.cells[key] = state.currentMapTile;
        mapDirtyStroke = true;
      }
    }
    renderMapEditor();
  }

  function commitMap(m) {
    let useSpaced = false;
    for (const v of Object.values(m.cells)) {
      if (v >= 16) { useSpaced = true; break; }
    }
    const rows = [];
    for (let y = 0; y < 16; y++) {
      const tokens = [];
      for (let x = 0; x < 16; x++) {
        const v = m.cells[x + ',' + y];
        if (v === undefined || v < 0) {
          tokens.push('.');
        } else if (useSpaced) {
          tokens.push(String(v));
        } else {
          tokens.push(v.toString(16).toUpperCase());
        }
      }
      rows.push(useSpaced ? tokens.join(' ') : tokens.join(''));
    }
    vscode.postMessage({ type: 'updateMap', mapIndex: m.index || 0, offsetX: m.offsetX || 0, offsetY: m.offsetY || 0, rows });
  }

  mapCanvas.addEventListener('mousedown', (e) => {
    const m = getActiveMap();
    const r = mapCanvas.getBoundingClientRect();
    const cx = Math.max(0, Math.min(15, Math.floor(((e.clientX - r.left) / r.width) * 16)));
    const cy = Math.max(0, Math.min(15, Math.floor(((e.clientY - r.top) / r.height) * 16)));

    // 右クリックでタイルをスポイト
    if (e.button === 2) {
      pickMapTileAt(m, cx, cy);
      return;
    }

    isMapDrawing = true;
    mapDirtyStroke = false;
    paintMapCell(e);
  });
  mapCanvas.addEventListener('mousemove', (e) => {
    if (e.buttons === 2) {
      const m = getActiveMap();
      const r = mapCanvas.getBoundingClientRect();
      const cx = Math.max(0, Math.min(15, Math.floor(((e.clientX - r.left) / r.width) * 16)));
      const cy = Math.max(0, Math.min(15, Math.floor(((e.clientY - r.top) / r.height) * 16)));
      pickMapTileAt(m, cx, cy);
      return;
    }
    if (isMapDrawing) paintMapCell(e);
  });
  window.addEventListener('mouseup', () => {
    if (isMapDrawing) {
      isMapDrawing = false;
      if (mapDirtyStroke) {
        mapDirtyStroke = false;
        const m = getActiveMap();
        commitMap(m);
      }
    }
  });
  mapCanvas.addEventListener('contextmenu', e => e.preventDefault());
  document.getElementById('btn-map-eraser').addEventListener('click', () => {
    state.currentMapTile = -1;
    document.getElementById('map-selected-tile-label').textContent = '消しゴム (.)';
    renderMapEditor();
  });

  // ================= SOUND EDITOR (WebAudio Synth) =================
  const PIANO_NOTES = [
    { label: 'C2', tok: 'c2', semi: 0, oct: 2 },
    { label: 'C#2', tok: 'c#2', semi: 1, oct: 2, sharp: true },
    { label: 'D2', tok: 'd2', semi: 2, oct: 2 },
    { label: 'D#2', tok: 'd#2', semi: 3, oct: 2, sharp: true },
    { label: 'E2', tok: 'e2', semi: 4, oct: 2 },
    { label: 'F2', tok: 'f2', semi: 5, oct: 2 },
    { label: 'F#2', tok: 'f#2', semi: 6, oct: 2, sharp: true },
    { label: 'G2', tok: 'g2', semi: 7, oct: 2 },
    { label: 'G#2', tok: 'g#2', semi: 8, oct: 2, sharp: true },
    { label: 'A2', tok: 'a2', semi: 9, oct: 2 },
    { label: 'A#2', tok: 'a#2', semi: 10, oct: 2, sharp: true },
    { label: 'B2', tok: 'b2', semi: 11, oct: 2 },
    { label: 'C3', tok: 'c3', semi: 0, oct: 3 },
    { label: 'E3', tok: 'e3', semi: 4, oct: 3 },
    { label: 'G3', tok: 'g3', semi: 7, oct: 3 },
    { label: 'C4', tok: 'c4', semi: 0, oct: 4 },
  ];

  let audioCtx = null;
  function getAudioCtx() {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    return audioCtx;
  }

  function noteToFreq(semi, oct) {
    const midi = (oct + 2) * 12 + 12 + semi;
    return 440 * Math.pow(2, (midi - 69) / 12);
  }

  function playNotePreview(freq, durationSec, wave) {
    const ctx = getAudioCtx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = (wave === 'triangle') ? 'triangle' : (wave === 'saw') ? 'sawtooth' : 'square';
    osc.frequency.setValueAtTime(freq, ctx.currentTime);
    gain.gain.setValueAtTime(0.18, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + durationSec);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + durationSec);
  }

  function playSfxSpecWebAudio(specText) {
    const ctx = getAudioCtx();
    let wave = document.getElementById('sfx-wave').value || 'square';
    let speed = parseFloat(document.getElementById('sfx-speed').value) || 4;
    const tokens = specText.replace(/#.*$/gm, '').trim().split(/\\s+/);
    let t = ctx.currentTime;

    for (let i = 0; i < tokens.length; i++) {
      const tok = tokens[i];
      if (tok === 'wave' && tokens[i + 1]) { wave = tokens[++i]; continue; }
      if (tok === 'speed' && tokens[i + 1]) { speed = parseFloat(tokens[++i]) || 4; continue; }
      const stepSec = Math.max(0.03, speed / 60);
      const m = /^([a-gA-G])([#+-]?)(\\d?)(?:\\*(\\d+))?/.exec(tok);
      if (m) {
        const baseMap = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 };
        let semi = baseMap[m[1].toLowerCase()] ?? 0;
        if (m[2] === '#' || m[2] === '+') semi += 1;
        if (m[2] === '-') semi -= 1;
        const oct = m[3] ? parseInt(m[3], 10) : 2;
        const mult = m[4] ? parseInt(m[4], 10) : 1;
        const dur = stepSec * mult;
        const freq = noteToFreq(semi, oct);

        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = (wave === 'triangle') ? 'triangle' : (wave === 'saw') ? 'sawtooth' : 'square';
        osc.frequency.setValueAtTime(freq, t);
        if (tok.includes(':drop')) {
          osc.frequency.exponentialRampToValueAtTime(Math.max(40, freq * 0.35), t + dur);
        } else if (tok.includes(':slide')) {
          osc.frequency.exponentialRampToValueAtTime(freq * 1.25, t + dur);
        }
        gain.gain.setValueAtTime(0.18, t);
        gain.gain.exponentialRampToValueAtTime(0.008, t + dur);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(t);
        osc.stop(t + dur);
        t += dur;
      }
    }
  }

  function initSoundEditor() {
    const pk = document.getElementById('piano-keys');
    pk.innerHTML = '';
    for (const n of PIANO_NOTES) {
      const btn = document.createElement('div');
      btn.className = 'piano-key' + (n.sharp ? ' sharp' : '');
      btn.textContent = n.label;
      btn.onclick = () => {
        const wave = document.getElementById('sfx-wave').value;
        playNotePreview(noteToFreq(n.semi, n.oct), 0.14, wave);
        const ta = document.getElementById('sfx-spec-text');
        ta.value = (ta.value.trim() + ' ' + n.tok).trim();
        commitSfx();
      };
      pk.appendChild(btn);
    }

    document.querySelectorAll('.sfx-preset').forEach(btn => {
      btn.addEventListener('click', () => {
        const spec = btn.dataset.spec.replace(/\\\\n/g, '\\n');
        document.getElementById('sfx-spec-text').value = spec;
        playSfxSpecWebAudio(spec);
        commitSfx();
      });
    });

    document.getElementById('btn-play-sfx').addEventListener('click', () => {
      playSfxSpecWebAudio(document.getElementById('sfx-spec-text').value);
    });

    document.getElementById('sfx-spec-text').addEventListener('input', () => {
      commitSfx();
    });
  }

  function commitSfx() {
    const kind = document.getElementById('sfx-kind').value;
    const id = parseInt(document.getElementById('sfx-id').value, 10) || 0;
    const specText = document.getElementById('sfx-spec-text').value;
    vscode.postMessage({ type: 'updateSfx', kind, id, specText });
  }

  function renderSoundEditor() {
    const kind = document.getElementById('sfx-kind').value;
    const id = parseInt(document.getElementById('sfx-id').value, 10) || 0;
    const found = state.sfxs.find(s => s.kind === kind && s.id === id) || state.sfxs[0];
    if (found && document.activeElement !== document.getElementById('sfx-spec-text')) {
      document.getElementById('sfx-kind').value = found.kind;
      document.getElementById('sfx-id').value = found.id;
      document.getElementById('sfx-spec-text').value = found.specText;
    }
  }

  function renderAll() {
    if (state.activeTab === 'sprite') renderSpriteEditor();
    if (state.activeTab === 'palette') renderPaletteEditor();
    if (state.activeTab === 'map') renderMapEditor();
    if (state.activeTab === 'sound') renderSoundEditor();
  }

  window.addEventListener('message', (event) => {
    const msg = event.data;
    if (msg.type === 'saveResult') {
      const saveBtn = document.getElementById('btn-global-save');
      if (saveBtn) {
        const orig = saveBtn.textContent;
        saveBtn.textContent = '✓ Saved!';
        saveBtn.style.background = '#28a745';
        saveBtn.style.color = '#fff';
        setTimeout(() => {
          saveBtn.textContent = orig;
          saveBtn.style.background = 'var(--accent)';
          saveBtn.style.color = '#000';
        }, 1200);
      }
      return;
    }
    if (msg.type === 'syncDocument') {
      document.getElementById('file-badge').textContent = msg.fileName;
      state.defaultPaletteId = msg.defaultPaletteId || 0;
      state.colorNames = msg.colorNames || [];
      state.palettes = msg.palettes || state.palettes;
      state.sprites = msg.sprites || [];
      state.maps = msg.maps || [];
      state.sfxs = msg.sfxs || [];

      if (msg.switchTab) {
        state.activeTab = msg.switchTab;
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === state.activeTab));
        document.querySelectorAll('.section').forEach(s => s.classList.toggle('active', s.id === 'tab-' + state.activeTab));
      }
      if (msg.selectId !== undefined) {
        if (state.activeTab === 'sprite') state.currentSpriteId = msg.selectId;
        if (state.activeTab === 'palette') state.currentPalEditId = msg.selectId || 1;
        if (state.activeTab === 'sound') document.getElementById('sfx-id').value = msg.selectId;
      }
      if (msg.subKind && state.activeTab === 'sound') {
        document.getElementById('sfx-kind').value = msg.subKind;
      }
      renderAll();
    }
  });

  // Global Shortcuts & Action buttons
  window.addEventListener('keydown', (e) => {
    const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
    const modifier = isMac ? e.metaKey : e.ctrlKey;

    if (modifier && (e.key === 's' || e.key === 'S')) {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      vscode.postMessage({ type: 'save' });
      return;
    }

    const target = e.target;
    const isInput = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA');
    if (isInput) {
      return;
    }

    if (modifier && !e.shiftKey && (e.key === 'z' || e.key === 'Z')) {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      vscode.postMessage({ type: 'undo' });
    } else if (
      (modifier && (e.key === 'y' || e.key === 'Y')) ||
      (modifier && e.shiftKey && (e.key === 'z' || e.key === 'Z'))
    ) {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      vscode.postMessage({ type: 'redo' });
    }
  }, true);

  document.getElementById('btn-global-undo').addEventListener('click', () => {
    vscode.postMessage({ type: 'undo' });
  });
  document.getElementById('btn-global-redo').addEventListener('click', () => {
    vscode.postMessage({ type: 'redo' });
  });
  document.getElementById('btn-global-save').addEventListener('click', () => {
    vscode.postMessage({ type: 'save' });
  });

  initSoundEditor();
  vscode.postMessage({ type: 'requestSync' });
</script>
</body>
</html>`;
  }
}

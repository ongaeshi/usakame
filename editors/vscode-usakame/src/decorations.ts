import * as vscode from 'vscode';
import {
  encodeRgbaToScaledPngDataUri,
  extractBank0RegionRgba,
  ParsedUsakameDocument,
} from './parser';

export class UsakameDecorator implements vscode.Disposable {
  private paletteSwatchDecorationTypes = new Map<string, vscode.TextEditorDecorationType>();
  private inlineIconDecorationTypes = new Map<string, vscode.TextEditorDecorationType>();

  constructor() {}

  public dispose(): void {
    this.clearAllDecorationTypes();
  }

  private clearAllDecorationTypes(): void {
    for (const d of this.paletteSwatchDecorationTypes.values()) {
      d.dispose();
    }
    this.paletteSwatchDecorationTypes.clear();
    for (const d of this.inlineIconDecorationTypes.values()) {
      d.dispose();
    }
    this.inlineIconDecorationTypes.clear();
  }

  private getSwatchDecorationType(hexColor: string): vscode.TextEditorDecorationType {
    let dt = this.paletteSwatchDecorationTypes.get(hexColor);
    if (!dt) {
      dt = vscode.window.createTextEditorDecorationType({
        before: {
          contentText: '■ ',
          color: hexColor,
          fontWeight: 'bold',
        },
      });
      this.paletteSwatchDecorationTypes.set(hexColor, dt);
    }
    return dt;
  }

  private getInlineIconDecorationType(key: string, dataUri: string, label: string): vscode.TextEditorDecorationType {
    let dt = this.inlineIconDecorationTypes.get(key);
    if (!dt) {
      if (this.inlineIconDecorationTypes.size > 128) {
        for (const old of this.inlineIconDecorationTypes.values()) {
          old.dispose();
        }
        this.inlineIconDecorationTypes.clear();
      }
      dt = vscode.window.createTextEditorDecorationType({
        after: {
          contentIconPath: vscode.Uri.parse(dataUri),
          margin: '0 0 0 8px',
          width: '16px',
          height: '16px',
          contentText: label ? ` ${label}` : '',
          color: new vscode.ThemeColor('editorCodeLens.foreground'),
        },
      });
      this.inlineIconDecorationTypes.set(key, dt);
    }
    return dt;
  }

  public updateDecorations(editor: vscode.TextEditor, parsed: ParsedUsakameDocument): void {
    const config = vscode.workspace.getConfiguration('usakame');
    const enableInlineIcons = config.get<boolean>('enableInlineSpriteIcons', true);

    // Clear previous ranges on all active decoration types
    for (const dt of this.paletteSwatchDecorationTypes.values()) {
      editor.setDecorations(dt, []);
    }
    for (const dt of this.inlineIconDecorationTypes.values()) {
      editor.setDecorations(dt, []);
    }

    const doc = editor.document;

    // 1. Swatches on #RRGGBB inside @PALETTE blocks
    if (parsed.hasEndMarker && parsed.paletteBlocks.size > 0) {
      const swatchRangesByHex = new Map<string, vscode.Range[]>();
      for (const palBlock of parsed.paletteBlocks.values()) {
        for (let lineNum = palBlock.headerLine; lineNum <= palBlock.endLine && lineNum < doc.lineCount; lineNum++) {
          const lineText = doc.lineAt(lineNum).text;
          const regex = /#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|0x[0-9a-fA-F]{6}\b/g;
          let m: RegExpExecArray | null;
          while ((m = regex.exec(lineText)) !== null) {
            const raw = m[0];
            const normHex = raw.startsWith('0x') || raw.startsWith('0X') ? `#${raw.slice(2).toUpperCase()}` : raw.toUpperCase();
            let arr = swatchRangesByHex.get(normHex);
            if (!arr) {
              arr = [];
              swatchRangesByHex.set(normHex, arr);
            }
            arr.push(new vscode.Range(lineNum, m.index, lineNum, m.index + raw.length));
          }
        }
      }

      for (const [hex, ranges] of swatchRangesByHex.entries()) {
        const dt = this.getSwatchDecorationType(hex);
        editor.setDecorations(dt, ranges);
      }
    }

    // 2. Inline mini sprite icons next to spr(...) and blt(...) calls in Ruby code section
    if (enableInlineIcons && parsed.sprites.size > 0) {
      const codeLimitLine = parsed.hasEndMarker ? parsed.endMarkerLine : doc.lineCount;
      const iconRanges = new Map<vscode.TextEditorDecorationType, vscode.Range[]>();

      for (let lineNum = 0; lineNum < codeLimitLine && lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        const trimmed = lineText.trim();
        if (trimmed.startsWith('#')) {
          continue;
        }

        // Check spr(id, ...)
        const sprMatch = /\bspr\s*\(\s*(\d+)\b/.exec(lineText);
        if (sprMatch) {
          const id = parseInt(sprMatch[1], 10);
          const sp = parsed.sprites.get(id);
          if (sp && !sp.emoji) {
            const dataUri = encodeRgbaToScaledPngDataUri(sp.rgba, sp.width, sp.height, 1, { checkerboard: true });
            const key = `spr:${id}:${sp.paletteId}:${sp.width}x${sp.height}:${sp.lines.join('')}`;
            const label = sp.paletteId > 0 ? `#${id} (pal:${sp.paletteId})` : `#${id}`;
            const dt = this.getInlineIconDecorationType(key, dataUri, label);
            const arr = iconRanges.get(dt) || [];
            arr.push(new vscode.Range(lineNum, lineText.length, lineNum, lineText.length));
            iconRanges.set(dt, arr);
            continue;
          }
        }

        // Check blt(x, y, bank, u, v, w, h, ...)
        const bltMatch = /\bblt\s*\(\s*([^,]+),\s*([^,]+),\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*(-?\d+)\s*,\s*(-?\d+))?(?:\s*,\s*[^,]+,\s*[^,]+,\s*(\d+))?/.exec(lineText);
        if (bltMatch) {
          const bankId = parseInt(bltMatch[3], 10);
          if (bankId === 0) {
            const u = parseInt(bltMatch[4], 10);
            const v = parseInt(bltMatch[5], 10);
            const w = bltMatch[6] !== undefined ? parseInt(bltMatch[6], 10) : 16;
            const h = bltMatch[7] !== undefined ? parseInt(bltMatch[7], 10) : 16;
            const palOverride = bltMatch[8] !== undefined ? parseInt(bltMatch[8], 10) : null;
            const regionRgba = extractBank0RegionRgba(parsed, u, v, w, h, palOverride);
            const absW = Math.max(1, Math.min(256, Math.abs(w)));
            const absH = Math.max(1, Math.min(256, Math.abs(h)));
            const dataUri = encodeRgbaToScaledPngDataUri(regionRgba, absW, absH, 1, { checkerboard: true });
            const key = `blt:${u},${v},${w},${h},${palOverride ?? -1}:${Buffer.from(regionRgba.slice(0, 64)).toString('base64')}`;
            const label = `(${u},${v} ${absW}x${absH}${palOverride !== null ? ` pal:${palOverride}` : ''})`;
            const dt = this.getInlineIconDecorationType(key, dataUri, label);
            const arr = iconRanges.get(dt) || [];
            arr.push(new vscode.Range(lineNum, lineText.length, lineNum, lineText.length));
            iconRanges.set(dt, arr);
          }
        }
      }

      for (const [dt, ranges] of iconRanges.entries()) {
        editor.setDecorations(dt, ranges);
      }
    }
  }
}

import * as vscode from 'vscode';
import {
  DEFAULT_PALETTE_RGBA,
  encodeRgbaToScaledPngDataUri,
  extractBank0RegionRgba,
  PALETTE_COLOR_NAMES,
  PaletteRgba,
  ParsedUsakameDocument,
  rgbaToHex,
} from './parser';

function isLightColor(r: number, g: number, b: number): boolean {
  const luminance = 0.299 * r + 0.587 * g + 0.114 * b;
  return luminance > 140;
}

export class UsakameDecorator implements vscode.Disposable {
  private colorDecorationTypes = new Map<string, vscode.TextEditorDecorationType>();
  private transparentDotDecorationType: vscode.TextEditorDecorationType;
  private paletteSwatchDecorationTypes = new Map<string, vscode.TextEditorDecorationType>();
  private inlineIconDecorationTypes = new Map<string, vscode.TextEditorDecorationType>();

  constructor() {
    this.transparentDotDecorationType = vscode.window.createTextEditorDecorationType({
      color: 'rgba(130, 140, 160, 0.35)',
    });
  }

  public dispose(): void {
    this.clearAllDecorationTypes();
    this.transparentDotDecorationType.dispose();
  }

  private clearAllDecorationTypes(): void {
    for (const d of this.colorDecorationTypes.values()) {
      d.dispose();
    }
    this.colorDecorationTypes.clear();
    for (const d of this.paletteSwatchDecorationTypes.values()) {
      d.dispose();
    }
    this.paletteSwatchDecorationTypes.clear();
    for (const d of this.inlineIconDecorationTypes.values()) {
      d.dispose();
    }
    this.inlineIconDecorationTypes.clear();
  }

  private getPixelColorDecorationType(hexColor: string, isLight: boolean): vscode.TextEditorDecorationType {
    let dt = this.colorDecorationTypes.get(hexColor);
    if (!dt) {
      dt = vscode.window.createTextEditorDecorationType({
        backgroundColor: hexColor,
        color: isLight ? 'rgba(0,0,0,0.65)' : 'rgba(255,255,255,0.65)',
        borderRadius: '1px',
      });
      this.colorDecorationTypes.set(hexColor, dt);
    }
    return dt;
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
    const enablePixelColoring = config.get<boolean>('enablePixelColoring', true);
    const enableInlineIcons = config.get<boolean>('enableInlineSpriteIcons', true);

    // Clear previous ranges on all active decoration types
    for (const dt of this.colorDecorationTypes.values()) {
      editor.setDecorations(dt, []);
    }
    editor.setDecorations(this.transparentDotDecorationType, []);
    for (const dt of this.paletteSwatchDecorationTypes.values()) {
      editor.setDecorations(dt, []);
    }
    for (const dt of this.inlineIconDecorationTypes.values()) {
      editor.setDecorations(dt, []);
    }

    const doc = editor.document;

    // 1. Pixel coloring inside @SPRITE and swatches inside @PALETTE
    if (enablePixelColoring && parsed.hasEndMarker) {
      const rangesByHex = new Map<string, { isLight: boolean; ranges: vscode.Range[] }>();
      const dotRanges: vscode.Range[] = [];

      for (const sp of parsed.sprites.values()) {
        if (sp.emoji) {
          continue;
        }
        const pal: PaletteRgba =
          parsed.palettes.get(sp.paletteId) ||
          parsed.palettes.get(parsed.defaultPaletteId) ||
          DEFAULT_PALETTE_RGBA;

        for (let lineNum = sp.startLine; lineNum <= sp.endLine && lineNum < doc.lineCount; lineNum++) {
          const lineText = doc.lineAt(lineNum).text;
          const trimmedCheck = lineText.trim();
          if (!trimmedCheck || trimmedCheck.startsWith('#') || trimmedCheck.startsWith('@')) {
            continue;
          }

          let col = 0;
          while (col < lineText.length) {
            const ch = lineText[col];
            if (ch === '.') {
              let endCol = col + 1;
              while (endCol < lineText.length && lineText[endCol] === '.') {
                endCol++;
              }
              dotRanges.push(new vscode.Range(lineNum, col, lineNum, endCol));
              col = endCol;
            } else if (/^[0-9a-fA-F]$/.test(ch)) {
              const colorIdx = parseInt(ch, 16);
              let endCol = col + 1;
              while (
                endCol < lineText.length &&
                /^[0-9a-fA-F]$/.test(lineText[endCol]) &&
                parseInt(lineText[endCol], 16) === colorIdx
              ) {
                endCol++;
              }
              const rgba = pal[colorIdx & 0x0f];
              const hex = rgbaToHex(rgba);
              let entry = rangesByHex.get(hex);
              if (!entry) {
                entry = { isLight: isLightColor(rgba[0], rgba[1], rgba[2]), ranges: [] };
                rangesByHex.set(hex, entry);
              }
              entry.ranges.push(new vscode.Range(lineNum, col, lineNum, endCol));
              col = endCol;
            } else {
              col++;
            }
          }
        }
      }

      for (const [hex, entry] of rangesByHex.entries()) {
        const dt = this.getPixelColorDecorationType(hex, entry.isLight);
        editor.setDecorations(dt, entry.ranges);
      }
      editor.setDecorations(this.transparentDotDecorationType, dotRanges);

      // Swatches on #RRGGBB inside @PALETTE blocks
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

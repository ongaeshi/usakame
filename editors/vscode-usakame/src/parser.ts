import * as zlib from 'zlib';

export type RgbaColor = [number, number, number, number];
export type PaletteRgba = RgbaColor[]; // 16 colors

/** PICO-8 Standard 16-color palette (Palette 0) */
export const DEFAULT_PALETTE_RGBA: PaletteRgba = [
  [0, 0, 0, 255],       // 0: Black (#000000)
  [29, 43, 83, 255],    // 1: Dark Blue (#1D2B53)
  [126, 37, 83, 255],   // 2: Dark Purple (#7E2553)
  [0, 135, 81, 255],    // 3: Dark Green (#008751)
  [171, 82, 54, 255],   // 4: Brown (#AB5236)
  [95, 87, 79, 255],    // 5: Dark Grey (#5F574F)
  [194, 195, 199, 255], // 6: Light Grey (#C2C3C7)
  [255, 241, 232, 255], // 7: White (#FFF1E8)
  [255, 0, 77, 255],    // 8: Red (#FF004D)
  [255, 163, 0, 255],   // 9: Orange (#FFA300)
  [255, 236, 39, 255],  // A: Yellow (#FFEC27)
  [0, 228, 54, 255],    // B: Green (#00E436)
  [41, 173, 255, 255],  // C: Blue (#29ADFF)
  [131, 118, 156, 255], // D: Indigo (#83769C)
  [255, 119, 168, 255], // E: Pink (#FF77A8)
  [255, 204, 170, 255], // F: Peach (#FFCCAA)
];

export const PALETTE_COLOR_NAMES: string[] = [
  'Black', 'Dark Blue', 'Dark Purple', 'Dark Green',
  'Brown', 'Dark Grey', 'Light Grey', 'White',
  'Red', 'Orange', 'Yellow', 'Green',
  'Blue', 'Indigo', 'Pink', 'Peach',
];

export function rgbaToHex(col: RgbaColor): string {
  const r = col[0].toString(16).padStart(2, '0').toUpperCase();
  const g = col[1].toString(16).padStart(2, '0').toUpperCase();
  const b = col[2].toString(16).padStart(2, '0').toUpperCase();
  return `#${r}${g}${b}`;
}

export function parseHexColor(s: string): RgbaColor | null {
  const clean = s.trim().replace(/[,;]$/, '');
  let hex = '';
  if (clean.startsWith('#')) {
    hex = clean.slice(1);
  } else if (clean.startsWith('0x') || clean.startsWith('0X')) {
    hex = clean.slice(2);
  } else {
    return null;
  }

  if (hex.length === 3 && /^[0-9a-fA-F]{3}$/.test(hex)) {
    const r = parseInt(hex[0] + hex[0], 16);
    const g = parseInt(hex[1] + hex[1], 16);
    const b = parseInt(hex[2] + hex[2], 16);
    return [r, g, b, 255];
  }
  if (hex.length === 6 && /^[0-9a-fA-F]{6}$/.test(hex)) {
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    return [r, g, b, 255];
  }
  return null;
}

export interface ParsedPaletteBlock {
  id: number;
  headerLine: number;
  startLine: number;
  endLine: number; // inclusive
  colors: PaletteRgba;
  overriddenIndices: number[];
}

export interface ParsedSpriteBlock {
  id: number;
  width: number;
  height: number;
  explicitDims: boolean;
  paletteId: number;
  emoji?: string;
  headerLine: number;
  startLine: number; // first pattern line
  endLine: number;   // last pattern line (inclusive)
  lines: string[];
  indexed: (number | null)[]; // width * height
  rgba: Uint8Array;           // width * height * 4
}

export interface ParsedMapBlock {
  offsetX: number;
  offsetY: number;
  headerLine: number;
  startLine: number;
  endLine: number;
  width: number;
  height: number;
  cells: Map<string, number>; // "x,y" -> tileId (-1 = empty)
  rawLines: string[];
}

export interface ParsedSfxBlock {
  kind: 'SFX' | 'MUSIC';
  id: number;
  headerLine: number;
  startLine: number;
  endLine: number;
  specText: string;
  rawLines: string[];
}

export interface ParsedBank0 {
  width: number;
  height: number;
  rgba: Uint8Array; // 256 * 256 * 4
  indexed: (number | null)[]; // 256 * 256
  paletteAtSlot: Map<string, number>; // "tx,ty" -> paletteId
  occupiedSlots: Map<string, { id: number; width: number; height: number }>;
  overlaps: { id: number; prevId: number; tx: number; ty: number; line: number }[];
}

export interface ParsedUsakameDocument {
  hasEndMarker: boolean;
  endMarkerLine: number;
  defaultPaletteId: number;
  palettes: Map<number, PaletteRgba>;
  paletteBlocks: Map<number, ParsedPaletteBlock>;
  sprites: Map<number, ParsedSpriteBlock>;
  mapBlocks: ParsedMapBlock[];
  sfxBlocks: ParsedSfxBlock[];
  bank0: ParsedBank0;
}

function clonePalette(pal: PaletteRgba): PaletteRgba {
  return pal.map((c) => [c[0], c[1], c[2], c[3]]);
}

function parseTileDims(tok: string): [number, number] | null {
  const clean = tok.trim().toLowerCase().replace(/^size:?/, '');
  const m = /^(\d+)x(\d+)$/.exec(clean);
  if (!m) {
    return null;
  }
  const w = parseInt(m[1], 10);
  const h = parseInt(m[2], 10);
  if (w > 0 && h > 0 && w <= 256 && h <= 256) {
    return [w, h];
  }
  return null;
}

function parseColorIdxToken(tok: string): number | null {
  const s = tok.trim();
  if (/^\d+$/.test(s)) {
    const v = parseInt(s, 10);
    if (v >= 0 && v < 16) {
      return v;
    }
  }
  if (/^[0-9a-fA-F]$/.test(s)) {
    return parseInt(s, 16);
  }
  return null;
}

function parsePaletteLine(
  line: string,
  pal: PaletteRgba,
  overridden: Set<number>,
  state: { nextAutoIdx: number }
): void {
  const rawTokens = line.trim().split(/\s+/);
  const parts: string[] = [];
  for (const tok of rawTokens) {
    if (!tok) {
      continue;
    }
    if (tok.startsWith('#') && !parseHexColor(tok)) {
      break; // comment
    }
    parts.push(tok);
  }
  if (parts.length === 0) {
    return;
  }

  let i = 0;
  while (i < parts.length) {
    const tok = parts[i];
    const sepMatch = /^([^:=]+)[:=](.*)$/.exec(tok);
    if (sepMatch) {
      const idx = parseColorIdxToken(sepMatch[1]);
      const colStr = sepMatch[2].trim();
      if (idx !== null) {
        if (colStr.length > 0) {
          const rgba = parseHexColor(colStr);
          if (rgba) {
            pal[idx] = rgba;
            overridden.add(idx);
            state.nextAutoIdx = idx + 1;
            i += 1;
            continue;
          }
        } else if (i + 1 < parts.length) {
          const rgba = parseHexColor(parts[i + 1]);
          if (rgba) {
            pal[idx] = rgba;
            overridden.add(idx);
            state.nextAutoIdx = idx + 1;
            i += 2;
            continue;
          }
        }
      }
    }

    const idx = parseColorIdxToken(tok);
    if (idx !== null) {
      let nextI = i + 1;
      if (nextI < parts.length && (parts[nextI] === ':' || parts[nextI] === '=')) {
        nextI += 1;
      }
      if (nextI < parts.length) {
        const rgba = parseHexColor(parts[nextI]);
        if (rgba) {
          pal[idx] = rgba;
          overridden.add(idx);
          state.nextAutoIdx = idx + 1;
          i = nextI + 1;
          continue;
        }
      }
    }

    const rgba = parseHexColor(tok);
    if (rgba && state.nextAutoIdx < 16) {
      pal[state.nextAutoIdx] = rgba;
      overridden.add(state.nextAutoIdx);
      state.nextAutoIdx += 1;
      i += 1;
      continue;
    }

    i += 1;
  }
}

export function parseUsakameDocument(text: string, isResourceOnlyFile = false): ParsedUsakameDocument {
  const allLines = text.split(/\r?\n/);
  let endMarkerLine = -1;
  let defaultPaletteId = 0;

  if (isResourceOnlyFile) {
    endMarkerLine = 0;
  } else {
    for (let i = 0; i < allLines.length; i++) {
      if (allLines[i].trim() === '__END__') {
        endMarkerLine = i;
        break;
      }
      // Check config(palette: N) or pal_bank(N)
      const palMatch = /(?:palette\s*:|pal\s*:|pal_bank\s*\()\s*(\d+)/.exec(allLines[i]);
      if (palMatch) {
        defaultPaletteId = parseInt(palMatch[1], 10);
      }
    }
  }

  const palettes = new Map<number, PaletteRgba>();
  palettes.set(0, clonePalette(DEFAULT_PALETTE_RGBA));
  const paletteBlocks = new Map<number, ParsedPaletteBlock>();
  const sprites = new Map<number, ParsedSpriteBlock>();
  const mapBlocks: ParsedMapBlock[] = [];
  const sfxBlocks: ParsedSfxBlock[] = [];

  const bank0: ParsedBank0 = {
    width: 256,
    height: 256,
    rgba: new Uint8Array(256 * 256 * 4),
    indexed: new Array<number | null>(256 * 256).fill(null),
    paletteAtSlot: new Map(),
    occupiedSlots: new Map(),
    overlaps: [],
  };

  if (endMarkerLine === -1) {
    return {
      hasEndMarker: false,
      endMarkerLine: -1,
      defaultPaletteId,
      palettes,
      paletteBlocks,
      sprites,
      mapBlocks,
      sfxBlocks,
      bank0,
    };
  }

  const startScanLine = isResourceOnlyFile ? 0 : endMarkerLine + 1;

  // Pass 1: Parse @PALETTE blocks first so @SPRITE can reference any @PALETTE in the file
  let curPalId: number | null = null;
  let curPalHeader = startScanLine;
  let curPalStart = startScanLine;
  let curPalEnd = startScanLine;
  let curPalColors = clonePalette(DEFAULT_PALETTE_RGBA);
  let curOverridden = new Set<number>();
  const autoIdxState = { nextAutoIdx: 0 };

  const flushPalette = () => {
    if (curPalId !== null && curPalId > 0) {
      palettes.set(curPalId, clonePalette(curPalColors));
      paletteBlocks.set(curPalId, {
        id: curPalId,
        headerLine: curPalHeader,
        startLine: curPalStart,
        endLine: curPalEnd,
        colors: clonePalette(curPalColors),
        overriddenIndices: Array.from(curOverridden).sort((a, b) => a - b),
      });
    }
    curPalId = null;
  };

  for (let lineIdx = startScanLine; lineIdx < allLines.length; lineIdx++) {
    const line = allLines[lineIdx].trim();
    if (!line) {
      continue;
    }
    if (line.startsWith('@PALETTE')) {
      flushPalette();
      const rest = line.slice('@PALETTE'.length).trim();
      const tokens = rest ? rest.split(/\s+/) : [];
      let palId = 1;
      let startIdx = 0;
      if (tokens.length > 0 && /^\d+$/.test(tokens[0])) {
        palId = parseInt(tokens[0], 10);
        startIdx = 1;
      }
      if (palId <= 0) {
        curPalId = null;
        continue;
      }
      curPalId = palId;
      curPalHeader = lineIdx;
      curPalStart = lineIdx + 1;
      curPalEnd = lineIdx;
      const existing = palettes.get(palId);
      curPalColors = existing ? clonePalette(existing) : clonePalette(DEFAULT_PALETTE_RGBA);
      curOverridden = new Set<number>();
      autoIdxState.nextAutoIdx = 0;
      const inlineRest = tokens.slice(startIdx).join(' ');
      if (inlineRest) {
        parsePaletteLine(inlineRest, curPalColors, curOverridden, autoIdxState);
      }
      continue;
    }
    if (line.startsWith('@')) {
      flushPalette();
      continue;
    }
    if (curPalId !== null) {
      curPalEnd = lineIdx;
      parsePaletteLine(line, curPalColors, curOverridden, autoIdxState);
    }
  }
  flushPalette();

  // Pass 2: Parse @SPRITE, @MAP, @SFX, @MUSIC
  type ActiveBlock =
    | {
        type: 'SPRITE';
        id: number;
        paletteId: number;
        dims: [number, number] | null;
        emoji?: string;
        headerLine: number;
        startLine: number;
        endLine: number;
        lines: string[];
      }
    | {
        type: 'MAP';
        offsetX: number;
        offsetY: number;
        headerLine: number;
        startLine: number;
        endLine: number;
        lines: string[];
      }
    | {
        type: 'SFX' | 'MUSIC';
        id: number;
        headerLine: number;
        startLine: number;
        endLine: number;
        lines: string[];
      };

  let active: ActiveBlock | null = null;

  const flushActive = () => {
    if (!active) {
      return;
    }
    if (active.type === 'SPRITE') {
      const pal = palettes.get(active.paletteId) || palettes.get(defaultPaletteId) || DEFAULT_PALETTE_RGBA;
      let width = 16;
      let height = 16;
      let explicitDims = false;
      if (active.dims) {
        width = active.dims[0];
        height = active.dims[1];
        explicitDims = true;
      } else if (active.lines.length > 0) {
        const maxCols = Math.max(...active.lines.map((l) => l.length), 16);
        width = Math.max(maxCols, 16);
        height = Math.max(active.lines.length, 16);
      }

      const rgba = new Uint8Array(width * height * 4);
      const indexed = new Array<number | null>(width * height).fill(null);

      for (let y = 0; y < Math.min(height, active.lines.length); y++) {
        const rowStr = active.lines[y];
        for (let x = 0; x < Math.min(width, rowStr.length); x++) {
          const ch = rowStr[x];
          let colorIdx: number | null = null;
          if (ch !== '.' && ch !== ' ') {
            if (/^[0-9a-fA-F]$/.test(ch)) {
              colorIdx = parseInt(ch, 16);
            }
          }
          const pxIdx = y * width + x;
          if (colorIdx !== null) {
            const c = pal[colorIdx & 0x0f];
            const off = pxIdx * 4;
            rgba[off] = c[0];
            rgba[off + 1] = c[1];
            rgba[off + 2] = c[2];
            rgba[off + 3] = c[3];
            indexed[pxIdx] = colorIdx & 0x0f;
          }
        }
      }

      const spriteBlock: ParsedSpriteBlock = {
        id: active.id,
        width,
        height,
        explicitDims,
        paletteId: active.paletteId,
        emoji: active.emoji,
        headerLine: active.headerLine,
        startLine: active.startLine,
        endLine: active.endLine,
        lines: active.lines,
        indexed,
        rgba,
      };
      sprites.set(active.id, spriteBlock);

      if (active.id >= 0 && active.id <= 255) {
        const slotX = (active.id % 16) * 16;
        const slotY = Math.floor(active.id / 16) * 16;
        const tilesW = Math.ceil(width / 16);
        const tilesH = Math.ceil(height / 16);
        const startTx = Math.floor(slotX / 16);
        const startTy = Math.floor(slotY / 16);

        for (let ty = startTy; ty < startTy + tilesH; ty++) {
          for (let tx = startTx; tx < startTx + tilesW; tx++) {
            const key = `${tx},${ty}`;
            const prev = bank0.occupiedSlots.get(key);
            if (prev && prev.id !== active.id) {
              bank0.overlaps.push({
                id: active.id,
                prevId: prev.id,
                tx,
                ty,
                line: active.headerLine,
              });
            } else {
              bank0.occupiedSlots.set(key, { id: active.id, width, height });
            }
            bank0.paletteAtSlot.set(key, active.paletteId);
          }
        }

        // Write into bank0
        for (let row = 0; row < height; row++) {
          const gy = slotY + row;
          if (gy >= 256) {
            break;
          }
          for (let col = 0; col < width; col++) {
            const gx = slotX + col;
            if (gx >= 256) {
              break;
            }
            const srcIdx = row * width + col;
            const dstIdx = gy * 256 + gx;
            bank0.indexed[dstIdx] = indexed[srcIdx];
            const srcOff = srcIdx * 4;
            const dstOff = dstIdx * 4;
            bank0.rgba[dstOff] = rgba[srcOff];
            bank0.rgba[dstOff + 1] = rgba[srcOff + 1];
            bank0.rgba[dstOff + 2] = rgba[srcOff + 2];
            bank0.rgba[dstOff + 3] = rgba[srcOff + 3];
          }
        }
      }
    } else if (active.type === 'MAP') {
      const cells = new Map<string, number>();
      let maxW = 0;
      let curY = active.offsetY;
      for (const rawRow of active.lines) {
        const trimmed = rawRow.trim();
        if (!trimmed || trimmed.startsWith('#')) {
          continue;
        }
        if (/[\s,]/.test(trimmed)) {
          const tokens = trimmed.split(/[\s,]+/);
          let x = active.offsetX;
          for (const tok of tokens) {
            if (!tok) {
              continue;
            }
            let val = -1;
            if (tok !== '.' && tok !== '..' && tok !== '_' && tok !== '-') {
              if (/^0x[0-9a-fA-F]+$/i.test(tok)) {
                val = parseInt(tok.slice(2), 16);
              } else if (/^\d+$/.test(tok)) {
                val = parseInt(tok, 10);
              } else if (/^[0-9a-fA-F]+$/.test(tok)) {
                val = parseInt(tok, 16);
              }
            }
            if (val >= 0) {
              cells.set(`${x},${curY}`, val);
            }
            x += 1;
            maxW = Math.max(maxW, x);
          }
        } else {
          for (let dx = 0; dx < trimmed.length; dx++) {
            const ch = trimmed[dx];
            const x = active.offsetX + dx;
            if (ch !== '.' && ch !== '_' && ch !== '-' && /^[0-9a-fA-F]$/.test(ch)) {
              cells.set(`${x},${curY}`, parseInt(ch, 16));
            }
            maxW = Math.max(maxW, x + 1);
          }
        }
        curY += 1;
      }
      mapBlocks.push({
        offsetX: active.offsetX,
        offsetY: active.offsetY,
        headerLine: active.headerLine,
        startLine: active.startLine,
        endLine: active.endLine,
        width: Math.max(maxW, 16),
        height: Math.max(curY, 16),
        cells,
        rawLines: active.lines,
      });
    } else if (active.type === 'SFX' || active.type === 'MUSIC') {
      sfxBlocks.push({
        kind: active.type,
        id: active.id,
        headerLine: active.headerLine,
        startLine: active.startLine,
        endLine: active.endLine,
        specText: active.lines.join('\n'),
        rawLines: active.lines,
      });
    }
    active = null;
  };

  for (let lineIdx = startScanLine; lineIdx < allLines.length; lineIdx++) {
    const rawLine = allLines[lineIdx];
    const line = rawLine.trim();
    if (!line || (line.startsWith('#') && (!active || active.type === 'SPRITE'))) {
      continue;
    }

    if (line.startsWith('@SPRITE') && !line.startsWith('@SPRITE_B64')) {
      flushActive();
      const rest = line.slice('@SPRITE'.length).trim();
      const parts = rest ? rest.split(/\s+/) : [];
      if (parts.length > 0 && /^\d+$/.test(parts[0])) {
        const id = parseInt(parts[0], 10);
        let palId = defaultPaletteId;
        let dims: [number, number] | null = null;
        let emoji: string | undefined;

        for (const tok of parts.slice(1)) {
          if (tok.startsWith('#')) {
            break;
          }
          const palM = /^(?:pal|p)[:=](\d+)$/i.exec(tok);
          if (palM) {
            palId = parseInt(palM[1], 10);
            continue;
          }
          const d = parseTileDims(tok);
          if (d) {
            dims = d;
            continue;
          }
          if (!/^\d+$/.test(tok) && !emoji) {
            emoji = tok;
          }
        }

        active = {
          type: 'SPRITE',
          id,
          paletteId: palId,
          dims,
          emoji,
          headerLine: lineIdx,
          startLine: lineIdx + 1,
          endLine: lineIdx,
          lines: [],
        };
      }
      continue;
    }

    if (line.startsWith('@MAP')) {
      flushActive();
      const rest = line.slice('@MAP'.length).trim();
      const parts = rest ? rest.split(/\s+/) : [];
      const offsetX = parts.length > 0 && /^-?\d+$/.test(parts[0]) ? parseInt(parts[0], 10) : 0;
      const offsetY = parts.length > 1 && /^-?\d+$/.test(parts[1]) ? parseInt(parts[1], 10) : 0;
      active = {
        type: 'MAP',
        offsetX,
        offsetY,
        headerLine: lineIdx,
        startLine: lineIdx + 1,
        endLine: lineIdx,
        lines: [],
      };
      continue;
    }

    if (line.startsWith('@SFX') || line.startsWith('@MUSIC')) {
      flushActive();
      const isMusic = line.startsWith('@MUSIC');
      const prefix = isMusic ? '@MUSIC' : '@SFX';
      const rest = line.slice(prefix.length).trim();
      const parts = rest ? rest.split(/\s+/) : [];
      const id = parts.length > 0 && /^\d+$/.test(parts[0]) ? parseInt(parts[0], 10) : 0;
      const inlineSpec = parts.slice(1).join(' ');
      active = {
        type: isMusic ? 'MUSIC' : 'SFX',
        id,
        headerLine: lineIdx,
        startLine: lineIdx + 1,
        endLine: lineIdx,
        lines: inlineSpec ? [inlineSpec] : [],
      };
      continue;
    }

    if (line.startsWith('@')) {
      flushActive();
      continue;
    }

    if (active) {
      active.lines.push(line);
      active.endLine = lineIdx;
    }
  }

  flushActive();

  return {
    hasEndMarker: true,
    endMarkerLine,
    defaultPaletteId,
    palettes,
    paletteBlocks,
    sprites,
    mapBlocks,
    sfxBlocks,
    bank0,
  };
}

/** Find next available sprite ID (taking multi-tile occupancy into account) */
export function findNextFreeSpriteId(doc: ParsedUsakameDocument, w = 16, h = 16): number {
  const tilesW = Math.ceil(w / 16);
  const tilesH = Math.ceil(h / 16);
  for (let id = 0; id < 256; id++) {
    const startTx = id % 16;
    const startTy = Math.floor(id / 16);
    if (startTx + tilesW > 16 || startTy + tilesH > 16) {
      continue;
    }
    let conflict = false;
    for (let ty = startTy; ty < startTy + tilesH; ty++) {
      for (let tx = startTx; tx < startTx + tilesW; tx++) {
        if (doc.bank0.occupiedSlots.has(`${tx},${ty}`)) {
          conflict = true;
          break;
        }
      }
      if (conflict) {
        break;
      }
    }
    if (!conflict && !doc.sprites.has(id)) {
      return id;
    }
  }
  return doc.sprites.size;
}

// ======================================================
// Pure Node.js PNG Encoder (for crisp Hover / SignatureHelp images)
// ======================================================
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function makePngChunk(type: string, data: Buffer): Buffer {
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcInput = Buffer.concat([typeBuf, data]);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(crcInput), 0);
  return Buffer.concat([lenBuf, typeBuf, data, crcBuf]);
}

/**
 * Render an RGBA pixel buffer into a nearest-neighbor scaled PNG Data URI
 * with a subtle checkerboard background for transparent pixels and optional highlight border.
 */
export function encodeRgbaToScaledPngDataUri(
  srcRgba: Uint8Array,
  srcW: number,
  srcH: number,
  scale = 4,
  options?: {
    checkerboard?: boolean;
    highlightRect?: { x: number; y: number; w: number; h: number };
  }
): string {
  const s = Math.max(1, Math.floor(scale));
  const outW = srcW * s;
  const outH = srcH * s;
  const useChecker = options?.checkerboard ?? true;
  const hl = options?.highlightRect;

  // Each scanline in PNG starts with filter byte 0
  const rawData = Buffer.alloc((outW * 4 + 1) * outH);

  for (let oy = 0; oy < outH; oy++) {
    const rowOffset = oy * (outW * 4 + 1);
    rawData[rowOffset] = 0; // Filter type 0 (None)
    const sy = Math.floor(oy / s);

    for (let ox = 0; ox < outW; ox++) {
      const sx = Math.floor(ox / s);
      const srcOff = (sy * srcW + sx) * 4;
      let r = srcRgba[srcOff];
      let g = srcRgba[srcOff + 1];
      let b = srcRgba[srcOff + 2];
      let a = srcRgba[srcOff + 3];

      if (a === 0 && useChecker) {
        const isDark = ((Math.floor(ox / Math.max(2, s / 2)) + Math.floor(oy / Math.max(2, s / 2))) % 2) === 0;
        const c = isDark ? 34 : 50;
        r = c;
        g = c;
        b = c;
        a = 255;
      }

      if (hl) {
        const hlx0 = hl.x * s;
        const hly0 = hl.y * s;
        const hlx1 = (hl.x + hl.w) * s - 1;
        const hly1 = (hl.y + hl.h) * s - 1;
        const onBorderX = (ox === hlx0 || ox === hlx0 + 1 || ox === hlx1 || ox === hlx1 - 1) && oy >= hly0 && oy <= hly1;
        const onBorderY = (oy === hly0 || oy === hly0 + 1 || oy === hly1 || oy === hly1 - 1) && ox >= hlx0 && ox <= hlx1;
        if (onBorderX || onBorderY) {
          r = 255;
          g = 0;
          b = 77;
          a = 255;
        }
      }

      const dstOff = rowOffset + 1 + ox * 4;
      rawData[dstOff] = r;
      rawData[dstOff + 1] = g;
      rawData[dstOff + 2] = b;
      rawData[dstOff + 3] = a;
    }
  }

  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(outW, 0);
  ihdr.writeUInt32BE(outH, 4);
  ihdr[8] = 8; // bit depth 8
  ihdr[9] = 6; // color type 6 (RGBA)
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const compressed = zlib.deflateSync(rawData, { level: 1 });
  const pngBuf = Buffer.concat([
    signature,
    makePngChunk('IHDR', ihdr),
    makePngChunk('IDAT', compressed),
    makePngChunk('IEND', Buffer.alloc(0)),
  ]);

  return `data:image/png;base64,${pngBuf.toString('base64')}`;
}

/** Extract a rectangular region (u, v, w, h) from Bank 0, optionally applying a custom palette */
export function extractBank0RegionRgba(
  doc: ParsedUsakameDocument,
  u: number,
  v: number,
  w: number,
  h: number,
  palIdOverride?: number | null
): Uint8Array {
  const absW = Math.max(1, Math.min(256, Math.abs(w)));
  const absH = Math.max(1, Math.min(256, Math.abs(h)));
  const flipX = w < 0;
  const flipY = h < 0;
  const out = new Uint8Array(absW * absH * 4);
  const overridePal =
    palIdOverride !== undefined && palIdOverride !== null
      ? doc.palettes.get(palIdOverride)
      : undefined;

  for (let row = 0; row < absH; row++) {
    const sy = v + (flipY ? absH - 1 - row : row);
    if (sy < 0 || sy >= 256) {
      continue;
    }
    for (let col = 0; col < absW; col++) {
      const sx = u + (flipX ? absW - 1 - col : col);
      if (sx < 0 || sx >= 256) {
        continue;
      }
      const srcIdx = sy * 256 + sx;
      const dstOff = (row * absW + col) * 4;
      const idxColor = doc.bank0.indexed[srcIdx];
      if (overridePal && idxColor !== null) {
        const c = overridePal[idxColor & 0x0f];
        out[dstOff] = c[0];
        out[dstOff + 1] = c[1];
        out[dstOff + 2] = c[2];
        out[dstOff + 3] = c[3];
      } else {
        const srcOff = srcIdx * 4;
        out[dstOff] = doc.bank0.rgba[srcOff];
        out[dstOff + 1] = doc.bank0.rgba[srcOff + 1];
        out[dstOff + 2] = doc.bank0.rgba[srcOff + 2];
        out[dstOff + 3] = doc.bank0.rgba[srcOff + 3];
      }
    }
  }
  return out;
}

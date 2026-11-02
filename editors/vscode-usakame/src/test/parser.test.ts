import * as assert from 'assert';
import {
  encodeRgbaToScaledPngDataUri,
  extractBank0RegionRgba,
  findNextFreeSpriteId,
  parseUsakameDocument,
} from '../parser';

const sampleScript = `
config(palette: 1)

def draw
  cls(0)
  spr(0, 10, 20)
  blt(50, 50, 0, 0, 0, 16, 16)
end

__END__
@PALETTE 1
1: #112233  # shadow
3: #445566  # mid
B: #778899  # highlight

@SPRITE 0 16x16 pal:1
..1111..........
.133331.........
.13BB31.........
..1111..........

@SPRITE 4 32x32 pal:1
................................
...BBBB.........................

@MAP 0 0
11111111
1......1
11111111

@SFX 0
wave square speed 4
c2 e2 g2 c3:fade
`;

const parsed = parseUsakameDocument(sampleScript);
assert.strictEqual(parsed.hasEndMarker, true, '__END__ marker should be detected');
assert.strictEqual(parsed.defaultPaletteId, 1, 'config(palette: 1) should be detected');

// Palette 1 check
const pal1 = parsed.palettes.get(1);
assert.ok(pal1, '@PALETTE 1 should exist');
assert.deepStrictEqual(pal1[1], [0x11, 0x22, 0x33, 255]);
assert.deepStrictEqual(pal1[3], [0x44, 0x55, 0x66, 255]);
assert.deepStrictEqual(pal1[11], [0x77, 0x88, 0x99, 255]);

// Sprite 0 check
const sp0 = parsed.sprites.get(0);
assert.ok(sp0, '@SPRITE 0 should exist');
assert.strictEqual(sp0.width, 16);
assert.strictEqual(sp0.height, 16);
assert.strictEqual(sp0.paletteId, 1);

// Sprite 4 (32x32) check and next free slot check
const sp4 = parsed.sprites.get(4);
assert.ok(sp4, '@SPRITE 4 should exist');
assert.strictEqual(sp4.width, 32);
assert.strictEqual(sp4.height, 32);

// Slot 0 is occupied by Sprite 0, so next free 16x16 slot should be 1
assert.strictEqual(findNextFreeSpriteId(parsed, 16, 16), 1);
// For a 32x32 sprite, slot 0 is taken, slot 1 is free, slot 2&3 are free (and 18&19 below them are free) -> ID 1 is free!
assert.strictEqual(findNextFreeSpriteId(parsed, 32, 32), 1);

// PNG encoding & Bank 0 extraction check
const pngUri = encodeRgbaToScaledPngDataUri(sp0.rgba, sp0.width, sp0.height, 4, { checkerboard: true });
assert.ok(pngUri.startsWith('data:image/png;base64,'), 'Should produce valid PNG Data URI');

const region = extractBank0RegionRgba(parsed, 0, 0, 16, 16);
assert.strictEqual(region.length, 16 * 16 * 4);

// Map & SFX check
assert.strictEqual(parsed.mapBlocks.length, 1);
assert.strictEqual(parsed.mapBlocks[0].cells.get('0,0'), 1);
assert.strictEqual(parsed.sfxBlocks.length, 1);
assert.strictEqual(parsed.sfxBlocks[0].id, 0);

console.log('✅ All vscode-usakame parser & PNG renderer tests passed!');

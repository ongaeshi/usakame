---
name: usakame-sprite-fast
description: >-
  Rapidly generate large batches of lightweight pixel art sprites (@SPRITE) for the Usakame (uk) retro game engine with minimal latency and token overhead.
  Use when the user wants fast prototyping, bulk sprite generation (many enemies, items, tiles, icons, bullets), or quick PICO-8 style 2-3 color flat sprites without spending time on complex custom palettes or multi-layer shading.
---

# Usakame Fast & Bulk Sprite Generator (`usakame-sprite-fast`)

This skill is optimized for **speed, low latency, and high-volume batch generation** of sprites in the **Usakame (`uk`)** retro game engine.
Wait times and output tokens are minimized by stripping away per-sprite custom palette design, 4-layer shading math, and manual slot ID calculations.

> **When to use which skill:**
> - **`usakame-sprite-fast` (this skill)**: Fast prototyping, bulk asset creation (5–20+ sprites at once), 8-bit/PICO-8 flat aesthetics, minor enemies, items, bullets, tiles, UI icons.
> - **`usakame-sprite`**: Hero characters, centerpiece bosses, or rich 16-bit SNES/GBA-style sprites with dedicated custom `@PALETTE` color ramps.

---

## 1. The 5 Rules of Fast Sprite Generation

Follow these rules strictly to maximize generation speed:

### Rule 1: Use Standard Palette `0` Only (Skip `@PALETTE`)
- **Do NOT design or output `@PALETTE` blocks** unless explicitly requested.
- Use the built-in PICO-8 16-color palette (`0`–`F`, `.` for transparent) directly:
  `0`:Black, `1`:DarkBlue, `2`:DarkPurple, `3`:DarkGreen, `4`:Brown, `5`:DarkGrey, `6`:LightGrey, `7`:White, `8`:Red, `9`:Orange, `A`:Yellow, `B`:Green, `C`:Blue, `D`:Indigo, `E`:Pink, `F`:Peach.
- **Color Variants for Free**: To create elemental or tier variants (e.g., Slime / Red Slime / Gold Slime), define the sprite **once** and use runtime palette swapping `spr(:slime, x, y, false, pal_id)` or `pal(c0, c1)` instead of duplicating sprite blocks.

### Rule 2: Flat 2-to-3 Color Shading (No Complex Ramps)
- Skip 4-layer hue-shifted shading. Use **at most 2–3 colors per part**:
  - **Outline / Eyes**: `0` (Black) or `1` (Dark Blue)
  - **Base Fill**: 1 solid color (e.g., `B` for green slime, `8` for red potion, `C` for blue blade)
  - **Accent / Highlight**: 1–2 pixels of `7` (White) or 1 shadow color
- Prioritize **clear, bold, symmetric silhouettes** over internal pixel dithering or anti-aliasing.

### Rule 3: Always Use `:name` Auto-Packing (Zero Slot Math)
- Always declare sprites by symbol name (`@SPRITE :goblin`, `@SPRITE :coin`, `@SPRITE :sword`).
- Never waste reasoning steps calculating Bank 0 grid coordinates or explicit slot IDs. The engine automatically packs named sprites into 2D slots.

### Rule 4: Minimize Grid Size & Leverage Auto-Padding / Built-in Emojis
Choose the lightest representation that fits the asset:
1. **Tier 1 — Built-in 1,400 Emojis (1 line, Instant)**:
   - For standard props, fruits, environment tiles, or rapid placeholders, bind built-in 16×16 pixel-art emojis in a single line:
     ```ruby
     @SPRITE :wall 🧱
     @SPRITE :apple 🍎
     @SPRITE :fire 🔥 ✨
     @SPRITE :chest 📦
     ```
2. **Tier 2 — `8x8` Micro Sprites (4x Faster than `16x16`)**:
   - Bullets, sparks, coins, small items, hearts, status icons, and minimalist enemies should use `8x8` (`64` chars vs `256` chars for `16x16`):
     ```ruby
     @SPRITE :coin 8x8
     ..0000..
     .0AA7A0.
     0A997AA0
     0A997AA0
     0A999AA0
     0AA99AA0
     .0AAAA0.
     ..0000..
     ```
3. **Tier 3 — Compact / Auto-Padded `16x16` Sprites**:
   - For standard characters, enemies, and weapons, use `16x16` with simple flat fills.
   - Note: If you omit `16x16` in `@SPRITE :name`, the engine automatically normalizes width/height to the bounding box of the lines written and pads shorter rows with `.` on the right/bottom. When explicit `16x16` centering is needed, write 16×16 rows with symmetric `.` padding.

### Rule 5: Code-First Batch Output & Cheap Animation
- **No lengthy explanations**: Output the `__END__` sprite definitions immediately without per-sprite commentary.
- **Template Cloning for Batches**: When generating multiple similar sprites (e.g., 5 weapons, 4 slimes, 6 RPG classes), reuse the same base silhouette and swap only the weapon/hat/color codes.
- **1-Frame + `spr_ext` or 1-Row Shift**:
  - Default to **1 frame** per sprite and animate in Ruby using Squash & Stretch (`spr_ext(:mob, x, y, 0, sx, sy)`) or rotation (`spr_rot(:star, x, y, angle)`).
  - If a 2-frame animation (`---`) is requested, create Frame 2 by shifting the body down by 1 row or toggling 2 foot pixels (`00..00` ↔ `.0000.`).

---

## 2. Fast Color Combinations Cheat Sheet (`pal:0`)

| Material / Theme | Outline | Base Color | Highlight / Accent |
| :--- | :---: | :---: | :---: |
| **Slime / Goblin / Grass** | `0` | `B` (Green) | `7` (White) or `3` (Dark Green) |
| **Fire / Dragon / Potion** | `0` | `8` (Red) | `9` (Orange) / `A` (Yellow) |
| **Knight / Water / Ice** | `0` or `1` | `C` (Blue) | `7` (White) |
| **Gold / Coin / Lightning** | `0` or `4` | `A` (Yellow) | `7` (White) / `9` (Orange) |
| **Steel / Skeleton / Stone** | `0` | `6` (Light Grey) | `7` (White) / `5` (Dark Grey) |
| **Wood / Chest / Beast** | `0` | `4` (Brown) | `9` (Orange) / `F` (Peach) |
| **Dark / Demon / Bat** | `0` | `2` (Dark Purple) | `E` (Pink) / `8` (Red eyes) |

---

## 3. Ready-to-Use Fast Templates (Bulk Example)

```ruby
__END__
# --- Instant Emoji Tiles & Props ---
@SPRITE :wall 🧱
@SPRITE :tree 🌲
@SPRITE :torch 🔥 ✨

# --- 8x8 Micro Assets (Items / Projectiles) ---
@SPRITE :bullet 8x8
..0000..
.0A77A0.
0A7777A0
09A77A90
099AA990
.099990.
..0000..
........

@SPRITE :heart 8x8
.00..00.
08800880
08788880
08888880
.088880.
..0880..
...00...
........

@SPRITE :sword 8x8
.....000
....0670
...0670.
..0670..
00460...
.0940...
040.0...
00......

# --- 16x16 Flat Chibi Characters & Monsters ---
@SPRITE :hero 16x16
....00000000....
...0CCCCCCCC0...
..0CC77CCCCCC0..
..00FFFFFFFF00..
..0FF0FFFF0FF0..
...0FFFFFFFF0...
....00000000....
...00CCCCCC00...
..0FFCAAAACFF0..
..000CCCCCC000..
....0CC00CC0....
....04400440....
....000..000....
................
................
................

@SPRITE :slime 16x16
................
.....000000.....
...00BBBBBB00...
..0BB77BBBBBB0..
.0BBB7BBBBBBBB0.
.0BBB0BBBB0BBB0.
.0BBB0BBBB0BBB0.
.0BBBBBBBBBBBB0.
..033BBBBBB330..
...0000000000...
................
................
................
................
................
................

@SPRITE :bat 16x16
................
.00..........00.
0220..0000..0220
0222002222002220
0202228228222020
00.0222222220.00
....00222200....
.....00..00.....
................
................
................
................
................
................
................
................
```

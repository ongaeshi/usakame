---
name: usakame-sprite
description: >-
  Generate high-quality pixel art sprites, custom color palettes (@PALETTE), and sprite-generation prompts for the Usakame (uk) retro game engine.
  Use when the user asks to create, draw, generate, or prompt for rich, detailed Usakame sprites (16x16, 32x32, 48x48, @PALETTE custom palettes, @SPRITE text pattern, or PNG/SHEET). For fast bulk generation or lightweight prototyping, prefer usakame-sprite-fast.
---

# Usakame Sprite & Palette Designer

This skill guides the creation of high-quality pixel art sprites (`@SPRITE`), custom 16-color palettes (`@PALETTE`), and generation prompts optimized for the **Usakame (`uk`)** retro game engine.

> **When to use which skill:**
> - **`usakame-sprite` (this skill)**: Hero characters, bosses, key monsters, and rich 16-bit SNES/GBA-style pixel art with dedicated `@PALETTE` 3–4 step color ramps.
> - **`usakame-sprite-fast`**: Fast prototyping or bulk generation (5–20+ sprites at once) using standard palette `0`, flat 2–3 color shading, `8x8` micro sprites, and built-in emojis.

---

## 1. Usakame Graphics & Palette Specifications

| Property | Specification |
| :--- | :--- |
| **Base Tile Size** | `16 × 16` pixels (Supports `8x8` micro sprites and multiples of 16: `32x32`, `16x32`, `32x16`, `48x48`, etc.) |
| **Virtual Screen** | `256 × 256` pixels |
| **System Palette (ID 0)** | 16-color PICO-8 standard palette (immutable base palette) |
| **Custom Palettes (ID >= 1)** | `@PALETTE <id>` (inherits PICO-8 base colors; supports pinpoint diff overrides or full 16-color definitions) |
| **Sprite Declaration** | `@SPRITE :name [WIDTHxHEIGHT] pal:<pal_id>` (auto-packed) or `@SPRITE <id> [WIDTHxHEIGHT] pal:<pal_id>` |

### Standard 16-Color Base Palette Table (Palette `0`)

| Code | Hex | Name | Typical Usage |
| :---: | :---: | :--- | :--- |
| `.` | Transparent | Transparent | Sprite background / transparent pixels |
| `0` | `#000000` | Black | Outlines, pupils, deep shadows |
| `1` | `#1D2B53` | Dark Blue | Night outlines, cool shadows, armor |
| `2` | `#7E2553` | Dark Purple | Warm shadows, capes, robes |
| `3` | `#008751` | Dark Green | Vegetation shadow, slime, monsters |
| `4` | `#AB5236` | Brown | Wood, leather, skin shadow, hair |
| `5` | `#5F574F` | Dark Grey | Stone, metal shadow, outline substitute |
| `6` | `#C2C3C7` | Light Grey | Metal base, stone highlight |
| `7` | `#FFF1E8` | White | Highlights, whites of eyes, bright metal |
| `8` | `#FF004D` | Red | HP potions, capes, danger elements |
| `9` | `#FFA300` | Orange | Fire, leather highlight, autumn |
| `A` | `#FFEC27` | Yellow | Gold, coins, light sources, hair |
| `B` | `#00E436` | Green | Foliage, poison, slimes |
| `C` | `#29ADFF` | Blue | Mana, sky, water, magic |
| `D` | `#83769C` | Indigo | Sky shadow, mystical cloth |
| `E` | `#FF77A8` | Pink | Hearts, magic, blush |
| `F` | `#FFCCAA` | Peach | Skin tone, warm highlights |

---

## 2. Custom Palette System (`@PALETTE <id>` + `pal:<id>`)

Usakame supports **base-palette + diff override** custom palettes via `@PALETTE <id>` (`id >= 1`; ID `0` is reserved for the system palette and cannot be overwritten).

### Key Rules for Custom Palettes
1. **Base Palette Inheritance (Diff Management)**:
   - Every `@PALETTE <id>` starts with all 16 colors of the standard PICO-8 palette (`0`..`F`).
   - You only need to specify the color indices (`0`..`9`, `A`..`F`) that you want to customize! Unspecified indices keep their default PICO-8 colors.
2. **Pinpoint Override Syntax (Recommended)**:
   ```ruby
   @PALETTE 1
   1: #14182E  # Deep navy outline / shadow
   3: #006838  # Dark forest green (shadow)
   B: #00B858  # Mid emerald green (base)
   A: #78F878  # Bright mint green (highlight)
   8: #F83800  # Rich vermilion red
   2: #A81000  # Crimson shadow
   ```
   *(Inline syntax is also supported: `@PALETTE 1 3:#006838 B:#00B858 A:#78F878`)*
3. **Full 16-Color Syntax**:
   - You can also list 16 hex colors (`#RRGGBB`) in order from `0` to `F` across one or two lines.
4. **Linking a Sprite to a Palette**:
   - Append `pal:<pal_id>` to the `@SPRITE` header (prefer `:name` symbol declaration for automatic 2D slot packing):
     ```ruby
     @SPRITE :hero 16x16 pal:1
     ```
   - For multi-frame animations of the same character, separate frames with `---` inside a single `@SPRITE :name` block (or share the same `@PALETTE` ID across frames).
   - When adding sprites to an existing `.rb` or `.spr` file, check existing `@PALETTE` IDs first and pick an unused ID (`1`, `2`, `3`...) unless intentionally sharing an existing palette.

---

## 3. Capabilities & Workflows

Choose the appropriate workflow based on what the user requests:

### Workflow A: Direct Text Sprite & Palette Generation (`@PALETTE` + `@SPRITE`)
When the user asks to create, draw, or code a high-quality sprite for Usakame:
1. **Design a Custom Palette (`@PALETTE <id>`) When Appropriate**:
   - **Proactively generate a `@PALETTE <id>` block** alongside `@SPRITE :name [WIDTHxHEIGHT] pal:<id>` whenever the subject benefits from dedicated color ramps (e.g., specific character themes, monsters, food/items, elemental effects, rich 16-bit SNES/GBA-style shading) — unless the user explicitly asks to stick to default palette `0`.
   - Keep `0` (`#000000` or very dark `#100C1C`) for crisp outlines/pupils and `7` (`#FFF1E8` or `#FFFFFF`) for specular highlights, and override the color slots used by the sprite's main materials to form smooth 3-to-4-step shading ramps (Shadow -> Midtone -> Highlight).
2. **Write the `@SPRITE` Block**:
   - Prefer declarative symbol naming `@SPRITE :name [WIDTHxHEIGHT] pal:<pal_id>` so the engine automatically packs 2D slots (explicit integer IDs like `@SPRITE 0 16x16 pal:1` are also supported when needed).
   - Ensure each row has **exact character width** (e.g. 16 chars for `16x16`, 32 chars for `32x32`) and **exact row count**.
   - Follow the **4-Layer Shading Rule**: Outline (`0` or `1`), Shadow, Base Midtone, and Highlight.
3. **Output Ready-to-Use Code**:
   ```ruby
   __END__
   @PALETTE 1
   1: #181425  # Deep outline / dark shadow
   C: #285CC4  # Armor / slime shadow blue
   D: #4196FF  # Armor / slime midtone cyan-blue
   6: #8CF4FF  # Ice highlight cyan
   8: #E43B44  # Ruby core base
   2: #9E1F28  # Ruby core shadow

   @SPRITE :slime 16x16 pal:1
   ................
   .....111111.....
   ...11DDDDDD11...
   ..1DD66DDDDDD1..
   ..1D676DDDDCCD1.
   .1DDDDDDDDDCCCD1
   .1DDD1DDDD1DCCD1
   .1DDD1DDDD1DCCD1
   .1DDDDD88DDDDCD1
   .1DDDD8782DDDCD1
   ..1DDD8222DDCD1.
   ..1CCCCCCCCCCC1.
   ...11CCCCCCCC11.
   .....11111111...
   ................
   ................
   ```

### Workflow B: Image Generation AI Prompts
When the user asks for prompts to generate sprites with external image models (Midjourney, DALL-E 3, Stable Diffusion):
1. Provide optimized English prompts with the following structure:
   - **Art Style**: `pixel art sprite, 16-bit retro game style, PICO-8 / SNES aesthetic`
   - **Resolution**: `[16x16 / 32x32] pixel sprite, crisp clean pixels, sharp edges, no anti-aliasing`
   - **Color Limit**: `limited 16-color palette, distinct 3-step shading ramps, high contrast, vibrant colors`
   - **Framing**: `isolated on solid plain background, full body, game asset, 2D view`
2. Include negative prompts (e.g. `anti-aliasing, blur, gradient, 3d, realistic, smooth, high resolution, messy pixels`).
3. Explain how to import into Usakame:
   - Nearest-neighbor downscale to target 16-multiple size.
   - Run `uk encode <image.png> --id <id> --tile 16x16 >> game.rb`.

---

## 4. Design Principles for High Quality 16x16 / 32x32 Sprites

1. **Readability Over Detail**:
   - At `16x16`, use 2-head-tall (chibi) proportions with a bold, unmistakable silhouette.
   - Eyes should be 1–2 pixels (`0` or `1` with `7` highlight).
2. **Color Shading (Ramping)**:
   - **With Custom `@PALETTE` (Recommended)**:
     - Create 3-step or 4-step hue-shifted ramps (shift shadows slightly cooler/purpler, shift highlights slightly warmer/yellower).
     - Override unused PICO-8 indices (e.g., if a sprite doesn't need brown/pink, repurpose `4`, `E`, `D` for extra shading steps).
   - **With Standard PICO-8 Palette (`pal:0`)**:
     - Gold/Yellow: `A` (Yellow) -> `9` (Orange) -> `4` (Brown)
     - Metal: `7` (White) -> `6` (Light Grey) -> `5` (Dark Grey) -> `0` (Black)
     - Foliage: `B` (Green) -> `3` (Dark Green) -> `1` (Dark Blue)
     - Skin: `7` (Highlight) -> `F` (Peach) -> `4` / `E` (Shadow)
3. **Single-Pixel Clean Outlines**:
   - Avoid unintentional 2-pixel-thick corners (jaggies). Keep curves smooth and lines single-pixel sharp.

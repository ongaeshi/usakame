---
name: usakame-sprite
description: >-
  Generate high-quality pixel art sprites and sprite-generation prompts for the Usakame (uk) retro game engine.
  Use when the user asks to create, draw, generate, or prompt for Usakame sprites (16x16, 32x32, 48x48, 16-color PICO-8 palette, @SPRITE text pattern, or PNG/SHEET).
---

# Usakame Sprite Designer & Generator

This skill guides the creation of pixel art sprites and generation prompts optimized for the **Usakame (`uk`)** retro game engine.

---

## 1. Usakame Graphics Specifications

| Property | Specification |
| :--- | :--- |
| **Base Tile Size** | `16 × 16` pixels (Expandable in multiples of 16: `32x32`, `16x32`, `48x48`, etc.) |
| **Virtual Screen** | `256 × 256` pixels |
| **Default Palette** | 16-color PICO-8 standard palette |

### Standard 16-Color Palette Table

| Code | Hex | Name | Typical Usage |
| :---: | :---: | :--- | :--- |
| `.` | Transparent | Transparent | Sprite background / transparent parts |
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

## 2. Capabilities & Workflows

Choose the appropriate workflow based on what the user requests:

### Workflow A: Direct Text Sprite Generation (`@SPRITE`)
When the user asks to create or code a sprite directly in Ruby / `__END__`:
1. Use the `@SPRITE <id> [WIDTHxHEIGHT]` format.
2. Ensure each row has exactly the specified number of characters (e.g. 16 chars for 16x16, 32 chars for 32x32).
3. Follow the **4-Layer Rule**: Outline (`0` or `1`), Base Color, Highlight, and Shadow.
4. Output ready-to-paste code for `__END__`:
   ```ruby
   __END__
   @SPRITE 0 16x16
   ................
   ...000000000....
   ..07777777770...
   ...
   ```

### Workflow B: Image Generation AI Prompts
When the user asks for prompts to generate sprites with Midjourney, DALL-E 3, or Stable Diffusion:
1. Provide optimized English prompts with the following structure:
   - **Art Style**: `pixel art sprite, 16-bit retro game style, PICO-8 aesthetic`
   - **Resolution**: `[16x16 / 32x32] pixel sprite, crisp clean pixels, sharp edges, no anti-aliasing`
   - **Color Limit**: `limited 16-color palette, high contrast, vibrant colors`
   - **Framing**: `isolated on solid plain white background (or magenta background), full body, game asset, 2D view`
2. Include negative prompts (e.g. `anti-aliasing, blur, gradient, 3d, realistic, smooth, high resolution, messy pixels`).
3. Explain how to import into Usakame:
   - Nearest neighbor downscaling to target 16-multiple size.
   - Run `uk encode <image.png> --id <id> --tile 16x16 >> game.rb`.

---

## 3. Design Principles for High Quality 16x16 / 32x32

1. **Readability Over Detail**:
   - At 16x16, use 2-head-tall (chibi) proportions.
   - Eyes should be 1-2 pixels (`0` with `7` highlight).
   - Use bold silhouettes that communicate action even from across the room.
2. **Color Shading (Ramping)**:
   - Gold/Yellow: `A` (Yellow) -> `9` (Orange) -> `4` (Brown)
   - Metal: `7` (White) -> `6` (Light Grey) -> `5` (Dark Grey) -> `0` (Black)
   - Foliage: `B` (Green) -> `3` (Dark Green) -> `1` (Dark Blue)
   - Skin: `7` (Highlight) -> `F` (Peach) -> `4` / `E` (Shadow)
3. **Double Outline Avoidance**:
   - Avoid unintentional 2-pixel-thick outlines (jaggies). Keep lines single-pixel sharp.

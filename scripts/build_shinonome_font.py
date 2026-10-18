import urllib.request
import re
import sys

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    return urllib.request.urlopen(req).read().decode('latin1')

def parse_bdf_source(content, is_jis=False):
    """
    Parse BDF or font_src.bit content.
    Returns list of (codepoint, width, bitmap_bytes)
    """
    glyphs = []
    lines = content.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith('STARTCHAR'):
            encoding = None
            dwidth = 16
            bitmap_lines = []
            comment_char = None
            
            i += 1
            while i < len(lines):
                cur = lines[i].strip()
                if cur.startswith('ENCODING'):
                    parts = cur.split()
                    if len(parts) >= 2:
                        encoding = int(parts[1])
                elif cur.startswith('DWIDTH'):
                    parts = cur.split()
                    if len(parts) >= 2:
                        dwidth = int(parts[1])
                elif cur.startswith('BITMAP'):
                    i += 1
                    while i < len(lines):
                        bline = lines[i].strip()
                        if bline.startswith('ENDCHAR'):
                            if '#' in bline:
                                comment_char = bline.split('#', 1)[1].strip()
                            break
                        bitmap_lines.append(bline)
                        i += 1
                    break
                i += 1
            
            if encoding is not None and bitmap_lines:
                glyphs.append((encoding, dwidth, bitmap_lines, comment_char))
        i += 1
    return glyphs

def lines_to_bytes(bitmap_lines, width):
    """Convert '.' and '@' or hex into exactly 32 bytes."""
    data = bytearray(32)
    for y in range(min(16, len(bitmap_lines))):
        line = bitmap_lines[y]
        if line.startswith('.' ) or line.startswith('@') or line.startswith('#'):
            # Bit character format
            row_bits = 0
            for x, ch in enumerate(line):
                if ch in ('@', '#', '1', '*'):
                    row_bits |= (1 << (15 - x if width == 16 else 7 - x))
            if width == 16:
                data[y * 2] = (row_bits >> 8) & 0xFF
                data[y * 2 + 1] = row_bits & 0xFF
            else:
                data[y] = row_bits & 0xFF
        else:
            # Hex format
            try:
                val = int(line, 16)
                if width == 16:
                    data[y * 2] = (val >> 8) & 0xFF
                    data[y * 2 + 1] = val & 0xFF
                else:
                    data[y] = val & 0xFF
            except ValueError:
                pass
    return bytes(data)

def main():
    print("Fetching Shinonome font sources...")
    latin1_url = "https://raw.githubusercontent.com/code4fukui/shinonome-font/main/16/latin1/font_src.bit"
    hankaku_url = "https://raw.githubusercontent.com/code4fukui/shinonome-font/main/16/hankaku/font_src_diff.bit"
    kanji_url = "https://raw.githubusercontent.com/code4fukui/shinonome-font/main/16/kanjic/font_src.bit"

    latin1_raw = fetch(latin1_url)
    hankaku_raw = fetch(hankaku_url)
    kanji_raw = fetch(kanji_url)

    glyphs_by_cp = {} # cp -> (width, 32 bytes)

    # 1. Parse latin1 (ASCII / Latin1, width=8)
    for enc, dwidth, blines, _ in parse_bdf_source(latin1_raw):
        if 0x20 <= enc <= 0xFF:
            bs = lines_to_bytes(blines, 8)
            glyphs_by_cp[enc] = (8, bs)

    # 2. Parse hankaku diff (width=8, e.g. 0xA1..0xDF are JIS hankaku kana)
    # JIS X 0201 kana (0xA1..0xDF) map to Unicode 0xFF61..0xFF9F
    for enc, dwidth, blines, _ in parse_bdf_source(hankaku_raw):
        if 0xA1 <= enc <= 0xDF:
            unicode_cp = 0xFF61 + (enc - 0xA1)
            bs = lines_to_bytes(blines, 8)
            glyphs_by_cp[unicode_cp] = (8, bs)
        elif enc == 92: # Backslash or Yen
            glyphs_by_cp[0x5C] = (8, lines_to_bytes(blines, 8))
        elif enc == 126: # Tilde
            glyphs_by_cp[0x7E] = (8, lines_to_bytes(blines, 8))

    # 3. Parse kanji (JIS X 0208, width=16)
    kanji_list = parse_bdf_source(kanji_raw, is_jis=True)
    print(f"Loaded {len(kanji_list)} kanji glyphs, converting JIS to Unicode...")

    converted_kanji = 0
    for enc, dwidth, blines, comment_char in kanji_list:
        # JIS X 0208 code: high byte = enc >> 8, low byte = enc & 0xFF (e.g. 0x2121)
        # Note: BDF encoding for JIS X 0208 is often either 0x2121..0x7E7E or decimal.
        # Check if enc in decimal or hex:
        # In BDF, `STARTCHAR 2121` / `ENCODING 8481` (8481 is 0x2121 in decimal!)
        jis_high = enc >> 8
        jis_low = enc & 0xFF
        
        # Try decoding via iso2022_jp
        unicode_char = None
        if 0x21 <= jis_high <= 0x7E and 0x21 <= jis_low <= 0x7E:
            try:
                seq = b'\x1b\x24\x42' + bytes([jis_high, jis_low]) + b'\x1b\x28\x42'
                decoded = seq.decode('iso2022_jp')
                if decoded:
                    unicode_char = decoded[0]
            except Exception:
                pass
        
        # If iso2022_jp failed, check comment_char
        if not unicode_char and comment_char:
            try:
                # comment_char might be utf-8 decoded as latin1
                raw_bytes = comment_char.encode('latin1')
                unicode_char = raw_bytes.decode('utf-8')[0]
            except Exception:
                pass

        if unicode_char:
            cp = ord(unicode_char)
            if cp <= 0xFFFF:
                bs = lines_to_bytes(blines, 16)
                glyphs_by_cp[cp] = (16, bs)
                converted_kanji += 1

    print(f"Successfully mapped {converted_kanji} kanji glyphs.")
    print(f"Total unique glyphs in database: {len(glyphs_by_cp)}")

    # Sort by codepoint
    sorted_cps = sorted(glyphs_by_cp.keys())

    # Build binary file:
    # Header: "SHNM16" (6 bytes) + u16 count (2 bytes) = 8 bytes
    # Records: count * 35 bytes
    #   u16 codepoint (little-endian)
    #   u8 width (8 or 16)
    #   32 bytes bitmap
    out_path = "assets/shinonome_font.bin"
    with open(out_path, "wb") as f:
        f.write(b"SHNM16")
        f.write(len(sorted_cps).to_bytes(2, "little"))
        for cp in sorted_cps:
            width, bs = glyphs_by_cp[cp]
            f.write(cp.to_bytes(2, "little"))
            f.write(bytes([width]))
            f.write(bs)

    import os
    size = os.path.getsize(out_path)
    print(f"Generated {out_path}: {size} bytes ({size / 1024:.1f} KB)")

    # Write LICENSE
    with open("assets/LICENSE-SHINONOME.md", "w", encoding="utf-8") as f:
        f.write("""# 東雲フォント (Shinonome Font) ライセンス

本プロジェクトに収録されている `shinonome_font.bin` は、古川泰人氏および /efont/ プロジェクトによって作成された東雲フォント（ゴシック体 16x16 / 8x16）から生成されています。

東雲フォントは **パブリックドメイン (Public Domain)** として公開されています。

- 原作: 古川泰人 (Yasuyuki Furukawa)
- メンテナンス: /efont/ -- Efont Open Laboratory (2001)
- ライセンス: Public Domain（商用利用、改変、再配布、バイナリ埋め込み自由）
""")
    print("Created assets/LICENSE-SHINONOME.md")

if __name__ == "__main__":
    main()

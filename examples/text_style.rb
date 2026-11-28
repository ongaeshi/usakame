# Text Measure & Style Demo
#
# Demonstrates:
#   - text_width(str, size) / text_height(str, size)
#   - print_text(str, x, y, col, size, alpha, align, outline, shadow)
#   - Positional arguments (zero Hash/GC allocation per frame)
#
# Controls:
#   Left / Right : Cycle alignment (:left / :center / :right)
#   Z    : Toggle font size (8px / 16px)
#   X    : Toggle decoration (Outline / Shadow / Both / None)

config(
  title: "Text Measure & Style Demo",
  width: 320,
  height: 240
)

class TextStyleDemo
  def initialize
    @t = 0
    @aligns = [:left, :center, :right]
    @align_idx = 1
    @size = 8
    @deco_idx = 0
    @decos = [
      ["OUTLINE (0)", 0, nil],
      ["SHADOW (0)", nil, 0],
      ["OUTLINE+SHADOW", 0, 0],
      ["PLAIN", nil, nil]
    ]
    @samples = [
      "USAKAME ENGINE 🐰",
      "日本語とASCII混在: HP 120/120",
      "LINE 1: 勇者うさぎ\nLINE 2: SCORE 99990"
    ]
    @sample_idx = 0
  end

  def update
    @t += 1
    if btnp(:left)
      @align_idx = (@align_idx + @aligns.size - 1) % @aligns.size
    end
    if btnp(:right)
      @align_idx = (@align_idx + 1) % @aligns.size
    end
    if btnp(:up)
      @sample_idx = (@sample_idx + @samples.size - 1) % @samples.size
    end
    if btnp(:down)
      @sample_idx = (@sample_idx + 1) % @samples.size
    end
    if btnp(1)
      @size = (@size == 8) ? 16 : 8
    end
    if btnp(2)
      @deco_idx = (@deco_idx + 1) % @decos.size
    end
  end

  def draw
    # Bright striped background to show outline/shadow readability
    cls(1)
    y = 0
    while y < 240
      band_col = ((y / 16 + @t / 30) % 2 == 0) ? 12 : 6
      rectfill(0, y, 320, 16, band_col, 0.35)
      y += 16
    end

    # Header (centered with black outline)
    print_text("TEXT MEASURE & STYLE DEMO", 160, 8, 7, 8, 1.0, :center, 0)
    print_text("ARROWS:ALIGN/MSG  Z:SIZE  X:DECO", 160, 20, 10, 8, 1.0, :center, 0)

    # Current settings status
    align = @aligns[@align_idx]
    deco = @decos[@deco_idx]
    deco_name = deco[0]
    outline_col = deco[1]
    shadow_col = deco[2]

    info = "ALIGN: :" + align.to_s + "  SIZE: " + @size.to_s + "  DECO: " + deco_name
    print_text(info, 160, 34, 11, 8, 1.0, :center, 0)

    # Measured popup box
    msg = @samples[@sample_idx]
    mw = text_width(msg, @size)
    mh = text_height(msg, @size)

    anchor_x = 160
    anchor_y = 92
    box_x = if align == :left
              anchor_x - 6
            elsif align == :center
              anchor_x - mw / 2 - 6
            else
              anchor_x - mw - 6
            end
    box_y = anchor_y - 6
    box_w = mw + 12
    box_h = mh + 12

    rectfill(box_x, box_y, box_w, box_h, 1, 0.75)
    rect(box_x, box_y, box_w, box_h, 7, 1, 0.9)

    # Anchor guide line
    line(anchor_x, anchor_y - 14, anchor_x, anchor_y + mh + 14, 8, 1, 0.85)

    # Draw measured & styled text
    print_text(msg, anchor_x, anchor_y, 7, @size, 1.0, align, outline_col, shadow_col)

    # Display exact measured dimensions
    dim_str = "text_width=" + mw.to_s + "px  text_height=" + mh.to_s + "px"
    print_text(dim_str, 160, 164, 7, 8, 1.0, :center, 0, 0)

    # Side-by-side comparison at bottom
    print_text("LEFT", 12, 196, 7, 8, 1.0, :left, 0)
    print_text("CENTER", 160, 196, 10, 8, 1.0, :center, 0)
    print_text("RIGHT", 308, 196, 14, 8, 1.0, :right, 0)

    print_text("SHADOW ONLY", 160, 214, 7, 8, 1.0, :center, nil, 0)
  end
end

run TextStyleDemo.new

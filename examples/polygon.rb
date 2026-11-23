# ==========================================
# Usakame Sample: Polygon & Thick Line Demo
# 太線 (line/rect/tri width) & 多角形 (polyline/quad/poly) デモ
# 実行コマンド: uk run examples/polygon.rb
# ==========================================

class PolygonDemoScene
  def initialize
    @t = 0
    @steer = 0.0
    @flipper_l = 0.0
    @flipper_r = 0.0
    @width_boost = 0
    @star_pts = []
    20.times { @star_pts << 0 }
    @wave_pts = []
    34.times { @wave_pts << 0 }
  end

  def update
    @t += 1

    # 左右キーで3Dロードのカーブ操作
    if btn(0)
      @steer -= 0.08
    elsif btn(1)
      @steer += 0.08
    else
      @steer *= 0.90
    end
    @steer = -1.2 if @steer < -1.2
    @steer = 1.2 if @steer > 1.2

    # 上下キーで太さブースト調整
    @width_boost += 1 if btnp(2) && @width_boost < 4
    @width_boost -= 1 if btnp(3) && @width_boost > -1

    # Zキーでフリッパー跳ね上げ & ネオンビーム太線化
    target_l = btn(4) ? -0.65 : 0.35
    target_r = btn(4) ? 0.65 : -0.35
    @flipper_l += (target_l - @flipper_l) * 0.35
    @flipper_r += (target_r - @flipper_r) * 0.35
  end

  def draw
    cls(1)

    # 1. 擬似3D ロード（quadfill による台形ポリゴン連打・シームなし）
    horizon_y = 128
    road_strips = 14
    i = 0
    while i < road_strips
      t0 = i.to_f / road_strips
      t1 = (i + 1).to_f / road_strips
      # 手前ほど幅と高さが広がるパース計算
      z0 = t0 * t0
      z1 = t1 * t1
      y0 = horizon_y + (z0 * 128).to_i
      y1 = horizon_y + (z1 * 128).to_i

      curve0 = @steer * 36.0 * (1.0 - t0) * (1.0 - t0)
      curve1 = @steer * 36.0 * (1.0 - t1) * (1.0 - t1)
      cx0 = 128 + curve0.to_i
      cx1 = 128 + curve1.to_i
      w0 = 14 + (z0 * 108).to_i
      w1 = 14 + (z1 * 108).to_i

      # 交互に色が切り替わる路面（quadfill で1回描画）
      phase = (i + (@t / 4)) % 2
      road_col = (phase == 0) ? 5 : 0
      quadfill(
        cx0 - w0, y0,
        cx0 + w0, y0,
        cx1 + w1, y1,
        cx1 - w1, y1,
        road_col
      )

      # 路肩の縁石
      curb_col = (phase == 0) ? 8 : 7
      cw0 = (w0 / 8) + 2
      cw1 = (w1 / 8) + 2
      quadfill(cx0 - w0 - cw0, y0, cx0 - w0, y0, cx1 - w1, y1, cx1 - w1 - cw1, y1, curb_col)
      quadfill(cx0 + w0, y0, cx0 + w0 + cw0, y0, cx1 + w1 + cw1, y1, cx1 + w1, y1, curb_col)

      # センターライン
      if phase == 0
        mw0 = (w0 / 16) + 1
        mw1 = (w1 / 16) + 1
        quadfill(cx0 - mw0, y0, cx0 + mw0, y0, cx1 + mw1, y1, cx1 - mw1, y1, 10)
      end

      i += 1
    end

    # 2. 半透明の台形ビーム（quadfill + quad + blend(:add)）
    blend(:add)
    beam_w = 12 + (sin(@t * 0.12) * 8).to_i
    quadfill(128, 36, 128 + beam_w, 36, 160 + beam_w * 2, 128, 96 - beam_w, 128, 12, 0.35)
    quad(128, 36, 128 + beam_w, 36, 160 + beam_w * 2, 128, 96 - beam_w, 128, 7, 2 + @width_boost, 0.6)
    blend(:normal)

    # 3. 連続波形ビジュアライザー（polyline で太線一括描画）
    idx = 0
    while idx < 17
      px = 16 + idx * 14
      py = 88 + (sin(@t * 0.1 + idx * 0.55) * 14).to_i + (cos(@t * 0.07 - idx * 0.3) * 6).to_i
      @wave_pts[idx * 2] = px
      @wave_pts[idx * 2 + 1] = py
      idx += 1
    end
    blend(:add)
    polyline(@wave_pts, 11, 5 + @width_boost, 0.45)
    polyline(@wave_pts, 7, 2 + (@width_boost > 0 ? 1 : 0), 0.9)
    blend(:normal)

    # 4. 回転する凹星型ポリゴン（polyfill + poly）
    star_cx = 46
    star_cy = 58
    angle_base = @t * 0.03
    k = 0
    while k < 10
      ang = angle_base + k * 0.628318
      r = (k % 2 == 0) ? 22 : 10
      @star_pts[k * 2] = star_cx + (cos(ang) * r).to_i
      @star_pts[k * 2 + 1] = star_cy + (sin(ang) * r).to_i
      k += 1
    end
    polyfill(@star_pts, 9, 0.75)
    poly(@star_pts, 10, 2 + @width_boost, 0.95)

    # 5. 太線トライアングル（tri with width）
    tri_cx = 208
    tri_cy = 58
    ta = -@t * 0.04
    tx0 = tri_cx + (cos(ta) * 20).to_i
    ty0 = tri_cy + (sin(ta) * 20).to_i
    tx1 = tri_cx + (cos(ta + 2.094) * 20).to_i
    ty1 = tri_cy + (sin(ta + 2.094) * 20).to_i
    tx2 = tri_cx + (cos(ta + 4.188) * 20).to_i
    ty2 = tri_cy + (sin(ta + 4.188) * 20).to_i
    trifill(tx0, ty0, tx1, ty1, tx2, ty2, 2, 0.65)
    tri(tx0, ty0, tx1, ty1, tx2, ty2, 14, 3 + @width_boost, 0.95)

    # 6. ピンボール風フリッパー（line with width: 丸端点カプセル）
    fl_len = 34
    fl_w = btn(4) ? 7 + @width_boost : 5 + @width_boost
    lx1 = 76 + (cos(@flipper_l) * fl_len).to_i
    ly1 = 210 + (sin(@flipper_l) * fl_len).to_i
    rx1 = 180 - (cos(@flipper_r) * fl_len).to_i
    ry1 = 210 - (sin(@flipper_r) * fl_len).to_i

    line(76, 210, lx1, ly1, 12, fl_w)
    line(76, 210, lx1, ly1, 7, 2)
    line(180, 210, rx1, ry1, 12, fl_w)
    line(180, 210, rx1, ry1, 7, 2)

    # 7. UI ヘッダ（rect with width: 直角太枠）
    rectfill(4, 4, 248, 22, 0, 0.7)
    rect(4, 4, 248, 22, 12, 2, 0.9)
    print_text("POLYGON & THICK LINE DEMO", 12, 8, 10)
    print_text("W:+#{@width_boost}", 206, 8, 7)

    rectfill(4, 234, 248, 18, 0, 0.7)
    rect(4, 234, 248, 18, 5, 2, 0.85)
    print_text("L/R:STEER  U/D:WIDTH  Z:FLIPPER", 12, 239, 7)
  end
end

run PolygonDemoScene.new

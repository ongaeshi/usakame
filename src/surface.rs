use std::collections::HashMap;

use macroquad::prelude::*;

use crate::{BlendMode, DrawState, PaletteRgba, PixelSpan, apply_gl_blend, apply_gl_scissor};

pub const MAX_SURFACES: usize = 64;
pub const MAX_SURFACE_DIM: u32 = 2048;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceMode {
    Gpu,
    Pixel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DrawTarget {
    Screen,
    Surface(i32),
}

pub struct GpuSurface {
    pub width: u32,
    pub height: u32,
    pub render_target: Option<RenderTarget>,
    pub camera: Option<Camera2D>,
}

pub struct PixelSurface {
    pub width: u32,
    pub height: u32,
    /// パレット色インデックス (0..=15) または 255 = 透明
    pub pixels: Vec<u8>,
    pub dirty_min_x: u32,
    pub dirty_min_y: u32,
    pub dirty_max_x: u32,
    pub dirty_max_y: u32,
    pub is_dirty: bool,
    pub texture: Option<Texture2D>,
    pub cached_pal_map: [u8; 16],
    pub cached_palt_mask: u16,
    pub cached_palette_rgba: crate::PaletteRgba,
}

impl PixelSurface {
    pub fn new(width: u32, height: u32) -> Self {
        let len = (width as usize).saturating_mul(height as usize);
        Self {
            width,
            height,
            pixels: vec![255u8; len],
            dirty_min_x: 0,
            dirty_min_y: 0,
            dirty_max_x: width,
            dirty_max_y: height,
            is_dirty: true,
            texture: None,
            cached_pal_map: crate::DEFAULT_PAL_MAP,
            cached_palt_mask: 0,
            cached_palette_rgba: crate::PALETTE_RGBA,
        }
    }

    pub fn mark_all_dirty(&mut self) {
        self.dirty_min_x = 0;
        self.dirty_min_y = 0;
        self.dirty_max_x = self.width;
        self.dirty_max_y = self.height;
        self.is_dirty = true;
    }

    pub fn expand_dirty(&mut self, x0: u32, y0: u32, x1: u32, y1: u32) {
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        if !self.is_dirty {
            self.dirty_min_x = x0;
            self.dirty_min_y = y0;
            self.dirty_max_x = x1;
            self.dirty_max_y = y1;
            self.is_dirty = true;
        } else {
            self.dirty_min_x = self.dirty_min_x.min(x0);
            self.dirty_min_y = self.dirty_min_y.min(y0);
            self.dirty_max_x = self.dirty_max_x.max(x1);
            self.dirty_max_y = self.dirty_max_y.max(y1);
        }
    }

    pub fn clear(&mut self, col_idx: Option<u8>) {
        let val = col_idx.map(|c| c & 0x0F).unwrap_or(255);
        self.pixels.fill(val);
        self.mark_all_dirty();
    }

    #[inline]
    pub fn get_pixel(&self, x: i32, y: i32) -> Option<u8> {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return None;
        }
        let v = self.pixels[(y as usize) * (self.width as usize) + (x as usize)];
        if v < 16 { Some(v) } else { None }
    }

    #[inline]
    pub fn set_pixel(&mut self, x: i32, y: i32, col_idx: Option<u8>) {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return;
        }
        let ux = x as u32;
        let uy = y as u32;
        let val = col_idx.map(|c| c & 0x0F).unwrap_or(255);
        let idx = (uy as usize) * (self.width as usize) + (ux as usize);
        if self.pixels[idx] != val {
            self.pixels[idx] = val;
            self.expand_dirty(ux, uy, ux + 1, uy + 1);
        }
    }

    pub fn swap_pixels(&mut self, x0: i32, y0: i32, x1: i32, y1: i32) {
        let w = self.width as i32;
        let h = self.height as i32;
        if x0 < 0 || y0 < 0 || x0 >= w || y0 >= h || x1 < 0 || y1 < 0 || x1 >= w || y1 >= h {
            return;
        }
        let i0 = (y0 as usize) * (self.width as usize) + (x0 as usize);
        let i1 = (y1 as usize) * (self.width as usize) + (x1 as usize);
        if i0 != i1 && self.pixels[i0] != self.pixels[i1] {
            self.pixels.swap(i0, i1);
            self.expand_dirty(x0 as u32, y0 as u32, x0 as u32 + 1, y0 as u32 + 1);
            self.expand_dirty(x1 as u32, y1 as u32, x1 as u32 + 1, y1 as u32 + 1);
        }
    }

    pub fn blit_spans(&mut self, spans: &[PixelSpan], col_idx: Option<u8>) {
        let sw = self.width as i32;
        let sh = self.height as i32;
        let val = col_idx.map(|c| c & 0x0F).unwrap_or(255);
        for s in spans {
            if s.w <= 0 || s.h <= 0 {
                continue;
            }
            let x0 = s.x.max(0);
            let y0 = s.y.max(0);
            let x1 = s.x.saturating_add(s.w).min(sw);
            let y1 = s.y.saturating_add(s.h).min(sh);
            if x0 >= x1 || y0 >= y1 {
                continue;
            }
            for py in y0..y1 {
                let row_start = (py as usize) * (self.width as usize) + (x0 as usize);
                let row_end = (py as usize) * (self.width as usize) + (x1 as usize);
                self.pixels[row_start..row_end].fill(val);
            }
            self.expand_dirty(x0 as u32, y0 as u32, x1 as u32, y1 as u32);
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn blit_indexed_rect(
        &mut self,
        src: &[Option<u8>],
        src_stride: usize,
        src_u: i32,
        src_v: i32,
        src_w: i32,
        src_h: i32,
        dst_x: f32,
        dst_y: f32,
        flip_x: bool,
        flip_y: bool,
        rotate_deg: f32,
        scale_x: f32,
        scale_y: f32,
        state: &DrawState,
        alpha: f32,
    ) {
        if src_w <= 0 || src_h <= 0 || scale_x == 0.0 || scale_y == 0.0 || alpha <= 0.0 {
            return;
        }
        let erase = state.blend == BlendMode::Erase;
        if erase && alpha < 0.5 {
            return;
        }

        let (sx_abs, fx) = if scale_x < 0.0 {
            (-scale_x, !flip_x)
        } else {
            (scale_x, flip_x)
        };
        let (sy_abs, fy) = if scale_y < 0.0 {
            (-scale_y, !flip_y)
        } else {
            (scale_y, flip_y)
        };

        let clip_x0 = state.clip.map(|c| c.x.max(0)).unwrap_or(0);
        let clip_y0 = state.clip.map(|c| c.y.max(0)).unwrap_or(0);
        let clip_x1 = state
            .clip
            .map(|c| (c.x + c.w).min(self.width as i32))
            .unwrap_or(self.width as i32);
        let clip_y1 = state
            .clip
            .map(|c| (c.y + c.h).min(self.height as i32))
            .unwrap_or(self.height as i32);
        if clip_x0 >= clip_x1 || clip_y0 >= clip_y1 {
            return;
        }

        // 高速パス: 回転なし・等倍
        if (rotate_deg == 0.0 || !rotate_deg.is_finite())
            && (sx_abs - 1.0).abs() < 1e-4
            && (sy_abs - 1.0).abs() < 1e-4
        {
            let bx = dst_x.floor() as i32;
            let by = dst_y.floor() as i32;
            let dx0 = bx.max(clip_x0);
            let dy0 = by.max(clip_y0);
            let dx1 = (bx + src_w).min(clip_x1);
            let dy1 = (by + src_h).min(clip_y1);
            if dx0 >= dx1 || dy0 >= dy1 {
                return;
            }
            for py in dy0..dy1 {
                let ly = py - by;
                let sy = src_v + if fy { src_h - 1 - ly } else { ly };
                if sy < 0 {
                    continue;
                }
                let src_row = (sy as usize) * src_stride;
                let dst_row = (py as usize) * (self.width as usize);
                for px in dx0..dx1 {
                    let lx = px - bx;
                    let sx = src_u + if fx { src_w - 1 - lx } else { lx };
                    if sx < 0 {
                        continue;
                    }
                    if let Some(Some(raw_idx)) = src.get(src_row + (sx as usize)).copied() {
                        let mapped = state.pal_map[(raw_idx & 0x0F) as usize] & 0x0F;
                        if (state.palt_mask & (1 << mapped)) != 0 {
                            continue;
                        }
                        self.pixels[dst_row + (px as usize)] = if erase { 255 } else { mapped };
                    }
                }
            }
            self.expand_dirty(dx0 as u32, dy0 as u32, dx1 as u32, dy1 as u32);
            return;
        }

        // 汎用パス: 回転・拡縮あり（逆写像）
        let base_x = dst_x.floor();
        let base_y = dst_y.floor();
        let w_f = src_w as f32;
        let h_f = src_h as f32;
        let cx = base_x + w_f * 0.5;
        let cy = base_y + h_f * 0.5;
        let scaled_w = w_f * sx_abs;
        let scaled_h = h_f * sy_abs;
        let rad = if rotate_deg.is_finite() {
            rotate_deg.to_radians()
        } else {
            0.0
        };
        let cos_r = rad.cos();
        let sin_r = rad.sin();
        let half_bw = (scaled_w * cos_r.abs() + scaled_h * sin_r.abs()) * 0.5 + 1.0;
        let half_bh = (scaled_w * sin_r.abs() + scaled_h * cos_r.abs()) * 0.5 + 1.0;
        let dx0 = ((cx - half_bw).floor() as i32).max(clip_x0);
        let dy0 = ((cy - half_bh).floor() as i32).max(clip_y0);
        let dx1 = ((cx + half_bw).ceil() as i32).min(clip_x1);
        let dy1 = ((cy + half_bh).ceil() as i32).min(clip_y1);
        if dx0 >= dx1 || dy0 >= dy1 {
            return;
        }

        let mut touched = false;
        for py in dy0..dy1 {
            let dy_f = (py as f32 + 0.5) - cy;
            let dst_row = (py as usize) * (self.width as usize);
            for px in dx0..dx1 {
                let dx_f = (px as f32 + 0.5) - cx;
                let rx = (dx_f * cos_r + dy_f * sin_r) / sx_abs + w_f * 0.5;
                let ry = (-dx_f * sin_r + dy_f * cos_r) / sy_abs + h_f * 0.5;
                if rx < 0.0 || ry < 0.0 || rx >= w_f || ry >= h_f {
                    continue;
                }
                let lx = rx.floor() as i32;
                let ly = ry.floor() as i32;
                let sx = src_u + if fx { src_w - 1 - lx } else { lx };
                let sy = src_v + if fy { src_h - 1 - ly } else { ly };
                if sx < 0 || sy < 0 {
                    continue;
                }
                if let Some(Some(raw_idx)) = src.get((sy as usize) * src_stride + (sx as usize)).copied() {
                    let mapped = state.pal_map[(raw_idx & 0x0F) as usize] & 0x0F;
                    if (state.palt_mask & (1 << mapped)) != 0 {
                        continue;
                    }
                    self.pixels[dst_row + (px as usize)] = if erase { 255 } else { mapped };
                    touched = true;
                }
            }
        }
        if touched {
            self.expand_dirty(dx0 as u32, dy0 as u32, dx1 as u32, dy1 as u32);
        }
    }

    pub fn is_rect_solid(&self, x: i32, y: i32, w: i32, h: i32) -> bool {
        if w <= 0 || h <= 0 {
            return false;
        }
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = x.saturating_add(w).min(self.width as i32);
        let y1 = y.saturating_add(h).min(self.height as i32);
        if x0 >= x1 || y0 >= y1 {
            return false;
        }
        for py in y0..y1 {
            let row = (py as usize) * (self.width as usize);
            for px in x0..x1 {
                if self.pixels[row + (px as usize)] < 16 {
                    return true;
                }
            }
        }
        false
    }

    pub fn is_circle_solid(&self, cx: i32, cy: i32, r: i32) -> bool {
        if r < 0 {
            return false;
        }
        let r2 = (r as i64) * (r as i64);
        let x0 = (cx - r).max(0);
        let y0 = (cy - r).max(0);
        let x1 = (cx + r + 1).min(self.width as i32);
        let y1 = (cy + r + 1).min(self.height as i32);
        if x0 >= x1 || y0 >= y1 {
            return false;
        }
        for py in y0..y1 {
            let dy = (py - cy) as i64;
            let dy2 = dy * dy;
            let row = (py as usize) * (self.width as usize);
            for px in x0..x1 {
                let dx = (px - cx) as i64;
                if dx * dx + dy2 <= r2 && self.pixels[row + (px as usize)] < 16 {
                    return true;
                }
            }
        }
        false
    }

    pub fn raycast(&self, x0: i32, y0: i32, x1: i32, y1: i32) -> Option<(i32, i32, u8)> {
        let mut x = x0;
        let mut y = y0;
        let dx = (x1 - x0).abs();
        let dy = -(y1 - y0).abs();
        let sx = if x0 < x1 { 1 } else { -1 };
        let sy = if y0 < y1 { 1 } else { -1 };
        let mut err = dx + dy;
        loop {
            if let Some(col) = self.get_pixel(x, y) {
                return Some((x, y, col));
            }
            if x == x1 && y == y1 {
                break;
            }
            let e2 = 2 * err;
            if e2 >= dy {
                if x == x1 {
                    break;
                }
                err += dy;
                x += sx;
            }
            if e2 <= dx {
                if y == y1 {
                    break;
                }
                err += dx;
                y += sy;
            }
        }
        None
    }

    pub fn count_pixels(&self, col: Option<u8>, x: i32, y: i32, w: Option<i32>, h: Option<i32>) -> usize {
        let sw = self.width as i32;
        let sh = self.height as i32;
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = match w {
            Some(wv) => x.saturating_add(wv).min(sw),
            None => sw,
        };
        let y1 = match h {
            Some(hv) => y.saturating_add(hv).min(sh),
            None => sh,
        };
        if x0 >= x1 || y0 >= y1 {
            return 0;
        }
        let mut count = 0usize;
        match col {
            Some(target) => {
                let t = target & 0x0F;
                for py in y0..y1 {
                    let row = (py as usize) * (self.width as usize);
                    for px in x0..x1 {
                        if self.pixels[row + (px as usize)] == t {
                            count += 1;
                        }
                    }
                }
            }
            None => {
                for py in y0..y1 {
                    let row = (py as usize) * (self.width as usize);
                    for px in x0..x1 {
                        if self.pixels[row + (px as usize)] < 16 {
                            count += 1;
                        }
                    }
                }
            }
        }
        count
    }

    pub fn sync_texture(
        &mut self,
        pal_map: &[u8; 16],
        palt_mask: u16,
        palette_rgba: &PaletteRgba,
    ) -> Option<&Texture2D> {
        let pal_changed = self.cached_pal_map != *pal_map
            || self.cached_palt_mask != palt_mask
            || self.cached_palette_rgba != *palette_rgba;

        if self.texture.is_none() || pal_changed {
            let w = self.width as usize;
            let h = self.height as usize;
            let mut rgba = vec![0u8; w * h * 4];
            for (i, &p) in self.pixels.iter().enumerate() {
                if p < 16 {
                    let mapped = pal_map[p as usize] & 0x0F;
                    if (palt_mask & (1 << mapped)) == 0 {
                        let c = palette_rgba[mapped as usize];
                        let off = i * 4;
                        rgba[off] = c[0];
                        rgba[off + 1] = c[1];
                        rgba[off + 2] = c[2];
                        rgba[off + 3] = c[3];
                    }
                }
            }
            let image = Image {
                bytes: rgba,
                width: self.width as u16,
                height: self.height as u16,
            };
            let tex = Texture2D::from_image(&image);
            tex.set_filter(FilterMode::Nearest);
            self.texture = Some(tex);
            self.cached_pal_map = *pal_map;
            self.cached_palt_mask = palt_mask;
            self.cached_palette_rgba = *palette_rgba;
            self.is_dirty = false;
        } else if self.is_dirty && self.dirty_max_x > self.dirty_min_x && self.dirty_max_y > self.dirty_min_y {
            let dx = self.dirty_min_x;
            let dy = self.dirty_min_y;
            let dw = self.dirty_max_x - dx;
            let dh = self.dirty_max_y - dy;
            let mut rgba = vec![0u8; (dw as usize) * (dh as usize) * 4];
            for ry in 0..dh {
                let src_row = ((dy + ry) as usize) * (self.width as usize) + (dx as usize);
                let dst_row = (ry as usize) * (dw as usize);
                for rx in 0..dw {
                    let p = self.pixels[src_row + (rx as usize)];
                    if p < 16 {
                        let mapped = pal_map[p as usize] & 0x0F;
                        if (palt_mask & (1 << mapped)) == 0 {
                            let c = palette_rgba[mapped as usize];
                            let off = (dst_row + (rx as usize)) * 4;
                            rgba[off] = c[0];
                            rgba[off + 1] = c[1];
                            rgba[off + 2] = c[2];
                            rgba[off + 3] = c[3];
                        }
                    }
                }
            }
            let part = Image {
                bytes: rgba,
                width: dw as u16,
                height: dh as u16,
            };
            if let Some(ref tex) = self.texture {
                tex.update_part(&part, dx as i32, dy as i32, dw as i32, dh as i32);
            }
            self.is_dirty = false;
        }
        self.texture.as_ref()
    }
}

pub enum SurfaceEntry {
    Gpu(GpuSurface),
    Pixel(PixelSurface),
}

impl SurfaceEntry {
    pub fn dimensions(&self) -> (u32, u32) {
        match self {
            SurfaceEntry::Gpu(g) => (g.width, g.height),
            SurfaceEntry::Pixel(p) => (p.width, p.height),
        }
    }

    pub fn is_pixel(&self) -> bool {
        matches!(self, SurfaceEntry::Pixel(_))
    }
}

#[derive(Debug, Clone)]
pub struct TargetStackFrame {
    pub target: DrawTarget,
    pub saved_state: DrawState,
}

pub struct SurfaceStore {
    pub entries: HashMap<i32, SurfaceEntry>,
    next_id: i32,
    pub active_target: DrawTarget,
    pub stack: Vec<TargetStackFrame>,
    pub screen_camera: Option<Camera2D>,
    pub headless: bool,
}

impl SurfaceStore {
    pub fn new(headless: bool) -> Self {
        Self {
            entries: HashMap::new(),
            next_id: 1,
            active_target: DrawTarget::Screen,
            stack: Vec::new(),
            screen_camera: None,
            headless,
        }
    }

    pub fn set_screen_camera(&mut self, cam: Option<Camera2D>) {
        self.screen_camera = cam;
    }

    pub fn active_target(&self) -> DrawTarget {
        self.active_target
    }

    pub fn active_pixel_surface_id(&self) -> Option<i32> {
        if let DrawTarget::Surface(id) = self.active_target {
            if matches!(self.entries.get(&id), Some(SurfaceEntry::Pixel(_))) {
                return Some(id);
            }
        }
        None
    }

    pub fn active_camera(&self) -> Option<&Camera2D> {
        match self.active_target {
            DrawTarget::Screen => self.screen_camera.as_ref(),
            DrawTarget::Surface(id) => match self.entries.get(&id) {
                Some(SurfaceEntry::Gpu(g)) => g.camera.as_ref(),
                _ => None,
            },
        }
    }

    pub fn apply_active_gl_target(&self, state: &DrawState) {
        if self.headless {
            return;
        }
        if let Some(cam) = self.active_camera() {
            set_camera(cam);
        }
        apply_gl_scissor(state.clip);
        apply_gl_blend(state.blend);
    }

    pub fn create_surface(&mut self, w: u32, h: u32, mode: SurfaceMode) -> Result<i32, String> {
        if w == 0 || h == 0 || w > MAX_SURFACE_DIM || h > MAX_SURFACE_DIM {
            return Err(format!(
                "create_surface: invalid size {}x{} (must be 1..={})",
                w, h, MAX_SURFACE_DIM
            ));
        }
        if self.entries.len() >= MAX_SURFACES {
            return Err(format!(
                "create_surface: surface limit reached (max {})",
                MAX_SURFACES
            ));
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);

        match mode {
            SurfaceMode::Gpu => {
                let (rt, cam) = if !self.headless {
                    let rt = render_target(w, h);
                    rt.texture.set_filter(FilterMode::Nearest);
                    let mut cam = Camera2D::from_display_rect(Rect::new(0.0, 0.0, w as f32, h as f32));
                    cam.render_target = Some(rt.clone());
                    set_camera(&cam);
                    clear_background(Color::from_rgba(0, 0, 0, 0));
                    if let Some(prev_cam) = self.active_camera() {
                        set_camera(prev_cam);
                    }
                    (Some(rt), Some(cam))
                } else {
                    (None, None)
                };
                self.entries.insert(
                    id,
                    SurfaceEntry::Gpu(GpuSurface {
                        width: w,
                        height: h,
                        render_target: rt,
                        camera: cam,
                    }),
                );
            }
            SurfaceMode::Pixel => {
                self.entries
                    .insert(id, SurfaceEntry::Pixel(PixelSurface::new(w, h)));
            }
        }
        Ok(id)
    }

    pub fn free_surface(&mut self, id: i32, draw_state: &mut DrawState, screen_w: i32, screen_h: i32) -> bool {
        let removed = self.entries.remove(&id).is_some();
        if removed && self.active_target == DrawTarget::Surface(id) {
            self.active_target = DrawTarget::Screen;
            draw_state.screen_w = screen_w;
            draw_state.screen_h = screen_h;
            draw_state.reset_clip();
            draw_state.reset_blend();
            self.apply_active_gl_target(draw_state);
        }
        removed
    }

    pub fn surface_size(&self, id: i32) -> Option<(u32, u32)> {
        self.entries.get(&id).map(|e| e.dimensions())
    }

    pub fn clear_surface(
        &mut self,
        id: i32,
        col: Option<i32>,
        alpha: f32,
        state: &DrawState,
    ) -> Result<(), String> {
        let alpha = alpha.clamp(0.0, 1.0);
        let entry = self
            .entries
            .get_mut(&id)
            .ok_or_else(|| format!("clear_surface: invalid surface id {}", id))?;
        match entry {
            SurfaceEntry::Gpu(g) => {
                if !self.headless {
                    if let Some(ref cam) = g.camera {
                        let color = match col {
                            Some(c) if alpha > 0.0 => state.map_color_with_alpha(c, alpha),
                            _ => Color::from_rgba(0, 0, 0, 0),
                        };
                        set_camera(cam);
                        clear_background(color);
                        if let Some(prev_cam) = self.active_camera() {
                            set_camera(prev_cam);
                        }
                    }
                }
            }
            SurfaceEntry::Pixel(p) => {
                let col_idx = match col {
                    Some(c) if alpha > 0.0 => Some(state.map_color_index(c) as u8),
                    _ => None,
                };
                p.clear(col_idx);
            }
        }
        Ok(())
    }

    pub fn push_target(&mut self, id: i32, draw_state: &mut DrawState) -> Result<(), String> {
        let (w, h) = self
            .surface_size(id)
            .ok_or_else(|| format!("render_to: invalid surface id {}", id))?;
        let saved_state = *draw_state;
        self.stack.push(TargetStackFrame {
            target: self.active_target,
            saved_state,
        });
        self.active_target = DrawTarget::Surface(id);
        draw_state.cam_x = 0.0;
        draw_state.cam_y = 0.0;
        draw_state.clip = None;
        draw_state.blend = BlendMode::Normal;
        draw_state.screen_w = w as i32;
        draw_state.screen_h = h as i32;
        self.apply_active_gl_target(draw_state);
        Ok(())
    }

    pub fn pop_target(&mut self, draw_state: &mut DrawState) -> bool {
        if let Some(frame) = self.stack.pop() {
            self.active_target = frame.target;
            *draw_state = frame.saved_state;
            self.apply_active_gl_target(draw_state);
            true
        } else {
            false
        }
    }

    pub fn set_target(
        &mut self,
        id: Option<i32>,
        draw_state: &mut DrawState,
        screen_w: i32,
        screen_h: i32,
    ) -> Result<(), String> {
        match id {
            Some(surf_id) => {
                let (w, h) = self
                    .surface_size(surf_id)
                    .ok_or_else(|| format!("set_target: invalid surface id {}", surf_id))?;
                self.active_target = DrawTarget::Surface(surf_id);
                draw_state.cam_x = 0.0;
                draw_state.cam_y = 0.0;
                draw_state.clip = None;
                draw_state.blend = BlendMode::Normal;
                draw_state.screen_w = w as i32;
                draw_state.screen_h = h as i32;
            }
            None => {
                self.active_target = DrawTarget::Screen;
                draw_state.clip = None;
                draw_state.blend = BlendMode::Normal;
                draw_state.screen_w = screen_w;
                draw_state.screen_h = screen_h;
            }
        }
        self.apply_active_gl_target(draw_state);
        Ok(())
    }

    pub fn reset_to_screen_if_needed(
        &mut self,
        draw_state: &mut DrawState,
        screen_w: i32,
        screen_h: i32,
    ) {
        while let Some(frame) = self.stack.pop() {
            self.active_target = frame.target;
            *draw_state = frame.saved_state;
        }
        if self.active_target != DrawTarget::Screen {
            self.active_target = DrawTarget::Screen;
            draw_state.clip = None;
            draw_state.blend = BlendMode::Normal;
            draw_state.screen_w = screen_w;
            draw_state.screen_h = screen_h;
            self.apply_active_gl_target(draw_state);
        }
    }

    pub fn get_pixel_surface(&self, id: i32) -> Result<&PixelSurface, String> {
        match self.entries.get(&id) {
            Some(SurfaceEntry::Pixel(p)) => Ok(p),
            Some(SurfaceEntry::Gpu(_)) => Err(format!(
                "surface {} is a :gpu surface. Use create_surface(w, h, :pixel) for pixel queries.",
                id
            )),
            None => Err(format!("invalid surface id {}", id)),
        }
    }

    pub fn get_pixel_surface_mut(&mut self, id: i32) -> Result<&mut PixelSurface, String> {
        match self.entries.get_mut(&id) {
            Some(SurfaceEntry::Pixel(p)) => Ok(p),
            Some(SurfaceEntry::Gpu(_)) => Err(format!(
                "surface {} is a :gpu surface. Use create_surface(w, h, :pixel) for pixel operations.",
                id
            )),
            None => Err(format!("invalid surface id {}", id)),
        }
    }

    pub fn blit_spans_to_pixel(&mut self, id: i32, spans: &[PixelSpan], col_idx: Option<u8>) {
        if let Some(SurfaceEntry::Pixel(p)) = self.entries.get_mut(&id) {
            p.blit_spans(spans, col_idx);
        }
    }
}

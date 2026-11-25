use std::collections::HashMap;

use macroquad::prelude::*;

use crate::{BlendMode, DrawState, apply_gl_blend, apply_gl_scissor};

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

    pub fn clear(&mut self, col_idx: Option<u8>) {
        let val = col_idx.map(|c| c & 0x0F).unwrap_or(255);
        self.pixels.fill(val);
        self.mark_all_dirty();
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
}

use crate::ButtonId;

pub const MAX_GAMEPADS: usize = 4;

pub const PAD_LEFT: u8 = 1 << 0;
pub const PAD_RIGHT: u8 = 1 << 1;
pub const PAD_UP: u8 = 1 << 2;
pub const PAD_DOWN: u8 = 1 << 3;
pub const PAD_A: u8 = 1 << 4;
pub const PAD_B: u8 = 1 << 5;

#[cfg(target_arch = "wasm32")]
unsafe extern "C" {
    fn usakame_gamepad_poll() -> u32;
    fn usakame_gamepad_mask(slot: u32) -> u32;
}

pub struct GamepadState {
    pub current_down: [u8; MAX_GAMEPADS],
    pub prev_down: [u8; MAX_GAMEPADS],
    pub connected_count: usize,
    headless: bool,
    #[cfg(not(target_arch = "wasm32"))]
    gilrs: Option<gilrs::Gilrs>,
}

impl Default for GamepadState {
    fn default() -> Self {
        Self::new(true)
    }
}

impl GamepadState {
    pub fn new(headless: bool) -> Self {
        #[cfg(not(target_arch = "wasm32"))]
        let gilrs = if headless {
            None
        } else {
            gilrs::Gilrs::new().ok()
        };

        Self {
            current_down: [0; MAX_GAMEPADS],
            prev_down: [0; MAX_GAMEPADS],
            connected_count: 0,
            headless,
            #[cfg(not(target_arch = "wasm32"))]
            gilrs,
        }
    }

    pub fn poll(&mut self) {
        self.prev_down = self.current_down;
        self.current_down = [0; MAX_GAMEPADS];
        self.connected_count = 0;

        if self.headless {
            return;
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            const STICK_DEADZONE: f32 = 0.35;
            if let Some(ref mut gilrs) = self.gilrs {
                while gilrs.next_event().is_some() {}
                let mut slot = 0usize;
                for (_id, gamepad) in gilrs.gamepads() {
                    if !gamepad.is_connected() {
                        continue;
                    }
                    if slot >= MAX_GAMEPADS {
                        break;
                    }
                    let mut mask = 0u8;
                    if gamepad.is_pressed(gilrs::Button::DPadLeft) {
                        mask |= PAD_LEFT;
                    }
                    if gamepad.is_pressed(gilrs::Button::DPadRight) {
                        mask |= PAD_RIGHT;
                    }
                    if gamepad.is_pressed(gilrs::Button::DPadUp) {
                        mask |= PAD_UP;
                    }
                    if gamepad.is_pressed(gilrs::Button::DPadDown) {
                        mask |= PAD_DOWN;
                    }
                    if let Some(axis) = gamepad.axis_data(gilrs::Axis::LeftStickX) {
                        let v = axis.value();
                        if v < -STICK_DEADZONE {
                            mask |= PAD_LEFT;
                        } else if v > STICK_DEADZONE {
                            mask |= PAD_RIGHT;
                        }
                    }
                    if let Some(axis) = gamepad.axis_data(gilrs::Axis::LeftStickY) {
                        let v = axis.value();
                        // gilrs: LeftStickY positive = up, negative = down
                        if v > STICK_DEADZONE {
                            mask |= PAD_UP;
                        } else if v < -STICK_DEADZONE {
                            mask |= PAD_DOWN;
                        }
                    }
                    if gamepad.is_pressed(gilrs::Button::South) {
                        mask |= PAD_A;
                    }
                    if gamepad.is_pressed(gilrs::Button::East) {
                        mask |= PAD_B;
                    }
                    self.current_down[slot] = mask;
                    slot += 1;
                }
                self.connected_count = slot;
            }
        }

        #[cfg(target_arch = "wasm32")]
        {
            let count = unsafe { usakame_gamepad_poll() } as usize;
            self.connected_count = count.min(MAX_GAMEPADS);
            for slot in 0..self.connected_count {
                self.current_down[slot] = unsafe { usakame_gamepad_mask(slot as u32) } as u8;
            }
        }
    }

    pub fn set_frame_masks(&mut self, masks: [u8; MAX_GAMEPADS], connected_count: usize) {
        self.prev_down = self.current_down;
        self.current_down = masks;
        self.connected_count = connected_count.min(MAX_GAMEPADS);
    }

    pub fn connected_count(&self) -> usize {
        self.connected_count
    }

    fn button_bit(btn: ButtonId) -> Option<u8> {
        match btn {
            ButtonId::Left => Some(PAD_LEFT),
            ButtonId::Right => Some(PAD_RIGHT),
            ButtonId::Up => Some(PAD_UP),
            ButtonId::Down => Some(PAD_DOWN),
            ButtonId::A => Some(PAD_A),
            ButtonId::B => Some(PAD_B),
            _ => None,
        }
    }

    pub fn is_down(&self, player: usize, btn: ButtonId) -> bool {
        if player >= MAX_GAMEPADS {
            return false;
        }
        Self::button_bit(btn)
            .map(|bit| (self.current_down[player] & bit) != 0)
            .unwrap_or(false)
    }

    pub fn is_pressed(&self, player: usize, btn: ButtonId) -> bool {
        if player >= MAX_GAMEPADS {
            return false;
        }
        Self::button_bit(btn)
            .map(|bit| {
                (self.current_down[player] & bit) != 0 && (self.prev_down[player] & bit) == 0
            })
            .unwrap_or(false)
    }
}

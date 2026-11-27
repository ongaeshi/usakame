use std::collections::{HashMap, HashSet};
use std::f32::consts::TAU;
use std::fmt;

use macroquad::audio::{
    PlaySoundParams, Sound, load_sound_from_bytes, play_sound, set_sound_volume, stop_sound,
};
use mrubyedge::yamrb::value::RValue;
use mrubyedge::yamrb::vm::VM;

use crate::decode_base64;

pub const SAMPLE_RATE: u32 = 22050;
pub const NUM_SFX_CHANNELS: usize = 8;
pub const SFX_COOLDOWN_FRAMES: u64 = 2;

/// `@SFX` / `@MUSIC` 定義の識別キー（整数 ID または `:name` シンボル名）
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SoundKey {
    Id(i32),
    Name(String),
}

impl SoundKey {
    /// シンボル名を正規化する（先頭の `:` を除去し小文字化）
    pub fn normalize_name(name: &str) -> String {
        name.trim().trim_start_matches(':').to_ascii_lowercase()
    }

    /// `__END__` 内の `@SFX <key>` / `@MUSIC <key>` ヘッダのキー文字列をパースする
    /// - 整数: `SoundKey::Id(n)`
    /// - `:name`: `SoundKey::Name(name)`
    pub fn from_tail_token(tok: &str) -> Option<Self> {
        let trimmed = tok.trim();
        if trimmed.is_empty() {
            return None;
        }
        if let Ok(id) = trimmed.parse::<i32>() {
            return Some(Self::Id(id));
        }
        if let Some(rest) = trimmed.strip_prefix(':') {
            let name = Self::normalize_name(rest);
            if !name.is_empty()
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            {
                return Some(Self::Name(name));
            }
        }
        None
    }

    pub fn cache_tag(&self) -> String {
        match self {
            Self::Id(id) => format!("id:{}", id),
            Self::Name(name) => format!("name:{}", name),
        }
    }
}

impl fmt::Display for SoundKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Id(id) => write!(f, "{}", id),
            Self::Name(name) => write!(f, ":{}", name),
        }
    }
}

/// 8-bit レトロシンセの波形種別
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Waveform {
    #[default]
    Square,
    Pulse,
    Pulse12,
    Triangle,
    Saw,
    Noise,
    Organ,
    Phaser,
    Sine,
}

impl Waveform {
    pub fn from_name(name: &str) -> Option<Self> {
        let lower = name.trim().trim_start_matches('@').to_ascii_lowercase();
        match lower.as_str() {
            "square" | "sq" | "s" | "0" => Some(Self::Square),
            "pulse" | "p" | "1" => Some(Self::Pulse),
            "pulse12" | "p12" | "2" => Some(Self::Pulse12),
            "triangle" | "tri" | "t" | "3" => Some(Self::Triangle),
            "saw" | "sawtooth" | "w" | "4" => Some(Self::Saw),
            "noise" | "n" | "5" => Some(Self::Noise),
            "organ" | "o" | "6" => Some(Self::Organ),
            "phaser" | "ph" | "7" => Some(Self::Phaser),
            "sine" | "sin" | "8" => Some(Self::Sine),
            _ => None,
        }
    }

    #[inline]
    pub fn sample(self, phase: f32, phase2: f32, noise_val: f32) -> f32 {
        let p = phase.rem_euclid(1.0);
        match self {
            Self::Square => {
                if p < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            }
            Self::Pulse => {
                if p < 0.25 {
                    1.0
                } else {
                    -1.0
                }
            }
            Self::Pulse12 => {
                if p < 0.125 {
                    1.0
                } else {
                    -1.0
                }
            }
            Self::Triangle => {
                if p < 0.5 {
                    4.0 * p - 1.0
                } else {
                    3.0 - 4.0 * p
                }
            }
            Self::Saw => 2.0 * p - 1.0,
            Self::Noise => noise_val,
            Self::Organ => {
                let s1 = (p * TAU).sin();
                let s2 = (p * 2.0 * TAU).sin() * 0.5;
                let s3 = (p * 3.0 * TAU).sin() * 0.25;
                (s1 + s2 + s3) / 1.75
            }
            Self::Phaser => {
                let p2 = phase2.rem_euclid(1.0);
                let sq1 = if p < 0.5 { 1.0 } else { -1.0 };
                let sq2 = if p2 < 0.5 { 1.0 } else { -1.0 };
                (sq1 + sq2) * 0.5
            }
            Self::Sine => (p * TAU).sin(),
        }
    }
}

/// ノート単位のエフェクト
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NoteEffect {
    #[default]
    None,
    Slide,
    Vibrato,
    FadeOut,
    FadeIn,
    Drop,
    Arpeggio,
}

impl NoteEffect {
    pub fn from_name(name: &str) -> Option<Self> {
        let lower = name.trim().to_ascii_lowercase();
        match lower.as_str() {
            "none" | "n" => Some(Self::None),
            "slide" | "s" => Some(Self::Slide),
            "vibrato" | "vib" | "v" => Some(Self::Vibrato),
            "fade" | "fadeout" | "f" => Some(Self::FadeOut),
            "fadein" | "fi" => Some(Self::FadeIn),
            "drop" | "d" => Some(Self::Drop),
            "arp" | "arpeggio" | "a" => Some(Self::Arpeggio),
            _ => None,
        }
    }
}

/// 合成用の1ノート/ステップイベント
#[derive(Debug, Clone)]
pub struct SynthEvent {
    /// 周波数 (Hz)。0.0 以下は休符
    pub freq: f32,
    /// 長さ（秒）
    pub duration_sec: f32,
    /// 波形
    pub waveform: Waveform,
    /// 音量 (0.0 ..= 1.0)
    pub volume: f32,
    /// エフェクト
    pub effect: NoteEffect,
    /// 次のノートとタイで繋がっているか
    pub tied_next: bool,
}

/// 16-bit モノラル PCM サンプル列 (`i16`) を 44バイト RIFF WAV バイト列へ変換する
pub fn pcm_to_wav_bytes(samples: &[i16], sample_rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let file_len = 36 + data_len;
    let byte_rate = sample_rate * 2;
    let mut buf = Vec::with_capacity(44 + data_len as usize);

    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&file_len.to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // PCM format chunk size
    buf.extend_from_slice(&1u16.to_le_bytes()); // AudioFormat = 1 (PCM)
    buf.extend_from_slice(&1u16.to_le_bytes()); // NumChannels = 1 (Mono)
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes()); // BlockAlign = 2
    buf.extend_from_slice(&16u16.to_le_bytes()); // BitsPerSample = 16
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for &s in samples {
        buf.extend_from_slice(&s.to_le_bytes());
    }
    buf
}

/// 音名とオクターブ (`c2` = C4 = 261.63Hz) から周波数 (Hz) を計算する
pub fn note_to_freq(semitone_from_c: i32, octave: i32) -> f32 {
    // Pyxel / PICO-8 風に octave=2 の C を C4 (MIDI 60, 261.63Hz) とする
    let midi = (octave + 3) * 12 + semitone_from_c;
    440.0 * 2.0f32.powf((midi as f32 - 69.0) / 12.0)
}

/// `SynthEvent` の列から 16-bit PCM サンプル列を合成する
pub fn synthesize_events_pcm(events: &[SynthEvent]) -> Vec<i16> {
    let mut out = Vec::new();
    let sr = SAMPLE_RATE as f32;
    let mut phase = 0.0f32;
    let mut phase2 = 0.0f32;
    let mut lfsr: u16 = 0x7FFF;
    let mut noise_phase = 0.0f32;
    let mut noise_val = 0.5f32;
    let mut prev_freq: Option<f32> = None;

    for ev in events {
        let num_samples = ((ev.duration_sec * sr).round() as usize).max(1);
        if ev.freq <= 0.0 || ev.volume <= 0.0 {
            out.resize(out.len() + num_samples, 0);
            prev_freq = None;
            continue;
        }

        let start_freq = match (ev.effect, prev_freq) {
            (NoteEffect::Slide, Some(pf)) if pf > 0.0 => pf,
            _ => ev.freq,
        };

        for i in 0..num_samples {
            let t = i as f32 / num_samples as f32;
            let time_sec = i as f32 / sr;

            let mut cur_freq = match ev.effect {
                NoteEffect::Slide => start_freq + (ev.freq - start_freq) * t,
                NoteEffect::Drop => ev.freq * (1.0 - t * 0.85).max(0.05),
                NoteEffect::Arpeggio => {
                    let step = ((time_sec * 30.0) as i32).rem_euclid(3);
                    let ratio = match step {
                        1 => 2.0f32.powf(4.0 / 12.0),
                        2 => 2.0f32.powf(7.0 / 12.0),
                        _ => 1.0,
                    };
                    ev.freq * ratio
                }
                _ => ev.freq,
            };

            if ev.effect == NoteEffect::Vibrato {
                let vib = (time_sec * 6.5 * TAU).sin() * 0.025;
                cur_freq *= 1.0 + vib;
            }

            // エンベロープ（クリックノイズ防止 + エフェクトに応じた減衰）
            let attack_samples = (0.0025 * sr) as usize;
            let release_samples = if ev.tied_next {
                0
            } else {
                ((0.006 * sr) as usize).min(num_samples / 4)
            };

            let mut env = if i < attack_samples && prev_freq.is_none() {
                i as f32 / attack_samples.max(1) as f32
            } else if release_samples > 0 && i + release_samples >= num_samples {
                (num_samples - i) as f32 / release_samples.max(1) as f32
            } else {
                1.0
            };

            match ev.effect {
                NoteEffect::FadeOut => {
                    env *= 1.0 - t;
                }
                NoteEffect::FadeIn => {
                    env *= t;
                }
                _ => {
                    // レトロ音源らしい自然な微減衰
                    if !ev.tied_next {
                        env *= 1.0 - 0.18 * t;
                    }
                }
            }

            // LFSR ノイズ更新（周波数に連動したレートで更新）
            noise_phase += (cur_freq * 8.0) / sr;
            while noise_phase >= 1.0 {
                noise_phase -= 1.0;
                let bit = (lfsr ^ (lfsr >> 1)) & 1;
                lfsr = (lfsr >> 1) | (bit << 14);
                noise_val = if (lfsr & 1) != 0 { 0.85 } else { -0.85 };
            }

            let raw = ev.waveform.sample(phase, phase2, noise_val);
            phase = (phase + cur_freq / sr).rem_euclid(1.0);
            phase2 = (phase2 + (cur_freq * 1.008) / sr).rem_euclid(1.0);

            let sample_f = (raw * ev.volume * env * 0.38).clamp(-1.0, 1.0);
            out.push((sample_f * 32767.0) as i16);
        }

        prev_freq = Some(ev.freq);
    }

    out
}

/// 単音 `tone(freq, dur, wave, vol, slide)` 用の 16-bit PCM サンプル列を合成する
pub fn synthesize_tone_pcm(freq: f32, dur: f32, wave: Waveform, slide: f32) -> Vec<i16> {
    if !freq.is_finite() || !dur.is_finite() || freq <= 0.0 || dur <= 0.0 {
        return Vec::new();
    }
    let sr = SAMPLE_RATE as f32;
    let start_freq = freq.clamp(20.0, 20000.0);
    let dur_sec = dur.clamp(0.005, 10.0);
    let slide_hz = if slide.is_finite() { slide } else { 0.0 };
    let end_freq = (start_freq + slide_hz).clamp(20.0, 20000.0);
    let num_samples = ((dur_sec * sr).round() as usize).max(1);

    let mut out = Vec::with_capacity(num_samples);
    let mut phase = 0.0f32;
    let mut phase2 = 0.0f32;
    let mut lfsr: u16 = 0x7FFF;
    let mut noise_phase = 0.0f32;
    let mut noise_val = 0.5f32;

    let attack_samples = (0.0025 * sr) as usize;
    let release_samples = ((0.006 * sr) as usize).min(num_samples / 4);

    for i in 0..num_samples {
        let t = i as f32 / num_samples as f32;
        let cur_freq = start_freq + (end_freq - start_freq) * t;

        let mut env = if i < attack_samples {
            i as f32 / attack_samples.max(1) as f32
        } else if release_samples > 0 && i + release_samples >= num_samples {
            (num_samples - i) as f32 / release_samples.max(1) as f32
        } else {
            1.0
        };
        env *= 1.0 - 0.18 * t;

        noise_phase += (cur_freq * 8.0) / sr;
        while noise_phase >= 1.0 {
            noise_phase -= 1.0;
            let bit = (lfsr ^ (lfsr >> 1)) & 1;
            lfsr = (lfsr >> 1) | (bit << 14);
            noise_val = if (lfsr & 1) != 0 { 0.85 } else { -0.85 };
        }

        let raw = wave.sample(phase, phase2, noise_val);
        phase = (phase + cur_freq / sr).rem_euclid(1.0);
        phase2 = (phase2 + (cur_freq * 1.008) / sr).rem_euclid(1.0);

        let sample_f = (raw * env * 0.38).clamp(-1.0, 1.0);
        out.push((sample_f * 32767.0) as i16);
    }

    out
}

/// 既存の 16-bit PCM サンプル列にピッチ倍率 (`0.25..=4.0`) を線形補間リサンプリングで適用する
pub fn apply_pitch_to_pcm(pcm: &[i16], pitch: f32) -> Vec<i16> {
    if pcm.is_empty() {
        return Vec::new();
    }
    let p = if pitch.is_finite() {
        pitch.clamp(0.25, 4.0)
    } else {
        1.0
    };
    if (p - 1.0).abs() < 0.001 {
        return pcm.to_vec();
    }
    let out_len = ((pcm.len() as f32 / p).round() as usize).max(1);
    let mut out = Vec::with_capacity(out_len);
    let last_idx = pcm.len() - 1;
    for i in 0..out_len {
        let pos = i as f32 * p;
        let idx = (pos.floor() as usize).min(last_idx);
        let frac = pos - idx as f32;
        let s0 = pcm[idx] as f32;
        let s1 = pcm[(idx + 1).min(last_idx)] as f32;
        let val = s0 + (s1 - s0) * frac;
        out.push(val.round().clamp(-32768.0, 32767.0) as i16);
    }
    out
}

// ==========================================
// プリセット効果音（サウンド版「絵文字」）
// ==========================================

/// 内蔵プリセット効果音（代表名）の一覧
pub const BUILTIN_SFX_PRESETS: &[&str] = &[
    "jump",
    "coin",
    "laser",
    "shoot",
    "explode",
    "explosion",
    "hit",
    "powerup",
    "select",
    "confirm",
    "cancel",
    "click",
    "slash",
    "splash",
    "clear",
    "gameover",
    "heal",
    "miss",
    "pause",
    "dash",
    "bell",
    "step",
];

/// 指定した名前（先頭 `:` 有無・大小文字不問）が内蔵プリセット（エイリアス含む）かどうか
pub fn is_builtin_preset(name: &str) -> bool {
    let key = SoundKey::normalize_name(name);
    matches!(
        key.as_str(),
        "jump"
            | "coin"
            | "pickup"
            | "laser"
            | "shoot"
            | "explode"
            | "explosion"
            | "boom"
            | "hit"
            | "damage"
            | "hurt"
            | "powerup"
            | "select"
            | "blip"
            | "cursor"
            | "confirm"
            | "ok"
            | "decide"
            | "cancel"
            | "back"
            | "no"
            | "click"
            | "slash"
            | "sword"
            | "swing"
            | "cut"
            | "splash"
            | "water"
            | "bubble"
            | "clear"
            | "win"
            | "victory"
            | "stage_clear"
            | "gameover"
            | "lose"
            | "heal"
            | "recover"
            | "potion"
            | "miss"
            | "error"
            | "ng"
            | "buzzer"
            | "pause"
            | "dash"
            | "boost"
            | "warp"
            | "bell"
            | "chime"
            | "ring"
            | "step"
            | "walk"
            | "footstep"
    )
}

/// プリセット効果音名（`:jump`, `:coin` 等）から PCM サンプル列を合成する
pub fn synthesize_preset_pcm(name: &str, pitch_mul: f32, speed_mul: f32, vol_mul: f32) -> Option<Vec<i16>> {
    let key = SoundKey::normalize_name(name);
    let p = pitch_mul.clamp(0.25, 4.0);
    let s = speed_mul.clamp(0.25, 4.0);
    let v = vol_mul.clamp(0.0, 1.5);

    let events: Vec<SynthEvent> = match key.as_str() {
        "jump" => vec![
            SynthEvent {
                freq: 180.0 * p,
                duration_sec: 0.03 / s,
                waveform: Waveform::Pulse,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 620.0 * p,
                duration_sec: 0.13 / s,
                waveform: Waveform::Pulse,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::Slide,
                tied_next: false,
            },
        ],
        "coin" | "pickup" => vec![
            SynthEvent {
                freq: 987.77 * p, // B5
                duration_sec: 0.075 / s,
                waveform: Waveform::Square,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 1318.51 * p, // E6
                duration_sec: 0.26 / s,
                waveform: Waveform::Square,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "laser" | "shoot" => vec![
            SynthEvent {
                freq: 880.0 * p,
                duration_sec: 0.02 / s,
                waveform: Waveform::Square,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 160.0 * p,
                duration_sec: 0.12 / s,
                waveform: Waveform::Square,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::Slide,
                tied_next: false,
            },
        ],
        "explode" | "explosion" | "boom" => vec![
            SynthEvent {
                freq: 220.0 * p,
                duration_sec: 0.06 / s,
                waveform: Waveform::Noise,
                volume: (0.95 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 95.0 * p,
                duration_sec: 0.34 / s,
                waveform: Waveform::Noise,
                volume: (0.95 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "hit" | "damage" | "hurt" => vec![
            SynthEvent {
                freq: 300.0 * p,
                duration_sec: 0.04 / s,
                waveform: Waveform::Noise,
                volume: (0.9 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 110.0 * p,
                duration_sec: 0.10 / s,
                waveform: Waveform::Saw,
                volume: (0.85 * v).min(1.0),
                effect: NoteEffect::Drop,
                tied_next: false,
            },
        ],
        "powerup" => {
            let notes = [330.0, 392.0, 659.25, 523.25, 587.33, 1046.5];
            notes
                .iter()
                .enumerate()
                .map(|(idx, &f)| SynthEvent {
                    freq: f * p,
                    duration_sec: 0.055 / s,
                    waveform: Waveform::Pulse,
                    volume: (0.8 * v).min(1.0),
                    effect: if idx + 1 == notes.len() {
                        NoteEffect::FadeOut
                    } else {
                        NoteEffect::None
                    },
                    tied_next: idx + 1 < notes.len(),
                })
                .collect()
        }
        "select" | "blip" | "cursor" => vec![SynthEvent {
            freq: 660.0 * p,
            duration_sec: 0.045 / s,
            waveform: Waveform::Square,
            volume: (0.75 * v).min(1.0),
            effect: NoteEffect::FadeOut,
            tied_next: false,
        }],
        "confirm" | "ok" | "decide" => vec![
            SynthEvent {
                freq: 523.25 * p, // C5
                duration_sec: 0.045 / s,
                waveform: Waveform::Square,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 783.99 * p, // G5
                duration_sec: 0.12 / s,
                waveform: Waveform::Square,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "cancel" | "back" | "no" => vec![
            SynthEvent {
                freq: 392.0 * p, // G4
                duration_sec: 0.05 / s,
                waveform: Waveform::Triangle,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 261.63 * p, // C4
                duration_sec: 0.11 / s,
                waveform: Waveform::Triangle,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "click" => vec![SynthEvent {
            freq: 1200.0 * p,
            duration_sec: 0.015 / s,
            waveform: Waveform::Pulse12,
            volume: (0.7 * v).min(1.0),
            effect: NoteEffect::FadeOut,
            tied_next: false,
        }],
        "slash" | "sword" | "swing" | "cut" => vec![
            SynthEvent {
                freq: 1400.0 * p,
                duration_sec: 0.025 / s,
                waveform: Waveform::Noise,
                volume: (0.85 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 320.0 * p,
                duration_sec: 0.085 / s,
                waveform: Waveform::Noise,
                volume: (0.8 * v).min(1.0),
                effect: NoteEffect::Slide,
                tied_next: false,
            },
        ],
        "splash" | "water" | "bubble" => vec![
            SynthEvent {
                freq: 420.0 * p,
                duration_sec: 0.04 / s,
                waveform: Waveform::Noise,
                volume: (0.7 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: true,
            },
            SynthEvent {
                freq: 320.0 * p,
                duration_sec: 0.04 / s,
                waveform: Waveform::Sine,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 680.0 * p,
                duration_sec: 0.08 / s,
                waveform: Waveform::Sine,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::Slide,
                tied_next: false,
            },
        ],
        "clear" | "win" | "victory" | "stage_clear" => {
            let notes = [523.25, 659.25, 783.99, 1046.5]; // C5 E5 G5 C6
            notes
                .iter()
                .enumerate()
                .map(|(idx, &f)| SynthEvent {
                    freq: f * p,
                    duration_sec: if idx + 1 == notes.len() { 0.32 / s } else { 0.08 / s },
                    waveform: Waveform::Square,
                    volume: (0.8 * v).min(1.0),
                    effect: if idx + 1 == notes.len() {
                        NoteEffect::FadeOut
                    } else {
                        NoteEffect::None
                    },
                    tied_next: false,
                })
                .collect()
        }
        "heal" | "recover" | "potion" => {
            let notes = [523.25, 659.25, 783.99, 987.77, 1318.51];
            notes
                .iter()
                .enumerate()
                .map(|(idx, &f)| SynthEvent {
                    freq: f * p,
                    duration_sec: 0.055 / s,
                    waveform: Waveform::Triangle,
                    volume: (0.8 * v).min(1.0),
                    effect: if idx + 1 == notes.len() {
                        NoteEffect::FadeOut
                    } else {
                        NoteEffect::None
                    },
                    tied_next: idx + 1 < notes.len(),
                })
                .collect()
        }
        "miss" | "error" | "ng" | "buzzer" => vec![
            SynthEvent {
                freq: 150.0 * p,
                duration_sec: 0.09 / s,
                waveform: Waveform::Saw,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 110.0 * p,
                duration_sec: 0.16 / s,
                waveform: Waveform::Saw,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "pause" => vec![
            SynthEvent {
                freq: 659.25 * p,
                duration_sec: 0.05 / s,
                waveform: Waveform::Square,
                volume: (0.72 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 523.25 * p,
                duration_sec: 0.05 / s,
                waveform: Waveform::Square,
                volume: (0.72 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 659.25 * p,
                duration_sec: 0.09 / s,
                waveform: Waveform::Square,
                volume: (0.72 * v).min(1.0),
                effect: NoteEffect::FadeOut,
                tied_next: false,
            },
        ],
        "dash" | "boost" | "warp" => vec![
            SynthEvent {
                freq: 240.0 * p,
                duration_sec: 0.03 / s,
                waveform: Waveform::Noise,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: true,
            },
            SynthEvent {
                freq: 820.0 * p,
                duration_sec: 0.12 / s,
                waveform: Waveform::Pulse,
                volume: (0.78 * v).min(1.0),
                effect: NoteEffect::Slide,
                tied_next: false,
            },
        ],
        "bell" | "chime" | "ring" => vec![SynthEvent {
            freq: 1046.5 * p, // C6
            duration_sec: 0.35 / s,
            waveform: Waveform::Organ,
            volume: (0.78 * v).min(1.0),
            effect: NoteEffect::FadeOut,
            tied_next: false,
        }],
        "step" | "walk" | "footstep" => vec![SynthEvent {
            freq: 140.0 * p,
            duration_sec: 0.035 / s,
            waveform: Waveform::Noise,
            volume: (0.55 * v).min(1.0),
            effect: NoteEffect::FadeOut,
            tied_next: false,
        }],
        "gameover" | "lose" => vec![
            SynthEvent {
                freq: 392.0 * p, // G4
                duration_sec: 0.16 / s,
                waveform: Waveform::Saw,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 369.99 * p, // F#4
                duration_sec: 0.16 / s,
                waveform: Waveform::Saw,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 349.23 * p, // F4
                duration_sec: 0.16 / s,
                waveform: Waveform::Saw,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::None,
                tied_next: false,
            },
            SynthEvent {
                freq: 329.63 * p, // E4
                duration_sec: 0.42 / s,
                waveform: Waveform::Saw,
                volume: (0.75 * v).min(1.0),
                effect: NoteEffect::Vibrato,
                tied_next: false,
            },
        ],
        _ => return None,
    };

    Some(synthesize_events_pcm(&events))
}

// ==========================================
// シンセレシピ (`wave:square freq:440->880 dur:0.15 env:decay`)
// ==========================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RecipeEnvelope {
    #[default]
    Decay,
    Attack,
    Flat,
    Punch,
    Drop,
    Vibrato,
    Arpeggio,
}

impl RecipeEnvelope {
    pub fn from_name(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "decay" | "fade" | "fadeout" | "d" | "f" => Some(Self::Decay),
            "attack" | "fadein" | "fi" => Some(Self::Attack),
            "flat" | "none" | "sustain" | "n" => Some(Self::Flat),
            "punch" | "perc" | "sharp" => Some(Self::Punch),
            "drop" => Some(Self::Drop),
            "vibrato" | "vib" | "v" => Some(Self::Vibrato),
            "arp" | "arpeggio" | "a" => Some(Self::Arpeggio),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SynthRecipe {
    pub wave: Waveform,
    pub freqs: Vec<f32>,
    pub duration_sec: f32,
    pub volume: f32,
    pub env: RecipeEnvelope,
    pub slide_hz: Option<f32>,
}

impl Default for SynthRecipe {
    fn default() -> Self {
        Self {
            wave: Waveform::Square,
            freqs: vec![440.0],
            duration_sec: 0.15,
            volume: 0.8,
            env: RecipeEnvelope::Decay,
            slide_hz: None,
        }
    }
}

fn is_recipe_key(key: &str) -> bool {
    matches!(
        key.to_ascii_lowercase().as_str(),
        "wave"
            | "w"
            | "waveform"
            | "inst"
            | "freq"
            | "f"
            | "dur"
            | "d"
            | "duration"
            | "vol"
            | "v"
            | "volume"
            | "env"
            | "e"
            | "envelope"
            | "effect"
            | "fx"
            | "slide"
            | "sweep"
    )
}

fn parse_freq_number(s: &str) -> Result<f32, String> {
    let trimmed = s.trim();
    let num_str = trimmed
        .strip_suffix("hz")
        .or_else(|| trimmed.strip_suffix("Hz"))
        .or_else(|| trimmed.strip_suffix("HZ"))
        .unwrap_or(trimmed);
    let val = num_str
        .parse::<f32>()
        .map_err(|_| format!("Invalid frequency '{}'", s))?;
    if !val.is_finite() || val <= 0.0 {
        return Err(format!("Frequency must be > 0 (got '{}')", s));
    }
    Ok(val.clamp(20.0, 20000.0))
}

fn parse_duration_sec(s: &str) -> Result<f32, String> {
    let trimmed = s.trim();
    let (num_str, scale) = if let Some(ms) = trimmed
        .strip_suffix("ms")
        .or_else(|| trimmed.strip_suffix("MS"))
    {
        (ms, 0.001)
    } else if let Some(sec) = trimmed.strip_suffix('s').or_else(|| trimmed.strip_suffix('S')) {
        (sec, 1.0)
    } else {
        (trimmed, 1.0)
    };
    let val = num_str
        .parse::<f32>()
        .map_err(|_| format!("Invalid duration '{}'", s))?;
    if !val.is_finite() || val <= 0.0 {
        return Err(format!("Duration must be > 0 (got '{}')", s));
    }
    Ok((val * scale).clamp(0.005, 10.0))
}

/// トークン列が Key-Value シンセレシピ記法（`wave:square freq:440->880 ...`）かどうか判定・パースする。
/// - `Ok(Some(recipe))`: シンセレシピとして有効
/// - `Ok(None)`: シンセレシピではない（MML 等として扱う）
/// - `Err(msg)`: シンセレシピとして書かれているが値等に構文エラーがある
pub fn try_parse_synth_recipe(spec: &str) -> Result<Option<SynthRecipe>, String> {
    let mut tokens = Vec::new();
    for raw_line in spec.lines() {
        let line = strip_sound_comment(raw_line);
        if line.is_empty() {
            continue;
        }
        for tok in line.split_whitespace() {
            tokens.push(tok);
        }
    }
    if tokens.is_empty() {
        return Ok(None);
    }

    let mut has_recipe_indicator = false;
    let mut all_kv_like = true;
    for tok in &tokens {
        if let Some((k, _)) = tok.split_once(':') {
            if is_recipe_key(k) {
                if matches!(
                    k.to_ascii_lowercase().as_str(),
                    "freq" | "f" | "dur" | "d" | "duration" | "env" | "e" | "envelope" | "slide" | "sweep"
                ) {
                    has_recipe_indicator = true;
                }
            } else {
                all_kv_like = false;
            }
        } else {
            all_kv_like = false;
        }
    }

    if !has_recipe_indicator && !all_kv_like {
        return Ok(None);
    }

    let mut recipe = SynthRecipe::default();
    for tok in tokens {
        let Some((k_raw, v)) = tok.split_once(':') else {
            return Err(format!("Unexpected token '{}' in synth recipe (expected key:value)", tok));
        };
        if v.is_empty() {
            return Err(format!("Missing value for key '{}' in synth recipe", k_raw));
        }
        match k_raw.to_ascii_lowercase().as_str() {
            "wave" | "w" | "waveform" | "inst" => {
                recipe.wave = Waveform::from_name(v)
                    .ok_or_else(|| format!("Unknown waveform '{}' in synth recipe", v))?;
            }
            "freq" | "f" => {
                let mut freqs = Vec::new();
                for part in v.split("->") {
                    if part.is_empty() {
                        return Err(format!("Incomplete frequency sweep '{}'", v));
                    }
                    freqs.push(parse_freq_number(part)?);
                }
                recipe.freqs = freqs;
            }
            "dur" | "d" | "duration" => {
                recipe.duration_sec = parse_duration_sec(v)?;
            }
            "vol" | "v" | "volume" => {
                let vol = v
                    .parse::<f32>()
                    .map_err(|_| format!("Invalid volume '{}' in synth recipe", v))?;
                if !vol.is_finite() || vol < 0.0 {
                    return Err(format!("Volume must be >= 0 (got '{}')", v));
                }
                recipe.volume = if vol > 1.0 {
                    (vol / 7.0).clamp(0.0, 1.0)
                } else {
                    vol.clamp(0.0, 1.0)
                };
            }
            "env" | "e" | "envelope" | "effect" | "fx" => {
                recipe.env = RecipeEnvelope::from_name(v)
                    .ok_or_else(|| format!("Unknown envelope '{}' in synth recipe", v))?;
            }
            "slide" | "sweep" => {
                let sl = v
                    .parse::<f32>()
                    .map_err(|_| format!("Invalid slide '{}' in synth recipe", v))?;
                if !sl.is_finite() {
                    return Err(format!("Invalid slide '{}' in synth recipe", v));
                }
                recipe.slide_hz = Some(sl);
            }
            _ => {
                return Err(format!("Unknown synth recipe key '{}'", k_raw));
            }
        }
    }

    Ok(Some(recipe))
}

/// `SynthRecipe` から 16-bit PCM サンプル列を合成する
pub fn synthesize_recipe_pcm(recipe: &SynthRecipe) -> Vec<i16> {
    let sr = SAMPLE_RATE as f32;
    let num_samples = ((recipe.duration_sec * sr).round() as usize).max(1);
    let mut out = Vec::with_capacity(num_samples);

    let mut freqs = recipe.freqs.clone();
    if freqs.is_empty() {
        freqs.push(440.0);
    }
    if freqs.len() == 1
        && let Some(slide) = recipe.slide_hz
    {
        freqs.push((freqs[0] + slide).clamp(20.0, 20000.0));
    }

    let mut phase = 0.0f32;
    let mut phase2 = 0.0f32;
    let mut lfsr: u16 = 0x7FFF;
    let mut noise_phase = 0.0f32;
    let mut noise_val = 0.5f32;

    let attack_samples = (0.0025 * sr) as usize;
    let release_samples = ((0.006 * sr) as usize).min(num_samples / 4);

    for i in 0..num_samples {
        let t = i as f32 / num_samples as f32;
        let time_sec = i as f32 / sr;

        // 周波数スイープ（1点なら固定、2点以上なら区間線形補間）
        let mut cur_freq = if freqs.len() == 1 {
            freqs[0]
        } else {
            let segs = freqs.len() - 1;
            let scaled = (t * segs as f32).clamp(0.0, segs as f32);
            let idx = (scaled.floor() as usize).min(segs - 1);
            let local_t = scaled - idx as f32;
            freqs[idx] + (freqs[idx + 1] - freqs[idx]) * local_t
        };

        match recipe.env {
            RecipeEnvelope::Drop => {
                cur_freq *= (1.0 - t * 0.85).max(0.05);
            }
            RecipeEnvelope::Vibrato => {
                cur_freq *= 1.0 + (time_sec * 6.5 * TAU).sin() * 0.025;
            }
            RecipeEnvelope::Arpeggio => {
                let step = ((time_sec * 30.0) as i32).rem_euclid(3);
                let ratio = match step {
                    1 => 2.0f32.powf(4.0 / 12.0),
                    2 => 2.0f32.powf(7.0 / 12.0),
                    _ => 1.0,
                };
                cur_freq *= ratio;
            }
            _ => {}
        }

        let mut env = if i < attack_samples {
            i as f32 / attack_samples.max(1) as f32
        } else if release_samples > 0 && i + release_samples >= num_samples {
            (num_samples - i) as f32 / release_samples.max(1) as f32
        } else {
            1.0
        };

        match recipe.env {
            RecipeEnvelope::Decay => env *= 1.0 - t,
            RecipeEnvelope::Punch => env *= (1.0 - t) * (1.0 - t),
            RecipeEnvelope::Attack => env *= t,
            RecipeEnvelope::Flat | RecipeEnvelope::Drop | RecipeEnvelope::Vibrato | RecipeEnvelope::Arpeggio => {
                env *= 1.0 - 0.18 * t;
            }
        }

        noise_phase += (cur_freq * 8.0) / sr;
        while noise_phase >= 1.0 {
            noise_phase -= 1.0;
            let bit = (lfsr ^ (lfsr >> 1)) & 1;
            lfsr = (lfsr >> 1) | (bit << 14);
            noise_val = if (lfsr & 1) != 0 { 0.85 } else { -0.85 };
        }

        let raw = recipe.wave.sample(phase, phase2, noise_val);
        phase = (phase + cur_freq / sr).rem_euclid(1.0);
        phase2 = (phase2 + (cur_freq * 1.008) / sr).rem_euclid(1.0);

        let sample_f = (raw * recipe.volume * env * 0.38).clamp(-1.0, 1.0);
        out.push((sample_f * 32767.0) as i16);
    }

    out
}

// ==========================================
// MML / ノート文字列パーサ
// ==========================================

/// 行内コメントを除去する。`#` は行頭または空白の直後にある場合のみコメント扱い（`c#` のシャープは保持）
pub fn strip_sound_comment(raw_line: &str) -> &str {
    let bytes = raw_line.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'#' && (i == 0 || bytes[i - 1].is_ascii_whitespace()) {
            return raw_line[..i].trim();
        }
    }
    raw_line.trim()
}

fn parse_semitone(note_char: char, accidental: Option<char>) -> Option<i32> {
    let base = match note_char.to_ascii_lowercase() {
        'c' => 0,
        'd' => 2,
        'e' => 4,
        'f' => 5,
        'g' => 7,
        'a' => 9,
        'b' => 11,
        _ => return None,
    };
    let offset = match accidental {
        Some('#') | Some('+') => 1,
        Some('-') => -1,
        _ => 0,
    };
    Some(base + offset)
}

/// `@SFX` のテキスト定義またはインライン文字列から PCM サンプル列を生成する
pub fn parse_and_synthesize_sfx_pcm(spec: &str) -> Vec<i16> {
    let trimmed = spec.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    // プリセット指定のチェック (`:jump`, `jump pitch=1.2` 等)
    let mut tokens_iter = trimmed.split_whitespace();
    if let Some(first_tok) = tokens_iter.next() {
        let candidate = first_tok.trim_start_matches(':');
        let mut pitch_mul = 1.0f32;
        let mut speed_mul = 1.0f32;
        let mut vol_mul = 1.0f32;
        let mut all_kv = true;
        for tok in tokens_iter {
            if let Some((k, v)) = tok.split_once('=') {
                match k.to_ascii_lowercase().as_str() {
                    "pitch" | "p" => pitch_mul = v.parse::<f32>().unwrap_or(1.0),
                    "speed" | "s" => speed_mul = v.parse::<f32>().unwrap_or(1.0),
                    "vol" | "volume" | "v" => vol_mul = v.parse::<f32>().unwrap_or(1.0),
                    _ => {}
                }
            } else {
                all_kv = false;
            }
        }
        if all_kv
            && let Some(pcm) = synthesize_preset_pcm(candidate, pitch_mul, speed_mul, vol_mul)
        {
            return pcm;
        }
    }

    // Key-Value シンセレシピ記法 (`wave:square freq:440->880 dur:0.15 env:decay`) のチェック
    if let Ok(Some(recipe)) = try_parse_synth_recipe(trimmed) {
        return synthesize_recipe_pcm(&recipe);
    }

    let mut waveform = Waveform::Square;
    let mut speed: f32 = 6.0; // 1ステップ = speed / 60.0 秒 (speed=6 -> 0.1秒)
    let mut tempo_bpm: Option<f32> = None;
    let mut default_len: f32 = 4.0;
    let mut current_octave: i32 = 2; // c2 = C4
    let mut current_vol: f32 = 6.0 / 7.0;
    let mut default_effect = NoteEffect::None;
    let mut mml_mode = false;

    let mut note_tokens: Vec<String> = Vec::new();

    for raw_line in trimmed.lines() {
        let line = strip_sound_comment(raw_line);
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() == 2 {
            let k = parts[0].to_ascii_lowercase();
            let v = parts[1];
            match k.as_str() {
                "wave" | "waveform" | "instrument" | "inst" => {
                    if let Some(w) = Waveform::from_name(v) {
                        waveform = w;
                        continue;
                    }
                }
                "speed" | "spd" => {
                    if let Ok(s) = v.parse::<f32>() {
                        speed = s.clamp(1.0, 120.0);
                        continue;
                    }
                }
                "tempo" | "bpm" => {
                    if let Ok(bpm) = v.parse::<f32>() {
                        tempo_bpm = Some(bpm.clamp(20.0, 400.0));
                        mml_mode = true;
                        continue;
                    }
                }
                "vol" | "volume" => {
                    if let Ok(vol) = v.parse::<f32>() {
                        current_vol = if vol > 1.0 {
                            (vol / 7.0).clamp(0.0, 1.0)
                        } else {
                            vol.clamp(0.0, 1.0)
                        };
                        continue;
                    }
                }
                "effect" | "fx" => {
                    if let Some(fx) = NoteEffect::from_name(v) {
                        default_effect = fx;
                        continue;
                    }
                }
                _ => {}
            }
        }

        for tok in parts {
            if let Some((k, v)) = tok.split_once('=') {
                match k.to_ascii_lowercase().as_str() {
                    "wave" | "w" => {
                        if let Some(w) = Waveform::from_name(v) {
                            waveform = w;
                        }
                    }
                    "speed" | "spd" | "s" => {
                        if let Ok(s) = v.parse::<f32>() {
                            speed = s.clamp(1.0, 120.0);
                        }
                    }
                    "tempo" | "bpm" | "t" => {
                        if let Ok(bpm) = v.parse::<f32>() {
                            tempo_bpm = Some(bpm.clamp(20.0, 400.0));
                            mml_mode = true;
                        }
                    }
                    "vol" | "volume" | "v" => {
                        if let Ok(vol) = v.parse::<f32>() {
                            current_vol = if vol > 1.0 {
                                (vol / 7.0).clamp(0.0, 1.0)
                            } else {
                                vol.clamp(0.0, 1.0)
                            };
                        }
                    }
                    "effect" | "fx" => {
                        if let Some(fx) = NoteEffect::from_name(v) {
                            default_effect = fx;
                        }
                    }
                    _ => {}
                }
            } else if let Some(w) = Waveform::from_name(tok) {
                waveform = w;
            } else {
                let upper = tok.to_ascii_uppercase();
                if let Some(num_s) = upper.strip_prefix('T')
                    && let Ok(bpm) = num_s.parse::<f32>()
                {
                    tempo_bpm = Some(bpm.clamp(20.0, 400.0));
                    mml_mode = true;
                } else if let Some(num_s) = upper.strip_prefix('L')
                    && let Ok(l) = num_s.parse::<f32>()
                {
                    default_len = l.clamp(1.0, 64.0);
                    mml_mode = true;
                } else if let Some(num_s) = upper.strip_prefix('O')
                    && let Ok(o) = num_s.parse::<i32>()
                {
                    current_octave = o.clamp(0, 7) - 2;
                    mml_mode = true;
                } else if tok == "<" || tok == ">" {
                    mml_mode = true;
                    note_tokens.push(tok.to_string());
                } else {
                    note_tokens.push(tok.to_string());
                }
            }
        }
    }

    let mut events = Vec::new();
    let step_sec = if let Some(bpm) = tempo_bpm {
        (60.0 / bpm) * (4.0 / default_len)
    } else {
        (speed / 60.0).max(0.01)
    };

    // トークン間にスペースが無い連結記法 (`"c2e2g2c3"` 等) も展開してパースする
    for raw_tok in note_tokens {
        parse_note_token_into_events(
            &raw_tok,
            &mut waveform,
            &mut current_octave,
            &mut current_vol,
            default_effect,
            step_sec,
            tempo_bpm,
            default_len,
            mml_mode,
            &mut events,
        );
    }

    // 連続するノートに Slide 指定がある場合は前のノートの tied_next を有効化する
    for i in 1..events.len() {
        if events[i].effect == NoteEffect::Slide && events[i].freq > 0.0 && events[i - 1].freq > 0.0
        {
            events[i - 1].tied_next = true;
        }
    }

    synthesize_events_pcm(&events)
}

#[allow(clippy::too_many_arguments)]
fn parse_note_token_into_events(
    raw_tok: &str,
    waveform: &mut Waveform,
    current_octave: &mut i32,
    current_vol: &mut f32,
    default_effect: NoteEffect,
    step_sec: f32,
    tempo_bpm: Option<f32>,
    default_len: f32,
    mml_mode: bool,
    events: &mut Vec<SynthEvent>,
) {
    // `:fade`, `:slide`, `:vib`, `:drop`, `:arp` 等のサフィックスを分離
    let mut note_part = raw_tok;
    let mut effect = default_effect;
    let mut mult_steps = 1.0f32;

    if let Some((head, suffix)) = raw_tok.split_once(':') {
        note_part = head;
        for part in suffix.split(':') {
            if let Some(fx) = NoteEffect::from_name(part) {
                effect = fx;
            } else if let Some(w) = Waveform::from_name(part) {
                *waveform = w;
            } else if let Ok(n) = part.parse::<f32>() {
                mult_steps = n.clamp(0.25, 64.0);
            }
        }
    }

    if let Some((head, mul_str)) = note_part.split_once('*') {
        note_part = head;
        if let Ok(m) = mul_str.parse::<f32>() {
            mult_steps *= m.clamp(0.25, 64.0);
        }
    }

    let chars: Vec<char> = note_part.chars().collect();
    let mut idx = 0;

    while idx < chars.len() {
        let ch = chars[idx];
        let lower = ch.to_ascii_lowercase();

        if ch == '>' {
            *current_octave = (*current_octave + 1).min(6);
            idx += 1;
            continue;
        }
        if ch == '<' {
            *current_octave = (*current_octave - 1).max(-2);
            idx += 1;
            continue;
        }
        if lower == 'v' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && (chars[idx].is_ascii_digit() || chars[idx] == '.') {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if let Ok(v) = num_s.parse::<f32>() {
                *current_vol = (v / 7.0).clamp(0.0, 1.0);
            }
            continue;
        }
        if lower == 'o' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if let Ok(o) = num_s.parse::<i32>() {
                *current_octave = o.clamp(0, 7) - 2;
            }
            continue;
        }
        if matches!(lower, 'r' | '.' | '-' | '_') {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            let dur = if mml_mode && !num_s.is_empty() {
                let len_val = num_s.parse::<f32>().unwrap_or(default_len).max(1.0);
                let bpm = tempo_bpm.unwrap_or(120.0);
                (60.0 / bpm) * (4.0 / len_val)
            } else if !num_s.is_empty() {
                let count = num_s.parse::<f32>().unwrap_or(1.0).clamp(1.0, 64.0);
                step_sec * count * mult_steps
            } else {
                step_sec * mult_steps
            };
            events.push(SynthEvent {
                freq: 0.0,
                duration_sec: dur,
                waveform: *waveform,
                volume: 0.0,
                effect: NoteEffect::None,
                tied_next: false,
            });
            continue;
        }
        if ch == '~' {
            if let Some(last) = events.last_mut() {
                last.duration_sec += step_sec;
            }
            idx += 1;
            continue;
        }

        if matches!(lower, 'a'..='g') {
            idx += 1;
            let mut accidental = None;
            if idx < chars.len() && matches!(chars[idx], '#' | '+' | '-') {
                accidental = Some(chars[idx]);
                idx += 1;
            }
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            let mut dotted = false;
            if idx < chars.len() && chars[idx] == '.' {
                dotted = true;
                idx += 1;
            }
            let mut sustain_ties = 0usize;
            while idx < chars.len() && chars[idx] == '~' {
                sustain_ties += 1;
                idx += 1;
            }

            if let Some(semi) = parse_semitone(lower, accidental) {
                let (oct, dur) = if mml_mode {
                    let len_val = if num_s.is_empty() {
                        default_len
                    } else {
                        num_s.parse::<f32>().unwrap_or(default_len).max(1.0)
                    };
                    let bpm = tempo_bpm.unwrap_or(120.0);
                    let mut d = (60.0 / bpm) * (4.0 / len_val) * mult_steps;
                    if dotted {
                        d *= 1.5;
                    }
                    d += sustain_ties as f32 * step_sec;
                    (*current_octave, d)
                } else {
                    let oct_val = if num_s.is_empty() {
                        *current_octave
                    } else {
                        num_s.parse::<i32>().unwrap_or(*current_octave).clamp(0, 7)
                    };
                    *current_octave = oct_val;
                    let mut d = step_sec * mult_steps * (1 + sustain_ties) as f32;
                    if dotted {
                        d *= 1.5;
                    }
                    (oct_val, d)
                };

                let freq = note_to_freq(semi, oct);
                events.push(SynthEvent {
                    freq,
                    duration_sec: dur,
                    waveform: *waveform,
                    volume: *current_vol,
                    effect,
                    tied_next: false,
                });
            }
        } else {
            idx += 1;
        }
    }
}

// ==========================================
// SFX / MUSIC データ構造とミキサー
// ==========================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SfxData {
    pub spec: String,
    pub pcm: Vec<i16>,
    pub wav_bytes: Vec<u8>,
}

impl SfxData {
    pub fn from_spec(spec: &str) -> Self {
        let pcm = parse_and_synthesize_sfx_pcm(spec);
        let wav_bytes = pcm_to_wav_bytes(&pcm, SAMPLE_RATE);
        Self {
            spec: spec.trim().to_string(),
            pcm,
            wav_bytes,
        }
    }

    pub fn from_raw_wav_bytes(spec_tag: &str, wav_bytes: Vec<u8>) -> Self {
        // WAV データ(16-bit mono 44バイトヘッダ想定)から簡易的に PCM も抽出しておく（@MUSIC ミキシング用）
        let mut pcm = Vec::new();
        if wav_bytes.len() > 44 && &wav_bytes[0..4] == b"RIFF" {
            for chunk in wav_bytes[44..].chunks_exact(2) {
                pcm.push(i16::from_le_bytes([chunk[0], chunk[1]]));
            }
        }
        Self {
            spec: spec_tag.to_string(),
            pcm,
            wav_bytes,
        }
    }

    pub fn duration_sec(&self) -> f32 {
        self.pcm.len() as f32 / SAMPLE_RATE as f32
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MusicData {
    pub spec: String,
    pub pcm: Vec<i16>,
    pub wav_bytes: Vec<u8>,
}

/// 複数チャンネルの PCM トラックを加算合成・クリッピング防止して1本の PCM にミックスする
pub fn mix_pcm_tracks(tracks: &[Vec<i16>]) -> Vec<i16> {
    let max_len = tracks.iter().map(|t| t.len()).max().unwrap_or(0);
    if max_len == 0 {
        return Vec::new();
    }
    let active_count = tracks.iter().filter(|t| !t.is_empty()).count().max(1);
    let scale = match active_count {
        1 => 1.0f32,
        2 => 0.78f32,
        3 => 0.65f32,
        _ => 0.56f32,
    };

    let mut mixed = vec![0i16; max_len];
    for i in 0..max_len {
        let mut sum = 0.0f32;
        for track in tracks {
            if let Some(&s) = track.get(i) {
                sum += s as f32;
            }
        }
        mixed[i] = (sum * scale).clamp(-32767.0, 32767.0) as i16;
    }
    mixed
}

impl MusicData {
    /// `@MUSIC` のテキストブロックと定義済み `sfx_map` から BGM を合成する
    /// 1) `ch0 ...` / `ch1 ...` のインラインマルチトラック記法
    /// 2) `0 1 2 .` や `:kick :snare . .` のような SFX パターン並び記法
    /// の両方をサポートする
    pub fn from_spec(spec: &str, sfx_map: &HashMap<SoundKey, SfxData>) -> Self {
        let mut ch_specs: [Vec<String>; 4] = Default::default();
        let mut pattern_rows: Vec<[Option<SoundKey>; 4]> = Vec::new();

        for raw_line in spec.lines() {
            let line = strip_sound_comment(raw_line);
            if line.is_empty() {
                continue;
            }
            let lower = line.to_ascii_lowercase();
            if lower.starts_with("loop") || lower == "end" {
                continue;
            }

            // `ch0 ...` または `ch0: ...` のチェック
            let mut matched_ch = false;
            for (ch_idx, prefix) in ["ch0", "ch1", "ch2", "ch3"].iter().enumerate() {
                if lower.starts_with(prefix) {
                    let after = line[prefix.len()..].trim().trim_start_matches(':').trim();
                    if !after.is_empty() {
                        ch_specs[ch_idx].push(after.to_string());
                        matched_ch = true;
                        break;
                    }
                }
            }
            if matched_ch {
                continue;
            }

            // パターン行 (`0 1 2 .` または `10, 11, -1, -1` または `:kick :snare . .`)
            let tokens: Vec<&str> = line
                .split(|c: char| c.is_ascii_whitespace() || c == ',' || c == '|')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();
            if !tokens.is_empty()
                && tokens.iter().all(|t| {
                    matches!(*t, "." | "-" | "_")
                        || t.parse::<i32>().is_ok()
                        || SoundKey::from_tail_token(t).is_some()
                })
            {
                let mut row: [Option<SoundKey>; 4] = Default::default();
                for (i, tok) in tokens.iter().take(4).enumerate() {
                    row[i] = if matches!(*tok, "." | "-" | "_") {
                        None
                    } else if let Ok(id) = tok.parse::<i32>() {
                        if id >= 0 {
                            Some(SoundKey::Id(id))
                        } else {
                            None
                        }
                    } else {
                        SoundKey::from_tail_token(tok)
                    };
                }
                pattern_rows.push(row);
            } else {
                // チャンネル指定無しのMML行は ch0 として扱う
                ch_specs[0].push(line.to_string());
            }
        }

        let mut final_pcm = Vec::new();

        // 1) パターン行がある場合は各行の SFX をミックスして連結
        for row in &pattern_rows {
            let mut row_tracks: Vec<Vec<i16>> = Vec::new();
            for key_opt in row {
                if let Some(key) = key_opt {
                    if let Some(sfx) = sfx_map.get(key) {
                        row_tracks.push(sfx.pcm.clone());
                    } else if let SoundKey::Name(name) = key
                        && let Some(pcm) = synthesize_preset_pcm(name, 1.0, 1.0, 1.0)
                    {
                        row_tracks.push(pcm);
                    }
                }
            }
            let row_mixed = mix_pcm_tracks(&row_tracks);
            final_pcm.extend_from_slice(&row_mixed);
        }

        // 2) インライン ch0..ch3 指定がある場合は各チャンネルを合成してミックス
        if ch_specs.iter().any(|v| !v.is_empty()) {
            let mut tracks = Vec::new();
            for ch_lines in &ch_specs {
                if !ch_lines.is_empty() {
                    let joined = ch_lines.join("\n");
                    tracks.push(parse_and_synthesize_sfx_pcm(&joined));
                }
            }
            let inline_mixed = mix_pcm_tracks(&tracks);
            final_pcm.extend_from_slice(&inline_mixed);
        }

        let wav_bytes = pcm_to_wav_bytes(&final_pcm, SAMPLE_RATE);
        Self {
            spec: spec.trim().to_string(),
            pcm: final_pcm,
            wav_bytes,
        }
    }
}

// ==========================================
// `__END__` & Ruby グローバル変数 (`$SFX`, `$MUSIC`) パーサ
// ==========================================

enum TailSoundBlock {
    Sfx(SoundKey),
    WavB64(SoundKey),
    Music(SoundKey),
}

fn flush_tail_sound_block(
    kind: Option<TailSoundBlock>,
    lines: &mut Vec<String>,
    sfx_map: &mut HashMap<SoundKey, SfxData>,
    music_specs: &mut Vec<(SoundKey, String)>,
) {
    let Some(kind) = kind else {
        lines.clear();
        return;
    };
    if lines.is_empty() {
        return;
    }

    match kind {
        TailSoundBlock::Sfx(key) => {
            let spec = lines.join("\n");
            let sfx = SfxData::from_spec(&spec);
            if !sfx.pcm.is_empty() {
                sfx_map.insert(key, sfx);
            }
        }
        TailSoundBlock::WavB64(key) => {
            let b64: String = lines.iter().map(|s| s.trim()).collect();
            if let Ok(bytes) = decode_base64(&b64)
                && !bytes.is_empty()
            {
                sfx_map.insert(
                    key.clone(),
                    SfxData::from_raw_wav_bytes(&format!("@WAV {}", key), bytes),
                );
            }
        }
        TailSoundBlock::Music(key) => {
            music_specs.push((key, lines.join("\n")));
        }
    }
    lines.clear();
}

/// `__END__` 以降の `@SFX`, `@WAV`, `@MUSIC` セクションをパースする
pub fn parse_tail_sounds(data_section: &str) -> (HashMap<SoundKey, SfxData>, HashMap<SoundKey, MusicData>) {
    let mut sfx_map = HashMap::new();
    let mut music_specs = Vec::new();
    let mut current_block: Option<TailSoundBlock> = None;
    let mut current_lines: Vec<String> = Vec::new();

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@SFX")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush_tail_sound_block(
                current_block.take(),
                &mut current_lines,
                &mut sfx_map,
                &mut music_specs,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Some(key) = SoundKey::from_tail_token(id_str)
            {
                let inline_spec: Vec<&str> = parts.collect();
                if !inline_spec.is_empty() {
                    current_lines.push(inline_spec.join(" "));
                }
                current_block = Some(TailSoundBlock::Sfx(key));
            }
        } else if let Some(rest) = line
            .strip_prefix("@WAV")
            .or_else(|| line.strip_prefix("@OGG"))
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush_tail_sound_block(
                current_block.take(),
                &mut current_lines,
                &mut sfx_map,
                &mut music_specs,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Some(key) = SoundKey::from_tail_token(id_str)
            {
                let inline_b64: String = parts.collect::<Vec<_>>().join("");
                if !inline_b64.is_empty() {
                    current_lines.push(inline_b64);
                }
                current_block = Some(TailSoundBlock::WavB64(key));
            }
        } else if let Some(rest) = line.strip_prefix("@MUSIC")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush_tail_sound_block(
                current_block.take(),
                &mut current_lines,
                &mut sfx_map,
                &mut music_specs,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Some(key) = SoundKey::from_tail_token(id_str)
            {
                let inline_spec: Vec<&str> = parts.collect();
                if !inline_spec.is_empty() {
                    current_lines.push(inline_spec.join(" "));
                }
                current_block = Some(TailSoundBlock::Music(key));
            }
        } else if line.starts_with('@') {
            flush_tail_sound_block(
                current_block.take(),
                &mut current_lines,
                &mut sfx_map,
                &mut music_specs,
            );
        } else if current_block.is_some() {
            current_lines.push(line.to_string());
        }
    }

    flush_tail_sound_block(
        current_block.take(),
        &mut current_lines,
        &mut sfx_map,
        &mut music_specs,
    );

    let mut music_map = HashMap::new();
    for (key, spec) in music_specs {
        let m = MusicData::from_spec(&spec, &sfx_map);
        if !m.pcm.is_empty() {
            music_map.insert(key, m);
        }
    }

    (sfx_map, music_map)
}

fn rvalue_to_sound_key(obj: &RValue) -> Option<SoundKey> {
    match obj {
        RValue::Integer(i) => Some(SoundKey::Id(*i as i32)),
        RValue::Symbol(sym) => {
            let norm = SoundKey::normalize_name(&sym.name);
            if norm.is_empty() { None } else { Some(SoundKey::Name(norm)) }
        }
        RValue::String(s, _) => {
            let raw = String::from_utf8_lossy(&s.borrow()).to_string();
            let norm = SoundKey::normalize_name(&raw);
            if norm.is_empty() { None } else { Some(SoundKey::Name(norm)) }
        }
        _ => None,
    }
}

/// Ruby グローバル変数 `$SFX` / `$MUSIC` からサウンド定義を取り込む
pub fn parse_ruby_sounds_globals(
    vm: &VM,
    sfx_map: &mut HashMap<SoundKey, SfxData>,
    music_map: &mut HashMap<SoundKey, MusicData>,
) {
    if let Some(sfx_obj) = vm.globals.get("$SFX") {
        match &sfx_obj.value {
            RValue::Array(list_cell) => {
                for (idx, item) in list_cell.borrow().iter().enumerate() {
                    if let Ok(s) = String::try_from(item.as_ref()) {
                        let sfx = SfxData::from_spec(&s);
                        if !sfx.pcm.is_empty() {
                            sfx_map.insert(SoundKey::Id(idx as i32), sfx);
                        }
                    }
                }
            }
            RValue::Hash(map_cell) => {
                for (_, (k, v)) in map_cell.borrow().iter() {
                    if let Some(key) = rvalue_to_sound_key(&k.value)
                        && let Ok(s) = String::try_from(v.as_ref())
                    {
                        let sfx = SfxData::from_spec(&s);
                        if !sfx.pcm.is_empty() {
                            sfx_map.insert(key, sfx);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    if let Some(music_obj) = vm.globals.get("$MUSIC") {
        match &music_obj.value {
            RValue::Array(list_cell) => {
                for (idx, item) in list_cell.borrow().iter().enumerate() {
                    match &item.value {
                        RValue::String(_, _) => {
                            if let Ok(s) = String::try_from(item.as_ref()) {
                                let m = MusicData::from_spec(&s, sfx_map);
                                if !m.pcm.is_empty() {
                                    music_map.insert(SoundKey::Id(idx as i32), m);
                                }
                            }
                        }
                        RValue::Array(lines_cell) => {
                            let mut lines = Vec::new();
                            for row in lines_cell.borrow().iter() {
                                if let Ok(s) = String::try_from(row.as_ref()) {
                                    lines.push(s);
                                }
                            }
                            let m = MusicData::from_spec(&lines.join("\n"), sfx_map);
                            if !m.pcm.is_empty() {
                                music_map.insert(SoundKey::Id(idx as i32), m);
                            }
                        }
                        _ => {}
                    }
                }
            }
            RValue::Hash(map_cell) => {
                for (_, (k, v)) in map_cell.borrow().iter() {
                    if let Some(key) = rvalue_to_sound_key(&k.value) {
                        match &v.value {
                            RValue::String(_, _) => {
                                if let Ok(s) = String::try_from(v.as_ref()) {
                                    let m = MusicData::from_spec(&s, sfx_map);
                                    if !m.pcm.is_empty() {
                                        music_map.insert(key, m);
                                    }
                                }
                            }
                            RValue::Array(lines_cell) => {
                                let mut lines = Vec::new();
                                for row in lines_cell.borrow().iter() {
                                    if let Ok(s) = String::try_from(row.as_ref()) {
                                        lines.push(s);
                                    }
                                }
                                let m = MusicData::from_spec(&lines.join("\n"), sfx_map);
                                if !m.pcm.is_empty() {
                                    music_map.insert(key, m);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

// ==========================================
// サウンドバンク & 再生キュー管理
// ==========================================

#[derive(Debug, Clone, PartialEq)]
pub enum AudioCommand {
    PlaySfxKey {
        key: SoundKey,
        channel: i32,
        volume: f32,
        pitch: f32,
    },
    PlaySfxInline {
        spec: String,
        channel: i32,
        volume: f32,
        pitch: f32,
    },
    StopSfx {
        channel: i32,
    },
    PlayMusic {
        key: SoundKey,
        looped: bool,
        volume: f32,
    },
    StopMusic,
    UpdateMusicVolume,
    UpdateSfxVolume,
}

pub struct SoundBank {
    pub sfx: HashMap<SoundKey, SfxData>,
    pub music: HashMap<SoundKey, MusicData>,
    pub inline_cache: HashMap<String, SfxData>,
    pub pending_commands: Vec<AudioCommand>,
    pub current_music_key: Option<SoundKey>,
    pub current_music_looped: bool,
    pub current_music_base_volume: f32,
    pub last_played_sfx_key: Option<SoundKey>,
    pub last_played_inline: Option<String>,
    pub master_volume: f32,
    pub sfx_volume: f32,
    pub music_volume: f32,
    pub frame_counter: u64,
    loaded_sfx_sounds: HashMap<String, Sound>,
    loaded_music_sounds: HashMap<String, Sound>,
    active_channel_keys: [Option<String>; NUM_SFX_CHANNELS],
    active_channel_base_volumes: [f32; NUM_SFX_CHANNELS],
    channel_start_frame: [u64; NUM_SFX_CHANNELS],
    channel_end_frame: [u64; NUM_SFX_CHANNELS],
    active_music_key: Option<String>,
    next_rr_channel: usize,
    last_sfx_frame: HashMap<String, u64>,
}

impl SoundBank {
    pub fn new(sfx: HashMap<SoundKey, SfxData>, music: HashMap<SoundKey, MusicData>) -> Self {
        Self {
            sfx,
            music,
            inline_cache: HashMap::new(),
            pending_commands: Vec::new(),
            current_music_key: None,
            current_music_looped: true,
            current_music_base_volume: 1.0,
            last_played_sfx_key: None,
            last_played_inline: None,
            master_volume: 1.0,
            sfx_volume: 1.0,
            music_volume: 1.0,
            frame_counter: 0,
            loaded_sfx_sounds: HashMap::new(),
            loaded_music_sounds: HashMap::new(),
            active_channel_keys: Default::default(),
            active_channel_base_volumes: [1.0; NUM_SFX_CHANNELS],
            channel_start_frame: [0; NUM_SFX_CHANNELS],
            channel_end_frame: [0; NUM_SFX_CHANNELS],
            active_music_key: None,
            next_rr_channel: 0,
            last_sfx_frame: HashMap::new(),
        }
    }

    pub fn update_definitions(
        &mut self,
        new_sfx: HashMap<SoundKey, SfxData>,
        new_music: HashMap<SoundKey, MusicData>,
    ) {
        self.sfx = new_sfx;
        self.music = new_music;
    }

    pub fn set_master_volume(&mut self, vol: f32) -> f32 {
        let clamped = if vol.is_finite() {
            vol.clamp(0.0, 1.0)
        } else {
            self.master_volume
        };
        self.master_volume = clamped;
        self.pending_commands.push(AudioCommand::UpdateMusicVolume);
        self.pending_commands.push(AudioCommand::UpdateSfxVolume);
        clamped
    }

    pub fn set_sfx_volume(&mut self, vol: f32) -> f32 {
        let clamped = if vol.is_finite() {
            vol.clamp(0.0, 1.0)
        } else {
            self.sfx_volume
        };
        self.sfx_volume = clamped;
        self.pending_commands.push(AudioCommand::UpdateSfxVolume);
        clamped
    }

    pub fn set_music_volume(&mut self, vol: f32) -> f32 {
        let clamped = if vol.is_finite() {
            vol.clamp(0.0, 1.0)
        } else {
            self.music_volume
        };
        self.music_volume = clamped;
        self.pending_commands.push(AudioCommand::UpdateMusicVolume);
        clamped
    }

    #[inline]
    pub fn effective_sfx_volume(&self, vol: f32) -> f32 {
        (vol * self.sfx_volume * self.master_volume).clamp(0.0, 2.0)
    }

    #[inline]
    pub fn effective_music_volume(&self, vol: f32) -> f32 {
        (vol * self.music_volume * self.master_volume).clamp(0.0, 2.0)
    }

    pub fn advance_frame(&mut self) {
        self.frame_counter = self.frame_counter.wrapping_add(1);
    }

    /// 同一 SFX キーが連続フレームで多重発音されるのを防ぐ（クールダウン判定）
    pub fn should_skip_sfx_cooldown(&mut self, cooldown_key: &str) -> bool {
        if let Some(&prev_frame) = self.last_sfx_frame.get(cooldown_key)
            && self.frame_counter.saturating_sub(prev_frame) < SFX_COOLDOWN_FRAMES
        {
            return true;
        }
        self.last_sfx_frame
            .insert(cooldown_key.to_string(), self.frame_counter);
        false
    }

    /// SFX 再生チャンネルを割り当て、上書き／ボイススチール対象の旧キーを返す
    pub fn allocate_sfx_channel(
        &mut self,
        channel: i32,
        cache_key: &str,
        base_volume: f32,
        duration_sec: f32,
    ) -> (usize, Option<String>) {
        let ch_idx = if channel >= 0 && (channel as usize) < NUM_SFX_CHANNELS {
            channel as usize
        } else {
            let mut chosen = None;
            for offset in 0..NUM_SFX_CHANNELS {
                let idx = (self.next_rr_channel + offset) % NUM_SFX_CHANNELS;
                if self.active_channel_keys[idx].is_none()
                    || self.frame_counter >= self.channel_end_frame[idx]
                {
                    chosen = Some(idx);
                    break;
                }
            }
            let idx = chosen.unwrap_or_else(|| {
                // 全チャンネル使用中: 最も古い発音スロットをボイススチールする
                (0..NUM_SFX_CHANNELS)
                    .min_by_key(|&i| self.channel_start_frame[i])
                    .unwrap_or(0)
            });
            self.next_rr_channel = (idx + 1) % NUM_SFX_CHANNELS;
            idx
        };

        let prev_key = self.active_channel_keys[ch_idx].take();
        self.active_channel_keys[ch_idx] = Some(cache_key.to_string());
        self.active_channel_base_volumes[ch_idx] = base_volume;
        self.channel_start_frame[ch_idx] = self.frame_counter;
        let dur_frames = (duration_sec.max(0.05) * 60.0).ceil() as u64;
        self.channel_end_frame[ch_idx] = self.frame_counter.saturating_add(dur_frames);
        (ch_idx, prev_key)
    }

    pub fn queue_play_sfx_key(&mut self, key: SoundKey, channel: i32, volume: f32, pitch: f32) {
        if let SoundKey::Id(id) = key
            && id < 0
        {
            self.queue_stop_sfx(channel);
            return;
        }
        self.last_played_sfx_key = Some(key.clone());
        let pitch_clamped = if pitch.is_finite() {
            pitch.clamp(0.25, 4.0)
        } else {
            1.0
        };
        self.pending_commands.push(AudioCommand::PlaySfxKey {
            key,
            channel,
            volume: volume.clamp(0.0, 2.0),
            pitch: pitch_clamped,
        });
    }

    pub fn queue_play_sfx_id(&mut self, id: i32, channel: i32, volume: f32, pitch: f32) {
        self.queue_play_sfx_key(SoundKey::Id(id), channel, volume, pitch);
    }

    /// シンボル名指定の SFX を再生する（ユーザー定義 `@SFX :name` を優先し、無ければ内蔵プリセットを再生）
    pub fn queue_play_sfx_symbol(&mut self, name: &str, channel: i32, volume: f32, pitch: f32) {
        let norm = SoundKey::normalize_name(name);
        if norm.is_empty() {
            return;
        }
        let key = SoundKey::Name(norm.clone());
        if self.sfx.contains_key(&key) {
            self.queue_play_sfx_key(key, channel, volume, pitch);
        } else if is_builtin_preset(&norm) {
            self.queue_play_sfx_inline(&norm, channel, volume, pitch);
        }
    }

    pub fn queue_play_sfx_inline(&mut self, spec: &str, channel: i32, volume: f32, pitch: f32) {
        let key = spec.trim().to_string();
        if key.is_empty() {
            return;
        }
        if !self.inline_cache.contains_key(&key) {
            let sfx = SfxData::from_spec(&key);
            if !sfx.pcm.is_empty() {
                self.inline_cache.insert(key.clone(), sfx);
            }
        }
        self.last_played_inline = Some(key.clone());
        let pitch_clamped = if pitch.is_finite() {
            pitch.clamp(0.25, 4.0)
        } else {
            1.0
        };
        self.pending_commands.push(AudioCommand::PlaySfxInline {
            spec: key,
            channel,
            volume: volume.clamp(0.0, 2.0),
            pitch: pitch_clamped,
        });
    }

    pub fn queue_play_tone(
        &mut self,
        freq: f32,
        dur: f32,
        wave: Waveform,
        volume: f32,
        slide: f32,
    ) {
        if !freq.is_finite() || !dur.is_finite() || freq <= 0.0 || dur <= 0.0 {
            return;
        }
        let freq_c = freq.clamp(20.0, 20000.0);
        let dur_c = dur.clamp(0.005, 10.0);
        let slide_c = if slide.is_finite() { slide } else { 0.0 };
        let key = format!(
            "tone:{:.1}:{:.3}:{}:{:.1}",
            freq_c, dur_c, wave as u8, slide_c
        );
        if !self.inline_cache.contains_key(&key) {
            let pcm = synthesize_tone_pcm(freq_c, dur_c, wave, slide_c);
            if !pcm.is_empty() {
                let wav_bytes = pcm_to_wav_bytes(&pcm, SAMPLE_RATE);
                self.inline_cache.insert(
                    key.clone(),
                    SfxData {
                        spec: key.clone(),
                        pcm,
                        wav_bytes,
                    },
                );
            }
        }
        self.last_played_inline = Some(key.clone());
        self.pending_commands.push(AudioCommand::PlaySfxInline {
            spec: key,
            channel: -1,
            volume: volume.clamp(0.0, 2.0),
            pitch: 1.0,
        });
    }

    pub fn queue_stop_sfx(&mut self, channel: i32) {
        self.pending_commands.push(AudioCommand::StopSfx { channel });
    }

    pub fn queue_play_music_key(&mut self, key: SoundKey, looped: bool, volume: f32) {
        if let SoundKey::Id(id) = key
            && id < 0
        {
            self.queue_stop_music();
            return;
        }
        let vol_c = volume.clamp(0.0, 2.0);
        self.current_music_key = Some(key.clone());
        self.current_music_looped = looped;
        self.current_music_base_volume = vol_c;
        self.pending_commands.push(AudioCommand::PlayMusic {
            key,
            looped,
            volume: vol_c,
        });
    }

    pub fn queue_play_music(&mut self, id: i32, looped: bool, volume: f32) {
        self.queue_play_music_key(SoundKey::Id(id), looped, volume);
    }

    pub fn queue_stop_music(&mut self) {
        self.current_music_key = None;
        self.pending_commands.push(AudioCommand::StopMusic);
    }

    /// 再生中の BGM と全 SFX を即時停止する（再起動時などのクリーンアップ用）
    pub fn stop_all_audio(&mut self) {
        if let Some(prev_key) = self.active_music_key.take()
            && let Some(prev_snd) = self.loaded_music_sounds.get(&prev_key)
        {
            stop_sound(prev_snd);
        }
        for idx in 0..NUM_SFX_CHANNELS {
            if let Some(key) = self.active_channel_keys[idx].take()
                && let Some(snd) = self.loaded_sfx_sounds.get(&key)
            {
                stop_sound(snd);
            }
            self.channel_end_frame[idx] = 0;
        }
        self.current_music_key = None;
        self.pending_commands.clear();
    }

    /// 定義済み `@SFX` / `@MUSIC` や主要プリセットを事前ロードする（非ヘッドレス環境用）
    pub async fn preload_all(&mut self) {
        for &preset in BUILTIN_SFX_PRESETS {
            if !self.inline_cache.contains_key(preset) {
                let sfx = SfxData::from_spec(preset);
                if !sfx.pcm.is_empty() {
                    self.inline_cache.insert(preset.to_string(), sfx);
                }
            }
        }

        let sfx_entries: Vec<(String, Vec<u8>)> = self
            .sfx
            .iter()
            .map(|(key, data)| (format!("{}:{}", key.cache_tag(), data.spec), data.wav_bytes.clone()))
            .chain(
                self.inline_cache
                    .iter()
                    .map(|(k, data)| (format!("in:{}", k), data.wav_bytes.clone())),
            )
            .collect();

        for (cache_key, wav_bytes) in sfx_entries {
            if !self.loaded_sfx_sounds.contains_key(&cache_key)
                && !wav_bytes.is_empty()
                && let Ok(snd) = load_sound_from_bytes(&wav_bytes).await
            {
                self.loaded_sfx_sounds.insert(cache_key, snd);
            }
        }

        let music_entries: Vec<(String, Vec<u8>)> = self
            .music
            .iter()
            .map(|(key, data)| (format!("music:{}:{}", key.cache_tag(), data.spec), data.wav_bytes.clone()))
            .collect();

        for (cache_key, wav_bytes) in music_entries {
            if !self.loaded_music_sounds.contains_key(&cache_key)
                && !wav_bytes.is_empty()
                && let Ok(snd) = load_sound_from_bytes(&wav_bytes).await
            {
                self.loaded_music_sounds.insert(cache_key, snd);
            }
        }
    }

    /// フレームごとの保留オーディオコマンドを実行する（非ヘッドレス環境用）
    pub async fn process_audio(&mut self) {
        self.advance_frame();
        if self.pending_commands.is_empty() {
            return;
        }
        let commands = std::mem::take(&mut self.pending_commands);

        for cmd in commands {
            match cmd {
                AudioCommand::PlaySfxKey {
                    key,
                    channel,
                    volume,
                    pitch,
                } => {
                    let cooldown_key = key.cache_tag();
                    if self.should_skip_sfx_cooldown(&cooldown_key) {
                        continue;
                    }
                    let Some(sfx_data) = self.sfx.get(&key).cloned() else {
                        continue;
                    };
                    let use_base = (pitch - 1.0).abs() < 0.001;
                    let cache_key = if use_base {
                        format!("{}:{}", key.cache_tag(), sfx_data.spec)
                    } else {
                        let pitch_q = (pitch.clamp(0.25, 4.0) * 100.0).round() as i32;
                        format!("{}:{}:p{}", key.cache_tag(), sfx_data.spec, pitch_q)
                    };
                    if !self.loaded_sfx_sounds.contains_key(&cache_key) {
                        let wav_bytes = if use_base {
                            sfx_data.wav_bytes.clone()
                        } else {
                            let pitched = apply_pitch_to_pcm(&sfx_data.pcm, pitch);
                            pcm_to_wav_bytes(&pitched, SAMPLE_RATE)
                        };
                        if let Ok(snd) = load_sound_from_bytes(&wav_bytes).await {
                            self.loaded_sfx_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    let dur_sec = sfx_data.duration_sec() / pitch.clamp(0.25, 4.0);
                    self.play_cached_sfx_on_channel(&cache_key, channel, volume, dur_sec);
                }
                AudioCommand::PlaySfxInline {
                    spec,
                    channel,
                    volume,
                    pitch,
                } => {
                    let cooldown_key = format!("in:{}", spec);
                    if self.should_skip_sfx_cooldown(&cooldown_key) {
                        continue;
                    }
                    let Some(sfx_data) = self.inline_cache.get(&spec).cloned() else {
                        continue;
                    };
                    let use_base = (pitch - 1.0).abs() < 0.001;
                    let cache_key = if use_base {
                        format!("in:{}", spec)
                    } else {
                        let pitch_q = (pitch.clamp(0.25, 4.0) * 100.0).round() as i32;
                        format!("in:{}:p{}", spec, pitch_q)
                    };
                    if !self.loaded_sfx_sounds.contains_key(&cache_key) {
                        let wav_bytes = if use_base {
                            sfx_data.wav_bytes.clone()
                        } else {
                            let pitched = apply_pitch_to_pcm(&sfx_data.pcm, pitch);
                            pcm_to_wav_bytes(&pitched, SAMPLE_RATE)
                        };
                        if let Ok(snd) = load_sound_from_bytes(&wav_bytes).await {
                            self.loaded_sfx_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    let dur_sec = sfx_data.duration_sec() / pitch.clamp(0.25, 4.0);
                    self.play_cached_sfx_on_channel(&cache_key, channel, volume, dur_sec);
                }
                AudioCommand::StopSfx { channel } => {
                    if channel < 0 {
                        for idx in 0..NUM_SFX_CHANNELS {
                            if let Some(key) = self.active_channel_keys[idx].take()
                                && let Some(snd) = self.loaded_sfx_sounds.get(&key)
                            {
                                stop_sound(snd);
                            }
                            self.channel_end_frame[idx] = 0;
                        }
                    } else if (channel as usize) < NUM_SFX_CHANNELS {
                        let idx = channel as usize;
                        if let Some(key) = self.active_channel_keys[idx].take()
                            && let Some(snd) = self.loaded_sfx_sounds.get(&key)
                        {
                            stop_sound(snd);
                        }
                        self.channel_end_frame[idx] = 0;
                    }
                }
                AudioCommand::PlayMusic { key, looped, volume } => {
                    if let Some(prev_key) = self.active_music_key.take()
                        && let Some(prev_snd) = self.loaded_music_sounds.get(&prev_key)
                    {
                        stop_sound(prev_snd);
                    }
                    let Some(music_data) = self.music.get(&key) else {
                        continue;
                    };
                    let cache_key = format!("music:{}:{}", key.cache_tag(), music_data.spec);
                    if !self.loaded_music_sounds.contains_key(&cache_key) {
                        if let Ok(snd) = load_sound_from_bytes(&music_data.wav_bytes).await {
                            self.loaded_music_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    let eff_vol = self.effective_music_volume(volume);
                    if let Some(snd) = self.loaded_music_sounds.get(&cache_key) {
                        play_sound(
                            snd,
                            PlaySoundParams {
                                looped,
                                volume: eff_vol,
                            },
                        );
                        self.active_music_key = Some(cache_key);
                    }
                }
                AudioCommand::StopMusic => {
                    if let Some(prev_key) = self.active_music_key.take()
                        && let Some(prev_snd) = self.loaded_music_sounds.get(&prev_key)
                    {
                        stop_sound(prev_snd);
                    }
                }
                AudioCommand::UpdateMusicVolume => {
                    if let Some(ref key) = self.active_music_key
                        && let Some(snd) = self.loaded_music_sounds.get(key)
                    {
                        let eff_vol = self.effective_music_volume(self.current_music_base_volume);
                        set_sound_volume(snd, eff_vol);
                    }
                }
                AudioCommand::UpdateSfxVolume => {
                    for idx in 0..NUM_SFX_CHANNELS {
                        if self.frame_counter < self.channel_end_frame[idx]
                            && let Some(ref key) = self.active_channel_keys[idx]
                            && let Some(snd) = self.loaded_sfx_sounds.get(key)
                        {
                            let eff_vol =
                                self.effective_sfx_volume(self.active_channel_base_volumes[idx]);
                            set_sound_volume(snd, eff_vol);
                        }
                    }
                }
            }
        }
    }

    fn play_cached_sfx_on_channel(
        &mut self,
        cache_key: &str,
        channel: i32,
        base_volume: f32,
        duration_sec: f32,
    ) {
        let (_ch_idx, prev_key_opt) =
            self.allocate_sfx_channel(channel, cache_key, base_volume, duration_sec);
        if let Some(prev_key) = prev_key_opt
            && let Some(prev_snd) = self.loaded_sfx_sounds.get(&prev_key)
        {
            stop_sound(prev_snd);
        }

        let eff_vol = self.effective_sfx_volume(base_volume);
        if let Some(snd) = self.loaded_sfx_sounds.get(cache_key) {
            stop_sound(snd);
            play_sound(
                snd,
                PlaySoundParams {
                    looped: false,
                    volume: eff_vol,
                },
            );
        }
    }
}

// ==========================================
// `uk check` 用サウンド静的検証
// ==========================================

fn validate_mml_note_token(raw_tok: &str) -> Result<usize, String> {
    let mut note_part = raw_tok;
    if let Some((head, suffix)) = raw_tok.split_once(':') {
        note_part = head;
        if suffix.is_empty() {
            return Err(format!("Empty modifier after ':' in '{}'", raw_tok));
        }
        for part in suffix.split(':') {
            if NoteEffect::from_name(part).is_none()
                && Waveform::from_name(part).is_none()
                && part.parse::<f32>().is_err()
            {
                return Err(format!("Unknown note modifier ':{}' in '{}'", part, raw_tok));
            }
        }
    }

    if let Some((head, mul_str)) = note_part.split_once('*') {
        note_part = head;
        if mul_str.parse::<f32>().is_err() {
            return Err(format!("Invalid duration multiplier '*{}' in '{}'", mul_str, raw_tok));
        }
    }

    let chars: Vec<char> = note_part.chars().collect();
    let mut idx = 0;
    let mut count = 0usize;

    while idx < chars.len() {
        let ch = chars[idx];
        let lower = ch.to_ascii_lowercase();

        if ch == '>' || ch == '<' || ch == '~' {
            idx += 1;
            continue;
        }
        if lower == 'v' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && (chars[idx].is_ascii_digit() || chars[idx] == '.') {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if num_s.is_empty() || num_s.parse::<f32>().is_err() {
                return Err(format!("Invalid volume command 'v{}' in '{}'", num_s, raw_tok));
            }
            continue;
        }
        if lower == 'o' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if num_s.is_empty() || num_s.parse::<i32>().is_err() {
                return Err(format!("Invalid octave command 'o{}' in '{}'", num_s, raw_tok));
            }
            continue;
        }
        if lower == 'l' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if num_s.is_empty() || num_s.parse::<f32>().is_err() {
                return Err(format!("Invalid length command 'l{}' in '{}'", num_s, raw_tok));
            }
            continue;
        }
        if lower == 't' {
            idx += 1;
            let mut num_s = String::new();
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                num_s.push(chars[idx]);
                idx += 1;
            }
            if num_s.is_empty() || num_s.parse::<f32>().is_err() {
                return Err(format!("Invalid tempo command 't{}' in '{}'", num_s, raw_tok));
            }
            continue;
        }
        if matches!(lower, 'r' | '.' | '-' | '_') {
            idx += 1;
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                idx += 1;
            }
            count += 1;
            continue;
        }
        if matches!(lower, 'a'..='g') {
            idx += 1;
            if idx < chars.len() && matches!(chars[idx], '#' | '+' | '-') {
                idx += 1;
            }
            while idx < chars.len() && chars[idx].is_ascii_digit() {
                idx += 1;
            }
            if idx < chars.len() && chars[idx] == '.' {
                idx += 1;
            }
            while idx < chars.len() && chars[idx] == '~' {
                idx += 1;
            }
            count += 1;
            continue;
        }

        return Err(format!("Unexpected character '{}' in MML token '{}'", ch, raw_tok));
    }

    Ok(count)
}

/// `@SFX` またはインライン `sfx("...")` の定義文字列を構文検証する
pub fn validate_sfx_spec(spec: &str) -> Result<(), String> {
    let trimmed = spec.trim();
    if trimmed.is_empty() {
        return Err("Empty SFX definition".to_string());
    }

    // 1) プリセット参照のチェック (`:jump`, `jump pitch=1.2` 等)
    let mut tokens_iter = trimmed.split_whitespace();
    if let Some(first_tok) = tokens_iter.next() {
        let rest_tokens: Vec<&str> = tokens_iter.collect();
        let mut all_kv = true;
        for tok in &rest_tokens {
            if let Some((k, v)) = tok.split_once('=') {
                match k.to_ascii_lowercase().as_str() {
                    "pitch" | "p" | "speed" | "s" | "vol" | "volume" | "v" => {
                        if v.parse::<f32>().is_err() {
                            return Err(format!("Invalid preset modifier '{}={}'", k, v));
                        }
                    }
                    _ => {
                        all_kv = false;
                        break;
                    }
                }
            } else {
                all_kv = false;
                break;
            }
        }
        if all_kv && is_builtin_preset(first_tok) {
            return Ok(());
        }
        // `:typoname` のように先頭が `:` でキー値形式でない単一プリセット参照っぽい場合は未定義プリセットエラー
        if rest_tokens.is_empty()
            && first_tok.starts_with(':')
            && !first_tok[1..].contains(':')
            && !is_builtin_preset(first_tok)
        {
            return Err(format!("Unknown preset SFX '{}'", first_tok));
        }
    }

    // 2) Key-Value シンセレシピ記法のチェック
    match try_parse_synth_recipe(trimmed) {
        Ok(Some(_)) => return Ok(()),
        Err(e) => return Err(e),
        Ok(None) => {}
    }

    // 3) MML / ノート列のチェック
    let mut note_count = 0usize;
    let mut has_any_setting = false;

    for raw_line in trimmed.lines() {
        let line = strip_sound_comment(raw_line);
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() == 2 {
            let k = parts[0].to_ascii_lowercase();
            let v = parts[1];
            match k.as_str() {
                "wave" | "waveform" | "instrument" | "inst" => {
                    if Waveform::from_name(v).is_none() {
                        return Err(format!("Unknown waveform '{}'", v));
                    }
                    has_any_setting = true;
                    continue;
                }
                "speed" | "spd" | "tempo" | "bpm" | "vol" | "volume" => {
                    if v.parse::<f32>().is_err() {
                        return Err(format!("Invalid numeric value '{}' for '{}'", v, k));
                    }
                    has_any_setting = true;
                    continue;
                }
                "effect" | "fx" => {
                    if NoteEffect::from_name(v).is_none() {
                        return Err(format!("Unknown effect '{}'", v));
                    }
                    has_any_setting = true;
                    continue;
                }
                _ => {}
            }
        }

        for tok in parts {
            if let Some((k, v)) = tok.split_once('=') {
                match k.to_ascii_lowercase().as_str() {
                    "wave" | "w" => {
                        if Waveform::from_name(v).is_none() {
                            return Err(format!("Unknown waveform '{}'", v));
                        }
                        has_any_setting = true;
                    }
                    "speed" | "spd" | "s" | "tempo" | "bpm" | "t" | "vol" | "volume" | "v" => {
                        if v.parse::<f32>().is_err() {
                            return Err(format!("Invalid numeric value '{}' in '{}'", v, tok));
                        }
                        has_any_setting = true;
                    }
                    "effect" | "fx" => {
                        if NoteEffect::from_name(v).is_none() {
                            return Err(format!("Unknown effect '{}'", v));
                        }
                        has_any_setting = true;
                    }
                    _ => {
                        return Err(format!("Unknown MML parameter '{}'", tok));
                    }
                }
            } else if Waveform::from_name(tok).is_some() {
                has_any_setting = true;
            } else {
                let upper = tok.to_ascii_uppercase();
                if let Some(num_s) = upper.strip_prefix('T')
                    && !num_s.is_empty()
                    && num_s.chars().all(|c| c.is_ascii_digit() || c == '.')
                {
                    if num_s.parse::<f32>().is_err() {
                        return Err(format!("Invalid tempo '{}'", tok));
                    }
                    has_any_setting = true;
                } else if let Some(num_s) = upper.strip_prefix('L')
                    && !num_s.is_empty()
                    && num_s.chars().all(|c| c.is_ascii_digit() || c == '.')
                {
                    if num_s.parse::<f32>().is_err() {
                        return Err(format!("Invalid note length '{}'", tok));
                    }
                    has_any_setting = true;
                } else if let Some(num_s) = upper.strip_prefix('O')
                    && !num_s.is_empty()
                    && num_s.chars().all(|c| c.is_ascii_digit())
                {
                    if num_s.parse::<i32>().is_err() {
                        return Err(format!("Invalid octave '{}'", tok));
                    }
                    has_any_setting = true;
                } else if tok == "<" || tok == ">" {
                    has_any_setting = true;
                } else {
                    note_count += validate_mml_note_token(tok)?;
                }
            }
        }
    }

    if note_count == 0 {
        if has_any_setting {
            return Err("SFX definition has parameters but no notes/rests".to_string());
        }
        return Err("Empty SFX definition".to_string());
    }

    Ok(())
}

/// `@MUSIC` 定義ブロックを構文検証する
pub fn validate_music_spec(
    spec: &str,
    defined_sfx: &HashSet<SoundKey>,
) -> Result<(), String> {
    let mut has_track_or_pattern = false;

    for raw_line in spec.lines() {
        let line = strip_sound_comment(raw_line);
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("loop") || lower == "end" {
            continue;
        }

        // `ch0 ...`..`ch3 ...` のチェック
        let mut matched_ch = false;
        for prefix in ["ch0", "ch1", "ch2", "ch3"] {
            if lower.starts_with(prefix) {
                let after_prefix = &line[prefix.len()..];
                if after_prefix.is_empty()
                    || after_prefix.starts_with(char::is_whitespace)
                    || after_prefix.starts_with(':')
                {
                    let body = after_prefix.trim().trim_start_matches(':').trim();
                    if body.is_empty() {
                        return Err(format!("Empty track specification for '{}'", prefix));
                    }
                    validate_sfx_spec(body).map_err(|e| format!("{}: {}", prefix, e))?;
                    has_track_or_pattern = true;
                    matched_ch = true;
                    break;
                }
            }
        }
        if matched_ch {
            continue;
        }

        // `ch4` 以上などの不正チャンネル指定チェック
        if let Some(rest) = lower.strip_prefix("ch")
            && let Some(first_c) = rest.chars().next()
            && first_c.is_ascii_digit()
        {
            return Err(format!("Invalid music channel in '{}' (only ch0..ch3 supported)", line));
        }

        // パターン行チェック
        let tokens: Vec<&str> = line
            .split(|c: char| c.is_ascii_whitespace() || c == ',' || c == '|')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        if !tokens.is_empty()
            && tokens.iter().all(|t| {
                matches!(*t, "." | "-" | "_")
                    || t.parse::<i32>().is_ok()
                    || SoundKey::from_tail_token(t).is_some()
            })
        {
            for tok in tokens.iter().take(4) {
                if matches!(*tok, "." | "-" | "_") {
                    continue;
                }
                if let Ok(id) = tok.parse::<i32>() {
                    if id >= 0 && !defined_sfx.contains(&SoundKey::Id(id)) {
                        return Err(format!("Pattern row references undefined @SFX {}", id));
                    }
                } else if let Some(key) = SoundKey::from_tail_token(tok) {
                    let exists = defined_sfx.contains(&key)
                        || matches!(&key, SoundKey::Name(n) if is_builtin_preset(n));
                    if !exists {
                        return Err(format!("Pattern row references undefined @SFX {}", key));
                    }
                }
            }
            has_track_or_pattern = true;
        } else {
            validate_sfx_spec(line)?;
            has_track_or_pattern = true;
        }
    }

    if !has_track_or_pattern {
        return Err("Empty @MUSIC definition".to_string());
    }
    Ok(())
}

/// `__END__` 以降の `@SFX` / `@WAV` / `@MUSIC` セクションの構文エラーをすべて収集する
pub fn validate_tail_sounds(data_section: &str, extra_defined_sfx: &HashSet<SoundKey>) -> Vec<String> {
    let mut errors = Vec::new();
    let mut sfx_keys = extra_defined_sfx.clone();
    let mut music_blocks: Vec<(SoundKey, String)> = Vec::new();

    enum Kind {
        Sfx(SoundKey),
        Wav(SoundKey),
        Music(SoundKey),
    }

    let mut current: Option<Kind> = None;
    let mut current_lines: Vec<String> = Vec::new();

    let flush = |kind: Option<Kind>,
                 lines: &mut Vec<String>,
                 sfx_keys: &mut HashSet<SoundKey>,
                 music_blocks: &mut Vec<(SoundKey, String)>,
                 errors: &mut Vec<String>| {
        let Some(k) = kind else {
            lines.clear();
            return;
        };
        let joined = lines.join("\n");
        lines.clear();
        match k {
            Kind::Sfx(key) => {
                if joined.trim().is_empty() {
                    errors.push(format!("@SFX {} has an empty definition", key));
                } else if let Err(e) = validate_sfx_spec(&joined) {
                    errors.push(format!("@SFX {}: {}", key, e));
                } else {
                    sfx_keys.insert(key);
                }
            }
            Kind::Wav(key) => {
                let b64: String = joined.split_whitespace().collect();
                if b64.is_empty() {
                    errors.push(format!("@WAV {} has empty base64 data", key));
                } else if decode_base64(&b64).is_err() {
                    errors.push(format!("@WAV {} contains invalid base64 data", key));
                } else {
                    sfx_keys.insert(key);
                }
            }
            Kind::Music(key) => {
                if joined.trim().is_empty() {
                    errors.push(format!("@MUSIC {} has an empty definition", key));
                } else {
                    music_blocks.push((key, joined));
                }
            }
        }
    };

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@SFX")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush(
                current.take(),
                &mut current_lines,
                &mut sfx_keys,
                &mut music_blocks,
                &mut errors,
            );
            let mut parts = rest.split_whitespace();
            match parts.next() {
                Some(id_str) => {
                    if let Some(key) = SoundKey::from_tail_token(id_str) {
                        let inline: Vec<&str> = parts.collect();
                        if !inline.is_empty() {
                            current_lines.push(inline.join(" "));
                        }
                        current = Some(Kind::Sfx(key));
                    } else {
                        errors.push(format!(
                            "@SFX header requires an integer ID or :symbol name (got '{}')",
                            id_str
                        ));
                    }
                }
                None => {
                    errors.push("@SFX header is missing an ID or :symbol name".to_string());
                }
            }
        } else if let Some(rest) = line
            .strip_prefix("@WAV")
            .or_else(|| line.strip_prefix("@OGG"))
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush(
                current.take(),
                &mut current_lines,
                &mut sfx_keys,
                &mut music_blocks,
                &mut errors,
            );
            let mut parts = rest.split_whitespace();
            match parts.next() {
                Some(id_str) => {
                    if let Some(key) = SoundKey::from_tail_token(id_str) {
                        let inline_b64: String = parts.collect::<Vec<_>>().join("");
                        if !inline_b64.is_empty() {
                            current_lines.push(inline_b64);
                        }
                        current = Some(Kind::Wav(key));
                    } else {
                        errors.push(format!(
                            "@WAV header requires an integer ID or :symbol name (got '{}')",
                            id_str
                        ));
                    }
                }
                None => {
                    errors.push("@WAV header is missing an ID or :symbol name".to_string());
                }
            }
        } else if let Some(rest) = line.strip_prefix("@MUSIC")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            flush(
                current.take(),
                &mut current_lines,
                &mut sfx_keys,
                &mut music_blocks,
                &mut errors,
            );
            let mut parts = rest.split_whitespace();
            match parts.next() {
                Some(id_str) => {
                    if let Some(key) = SoundKey::from_tail_token(id_str) {
                        let inline: Vec<&str> = parts.collect();
                        if !inline.is_empty() {
                            current_lines.push(inline.join(" "));
                        }
                        current = Some(Kind::Music(key));
                    } else {
                        errors.push(format!(
                            "@MUSIC header requires an integer ID or :symbol name (got '{}')",
                            id_str
                        ));
                    }
                }
                None => {
                    errors.push("@MUSIC header is missing an ID or :symbol name".to_string());
                }
            }
        } else if line.starts_with('@') {
            flush(
                current.take(),
                &mut current_lines,
                &mut sfx_keys,
                &mut music_blocks,
                &mut errors,
            );
        } else if current.is_some() {
            current_lines.push(line.to_string());
        }
    }

    flush(
        current.take(),
        &mut current_lines,
        &mut sfx_keys,
        &mut music_blocks,
        &mut errors,
    );

    for (key, spec) in music_blocks {
        if let Err(e) = validate_music_spec(&spec, &sfx_keys) {
            errors.push(format!("@MUSIC {}: {}", key, e));
        }
    }

    errors
}

/// Ruby コード中の `sfx(...)` / `music(...)` 呼び出しにおける未定義シンボル・ID・不正インライン記法を静的検証する
pub fn validate_ruby_sound_calls(
    ruby_code: &str,
    defined_sfx: &HashSet<SoundKey>,
    defined_music: &HashSet<SoundKey>,
) -> Vec<String> {
    let mut errors = Vec::new();
    let bytes = ruby_code.as_bytes();
    let len = bytes.len();
    let mut i = 0usize;
    let mut line_no = 1usize;

    while i < len {
        let b = bytes[i];
        if b == b'\n' {
            line_no += 1;
            i += 1;
            continue;
        }
        // コメント行をスキップ
        if b == b'#' {
            while i < len && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        // 文字列リテラルをスキップ
        if b == b'"' || b == b'\'' {
            let quote = b;
            i += 1;
            while i < len {
                if bytes[i] == b'\\' {
                    i = (i + 2).min(len);
                    continue;
                }
                if bytes[i] == b'\n' {
                    line_no += 1;
                }
                if bytes[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // `sfx(` または `music(` の検出
        let matched_fn = if ruby_code[i..].starts_with("sfx(") {
            Some(("sfx", 4))
        } else if ruby_code[i..].starts_with("music(") {
            Some(("music", 6))
        } else {
            None
        };

        if let Some((fn_name, prefix_len)) = matched_fn {
            let prev_is_ident = i > 0
                && (bytes[i - 1].is_ascii_alphanumeric()
                    || bytes[i - 1] == b'_'
                    || bytes[i - 1] == b'.'
                    || bytes[i - 1] == b':');
            if !prev_is_ident {
                let call_line = line_no;
                let mut arg_start = i + prefix_len;
                while arg_start < len && bytes[arg_start].is_ascii_whitespace() {
                    if bytes[arg_start] == b'\n' {
                        line_no += 1;
                    }
                    arg_start += 1;
                }

                if arg_start < len {
                    let first_b = bytes[arg_start];
                    if first_b == b':' {
                        // シンボル引数 `:name`
                        let mut end = arg_start + 1;
                        while end < len
                            && (bytes[end].is_ascii_alphanumeric()
                                || bytes[end] == b'_'
                                || bytes[end] == b'-')
                        {
                            end += 1;
                        }
                        let sym_name = &ruby_code[arg_start + 1..end];
                        let mut after_sym = end;
                        while after_sym < len && bytes[after_sym].is_ascii_whitespace() {
                            after_sym += 1;
                        }
                        let is_standalone_arg = after_sym < len
                            && (bytes[after_sym] == b',' || bytes[after_sym] == b')');
                        if !sym_name.is_empty() && is_standalone_arg {
                            let norm = SoundKey::normalize_name(sym_name);
                            let key = SoundKey::Name(norm.clone());
                            if fn_name == "sfx" {
                                if !defined_sfx.contains(&key) && !is_builtin_preset(&norm) {
                                    errors.push(format!(
                                        "Line {}: Undefined SFX symbol ':{}' in sfx(:{}) (not defined in @SFX/$SFX and not a built-in preset)",
                                        call_line, sym_name, sym_name
                                    ));
                                }
                            } else if !defined_music.contains(&key) {
                                errors.push(format!(
                                    "Line {}: Undefined MUSIC symbol ':{}' in music(:{}) (not defined in @MUSIC/$MUSIC)",
                                    call_line, sym_name, sym_name
                                ));
                            }
                        }
                    } else if first_b.is_ascii_digit() || first_b == b'-' {
                        // 整数リテラル引数 `0`, `12`, `-1`
                        let mut end = arg_start + 1;
                        while end < len && bytes[end].is_ascii_digit() {
                            end += 1;
                        }
                        let num_str = &ruby_code[arg_start..end];
                        let mut after_num = end;
                        while after_num < len && bytes[after_num].is_ascii_whitespace() {
                            after_num += 1;
                        }
                        let is_standalone_arg = after_num < len
                            && (bytes[after_num] == b',' || bytes[after_num] == b')');
                        if is_standalone_arg
                            && let Ok(id) = num_str.parse::<i32>()
                            && id >= 0
                        {
                            let key = SoundKey::Id(id);
                            if fn_name == "sfx" {
                                if !defined_sfx.contains(&key) {
                                    errors.push(format!(
                                        "Line {}: Undefined SFX ID {} in sfx({}) (not defined in @SFX/$SFX)",
                                        call_line, id, id
                                    ));
                                }
                            } else if !defined_music.contains(&key) {
                                errors.push(format!(
                                    "Line {}: Undefined MUSIC ID {} in music({}) (not defined in @MUSIC/$MUSIC)",
                                    call_line, id, id
                                ));
                            }
                        }
                    } else if fn_name == "sfx" && (first_b == b'"' || first_b == b'\'') {
                        // インライン文字列リテラル `sfx("...")` の検証
                        let quote = first_b;
                        let mut end = arg_start + 1;
                        let mut has_interp = false;
                        while end < len {
                            if bytes[end] == b'\\' {
                                end = (end + 2).min(len);
                                continue;
                            }
                            if quote == b'"'
                                && bytes[end] == b'#'
                                && end + 1 < len
                                && bytes[end + 1] == b'{'
                            {
                                has_interp = true;
                            }
                            if bytes[end] == quote {
                                break;
                            }
                            end += 1;
                        }
                        if end < len && bytes[end] == quote && !has_interp {
                            let literal = &ruby_code[arg_start + 1..end];
                            let mut after_str = end + 1;
                            while after_str < len && bytes[after_str].is_ascii_whitespace() {
                                after_str += 1;
                            }
                            if after_str < len
                                && (bytes[after_str] == b',' || bytes[after_str] == b')')
                            {
                                let trimmed = literal.trim();
                                // `":name"` のような名前指定は定義済みチェック、それ以外はインライン定義構文チェック
                                if let Some(rest) = trimmed.strip_prefix(':')
                                    && !rest.is_empty()
                                    && !rest.chars().any(char::is_whitespace)
                                {
                                    let norm = SoundKey::normalize_name(rest);
                                    if !defined_sfx.contains(&SoundKey::Name(norm.clone()))
                                        && !is_builtin_preset(&norm)
                                    {
                                        errors.push(format!(
                                            "Line {}: Undefined SFX '{}' in sfx(\"{}\")",
                                            call_line, trimmed, literal
                                        ));
                                    }
                                } else if let Err(e) = validate_sfx_spec(trimmed) {
                                    errors.push(format!(
                                        "Line {}: Invalid inline SFX spec in sfx(\"{}\"): {}",
                                        call_line, literal, e
                                    ));
                                }
                            }
                        }
                    }
                }
                i += prefix_len;
                continue;
            }
        }

        i += 1;
    }

    errors
}

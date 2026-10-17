use std::collections::HashMap;
use std::f32::consts::TAU;

use macroquad::audio::{
    PlaySoundParams, Sound, load_sound_from_bytes, play_sound, stop_sound,
};
use mrubyedge::yamrb::value::RValue;
use mrubyedge::yamrb::vm::VM;

use crate::decode_base64;

pub const SAMPLE_RATE: u32 = 22050;
pub const NUM_SFX_CHANNELS: usize = 4;

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

// ==========================================
// プリセット効果音（サウンド版「絵文字」）
// ==========================================

/// プリセット効果音名（`:jump`, `:coin` 等）から PCM サンプル列を合成する
pub fn synthesize_preset_pcm(name: &str, pitch_mul: f32, speed_mul: f32, vol_mul: f32) -> Option<Vec<i16>> {
    let key = name
        .trim()
        .trim_start_matches(':')
        .to_ascii_lowercase();
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
        "explosion" | "boom" => vec![
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
        "click" => vec![SynthEvent {
            freq: 1200.0 * p,
            duration_sec: 0.015 / s,
            waveform: Waveform::Pulse12,
            volume: (0.7 * v).min(1.0),
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
// MML / ノート文字列パーサ
// ==========================================

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
        let line = raw_line
            .split('#')
            .next()
            .unwrap_or("")
            .trim();
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
    /// 2) `0 1 2 .` のような PICO-8 風 SFX パターン番号並び記法
    /// の両方をサポートする
    pub fn from_spec(spec: &str, sfx_map: &HashMap<i32, SfxData>) -> Self {
        let mut ch_specs: [Vec<String>; 4] = Default::default();
        let mut pattern_rows: Vec<[i32; 4]> = Vec::new();

        for raw_line in spec.lines() {
            let line = raw_line.split('#').next().unwrap_or("").trim();
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

            // パターン行 (`0 1 2 .` または `10, 11, -1, -1`)
            let tokens: Vec<&str> = line
                .split(|c: char| c.is_ascii_whitespace() || c == ',' || c == '|')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();
            if !tokens.is_empty()
                && tokens.iter().all(|t| {
                    matches!(*t, "." | "-" | "_") || t.parse::<i32>().is_ok()
                })
            {
                let mut row = [-1i32; 4];
                for (i, tok) in tokens.iter().take(4).enumerate() {
                    row[i] = match *tok {
                        "." | "-" | "_" => -1,
                        other => other.parse::<i32>().unwrap_or(-1),
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
            for &sfx_id in row {
                if sfx_id >= 0
                    && let Some(sfx) = sfx_map.get(&sfx_id)
                {
                    row_tracks.push(sfx.pcm.clone());
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
    Sfx(i32),
    WavB64(i32),
    Music(i32),
}

fn flush_tail_sound_block(
    kind: Option<TailSoundBlock>,
    lines: &mut Vec<String>,
    sfx_map: &mut HashMap<i32, SfxData>,
    music_specs: &mut Vec<(i32, String)>,
) {
    let Some(kind) = kind else {
        lines.clear();
        return;
    };
    if lines.is_empty() {
        return;
    }

    match kind {
        TailSoundBlock::Sfx(id) => {
            let spec = lines.join("\n");
            let sfx = SfxData::from_spec(&spec);
            if !sfx.pcm.is_empty() {
                sfx_map.insert(id, sfx);
            }
        }
        TailSoundBlock::WavB64(id) => {
            let b64: String = lines.iter().map(|s| s.trim()).collect();
            if let Ok(bytes) = decode_base64(&b64)
                && !bytes.is_empty()
            {
                sfx_map.insert(id, SfxData::from_raw_wav_bytes(&format!("@WAV {}", id), bytes));
            }
        }
        TailSoundBlock::Music(id) => {
            music_specs.push((id, lines.join("\n")));
        }
    }
    lines.clear();
}

/// `__END__` 以降の `@SFX`, `@WAV`, `@MUSIC` セクションをパースする
pub fn parse_tail_sounds(data_section: &str) -> (HashMap<i32, SfxData>, HashMap<i32, MusicData>) {
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
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_spec: Vec<&str> = parts.collect();
                if !inline_spec.is_empty() {
                    current_lines.push(inline_spec.join(" "));
                }
                current_block = Some(TailSoundBlock::Sfx(id));
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
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_b64: String = parts.collect::<Vec<_>>().join("");
                if !inline_b64.is_empty() {
                    current_lines.push(inline_b64);
                }
                current_block = Some(TailSoundBlock::WavB64(id));
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
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_spec: Vec<&str> = parts.collect();
                if !inline_spec.is_empty() {
                    current_lines.push(inline_spec.join(" "));
                }
                current_block = Some(TailSoundBlock::Music(id));
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
    for (id, spec) in music_specs {
        let m = MusicData::from_spec(&spec, &sfx_map);
        if !m.pcm.is_empty() {
            music_map.insert(id, m);
        }
    }

    (sfx_map, music_map)
}

/// Ruby グローバル変数 `$SFX` / `$MUSIC` からサウンド定義を取り込む
pub fn parse_ruby_sounds_globals(
    vm: &VM,
    sfx_map: &mut HashMap<i32, SfxData>,
    music_map: &mut HashMap<i32, MusicData>,
) {
    if let Some(sfx_obj) = vm.globals.get("$SFX") {
        match &sfx_obj.value {
            RValue::Array(list_cell) => {
                for (idx, item) in list_cell.borrow().iter().enumerate() {
                    if let Ok(s) = String::try_from(item.as_ref()) {
                        let sfx = SfxData::from_spec(&s);
                        if !sfx.pcm.is_empty() {
                            sfx_map.insert(idx as i32, sfx);
                        }
                    }
                }
            }
            RValue::Hash(map_cell) => {
                for (_, (k, v)) in map_cell.borrow().iter() {
                    let id_opt = match k.value {
                        RValue::Integer(i) => Some(i as i32),
                        _ => None,
                    };
                    if let Some(id) = id_opt
                        && let Ok(s) = String::try_from(v.as_ref())
                    {
                        let sfx = SfxData::from_spec(&s);
                        if !sfx.pcm.is_empty() {
                            sfx_map.insert(id, sfx);
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
                                    music_map.insert(idx as i32, m);
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
                                music_map.insert(idx as i32, m);
                            }
                        }
                        _ => {}
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
    PlaySfxId {
        id: i32,
        channel: i32,
        volume: f32,
    },
    PlaySfxInline {
        spec: String,
        channel: i32,
        volume: f32,
    },
    StopSfx {
        channel: i32,
    },
    PlayMusic {
        id: i32,
        looped: bool,
        volume: f32,
    },
    StopMusic,
}

pub struct SoundBank {
    pub sfx: HashMap<i32, SfxData>,
    pub music: HashMap<i32, MusicData>,
    pub inline_cache: HashMap<String, SfxData>,
    pub pending_commands: Vec<AudioCommand>,
    pub current_music_id: Option<i32>,
    pub last_played_sfx_id: Option<i32>,
    pub last_played_inline: Option<String>,
    loaded_sfx_sounds: HashMap<String, Sound>,
    loaded_music_sounds: HashMap<String, Sound>,
    active_channel_keys: [Option<String>; NUM_SFX_CHANNELS],
    active_music_key: Option<String>,
    next_rr_channel: usize,
}

impl SoundBank {
    pub fn new(sfx: HashMap<i32, SfxData>, music: HashMap<i32, MusicData>) -> Self {
        Self {
            sfx,
            music,
            inline_cache: HashMap::new(),
            pending_commands: Vec::new(),
            current_music_id: None,
            last_played_sfx_id: None,
            last_played_inline: None,
            loaded_sfx_sounds: HashMap::new(),
            loaded_music_sounds: HashMap::new(),
            active_channel_keys: Default::default(),
            active_music_key: None,
            next_rr_channel: 0,
        }
    }

    pub fn update_definitions(
        &mut self,
        new_sfx: HashMap<i32, SfxData>,
        new_music: HashMap<i32, MusicData>,
    ) {
        self.sfx = new_sfx;
        self.music = new_music;
    }

    pub fn queue_play_sfx_id(&mut self, id: i32, channel: i32, volume: f32) {
        if id < 0 {
            self.queue_stop_sfx(channel);
            return;
        }
        self.last_played_sfx_id = Some(id);
        self.pending_commands.push(AudioCommand::PlaySfxId {
            id,
            channel,
            volume: volume.clamp(0.0, 2.0),
        });
    }

    pub fn queue_play_sfx_inline(&mut self, spec: &str, channel: i32, volume: f32) {
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
        self.pending_commands.push(AudioCommand::PlaySfxInline {
            spec: key,
            channel,
            volume: volume.clamp(0.0, 2.0),
        });
    }

    pub fn queue_stop_sfx(&mut self, channel: i32) {
        self.pending_commands.push(AudioCommand::StopSfx { channel });
    }

    pub fn queue_play_music(&mut self, id: i32, looped: bool, volume: f32) {
        if id < 0 {
            self.queue_stop_music();
            return;
        }
        self.current_music_id = Some(id);
        self.pending_commands.push(AudioCommand::PlayMusic {
            id,
            looped,
            volume: volume.clamp(0.0, 2.0),
        });
    }

    pub fn queue_stop_music(&mut self) {
        self.current_music_id = None;
        self.pending_commands.push(AudioCommand::StopMusic);
    }

    /// 定義済み `@SFX` / `@MUSIC` や主要プリセットを事前ロードする（非ヘッドレス環境用）
    pub async fn preload_all(&mut self) {
        for preset in [
            "jump",
            "coin",
            "laser",
            "explosion",
            "hit",
            "powerup",
            "select",
            "click",
            "gameover",
        ] {
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
            .map(|(id, data)| (format!("id:{}:{}", id, data.spec), data.wav_bytes.clone()))
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
            .map(|(id, data)| (format!("music:{}:{}", id, data.spec), data.wav_bytes.clone()))
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
        if self.pending_commands.is_empty() {
            return;
        }
        let commands = std::mem::take(&mut self.pending_commands);

        for cmd in commands {
            match cmd {
                AudioCommand::PlaySfxId {
                    id,
                    channel,
                    volume,
                } => {
                    let Some(sfx_data) = self.sfx.get(&id) else {
                        continue;
                    };
                    let cache_key = format!("id:{}:{}", id, sfx_data.spec);
                    if !self.loaded_sfx_sounds.contains_key(&cache_key) {
                        if let Ok(snd) = load_sound_from_bytes(&sfx_data.wav_bytes).await {
                            self.loaded_sfx_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    self.play_cached_sfx_on_channel(&cache_key, channel, volume);
                }
                AudioCommand::PlaySfxInline {
                    spec,
                    channel,
                    volume,
                } => {
                    let Some(sfx_data) = self.inline_cache.get(&spec) else {
                        continue;
                    };
                    let cache_key = format!("in:{}", spec);
                    if !self.loaded_sfx_sounds.contains_key(&cache_key) {
                        if let Ok(snd) = load_sound_from_bytes(&sfx_data.wav_bytes).await {
                            self.loaded_sfx_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    self.play_cached_sfx_on_channel(&cache_key, channel, volume);
                }
                AudioCommand::StopSfx { channel } => {
                    if channel < 0 {
                        for slot in &mut self.active_channel_keys {
                            if let Some(key) = slot.take()
                                && let Some(snd) = self.loaded_sfx_sounds.get(&key)
                            {
                                stop_sound(snd);
                            }
                        }
                    } else if (channel as usize) < NUM_SFX_CHANNELS {
                        if let Some(key) = self.active_channel_keys[channel as usize].take()
                            && let Some(snd) = self.loaded_sfx_sounds.get(&key)
                        {
                            stop_sound(snd);
                        }
                    }
                }
                AudioCommand::PlayMusic { id, looped, volume } => {
                    if let Some(prev_key) = self.active_music_key.take()
                        && let Some(prev_snd) = self.loaded_music_sounds.get(&prev_key)
                    {
                        stop_sound(prev_snd);
                    }
                    let Some(music_data) = self.music.get(&id) else {
                        continue;
                    };
                    let cache_key = format!("music:{}:{}", id, music_data.spec);
                    if !self.loaded_music_sounds.contains_key(&cache_key) {
                        if let Ok(snd) = load_sound_from_bytes(&music_data.wav_bytes).await {
                            self.loaded_music_sounds.insert(cache_key.clone(), snd);
                        }
                    }
                    if let Some(snd) = self.loaded_music_sounds.get(&cache_key) {
                        play_sound(
                            snd,
                            PlaySoundParams {
                                looped,
                                volume,
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
            }
        }
    }

    fn play_cached_sfx_on_channel(&mut self, cache_key: &str, channel: i32, volume: f32) {
        let ch_idx = if channel >= 0 && (channel as usize) < NUM_SFX_CHANNELS {
            let idx = channel as usize;
            if let Some(prev_key) = self.active_channel_keys[idx].take()
                && let Some(prev_snd) = self.loaded_sfx_sounds.get(&prev_key)
            {
                stop_sound(prev_snd);
            }
            idx
        } else {
            let idx = self.next_rr_channel;
            self.next_rr_channel = (self.next_rr_channel + 1) % NUM_SFX_CHANNELS;
            idx
        };

        if let Some(snd) = self.loaded_sfx_sounds.get(cache_key) {
            stop_sound(snd);
            play_sound(
                snd,
                PlaySoundParams {
                    looped: false,
                    volume,
                },
            );
            self.active_channel_keys[ch_idx] = Some(cache_key.to_string());
        }
    }
}

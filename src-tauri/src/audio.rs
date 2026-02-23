use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use tauri::{AppHandle, Emitter};

const TARGET_RATE: u32 = 16000;

// RMS level (as fixed-point u32, value * 1_000_000) below which a chunk is
// considered "silent / mic still initialising". We skip forwarding until the
// mic produces audio above this floor OR the hard skip window expires.
// 0.005 * 1_000_000 = 5_000  (~ambient noise floor)
const WARMUP_RMS_THRESHOLD: f32 = 0.005;
// Maximum number of chunks to skip regardless of RMS (= 1 500 ms @ 100 ms/chunk)
const WARMUP_MAX_SKIP: u32 = 15;

pub struct AudioCapture {
    is_active: Arc<AtomicBool>,
    // Per-session stop signal. Each start() creates a fresh one so that
    // stop() + immediate start() cannot leave the old thread running:
    //   - stop() fires the old thread's signal → callback stops immediately
    //   - new thread gets its own signal, unaffected by any previous session
    thread_stop: Option<Arc<AtomicBool>>,
    // Counts down from WARMUP_MAX_SKIP to 0 at session start.
    // While > 0 and RMS is below threshold, chunks are discarded.
    warmup_remaining: Arc<AtomicU32>,
}

impl AudioCapture {
    pub fn new() -> Self {
        Self {
            is_active: Arc::new(AtomicBool::new(false)),
            thread_stop: None,
            warmup_remaining: Arc::new(AtomicU32::new(0)),
        }
    }

    pub fn start(&mut self, app: AppHandle, device_name: Option<String>) {
        if self.is_active.swap(true, Ordering::SeqCst) {
            return; // already running
        }
        self.warmup_remaining.store(WARMUP_MAX_SKIP, Ordering::SeqCst);

        // Fresh per-session stop signal — the callback and thread loop check
        // this instead of the shared is_active, so old threads exit cleanly
        // even when a new session sets is_active back to true.
        let stop = Arc::new(AtomicBool::new(false));
        self.thread_stop = Some(Arc::clone(&stop));

        let is_active = Arc::clone(&self.is_active);
        let warmup_remaining = Arc::clone(&self.warmup_remaining);

        std::thread::spawn(move || {
            let host = cpal::default_host();

            let device = if let Some(name) = device_name {
                let found = host
                    .input_devices()
                    .ok()
                    .and_then(|mut devs| devs.find(|d| d.name().map(|n| n == name).unwrap_or(false)));

                match found {
                    Some(d) => d,
                    None => {
                        eprintln!("[audio] Device '{}' not found, falling back to default", name);
                        match host.default_input_device() {
                            Some(d) => d,
                            None => {
                                eprintln!("[audio] No input device");
                                is_active.store(false, Ordering::SeqCst);
                                return;
                            }
                        }
                    }
                }
            } else {
                match host.default_input_device() {
                    Some(d) => d,
                    None => {
                        eprintln!("[audio] No input device");
                        is_active.store(false, Ordering::SeqCst);
                        return;
                    }
                }
            };

            let default_cfg = match device.default_input_config() {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[audio] Config error: {:?}", e);
                    is_active.store(false, Ordering::SeqCst);
                    return;
                }
            };

            let actual_rate = default_cfg.sample_rate().0;
            let channels = default_cfg.channels() as usize;
            let device_name_str = device.name().unwrap_or_else(|_| "unknown".to_string());
            eprintln!("[audio] Capture: {}Hz, {} ch, device={}", actual_rate, channels, device_name_str);

            let sample_fmt = default_cfg.sample_format();
            let stream_cfg = cpal::StreamConfig {
                channels: default_cfg.channels(),
                sample_rate: default_cfg.sample_rate(),
                buffer_size: cpal::BufferSize::Default,
            };

            let ratio = actual_rate as f64 / TARGET_RATE as f64;

            // Build a typed input stream for the device's native sample format,
            // converting each sample to f32 before processing. This avoids
            // StreamTypeNotSupported errors on devices that don't provide f32
            // (e.g. USB mics that only expose i16).
            macro_rules! build_stream {
                ($t:ty, $to_f32:expr) => {{
                    let stop_cb = Arc::clone(&stop);
                    let warmup_cb = Arc::clone(&warmup_remaining);
                    let app_cb = app.clone();
                    device.build_input_stream(
                        &stream_cfg,
                        {
                            let mut pos = 0.0_f64;
                            let mut buf: Vec<i16> = Vec::new();
                            // emit every 100ms = 1600 samples at 16kHz
                            const EMIT_THRESHOLD: usize = 1600;
                            move |data: &[$t], _| {
                                if stop_cb.load(Ordering::SeqCst) { return; }
                                // convert to f32 and mix to mono
                                let mono: Vec<f32> = data.chunks(channels)
                                    .map(|ch| ch.iter().map(|&s| $to_f32(s)).sum::<f32>() / channels as f32)
                                    .collect();
                                // resample to 16000Hz into buffer
                                while pos < mono.len() as f64 {
                                    let i = pos as usize;
                                    let f = (pos - i as f64) as f32;
                                    let s = if i + 1 < mono.len() {
                                        mono[i] + f * (mono[i + 1] - mono[i])
                                    } else {
                                        mono[i]
                                    };
                                    buf.push((s * 32767.0).clamp(-32768.0, 32767.0) as i16);
                                    pos += ratio;
                                }
                                pos -= mono.len() as f64;
                                if buf.len() >= EMIT_THRESHOLD {
                                    let remaining = warmup_cb.load(Ordering::Relaxed);
                                    if remaining > 0 {
                                        let rms = {
                                            let sum_sq: f64 = buf.iter()
                                                .map(|&s| (s as f64 / 32768.0).powi(2))
                                                .sum();
                                            (sum_sq / buf.len() as f64).sqrt() as f32
                                        };
                                        if rms >= WARMUP_RMS_THRESHOLD {
                                            warmup_cb.store(0, Ordering::Relaxed);
                                            let _ = app_cb.emit("audio:chunk", buf.clone());
                                        } else {
                                            warmup_cb.store(remaining - 1, Ordering::Relaxed);
                                        }
                                    } else {
                                        let _ = app_cb.emit("audio:chunk", buf.clone());
                                    }
                                    buf.clear();
                                }
                            }
                        },
                        |err| eprintln!("[audio] Error: {:?}", err),
                        None,
                    )
                }};
            }

            let stream = match sample_fmt {
                cpal::SampleFormat::F32 => build_stream!(f32, |s: f32| s),
                cpal::SampleFormat::I16 => build_stream!(i16, |s: i16| s as f32 / 32768.0),
                cpal::SampleFormat::I32 => build_stream!(i32, |s: i32| s as f32 / 2_147_483_648.0),
                cpal::SampleFormat::U16 => build_stream!(u16, |s: u16| (s as f32 - 32768.0) / 32768.0),
                fmt => {
                    eprintln!("[audio] Unsupported sample format {:?}, trying f32", fmt);
                    build_stream!(f32, |s: f32| s)
                }
            };

            match stream {
                Ok(s) => {
                    s.play().ok();
                    // Block on the per-session stop signal (not shared is_active).
                    while !stop.load(Ordering::SeqCst) {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    // Explicitly pause before drop — CoreAudio needs AudioDeviceStop
                    // called before AudioDeviceDestroyIOProcID to release the device.
                    s.pause().ok();
                    drop(s);
                    // Do NOT touch is_active here on normal exit — stop() already
                    // cleared it, and a new session may have set it back to true.
                }
                Err(e) => {
                    eprintln!("[audio] Build error: {:?}", e);
                    is_active.store(false, Ordering::SeqCst);
                }
            }
        });
    }

    pub fn stop(&mut self) {
        // Fire the per-session stop signal so the thread's callback halts
        // immediately and the thread exits its sleep loop within ~10 ms.
        if let Some(sig) = self.thread_stop.take() {
            sig.store(true, Ordering::SeqCst);
        }
        self.is_active.store(false, Ordering::SeqCst);
        self.warmup_remaining.store(0, Ordering::SeqCst);
    }
}

#[tauri::command]
pub fn list_audio_devices() -> Vec<String> {
    let host = cpal::default_host();
    match host.input_devices() {
        Ok(devices) => devices.filter_map(|d| d.name().ok()).collect(),
        Err(_) => vec![],
    }
}

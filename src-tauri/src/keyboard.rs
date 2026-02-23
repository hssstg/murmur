use crate::audio::AudioCapture;
use crate::config::SharedConfig;
use device_query::{DeviceQuery, DeviceState, Keycode};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, LogicalPosition, Manager};

fn hotkey_to_keycode(s: &str) -> Keycode {
    match s {
        "LOption" => Keycode::LOption,
        "RControl" => Keycode::RControl,
        "LControl" => Keycode::LControl,
        "F13" => Keycode::F13,
        "F14" => Keycode::F14,
        "F15" => Keycode::F15,
        _ => Keycode::ROption, // default
    }
}

pub fn start(app: AppHandle, audio: Arc<Mutex<AudioCapture>>, config: SharedConfig) {
    std::thread::spawn(move || {
        let device_state = DeviceState::new();
        let is_held = AtomicBool::new(false);
        let held_by_keyboard = AtomicBool::new(false);

        loop {
            let keys = device_state.get_keys();
            let hotkey = hotkey_to_keycode(&config.lock().unwrap().hotkey);
            let ptt_pressed = keys.contains(&hotkey);

            // File-based trigger for automated testing:
            //   touch /tmp/murmur_ptt_start  → simulate key press
            //   touch /tmp/murmur_ptt_stop   → simulate key release
            let file_start = std::path::Path::new("/tmp/murmur_ptt_start").exists();
            let file_stop  = std::path::Path::new("/tmp/murmur_ptt_stop").exists();
            if file_start { std::fs::remove_file("/tmp/murmur_ptt_start").ok(); }
            if file_stop  { std::fs::remove_file("/tmp/murmur_ptt_stop").ok(); }

            let currently_held = is_held.load(Ordering::SeqCst);

            // --- START ---
            if !currently_held && (ptt_pressed || file_start) {
                is_held.store(true, Ordering::SeqCst);
                held_by_keyboard.store(ptt_pressed, Ordering::SeqCst);
                position_window_at_cursor(&app, &device_state);
                if let Ok(mut a) = audio.lock() {
                    let device_name = config.lock().unwrap().microphone.clone();
                    a.start(app.clone(), device_name);
                }
                let _ = app.emit("ptt:start", ());

            // --- STOP ---
            } else if currently_held {
                let by_kb = held_by_keyboard.load(Ordering::SeqCst);
                let stop = (by_kb && !ptt_pressed) || (!by_kb && file_stop);
                if stop {
                    is_held.store(false, Ordering::SeqCst);
                    if let Ok(mut a) = audio.lock() {
                        a.stop();
                    }
                    let _ = app.emit("ptt:stop", ());
                }
            }

            std::thread::sleep(Duration::from_millis(20));
        }
    });
}

fn position_window_at_cursor(app: &AppHandle, device_state: &DeviceState) {
    let window = match app.get_webview_window("main") {
        Some(w) => w,
        None => return,
    };

    let monitors = match app.available_monitors() {
        Ok(m) => m,
        Err(_) => return,
    };

    let mouse = device_state.get_mouse();
    let (cursor_x, cursor_y) = (mouse.coords.0 as f64, mouse.coords.1 as f64);

    const WIN_W: f64 = 360.0;
    const WIN_H: f64 = 130.0;
    const MARGIN_BOTTOM: f64 = 120.0;

    let target = monitors.iter().find(|m| {
        let scale = m.scale_factor();
        let x = m.position().x as f64 / scale;
        let y = m.position().y as f64 / scale;
        let w = m.size().width as f64 / scale;
        let h = m.size().height as f64 / scale;
        cursor_x >= x && cursor_x < x + w && cursor_y >= y && cursor_y < y + h
    });

    let monitor = match target.or_else(|| monitors.first()) {
        Some(m) => m,
        None => return,
    };

    let scale = monitor.scale_factor();
    let mon_x = monitor.position().x as f64 / scale;
    let mon_y = monitor.position().y as f64 / scale;
    let mon_w = monitor.size().width as f64 / scale;
    let mon_h = monitor.size().height as f64 / scale;

    let x = mon_x + (mon_w - WIN_W) / 2.0;
    let y = mon_y + mon_h - WIN_H - MARGIN_BOTTOM;

    let _ = window.set_position(LogicalPosition::new(x, y));
}

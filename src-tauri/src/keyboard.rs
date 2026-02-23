use crate::audio::AudioCapture;
use crate::config::SharedConfig;
use rdev::{listen, Event, EventType, Key};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, LogicalPosition, Manager};

fn hotkey_to_key(s: &str) -> Key {
    match s {
        "LAlt"     => Key::Alt,            // Left Alt  (macOS: Left Option,  kVK_Option = 58)
        "RControl" => Key::Unknown(62),    // Right Control (kVK_RightControl = 62, rdev workaround)
        "LControl" => Key::ControlLeft,    // Left Control  (kVK_Control = 59)
        "RShift"   => Key::ShiftRight,     // Right Shift   (kVK_RightShift = 60)
        "CapsLock" => Key::CapsLock,       // Caps Lock     (kVK_CapsLock = 57)
        // Legacy values from old configs — keep working after migration
        "LOption"  => Key::Alt,
        "ROption"  => Key::AltGr,
        "F13"      => Key::Unknown(105),
        "F14"      => Key::Unknown(107),
        "F15"      => Key::Unknown(113),
        _          => Key::AltGr,          // RAlt / default (macOS: Right Option, kVK_RightOption = 61)
    }
}

pub fn start(app: AppHandle, audio: Arc<Mutex<AudioCapture>>, config: SharedConfig) {
    // Shared cursor position updated by MouseMove events.
    let cursor_x = Arc::new(AtomicI32::new(0));
    let cursor_y = Arc::new(AtomicI32::new(0));

    let is_held   = Arc::new(AtomicBool::new(false));

    // Clone arcs for the listener closure.
    let cx = cursor_x.clone();
    let cy = cursor_y.clone();
    let held   = is_held.clone();
    let app2   = app.clone();
    let audio2 = audio.clone();
    let config2 = config.clone();

    std::thread::spawn(move || {
        let callback = move |event: Event| {
            let hotkey = hotkey_to_key(&config2.lock().unwrap().hotkey);

            match event.event_type {
                EventType::MouseMove { x, y } => {
                    cx.store(x as i32, Ordering::Relaxed);
                    cy.store(y as i32, Ordering::Relaxed);
                }

                EventType::KeyPress(key) if key == hotkey => {
                    // Guard against key-repeat events.
                    if held.swap(true, Ordering::SeqCst) {
                        return;
                    }
                    let mouse_x = cx.load(Ordering::Relaxed) as f64;
                    let mouse_y = cy.load(Ordering::Relaxed) as f64;
                    position_window_at_cursor(&app2, mouse_x, mouse_y);
                    if let Ok(mut a) = audio2.lock() {
                        let device_name = config2.lock().unwrap().microphone.clone();
                        a.start(app2.clone(), device_name);
                    }
                    let _ = app2.emit("ptt:start", ());
                }

                EventType::KeyRelease(key) if key == hotkey => {
                    if !held.swap(false, Ordering::SeqCst) {
                        return;
                    }
                    if let Ok(mut a) = audio2.lock() {
                        a.stop();
                    }
                    let _ = app2.emit("ptt:stop", ());
                }

                _ => {}
            }
        };

        if let Err(e) = listen(callback) {
            eprintln!("[keyboard] rdev listen error: {:?}", e);
        }
    });

    // File-based trigger for automated testing (debug builds only).
    #[cfg(debug_assertions)]
    {
        let held_file = is_held.clone();
        std::thread::spawn(move || {
            loop {
                let file_start = std::path::Path::new("/tmp/murmur_ptt_start").exists();
                let file_stop  = std::path::Path::new("/tmp/murmur_ptt_stop").exists();
                if file_start { std::fs::remove_file("/tmp/murmur_ptt_start").ok(); }
                if file_stop  { std::fs::remove_file("/tmp/murmur_ptt_stop").ok(); }

                let currently_held = held_file.load(Ordering::SeqCst);

                if !currently_held && file_start {
                    held_file.store(true, Ordering::SeqCst);
                    position_window_at_cursor(&app, 0.0, 0.0);
                    if let Ok(mut a) = audio.lock() {
                        let device_name = config.lock().unwrap().microphone.clone();
                        a.start(app.clone(), device_name);
                    }
                    let _ = app.emit("ptt:start", ());
                } else if currently_held && file_stop {
                    held_file.store(false, Ordering::SeqCst);
                    if let Ok(mut a) = audio.lock() {
                        a.stop();
                    }
                    let _ = app.emit("ptt:stop", ());
                }

                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        });
    }
}

fn position_window_at_cursor(app: &AppHandle, cursor_x: f64, cursor_y: f64) {
    let window = match app.get_webview_window("main") {
        Some(w) => w,
        None => return,
    };

    let monitors = match app.available_monitors() {
        Ok(m) => m,
        Err(_) => return,
    };

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

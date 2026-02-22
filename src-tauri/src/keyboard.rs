use rdev::{listen, Event, EventType, Key};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let is_held = Arc::new(AtomicBool::new(false));
        let is_held_clone = is_held.clone();

        let callback = move |event: Event| {
            match event.event_type {
                EventType::KeyPress(Key::AltGr) => {
                    if !is_held_clone.load(Ordering::SeqCst) {
                        is_held_clone.store(true, Ordering::SeqCst);
                        let _ = app.emit("ptt:start", ());
                    }
                }
                EventType::KeyRelease(Key::AltGr) => {
                    if is_held_clone.load(Ordering::SeqCst) {
                        is_held_clone.store(false, Ordering::SeqCst);
                        let _ = app.emit("ptt:stop", ());
                    }
                }
                _ => {}
            }
        };

        if let Err(e) = listen(callback) {
            eprintln!("[keyboard] rdev listen error: {:?}", e);
        }
    });
}

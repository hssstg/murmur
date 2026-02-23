use crate::audio::AudioCapture;
use crate::config::SharedConfig;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, LogicalPosition, Manager};

// ─── macOS Virtual Key Codes ──────────────────────────────────────────────────

fn hotkey_to_vkcode(s: &str) -> u64 {
    match s {
        "ROption"  => 61, // kVK_RightOption
        "LOption"  => 58, // kVK_Option
        "RControl" => 62, // kVK_RightControl
        "LControl" => 59, // kVK_Control
        "CapsLock" => 57, // kVK_CapsLock
        "F13"      => 105,
        "F14"      => 107,
        "F15"      => 113,
        _          => 61,
    }
}

/// Returns true if the key code is a modifier key (detected via FlagsChanged).
fn is_modifier_vk(code: u64) -> bool {
    matches!(code, 58 | 59 | 61 | 62 | 57)
}

/// Returns the CGEventFlags bit that corresponds to a modifier key code.
fn modifier_flag_bit(code: u64) -> u64 {
    match code {
        58 | 61 => 0x0008_0000, // kCGEventFlagMaskAlternate  (Option)
        59 | 62 => 0x0004_0000, // kCGEventFlagMaskControl
        57      => 0x0001_0000, // kCGEventFlagMaskAlphaShift (CapsLock)
        _       => 0,
    }
}

// ─── CoreGraphics / CoreFoundation FFI ───────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

extern "C" {
    // CoreGraphics
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: unsafe extern "C" fn(*mut c_void, u32, *mut c_void, *mut c_void) -> *mut c_void,
        user_info: *mut c_void,
    ) -> *mut c_void;
    fn CGEventGetIntegerValueField(event: *mut c_void, field: i32) -> i64;
    fn CGEventGetFlags(event: *mut c_void) -> u64;
    fn CGEventGetLocation(event: *mut c_void) -> CGPoint;

    // CoreFoundation
    fn CFMachPortCreateRunLoopSource(
        alloc: *mut c_void,
        tap: *mut c_void,
        order: isize,
    ) -> *mut c_void;
    fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopGetCurrent() -> *mut c_void;
    fn CFRunLoopRun();
    static kCFRunLoopCommonModes: *const c_void;
    fn CGEventTapEnable(tap: *mut c_void, enable: bool);
}

// ─── Callback data ────────────────────────────────────────────────────────────

struct TapData {
    app: AppHandle,
    audio: Arc<Mutex<AudioCapture>>,
    config: SharedConfig,
    held: Arc<AtomicBool>,
    cursor_x: Arc<AtomicI32>,
    cursor_y: Arc<AtomicI32>,
    /// Tracks the current modifier-flag bit for the configured hotkey,
    /// so we can detect press (0→N) and release (N→0) transitions.
    prev_flag: AtomicU64,
}

// TapData lives on the heap and is accessed only from the CFRunLoop callback
// thread.  All inner types are Send+Sync, so this is safe.
unsafe impl Send for TapData {}
unsafe impl Sync for TapData {}

// CGEventType values
const EV_MOUSE_MOVED:   u32 = 5;
const EV_MOUSE_DRAG_L:  u32 = 6;
const EV_MOUSE_DRAG_R:  u32 = 7;
const EV_KEY_DOWN:      u32 = 10;
const EV_KEY_UP:        u32 = 11;
const EV_FLAGS_CHANGED: u32 = 12;

// kCGKeyboardEventKeycode
const FIELD_KEYCODE: i32 = 9;

fn event_mask() -> u64 {
    (1 << EV_MOUSE_MOVED)
        | (1 << EV_MOUSE_DRAG_L)
        | (1 << EV_MOUSE_DRAG_R)
        | (1 << EV_KEY_DOWN)
        | (1 << EV_KEY_UP)
        | (1 << EV_FLAGS_CHANGED)
}

unsafe extern "C" fn tap_callback(
    _proxy: *mut c_void,
    event_type: u32,
    event: *mut c_void,
    refcon: *mut c_void,
) -> *mut c_void {
    let d = &*(refcon as *const TapData);

    // Update cursor position from mouse events (no TSM involvement).
    if matches!(event_type, EV_MOUSE_MOVED | EV_MOUSE_DRAG_L | EV_MOUSE_DRAG_R) {
        let pt = CGEventGetLocation(event);
        d.cursor_x.store(pt.x as i32, Ordering::Relaxed);
        d.cursor_y.store(pt.y as i32, Ordering::Relaxed);
        return event;
    }

    let keycode = CGEventGetIntegerValueField(event, FIELD_KEYCODE) as u64;
    let hotkey = hotkey_to_vkcode(&d.config.lock().unwrap().hotkey);

    let (pressed, released) = if is_modifier_vk(hotkey) {
        // Modifier key: detect press/release via flags transition.
        if event_type == EV_FLAGS_CHANGED && keycode == hotkey {
            let bit = modifier_flag_bit(hotkey);
            let flags = CGEventGetFlags(event);
            let prev = d.prev_flag.load(Ordering::SeqCst);
            let curr = flags & bit;
            d.prev_flag.store(curr, Ordering::SeqCst);
            (prev == 0 && curr != 0, prev != 0 && curr == 0)
        } else {
            (false, false)
        }
    } else {
        // Regular key (F13-F15): detect via key down / key up.
        if keycode == hotkey {
            (event_type == EV_KEY_DOWN, event_type == EV_KEY_UP)
        } else {
            (false, false)
        }
    };

    if pressed && !d.held.swap(true, Ordering::SeqCst) {
        let mx = d.cursor_x.load(Ordering::Relaxed) as f64;
        let my = d.cursor_y.load(Ordering::Relaxed) as f64;
        position_window_at_cursor(&d.app, mx, my);
        if let Ok(mut a) = d.audio.lock() {
            let dev = d.config.lock().unwrap().microphone.clone();
            a.start(d.app.clone(), dev);
        }
        let _ = d.app.emit("ptt:start", ());
    } else if released && d.held.swap(false, Ordering::SeqCst) {
        if let Ok(mut a) = d.audio.lock() {
            a.stop();
        }
        let _ = d.app.emit("ptt:stop", ());
    }

    event
}

// ─── Public entry point ───────────────────────────────────────────────────────

pub fn start(app: AppHandle, audio: Arc<Mutex<AudioCapture>>, config: SharedConfig) {
    let is_held = Arc::new(AtomicBool::new(false));
    let cursor_x = Arc::new(AtomicI32::new(0));
    let cursor_y = Arc::new(AtomicI32::new(0));

    let data = Box::new(TapData {
        app: app.clone(),
        audio: audio.clone(),
        config: config.clone(),
        held: is_held.clone(),
        cursor_x: cursor_x.clone(),
        cursor_y: cursor_y.clone(),
        prev_flag: AtomicU64::new(0),
    });
    // usize is Send; we recover the pointer inside the thread.
    let data_usize = Box::into_raw(data) as usize;

    std::thread::spawn(move || unsafe {
        let data_ptr = data_usize as *mut c_void;

        // kCGSessionEventTap=1, kCGHeadInsertEventTap=0, kCGEventTapOptionDefault=0
        let tap = CGEventTapCreate(1, 0, 0, event_mask(), tap_callback, data_ptr);
        if tap.is_null() {
            eprintln!("[keyboard] CGEventTapCreate failed — grant Accessibility permission");
            drop(Box::from_raw(data_ptr as *mut TapData));
            return;
        }
        let source = CFMachPortCreateRunLoopSource(std::ptr::null_mut(), tap, 0);
        if source.is_null() {
            eprintln!("[keyboard] CFMachPortCreateRunLoopSource failed");
            drop(Box::from_raw(data_ptr as *mut TapData));
            return;
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
        CFRunLoopRun();
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

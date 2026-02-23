mod audio;
mod config;
mod keyboard;
mod text;

use audio::AudioCapture;
use config::{Config, SharedConfig};
use audio::list_audio_devices;
use std::sync::{Arc, Mutex};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let audio = Arc::new(Mutex::new(AudioCapture::new()));
    let cfg: SharedConfig = Arc::new(Mutex::new(Config::default()));

    let cfg_for_setup = Arc::clone(&cfg);
    let cfg_for_keyboard = Arc::clone(&cfg);

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_websocket::init())
        .manage(Arc::clone(&cfg))
        .invoke_handler(tauri::generate_handler![
            text::insert_text,
            text::append_log,
            config::get_config,
            config::save_config,
            list_audio_devices,
        ])
        .setup(move |app| {
            // Load config from disk and update shared state
            let loaded = config::load_config(app.handle());
            *cfg_for_setup.lock().unwrap() = loaded;

            let settings_item =
                MenuItem::with_id(app, "settings", "Settings...", true, None::<&str>)?;
            let devtools_item =
                MenuItem::with_id(app, "devtools", "Open DevTools", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Murmur", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings_item, &devtools_item, &quit])?;

            TrayIconBuilder::new()
                .icon(tauri::include_image!("icons/tray.png"))
                .icon_as_template(true)
                .menu(&menu)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "settings" => {
                        if let Some(w) = app.get_webview_window("settings") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        } else if let Ok(w) = tauri::WebviewWindowBuilder::new(
                            app,
                            "settings",
                            tauri::WebviewUrl::App("index.html".into()),
                        )
                        .title("Murmur Settings")
                        .inner_size(520.0, 480.0)
                        .resizable(false)
                        .always_on_top(false)
                        .transparent(false)
                        .build()
                        {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "devtools" => {
                        if let Some(w) = app.get_webview_window("main") {
                            w.open_devtools();
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            keyboard::start(app.handle().clone(), Arc::clone(&audio), cfg_for_keyboard);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

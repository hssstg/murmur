use enigo::{Enigo, Keyboard, Settings};

#[tauri::command]
pub fn insert_text(text: String) -> Result<(), String> {
    // Give time for the floating window to hide and focus to return to target app
    std::thread::sleep(std::time::Duration::from_millis(150));

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.text(&text).map_err(|e| e.to_string())?;
    Ok(())
}

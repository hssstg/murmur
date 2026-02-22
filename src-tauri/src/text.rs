use enigo::{Enigo, Keyboard, Settings};

#[tauri::command]
pub async fn insert_text(text: String) -> Result<(), String> {
    // Wait for window to hide and focus to return to the target app
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.text(&text).map_err(|e| e.to_string())?;
    Ok(())
}

use enigo::{Enigo, Keyboard, Settings};

#[tauri::command]
pub fn append_log(line: String) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/murmur_debug.log")
    {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let _ = writeln!(f, "[{}] {}", ts, line);
    }
}

#[tauri::command]
pub async fn insert_text(text: String) -> Result<(), String> {
    // Wait for window to hide and focus to return to the target app
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.text(&text).map_err(|e| e.to_string())?;
    Ok(())
}

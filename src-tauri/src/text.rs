use enigo::{Enigo, Keyboard, Settings};

/// Strips leading punctuation left by filler removal
/// (e.g. LLM outputs "，就是说..." after removing a leading filler).
pub(crate) fn strip_leading_punctuation(s: &str) -> &str {
    s.trim()
        .trim_start_matches(|c| matches!(c, '，' | '。' | '、' | '；' | '：' | '？' | '！' | ',' | '.' | ';' | ':'))
        .trim()
}

#[tauri::command]
pub fn append_log(#[allow(unused_variables)] line: String) {
    #[cfg(debug_assertions)]
    {
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
}

#[tauri::command]
pub async fn insert_text(text: String) -> Result<(), String> {
    // Wait for window to hide and focus to return to the target app
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.text(&text).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn polish_text(
    text: String,
    llm_base_url: String,
    llm_api_key: String,
    llm_model: String,
    system_prompt: String,
) -> Result<String, String> {
    let url = format!(
        "{}/v1/chat/completions",
        llm_base_url.trim_end_matches('/')
    );

    let body = serde_json::json!({
        "model": llm_model,
        "think": false,
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": text }
        ],
        "stream": false
    });

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client.post(&url).json(&body);
    if !llm_api_key.is_empty() {
        req = req.bearer_auth(&llm_api_key);
    }

    let res = req.send().await.map_err(|e| e.to_string())?;
    let status = res.status();
    if !status.is_success() {
        let body = res.text().await.unwrap_or_default();
        append_log(format!("polish_text HTTP {}: {}", status, &body[..body.len().min(200)]));
        return Ok(text);
    }

    let data: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    let polished = data["choices"][0]["message"]["content"]
        .as_str()
        .map(|s| {
            strip_leading_punctuation(s).to_string()
        })
        .filter(|s| !s.is_empty())
        .unwrap_or(text);

    Ok(polished)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_chinese_leading_punctuation() {
        assert_eq!(strip_leading_punctuation("，就是说"), "就是说");
        assert_eq!(strip_leading_punctuation("。好的"), "好的");
        assert_eq!(strip_leading_punctuation("、然后"), "然后");
        assert_eq!(strip_leading_punctuation("；接着"), "接着");
        assert_eq!(strip_leading_punctuation("：说明"), "说明");
        assert_eq!(strip_leading_punctuation("？问题"), "问题");
        assert_eq!(strip_leading_punctuation("！感叹"), "感叹");
    }

    #[test]
    fn test_strip_english_leading_punctuation() {
        assert_eq!(strip_leading_punctuation(",hello"), "hello");
        assert_eq!(strip_leading_punctuation(".world"), "world");
        assert_eq!(strip_leading_punctuation(";next"), "next");
        assert_eq!(strip_leading_punctuation(":label"), "label");
    }

    #[test]
    fn test_strip_trims_whitespace_around_punctuation() {
        assert_eq!(strip_leading_punctuation("  ，  文本  "), "文本");
        assert_eq!(strip_leading_punctuation("  .  text  "), "text");
    }

    #[test]
    fn test_strip_preserves_normal_text() {
        assert_eq!(strip_leading_punctuation("正常文本"), "正常文本");
        assert_eq!(strip_leading_punctuation("hello world"), "hello world");
    }

    #[test]
    fn test_strip_multiple_leading_punctuation() {
        assert_eq!(strip_leading_punctuation("，。、文本"), "文本");
        assert_eq!(strip_leading_punctuation(",.;text"), "text");
    }

    #[test]
    fn test_strip_empty_and_punctuation_only() {
        assert_eq!(strip_leading_punctuation(""), "");
        assert_eq!(strip_leading_punctuation("，。"), "");
        assert_eq!(strip_leading_punctuation("   "), "");
    }

    #[test]
    fn test_strip_preserves_trailing_punctuation() {
        assert_eq!(strip_leading_punctuation("，文本，"), "文本，");
        assert_eq!(strip_leading_punctuation(",text,"), "text,");
    }

    #[test]
    fn test_llm_polish_url_trailing_slash_stripped() {
        let base = "https://api.example.com/";
        let url = format!("{}/v1/chat/completions", base.trim_end_matches('/'));
        assert_eq!(url, "https://api.example.com/v1/chat/completions");

        let base_no_slash = "https://api.example.com";
        let url2 = format!("{}/v1/chat/completions", base_no_slash.trim_end_matches('/'));
        assert_eq!(url2, "https://api.example.com/v1/chat/completions");
    }
}


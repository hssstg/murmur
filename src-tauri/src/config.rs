use std::sync::{Arc, Mutex};
use tauri::Manager;

pub type SharedConfig = Arc<Mutex<Config>>;

fn default_asr_language() -> String { "zh-CN".to_string() }
fn default_true() -> bool { true }

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Config {
    pub api_app_id: String,
    pub api_access_token: String,
    pub api_resource_id: String,
    pub hotkey: String, // "ROption","LOption","RControl","LControl","F13","F14","F15"
    pub microphone: Option<String>, // None = system default
    #[serde(default = "default_asr_language")]
    pub asr_language: String,
    #[serde(default = "default_true")]
    pub asr_enable_punc: bool,
    #[serde(default = "default_true")]
    pub asr_enable_itn: bool,
    #[serde(default = "default_true")]
    pub asr_enable_ddc: bool,
    #[serde(default)]
    pub asr_vocabulary: String,
    #[serde(default)]
    pub llm_enabled: bool,
    #[serde(default)]
    pub llm_base_url: String,
    #[serde(default)]
    pub llm_model: String,
    #[serde(default)]
    pub llm_api_key: String,
    /// Mouse button to remap as Enter key. None = disabled.
    /// Values: "MouseMiddle" | "MouseSideBack" | "MouseSideFwd"
    #[serde(default)]
    pub mouse_enter_btn: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            api_app_id: String::new(),
            api_access_token: String::new(),
            api_resource_id: "volc.bigasr.sauc.duration".to_string(),
            hotkey: "ROption".to_string(),
            microphone: None,
            asr_language: default_asr_language(),
            asr_enable_punc: true,
            asr_enable_itn: true,
            asr_enable_ddc: true,
            asr_vocabulary: String::new(),
            llm_enabled: false,
            llm_base_url: String::new(),
            llm_model: String::new(),
            llm_api_key: String::new(),
            mouse_enter_btn: None,
        }
    }
}

pub fn load_config(app: &tauri::AppHandle) -> Config {
    let config_path = match app.path().app_config_dir() {
        Ok(dir) => dir.join("config.json"),
        Err(e) => {
            eprintln!("[config] Failed to get config dir: {:?}", e);
            return Config::default();
        }
    };

    match std::fs::read_to_string(&config_path) {
        Ok(contents) => match serde_json::from_str::<Config>(&contents) {
            Ok(cfg) => cfg,
            Err(e) => {
                eprintln!("[config] Failed to parse config: {:?}", e);
                Config::default()
            }
        },
        Err(e) => {
            eprintln!("[config] Failed to read config file: {:?}", e);
            Config::default()
        }
    }
}

pub fn save_config_to_disk(app: &tauri::AppHandle, config: &Config) -> Result<(), String> {
    let config_dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("Failed to get config dir: {:?}", e))?;

    std::fs::create_dir_all(&config_dir)
        .map_err(|e| format!("Failed to create config dir: {:?}", e))?;

    let config_path = config_dir.join("config.json");
    let contents =
        serde_json::to_string_pretty(config).map_err(|e| format!("Failed to serialize config: {:?}", e))?;

    std::fs::write(&config_path, contents)
        .map_err(|e| format!("Failed to write config file: {:?}", e))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_default_values() {
        let cfg = Config::default();
        assert_eq!(cfg.hotkey, "ROption");
        assert_eq!(cfg.api_resource_id, "volc.bigasr.sauc.duration");
        assert_eq!(cfg.asr_language, "zh-CN");
        assert!(cfg.asr_enable_punc);
        assert!(cfg.asr_enable_itn);
        assert!(cfg.asr_enable_ddc);
        assert!(!cfg.llm_enabled);
        assert!(cfg.microphone.is_none());
        assert!(cfg.mouse_enter_btn.is_none());
    }

    #[test]
    fn test_config_serde_roundtrip() {
        let mut cfg = Config::default();
        cfg.api_app_id = "test_app".to_string();
        cfg.hotkey = "LControl".to_string();
        cfg.llm_enabled = true;
        cfg.llm_model = "gpt-4".to_string();
        cfg.mouse_enter_btn = Some("MouseSideBack".to_string());

        let json = serde_json::to_string(&cfg).unwrap();
        let restored: Config = serde_json::from_str(&json).unwrap();

        assert_eq!(restored.api_app_id, "test_app");
        assert_eq!(restored.hotkey, "LControl");
        assert!(restored.llm_enabled);
        assert_eq!(restored.llm_model, "gpt-4");
        assert_eq!(restored.mouse_enter_btn, Some("MouseSideBack".to_string()));
    }

    #[test]
    fn test_config_missing_new_fields_use_defaults() {
        // Simulate an old config file that lacks newer optional fields
        let json = r#"{
            "api_app_id": "123",
            "api_access_token": "tok",
            "api_resource_id": "volc.bigasr.sauc.duration",
            "hotkey": "ROption",
            "microphone": null
        }"#;
        let cfg: Config = serde_json::from_str(json).unwrap();

        assert_eq!(cfg.asr_language, "zh-CN");
        assert!(cfg.asr_enable_punc);
        assert!(!cfg.llm_enabled);
        assert!(cfg.llm_base_url.is_empty());
        assert!(cfg.mouse_enter_btn.is_none());
    }

    #[test]
    fn test_config_microphone_none_and_some() {
        let json_none = r#"{"api_app_id":"","api_access_token":"","api_resource_id":"","hotkey":"ROption","microphone":null}"#;
        let cfg: Config = serde_json::from_str(json_none).unwrap();
        assert!(cfg.microphone.is_none());

        let json_some = r#"{"api_app_id":"","api_access_token":"","api_resource_id":"","hotkey":"ROption","microphone":"DJI Mic Mini"}"#;
        let cfg2: Config = serde_json::from_str(json_some).unwrap();
        assert_eq!(cfg2.microphone, Some("DJI Mic Mini".to_string()));
    }
}

#[tauri::command]
pub fn get_config(
    _app: tauri::AppHandle,
    state: tauri::State<SharedConfig>,
) -> Config {
    state.lock().unwrap().clone()
}

#[tauri::command]
pub fn save_config(
    app: tauri::AppHandle,
    state: tauri::State<SharedConfig>,
    config: Config,
) -> Result<(), String> {
    save_config_to_disk(&app, &config)?;
    *state.lock().unwrap() = config;
    Ok(())
}

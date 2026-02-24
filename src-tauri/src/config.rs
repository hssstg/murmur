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

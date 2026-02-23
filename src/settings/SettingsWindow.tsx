import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import './SettingsWindow.css';

interface Config {
  api_app_id: string;
  api_access_token: string;
  api_resource_id: string;
  hotkey: string;
  microphone: string | null;
  asr_language: string;
  asr_enable_punc: boolean;
  asr_enable_itn: boolean;
  asr_enable_ddc: boolean;
  asr_vocabulary: string;
}

const DEFAULT_CONFIG: Config = {
  api_app_id: '',
  api_access_token: '',
  api_resource_id: 'volc.bigasr.sauc.duration',
  hotkey: 'ROption',
  microphone: null,
  asr_language: 'zh-CN',
  asr_enable_punc: true,
  asr_enable_itn: true,
  asr_enable_ddc: true,
  asr_vocabulary: '',
};

const HOTKEY_OPTIONS: { label: string; value: string }[] = [
  { label: 'Right Option', value: 'ROption' },
  { label: 'Left Option', value: 'LOption' },
  { label: 'Right Control', value: 'RControl' },
  { label: 'Left Control', value: 'LControl' },
  { label: 'F13', value: 'F13' },
  { label: 'F14', value: 'F14' },
  { label: 'F15', value: 'F15' },
];

const LANGUAGE_OPTIONS: { label: string; value: string }[] = [
  { label: '中文', value: 'zh-CN' },
  { label: 'English', value: 'en-US' },
  { label: '粤语', value: 'zh-Yue' },
  { label: '日本語', value: 'ja-JP' },
];

type SaveState = 'idle' | 'saving' | 'saved' | 'error';

// Simple eye-open SVG icon
function EyeIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path
        d="M8 3C4.5 3 1.5 5.5 1 8c.5 2.5 3.5 5 7 5s6.5-2.5 7-5c-.5-2.5-3.5-5-7-5z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
      <circle cx="8" cy="8" r="2.2" stroke="currentColor" strokeWidth="1.3" />
    </svg>
  );
}

// Simple eye-off SVG icon
function EyeOffIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path
        d="M2 2l12 12M6.5 6.6A2.2 2.2 0 0 0 9.4 9.5M4.2 4.3C2.8 5.2 1.7 6.5 1 8c.5 2.5 3.5 5 7 5 1.4 0 2.7-.4 3.8-1M7 3.1C7.3 3 7.7 3 8 3c3.5 0 6.5 2.5 7 5a7.4 7.4 0 0 1-2.1 3.4"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export default function SettingsWindow() {
  const [config, setConfig] = useState<Config>(DEFAULT_CONFIG);
  const [devices, setDevices] = useState<string[]>([]);
  const [saveState, setSaveState] = useState<SaveState>('idle');
  const [showToken, setShowToken] = useState(false);

  useEffect(() => {
    invoke<Config>('get_config')
      .then(setConfig)
      .catch(() => {
        // Keep defaults if config load fails
      });

    invoke<string[]>('list_audio_devices')
      .then(setDevices)
      .catch(() => {
        setDevices([]);
      });
  }, []);

  function setField<K extends keyof Config>(key: K, value: Config[K]) {
    setConfig((prev) => ({ ...prev, [key]: value }));
  }

  async function handleSave() {
    if (saveState === 'saving') return;
    setSaveState('saving');
    try {
      await invoke('save_config', { config });
      setSaveState('saved');
      setTimeout(() => setSaveState('idle'), 2200);
    } catch {
      setSaveState('error');
      setTimeout(() => setSaveState('idle'), 2500);
    }
  }

  function getSaveLabel(): string {
    if (saveState === 'saving') return 'Saving...';
    if (saveState === 'saved') return 'Saved';
    if (saveState === 'error') return 'Failed to save';
    return 'Save Settings';
  }

  function getSaveBtnClass(): string {
    const base = 'settings-save-btn';
    if (saveState === 'saved') return `${base} ${base}--saved`;
    if (saveState === 'error') return `${base} ${base}--error`;
    return base;
  }

  return (
    <div className="settings-window">
      <header className="settings-header">
        <div className="settings-header__title">Murmur Settings</div>
        <div className="settings-header__subtitle">Push-to-talk voice input configuration</div>
      </header>

      <div className="settings-content">
        {/* ── API Configuration ── */}
        <section className="settings-section">
          <div className="settings-section__heading">API Configuration</div>

          <div className="settings-field">
            <label className="settings-field__label">App ID</label>
            <input
              className="settings-field__input settings-field__input--mono"
              type="text"
              placeholder="your-app-id"
              value={config.api_app_id}
              onChange={(e) => setField('api_app_id', e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
          </div>

          <div className="settings-field">
            <label className="settings-field__label">Access Token</label>
            <div className="settings-field__input-wrapper">
              <input
                className="settings-field__input settings-field__input--mono settings-field__input--has-toggle"
                type={showToken ? 'text' : 'password'}
                placeholder="••••••••••••••••"
                value={config.api_access_token}
                onChange={(e) => setField('api_access_token', e.target.value)}
                autoComplete="off"
                spellCheck={false}
              />
              <button
                className="settings-field__toggle"
                type="button"
                onClick={() => setShowToken((v) => !v)}
                title={showToken ? 'Hide token' : 'Show token'}
                tabIndex={-1}
              >
                {showToken ? <EyeOffIcon /> : <EyeIcon />}
              </button>
            </div>
          </div>

          <div className="settings-field">
            <label className="settings-field__label">Resource ID</label>
            <input
              className="settings-field__input settings-field__input--mono"
              type="text"
              placeholder="your-resource-id"
              value={config.api_resource_id}
              onChange={(e) => setField('api_resource_id', e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
          </div>
        </section>

        {/* ── Push-to-Talk Key ── */}
        <section className="settings-section">
          <div className="settings-section__heading">Push-to-Talk Key</div>

          <div className="settings-field">
            <label className="settings-field__label">Hotkey</label>
            <select
              className="settings-field__select"
              value={config.hotkey}
              onChange={(e) => setField('hotkey', e.target.value)}
            >
              {HOTKEY_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>
                  {opt.label}
                </option>
              ))}
            </select>
            <span className="settings-field__hint">
              Hold this key to record, release to transcribe.
            </span>
          </div>
        </section>

        {/* ── Microphone ── */}
        <section className="settings-section">
          <div className="settings-section__heading">Microphone</div>

          <div className="settings-field">
            <label className="settings-field__label">Input Device</label>
            <select
              className="settings-field__select"
              value={config.microphone ?? ''}
              onChange={(e) => setField('microphone', e.target.value === '' ? null : e.target.value)}
            >
              <option value="">System Default</option>
              {devices.map((device) => (
                <option key={device} value={device}>
                  {device}
                </option>
              ))}
            </select>
          </div>
        </section>

        {/* ── Recognition ── */}
        <section className="settings-section">
          <div className="settings-section__heading">Recognition</div>

          <div className="settings-field">
            <label className="settings-field__label">Language</label>
            <select
              className="settings-field__select"
              value={config.asr_language}
              onChange={(e) => setField('asr_language', e.target.value)}
            >
              {LANGUAGE_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>
                  {opt.label}
                </option>
              ))}
            </select>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Punctuation</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_punc}
                onChange={(e) => setField('asr_enable_punc', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Number Format</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_itn}
                onChange={(e) => setField('asr_enable_itn', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Filter Fillers</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_ddc}
                onChange={(e) => setField('asr_enable_ddc', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-field">
            <label className="settings-field__label">Vocabulary</label>
            <input
              className="settings-field__input settings-field__input--mono"
              type="text"
              placeholder="Vocabulary ID (optional)"
              value={config.asr_vocabulary}
              onChange={(e) => setField('asr_vocabulary', e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
            <span className="settings-field__hint">
              Custom vocabulary ID for improved recognition of domain-specific terms.
            </span>
          </div>
        </section>
      </div>

      <footer className="settings-footer">
        <button
          className={getSaveBtnClass()}
          onClick={handleSave}
          disabled={saveState === 'saving'}
        >
          {getSaveLabel()}
        </button>
      </footer>
    </div>
  );
}

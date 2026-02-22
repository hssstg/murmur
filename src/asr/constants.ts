export const AUDIO_CONFIG = {
  sampleRate: 16000,
  channelCount: 1,
  bitsPerSample: 16,
  bufferSize: 4096,
} as const;

export const VOLCENGINE_CONSTANTS = {
  ENDPOINT: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
  DEFAULT_RESOURCE_ID: 'volc.bigasr.sauc',
} as const;

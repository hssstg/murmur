export type ASRStatus =
  | 'idle'
  | 'connecting'
  | 'listening'
  | 'processing'
  | 'done'
  | 'error';

export interface ASRResult {
  type: 'interim' | 'final';
  text: string;
  isFinal: boolean;
}

export type ConnectionState =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'error';

export interface VolcengineClientConfig {
  appId: string;
  accessToken: string;
  resourceId: string;
}

export type AudioChunkCallback = (chunk: ArrayBuffer) => void;

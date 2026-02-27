/**
 * Volcengine ASR WebSocket Client (V3 BigModel API)
 * Binary protocol implementation based on: https://www.volcengine.com/docs/6561/1354869
 *
 * Browser-compatible port for Tauri v2 — uses @tauri-apps/plugin-websocket
 * so that custom HTTP headers can be sent on the WebSocket upgrade request.
 */

import EventEmitter from 'eventemitter3';
import pako from 'pako';
import TauriWebSocket from '@tauri-apps/plugin-websocket';
import type { ASRResult, ASRStatus } from './types';
import type { VolcengineClientConfig, ConnectionState } from './types';
import { VOLCENGINE_CONSTANTS } from './constants';
import { flog } from '../utils/log';

// ============ Helper: concatenate Uint8Arrays ============

function concatUint8Arrays(arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((sum, a) => sum + a.length, 0);
  const result = new Uint8Array(total);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

// ============ Protocol Constants (V3 BigModel) ============

const PROTOCOL = {
  VERSION: 0b0001,
  HEADER_SIZE: 0b0001,

  // Message types
  MSG_FULL_CLIENT_REQUEST: 0b0001,
  MSG_AUDIO_ONLY_REQUEST: 0b0010,
  MSG_FULL_SERVER_RESPONSE: 0b1001,
  MSG_SERVER_ACK: 0b1011,
  MSG_SERVER_ERROR: 0b1111,

  // Message type specific flags
  FLAG_NO_SEQUENCE: 0b0000,
  FLAG_POS_SEQUENCE: 0b0001,
  FLAG_NEG_SEQUENCE: 0b0011,

  // Serialization
  SERIAL_JSON: 0b0001,

  // Compression
  COMPRESS_NONE: 0b0000,
  COMPRESS_GZIP: 0b0001,
};

// ============ Helper Functions ============

function gzipCompress(data: Uint8Array): Uint8Array {
  return pako.gzip(data);
}

function gzipDecompress(data: Uint8Array): Uint8Array {
  return pako.ungzip(data);
}

function buildHeader(
  messageType: number,
  messageTypeFlags: number,
  serialization: number,
  compression: number,
): Uint8Array {
  const header = new Uint8Array(4);
  header[0] = (PROTOCOL.VERSION << 4) | PROTOCOL.HEADER_SIZE;
  header[1] = (messageType << 4) | messageTypeFlags;
  header[2] = (serialization << 4) | compression;
  header[3] = 0x00;
  return header;
}

function intToBytes(value: number): Uint8Array {
  const buf = new Uint8Array(4);
  new DataView(buf.buffer).setInt32(0, value, false);
  return buf;
}

function bytesToInt(data: Uint8Array, offset = 0): number {
  return new DataView(data.buffer, data.byteOffset).getInt32(offset, false);
}

// Build initial request payload (with sequence)
function buildInitRequest(data: object, sequence: number): Uint8Array {
  const header = buildHeader(
    PROTOCOL.MSG_FULL_CLIENT_REQUEST,
    PROTOCOL.FLAG_POS_SEQUENCE,
    PROTOCOL.SERIAL_JSON,
    PROTOCOL.COMPRESS_GZIP,
  );

  const jsonStr = JSON.stringify(data);
  const jsonBytes = new TextEncoder().encode(jsonStr);
  const compressedPayload = gzipCompress(jsonBytes);

  const seqBytes = intToBytes(sequence);
  const payloadSize = intToBytes(compressedPayload.length);

  return concatUint8Arrays([header, seqBytes, payloadSize, compressedPayload]);
}

// Build audio chunk payload (with sequence)
function buildAudioRequest(
  audioData: Uint8Array,
  sequence: number,
  isLast: boolean,
): Uint8Array {
  const flag = isLast ? PROTOCOL.FLAG_NEG_SEQUENCE : PROTOCOL.FLAG_POS_SEQUENCE;
  const header = buildHeader(
    PROTOCOL.MSG_AUDIO_ONLY_REQUEST,
    flag,
    PROTOCOL.SERIAL_JSON,
    PROTOCOL.COMPRESS_NONE,
  );

  // For last packet, sequence is negative
  const seqValue = isLast ? -sequence : sequence;
  const seqBytes = intToBytes(seqValue);

  const payloadSize = intToBytes(audioData.length);

  return concatUint8Arrays([header, seqBytes, payloadSize, audioData]);
}

// Parse server response
interface ParsedResponse {
  type: 'ack' | 'result' | 'error';
  sequence: number;
  text?: string;
  isFinal?: boolean;
  error?: string;
}

function parseResponse(data: Uint8Array): ParsedResponse | null {
  if (data.length < 4) return null;

  const messageType = (data[1] >> 4) & 0x0f;
  const messageFlags = data[1] & 0x0f;
  const compression = data[2] & 0x0f;

  console.log('[volcengine-client] Parse response', { messageType, messageFlags, compression });

  if (messageType === PROTOCOL.MSG_SERVER_ERROR) {
    // Error response: header(4) + code(4) + msgSize(4) + message
    if (data.length < 12) return null;
    const msgSize = bytesToInt(data, 8);
    if (data.length < 12 + msgSize) return null;
    const rawMsg = data.slice(12, 12 + msgSize);
    let message: string;
    if (compression === PROTOCOL.COMPRESS_GZIP) {
      message = new TextDecoder().decode(gzipDecompress(rawMsg));
    } else {
      message = new TextDecoder().decode(rawMsg);
    }
    const errorCode = bytesToInt(data, 4);
    console.error(`[volcengine-client] Server error code=${errorCode}: ${message}`);
    return { type: 'error', sequence: 0, error: message };
  }

  if (messageType === PROTOCOL.MSG_SERVER_ACK) {
    // ACK response: header(4) + sequence(4)
    if (data.length < 8) return null;
    const sequence = bytesToInt(data, 4);
    console.log('[volcengine-client] Server ACK', { sequence });
    return { type: 'ack', sequence };
  }

  if (messageType === PROTOCOL.MSG_FULL_SERVER_RESPONSE) {
    // Full response: header(4) + sequence(4) + payloadSize(4) + payload
    if (data.length < 12) return null;
    const sequence = bytesToInt(data, 4);
    const payloadSize = bytesToInt(data, 8);
    if (payloadSize < 0 || data.length < 12 + payloadSize) return null;
    const rawPayload = data.slice(12, 12 + payloadSize);
    const payloadBytes =
      compression === PROTOCOL.COMPRESS_GZIP
        ? gzipDecompress(rawPayload)
        : rawPayload;

    const payloadStr = new TextDecoder().decode(payloadBytes);
    console.log('[volcengine-client] Server response', { sequence, payload: payloadStr });

    try {
      const payload = JSON.parse(payloadStr);
      // Check if this is the final result (negative sequence or NEG_SEQUENCE flag)
      const isFinal =
        sequence < 0 || messageFlags === PROTOCOL.FLAG_NEG_SEQUENCE;

      // Extract text from result
      let text = '';
      if (payload.result) {
        text = payload.result.text || '';
        // If no direct text, try to concatenate utterances
        if (!text && payload.result.utterances) {
          text = payload.result.utterances.map((u: { text: string }) => u.text).join('');
        }
      }

      return { type: 'result', sequence, text, isFinal };
    } catch (e) {
      console.error('[volcengine-client] Failed to parse JSON payload', { error: e });
      return null;
    }
  }

  console.log('[volcengine-client] Unknown message type', { messageType });
  return null;
}

// ============ Event Types ============

export interface VolcengineClientEvents {
  result: (result: ASRResult) => void;
  status: (status: ASRStatus) => void;
  error: (error: Error) => void;
}

// ============ ASR Client Class ============

export class VolcengineClient extends EventEmitter<VolcengineClientEvents> {
  private readonly config: VolcengineClientConfig;
  private ws: TauriWebSocket | null = null;
  private unlistenWs: (() => void) | null = null;
  private connectionState: ConnectionState = 'disconnected';
  private requestId = '';
  private sequence = 0;
  // Track open state manually since plugin-websocket has no readyState
  private wsOpen = false;
  // Chunks that arrive while the WebSocket is still connecting are buffered here
  // and flushed immediately after the init request is sent.
  private pendingAudioChunks: Uint8Array[] = [];
  // Set to true when finishAudio() is called while still connecting.
  // The finish signal is sent right after the pending audio flush in connect().
  private pendingFinish = false;

  constructor(config: VolcengineClientConfig) {
    super();
    this.config = config;
  }

  get isConnected(): boolean {
    return this.connectionState === 'connected' && this.wsOpen;
  }

  get state(): ConnectionState {
    return this.connectionState;
  }

  async connect(): Promise<void> {
    if (this.isConnected) {
      console.log('[volcengine-client] Already connected');
      return;
    }

    this.reset();
    this.updateState('connecting');
    this.emitStatus('connecting');

    this.requestId = crypto.randomUUID();
    this.sequence = 1; // V3 starts with sequence 1

    console.log('[volcengine-client] Connecting to Volcengine ASR', {
      endpoint: VOLCENGINE_CONSTANTS.ENDPOINT,
      requestId: this.requestId,
    });

    const headers: Record<string, string> = {
      'X-Api-App-Key': this.config.appId,
      'X-Api-Access-Key': this.config.accessToken,
      'X-Api-Resource-Id': this.config.resourceId,
      'X-Api-Connect-Id': this.requestId,
    };

    let ws: TauriWebSocket;
    try {
      flog(`connect() calling TauriWebSocket.connect reqId=${this.requestId.slice(0,8)}`);
      ws = await TauriWebSocket.connect(VOLCENGINE_CONSTANTS.ENDPOINT, { headers });
      flog(`connect() TauriWebSocket connected reqId=${this.requestId.slice(0,8)}`);
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      flog(`connect() TauriWebSocket.connect FAILED: ${err.message}`);
      console.error('[volcengine-client] Failed to connect WebSocket', { error: err.message });
      this.updateState('error');
      this.emitStatus('error');
      this.emit('error', err);
      throw err;
    }

    this.ws = ws;
    this.wsOpen = true;
    // Keep state as 'connecting' until after init + flush so that any
    // audio:chunk events that fire during the await below are still buffered.
    // Setting 'connected' here was causing live audio to race with the flush
    // and creating sequence number gaps (autoAssignedSequence mismatch).

    // Register message listener
    this.unlistenWs = ws.addListener((message) => {
      if (message.type === 'Binary') {
        const data = new Uint8Array(message.data);
        this.handleMessage(data);
      } else if (message.type === 'Close') {
        console.log('[volcengine-client] WebSocket closed', {
          code: message.data?.code,
          reason: message.data?.reason,
          requestId: this.requestId,
        });
        this.wsOpen = false;
        if (this.connectionState !== 'disconnected') {
          this.updateState('disconnected');
          this.emitStatus('idle');
        }
      } else if (message.type === 'Text') {
        // Volcengine uses binary protocol; unexpected text frames are ignored
        console.log('[volcengine-client] Received unexpected text frame', { data: message.data });
      }
    });

    // Send initial request with V3 binary format
    const initRequest = {
      user: { uid: 'tauri_user' },
      audio: {
        format: 'pcm',
        sample_rate: 16000,
        channel: 1,
        bits: 16,
        codec: 'raw',
      },
      request: {
        model_name: 'bigmodel',
        language: this.config.language,
        enable_punc: this.config.enablePunc,
        enable_itn: this.config.enableItn,
        enable_ddc: this.config.enableDdc,
        ...(this.config.vocabulary ? { corpus: { boosting_table_name: this.config.vocabulary } } : {}),
        show_utterances: true,
        result_type: 'full',
      },
    };

    console.log('[volcengine-client] Sending init request', initRequest);
    const payload = buildInitRequest(initRequest, this.sequence);
    this.sequence = 2; // Next sequence for audio
    flog(`connect() sending init seq=1 pendingAudio=${this.pendingAudioChunks.length}`);
    await this.ws.send({ type: 'Binary', data: Array.from(payload) });

    // Flush any audio chunks that arrived during the connection handshake
    if (this.pendingAudioChunks.length > 0) {
      console.log('[volcengine-client] Flushing buffered audio chunks', {
        count: this.pendingAudioChunks.length,
      });
      for (const chunk of this.pendingAudioChunks) {
        this.sendAudioChunk(chunk);
      }
      this.pendingAudioChunks = [];
    }

    // All buffered audio is flushed — now mark as connected so live audio
    // flows directly instead of being buffered.
    this.updateState('connected');
    flog(`connect() state=connected seq=${this.sequence} pendingFinish=${this.pendingFinish}`);

    // If finishAudio() was called while we were still connecting, send the
    // finish signal now (after the audio flush, so ordering is correct).
    if (this.pendingFinish) {
      this.pendingFinish = false;
      const finishSeq = this.sequence;
      console.log('[volcengine-client] Sending deferred finish signal', { sequence: finishSeq });
      this.emitStatus('processing');
      const finishPayload = buildAudioRequest(new Uint8Array(0), finishSeq, true);
      this.ws.send({ type: 'Binary', data: Array.from(finishPayload) }).catch((err: unknown) => {
        console.error('[volcengine-client] Failed to send deferred finish signal', { err });
      });
    } else {
      this.emitStatus('listening');
    }
  }

  disconnect(): void {
    console.log('[volcengine-client] Disconnecting', { requestId: this.requestId });
    this.cleanup();
    this.updateState('disconnected');
    this.emitStatus('idle');
  }

  sendAudio(chunk: ArrayBuffer): void {
    if (this.connectionState === 'connecting') {
      // Buffer until the WebSocket handshake completes and init request is sent
      this.pendingAudioChunks.push(new Uint8Array(chunk));
      return;
    }

    if (!this.isConnected) {
      console.log('[volcengine-client] Cannot send audio: not connected');
      return;
    }

    this.sendAudioChunk(new Uint8Array(chunk));
  }

  private sendAudioChunk(audioData: Uint8Array): void {
    const payload = buildAudioRequest(audioData, this.sequence, false);
    this.sequence++;

    if (this.ws) {
      // fire-and-forget; errors will surface via the Close/error message
      this.ws.send({ type: 'Binary', data: Array.from(payload) }).catch((err: unknown) => {
        console.error('[volcengine-client] Failed to send audio chunk', { err });
      });
    }
  }

  finishAudio(): void {
    if (this.connectionState === 'connecting') {
      // connect() hasn't resolved yet — defer the finish signal until after the
      // audio buffer is flushed in connect().
      console.log('[volcengine-client] Deferring finish signal until connected');
      this.pendingFinish = true;
      return;
    }

    if (!this.isConnected) {
      console.log('[volcengine-client] Cannot finish audio: not connected');
      return;
    }

    // this.sequence holds the NEXT sequence number to use, which is what the
    // server expects in the finish packet (negated). Do NOT use sequence - 1.
    const finishSeq = this.sequence;
    console.log('[volcengine-client] Sending finish signal', { sequence: finishSeq });
    flog(`finishAudio() seq=${finishSeq}`);
    this.emitStatus('processing');

    // Send final packet with empty audio and negative sequence
    const payload = buildAudioRequest(new Uint8Array(0), finishSeq, true);
    if (this.ws) {
      this.ws.send({ type: 'Binary', data: Array.from(payload) }).catch((err: unknown) => {
        console.error('[volcengine-client] Failed to send finish signal', { err });
      });
    }
  }

  // ============ Private Methods ============

  private reset(): void {
    this.requestId = '';
    this.sequence = 0;
    this.wsOpen = false;
    this.pendingAudioChunks = [];
    this.pendingFinish = false;
  }

  private updateState(state: ConnectionState): void {
    this.connectionState = state;
  }

  private emitStatus(status: ASRStatus): void {
    this.emit('status', status);
  }

  private cleanup(): void {
    if (this.unlistenWs) {
      this.unlistenWs();
      this.unlistenWs = null;
    }
    if (this.ws) {
      this.wsOpen = false;
      this.ws.disconnect().catch(() => {
        // Ignore errors when closing
      });
      this.ws = null;
    }
  }

  private handleMessage(data: Uint8Array): void {
    try {
      const response = parseResponse(data);
      if (!response) return;

    if (response.type === 'error' && response.error) {
      flog(`handleMessage ERROR: ${response.error}`);
      this.emit('error', new Error(response.error));
      this.emitStatus('error');
    } else if (response.type === 'result' && response.text !== undefined) {
      const result: ASRResult = {
        type: response.isFinal ? 'final' : 'interim',
        text: response.text,
        isFinal: response.isFinal ?? false,
      };

      console.log('[volcengine-client] ASR result', {
        type: result.type,
        textLength: result.text.length,
      });
      flog(`handleMessage RESULT isFinal=${result.isFinal} textLen=${result.text.length}`);

      this.emit('result', result);

      if (response.isFinal) {
        this.emitStatus('done');
      }
    }
    // ACK messages are logged only, no event emitted
    } catch (e) {
      console.error('[volcengine-client] handleMessage unexpected error', { error: e });
    }
  }
}

// ============ Config Loader ============

export function loadConfig(): VolcengineClientConfig {
  const appId = import.meta.env.VITE_VOLCENGINE_APP_ID as string;
  const accessToken = import.meta.env.VITE_VOLCENGINE_ACCESS_TOKEN as string;
  const resourceId =
    (import.meta.env.VITE_VOLCENGINE_RESOURCE_ID as string) ??
    VOLCENGINE_CONSTANTS.DEFAULT_RESOURCE_ID;
  if (!appId || !accessToken) {
    throw new Error(
      'Missing VITE_VOLCENGINE_APP_ID or VITE_VOLCENGINE_ACCESS_TOKEN in .env'
    );
  }
  return { appId, accessToken, resourceId, language: '', enablePunc: false, enableItn: true, enableDdc: true };
}

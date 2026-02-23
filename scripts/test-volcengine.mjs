#!/usr/bin/env node
/**
 * Minimal Volcengine ASR API smoke test
 *
 * Generates a short Chinese TTS clip via macOS `say`, converts it to
 * raw PCM-16LE at 16 kHz mono, then drives the exact same binary
 * protocol as volcengine-client.ts — no npm packages needed.
 *
 * Usage (from project root):
 *   node scripts/test-volcengine.mjs
 */

import { connect } from 'tls';
import { randomBytes } from 'crypto';
import { readFileSync, existsSync } from 'fs';
import { gzipSync, gunzipSync } from 'zlib';
import { execSync } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

// ─── .env loader ─────────────────────────────────────────────────────────────

function loadEnv() {
  const path = resolve(ROOT, '.env');
  if (!existsSync(path)) throw new Error('.env not found — run from project root');
  const env = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^([^#=\s][^=]*)=(.*)/);
    if (m) env[m[1].trim()] = m[2].trim();
  }
  return env;
}

// ─── Volcengine binary protocol (mirrors volcengine-client.ts) ───────────────

const P = {
  MSG_FULL_CLIENT_REQUEST: 0b0001,
  MSG_AUDIO_ONLY_REQUEST:  0b0010,
  MSG_FULL_SERVER_RESPONSE: 0b1001,
  MSG_SERVER_ACK:          0b1011,
  MSG_SERVER_ERROR:        0b1111,
  FLAG_POS_SEQUENCE:       0b0001,
  FLAG_NEG_SEQUENCE:       0b0011,
  SERIAL_JSON:             0b0001,
  COMPRESS_NONE:           0b0000,
  COMPRESS_GZIP:           0b0001,
};

function buildHeader(msgType, flag, serial, compress) {
  // byte0: version(1)<<4 | headerSize(1)
  // byte1: msgType<<4 | flag
  // byte2: serial<<4 | compress
  // byte3: reserved
  return Buffer.from([0x11, (msgType << 4) | flag, (serial << 4) | compress, 0x00]);
}

function i32be(n) {
  const b = Buffer.alloc(4);
  b.writeInt32BE(n);
  return b;
}

function readI32BE(buf, offset = 0) {
  return buf.readInt32BE(offset);
}

function buildInitRequest(seq) {
  const header = buildHeader(P.MSG_FULL_CLIENT_REQUEST, P.FLAG_POS_SEQUENCE, P.SERIAL_JSON, P.COMPRESS_GZIP);
  const body = gzipSync(Buffer.from(JSON.stringify({
    user:    { uid: 'smoke_test' },
    audio:   { format: 'pcm', sample_rate: 16000, channel: 1, bits: 16, codec: 'raw' },
    request: {
      model_name:      'bigmodel',
      enable_punc:     true,
      enable_itn:      true,
      enable_ddc:      true,
      show_utterances: true,
      result_type:     'full',
    },
  })));
  return Buffer.concat([header, i32be(seq), i32be(body.length), body]);
}

function buildAudioChunk(pcm, seq, isLast) {
  const flag = isLast ? P.FLAG_NEG_SEQUENCE : P.FLAG_POS_SEQUENCE;
  const header = buildHeader(P.MSG_AUDIO_ONLY_REQUEST, flag, P.SERIAL_JSON, P.COMPRESS_NONE);
  return Buffer.concat([header, i32be(isLast ? -seq : seq), i32be(pcm.length), pcm]);
}

function parseServerMessage(data) {
  if (data.length < 4) return null;
  const msgType = (data[1] >> 4) & 0x0f;
  const msgFlags = data[1] & 0x0f;
  const compress = data[2] & 0x0f;

  if (msgType === P.MSG_SERVER_ERROR) {
    const size = readI32BE(data, 8);
    let msg = data.slice(12, 12 + size);
    if (compress === P.COMPRESS_GZIP) msg = gunzipSync(msg);
    return { type: 'error', error: msg.toString('utf8') };
  }
  if (msgType === P.MSG_SERVER_ACK) {
    return { type: 'ack', seq: readI32BE(data, 4) };
  }
  if (msgType === P.MSG_FULL_SERVER_RESPONSE) {
    const seq         = readI32BE(data, 4);
    const payloadSize = readI32BE(data, 8);
    let payload       = data.slice(12, 12 + payloadSize);
    if (compress === P.COMPRESS_GZIP) payload = gunzipSync(payload);
    try {
      const json    = JSON.parse(payload.toString('utf8'));
      const isFinal = seq < 0 || msgFlags === P.FLAG_NEG_SEQUENCE;
      let text      = json.result?.text ?? '';
      if (!text && json.result?.utterances) {
        text = json.result.utterances.map(u => u.text).join('');
      }
      return { type: 'result', seq, isFinal, text, raw: json };
    } catch {
      return null;
    }
  }
  return { type: 'unknown', msgType };
}

// ─── Minimal WebSocket frame builder / parser ─────────────────────────────────

function wsBinaryFrame(payload) {
  const len     = payload.length;
  const maskKey = randomBytes(4);
  let lenBytes;
  if (len <= 125)       lenBytes = Buffer.from([0x80 | len]);
  else if (len <= 65535) lenBytes = Buffer.concat([Buffer.from([0xfe]), (() => { const b = Buffer.alloc(2); b.writeUInt16BE(len); return b; })()]);
  else                  lenBytes = Buffer.concat([Buffer.from([0xff]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(len)); return b; })()]);

  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= maskKey[i % 4];
  return Buffer.concat([Buffer.from([0x82]), lenBytes, maskKey, masked]);
}

// Returns { opcode, fin, payload, consumed } or null if buffer too short.
function parseWsFrame(buf) {
  if (buf.length < 2) return null;
  const fin    = (buf[0] & 0x80) !== 0;
  const opcode = buf[0] & 0x0f;
  const lenByte = buf[1] & 0x7f;
  let offset   = 2;
  let payloadLen;

  if (lenByte <= 125) {
    payloadLen = lenByte;
  } else if (lenByte === 126) {
    if (buf.length < 4) return null;
    payloadLen = buf.readUInt16BE(2);
    offset = 4;
  } else {
    if (buf.length < 10) return null;
    payloadLen = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }

  if (buf.length < offset + payloadLen) return null;
  const payload  = buf.slice(offset, offset + payloadLen);
  const consumed = offset + payloadLen;
  return { opcode, fin, payload, consumed };
}

// ─── Test audio generation ────────────────────────────────────────────────────

function generateTestAudio() {
  const aiff = '/tmp/_murmur_smoke.aiff';
  const wav  = '/tmp/_murmur_smoke.wav';
  console.log('🎙  Generating Chinese TTS via macOS say...');
  execSync(`say -o "${aiff}" -v Tingting "你好，这是火山语音识别的测试"`);
  execSync(`afconvert -f WAVE -d LEI16@16000 -c 1 "${aiff}" "${wav}"`);
  const wavBuf = readFileSync(wav);
  // Find the data chunk offset in the WAV file (skip past headers robustly)
  const pcm = findWavDataChunk(wavBuf);
  console.log(`✅ Audio ready: ${pcm.length} bytes PCM ≈ ${(pcm.length / 32000).toFixed(2)}s`);
  return pcm;
}

// Parse RIFF chunks to find 'data' chunk (handles non-44-byte headers)
function findWavDataChunk(wavBuf) {
  let pos = 12; // skip RIFF header (4) + size (4) + WAVE (4)
  while (pos + 8 <= wavBuf.length) {
    const chunkId   = wavBuf.slice(pos, pos + 4).toString('ascii');
    const chunkSize = wavBuf.readUInt32LE(pos + 4);
    if (chunkId === 'data') return wavBuf.slice(pos + 8, pos + 8 + chunkSize);
    pos += 8 + chunkSize;
  }
  throw new Error('WAV data chunk not found');
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const env = loadEnv();
  const appId       = env.VITE_VOLCENGINE_APP_ID;
  const accessToken = env.VITE_VOLCENGINE_ACCESS_TOKEN;
  const resourceId  = env.VITE_VOLCENGINE_RESOURCE_ID || 'volc.bigasr.sauc';

  if (!appId || !accessToken) {
    console.error('❌  Missing credentials in .env');
    process.exit(1);
  }

  const pcm       = generateTestAudio();
  const requestId = randomBytes(16).toString('hex');
  const wsKey     = randomBytes(16).toString('base64');

  return new Promise((resolve, reject) => {
    const tls = connect(443, 'openspeech.bytedance.com', { servername: 'openspeech.bytedance.com' });

    let rawBuf          = Buffer.alloc(0); // pre-handshake accumulator
    let wsBuf           = Buffer.alloc(0); // post-handshake accumulator
    let handshakeDone   = false;
    let seq             = 1;
    const CHUNK_BYTES   = 3200; // 100 ms at 16 kHz × 2 bytes

    tls.on('error', (err) => { console.error('❌  TLS error:', err.message); reject(err); });

    tls.on('secureConnect', () => {
      console.log('🔗  TLS connected → sending WebSocket upgrade...');
      tls.write([
        `GET /api/v3/sauc/bigmodel HTTP/1.1`,
        `Host: openspeech.bytedance.com`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${wsKey}`,
        `Sec-WebSocket-Version: 13`,
        `X-Api-App-Key: ${appId}`,
        `X-Api-Access-Key: ${accessToken}`,
        `X-Api-Resource-Id: ${resourceId}`,
        `X-Api-Connect-Id: ${requestId}`,
        ``, ``,
      ].join('\r\n'));
    });

    tls.on('data', (chunk) => {
      if (!handshakeDone) {
        rawBuf = Buffer.concat([rawBuf, chunk]);
        const headerEnd = rawBuf.indexOf('\r\n\r\n');
        if (headerEnd === -1) return; // need more data

        const headerStr = rawBuf.slice(0, headerEnd).toString('utf8');
        console.log('📡  Server:', headerStr.split('\r\n')[0]);

        if (!headerStr.includes('101')) {
          reject(new Error('WebSocket upgrade failed:\n' + headerStr));
          tls.destroy();
          return;
        }

        handshakeDone = true;
        console.log('✅  WebSocket handshake OK');

        // Anything after the headers belongs to WS frames
        wsBuf = rawBuf.slice(headerEnd + 4);
        rawBuf = Buffer.alloc(0);

        // ── Send init request ──
        console.log(`📤  Init (seq=${seq})`);
        tls.write(wsBinaryFrame(buildInitRequest(seq)));
        seq = 2;

        // ── Send all audio chunks, mark the last one ──
        let offset   = 0;
        let audioSeq = seq;
        while (offset < pcm.length) {
          const end    = Math.min(offset + CHUNK_BYTES, pcm.length);
          const isLast = end >= pcm.length;
          tls.write(wsBinaryFrame(buildAudioChunk(pcm.slice(offset, end), audioSeq, isLast)));
          audioSeq++;
          offset = end;
        }
        console.log(`📤  Sent ${audioSeq - seq} audio chunk(s), finish at seq=${audioSeq - 1}`);

        processFrames();
        return;
      }

      wsBuf = Buffer.concat([wsBuf, chunk]);
      processFrames();
    });

    function processFrames() {
      while (wsBuf.length > 0) {
        const frame = parseWsFrame(wsBuf);
        if (!frame) break;
        wsBuf = wsBuf.slice(frame.consumed);

        if (frame.opcode === 0x8) { // Close
          console.log('🔌  Server closed connection');
          tls.destroy();
          return;
        }

        if (frame.opcode === 0x2 || frame.opcode === 0x0) { // Binary / continuation
          const msg = parseServerMessage(frame.payload);
          if (!msg) { console.warn('⚠️   Could not parse server message'); continue; }

          if (msg.type === 'ack') {
            console.log(`   ↩  ACK seq=${msg.seq}`);
          } else if (msg.type === 'error') {
            console.error(`❌  Server error: ${msg.error}`);
            tls.destroy();
            reject(new Error(msg.error));
            return;
          } else if (msg.type === 'result') {
            const tag = msg.isFinal ? '[FINAL]' : '[INTERIM]';
            if (msg.text) {
              console.log(`📝  ${tag} "${msg.text}"`);
            } else {
              console.log(`📭  ${tag} (empty) raw result: ${JSON.stringify(msg.raw?.result)}`);
            }

            if (msg.isFinal) {
              tls.destroy();
              if (msg.text) {
                console.log(`\n✅  PASS — API returned: "${msg.text}"`);
              } else {
                console.log(`\n❌  FAIL — Final result has empty text`);
                console.log('    Full response:', JSON.stringify(msg.raw, null, 2));
              }
              resolve(msg.text);
            }
          }
        }
      }
    }
  });
}

main().catch((err) => {
  console.error('\nFatal:', err.message);
  process.exit(1);
});

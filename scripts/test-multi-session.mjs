#!/usr/bin/env node
/**
 * Multi-session Volcengine ASR smoke test
 *
 * Runs 3 back-to-back ASR sessions to reproduce the sequence-mismatch bug.
 * Uses chunked sending (100ms per chunk) + separate empty finish packet,
 * exactly mirroring what volcengine-client.ts does.
 *
 * Usage:
 *   node scripts/test-multi-session.mjs
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
  if (!existsSync(path)) throw new Error('.env not found');
  const env = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^([^#=\s][^=]*)=(.*)/);
    if (m) env[m[1].trim()] = m[2].trim();
  }
  return env;
}

// ─── Protocol ────────────────────────────────────────────────────────────────

const P = {
  MSG_FULL_CLIENT_REQUEST:  0b0001,
  MSG_AUDIO_ONLY_REQUEST:   0b0010,
  MSG_FULL_SERVER_RESPONSE: 0b1001,
  MSG_SERVER_ACK:           0b1011,
  MSG_SERVER_ERROR:         0b1111,
  FLAG_POS_SEQUENCE:        0b0001,
  FLAG_NEG_SEQUENCE:        0b0011,
  SERIAL_JSON:              0b0001,
  COMPRESS_NONE:            0b0000,
  COMPRESS_GZIP:            0b0001,
};

function buildHeader(msgType, flag, serial, compress) {
  return Buffer.from([0x11, (msgType << 4) | flag, (serial << 4) | compress, 0x00]);
}
function i32be(n) { const b = Buffer.alloc(4); b.writeInt32BE(n); return b; }
function readI32BE(buf, off = 0) { return buf.readInt32BE(off); }

function buildInitRequest(seq) {
  const header = buildHeader(P.MSG_FULL_CLIENT_REQUEST, P.FLAG_POS_SEQUENCE, P.SERIAL_JSON, P.COMPRESS_GZIP);
  const body = gzipSync(Buffer.from(JSON.stringify({
    user:    { uid: 'multi_test' },
    audio:   { format: 'pcm', sample_rate: 16000, channel: 1, bits: 16, codec: 'raw' },
    request: { model_name: 'bigmodel', enable_punc: false, enable_itn: true,
                enable_ddc: true, show_utterances: true, result_type: 'full' },
  })));
  return Buffer.concat([header, i32be(seq), i32be(body.length), body]);
}

// Regular audio chunk (not last)
function buildAudioChunk(pcm, seq) {
  const header = buildHeader(P.MSG_AUDIO_ONLY_REQUEST, P.FLAG_POS_SEQUENCE, P.SERIAL_JSON, P.COMPRESS_NONE);
  return Buffer.concat([header, i32be(seq), i32be(pcm.length), pcm]);
}

// Empty finish packet — mirrors what volcengine-client.ts sends
// finishSeq = last audio seq (this.sequence - 1 in the app)
function buildEmptyFinish(finishSeq) {
  const header = buildHeader(P.MSG_AUDIO_ONLY_REQUEST, P.FLAG_NEG_SEQUENCE, P.SERIAL_JSON, P.COMPRESS_NONE);
  return Buffer.concat([header, i32be(-finishSeq), i32be(0)]);
}

function parseMsg(data) {
  if (data.length < 4) return null;
  const msgType = (data[1] >> 4) & 0x0f;
  const msgFlags = data[1] & 0x0f;
  const compress = data[2] & 0x0f;
  if (msgType === P.MSG_SERVER_ERROR) {
    const code = readI32BE(data, 4);
    const size = readI32BE(data, 8);
    let msg = data.slice(12, 12 + size);
    if (compress === P.COMPRESS_GZIP) msg = gunzipSync(msg);
    return { type: 'error', code, error: msg.toString('utf8') };
  }
  if (msgType === P.MSG_SERVER_ACK) return { type: 'ack', seq: readI32BE(data, 4) };
  if (msgType === P.MSG_FULL_SERVER_RESPONSE) {
    const seq = readI32BE(data, 4);
    const psz = readI32BE(data, 8);
    let pl = data.slice(12, 12 + psz);
    if (compress === P.COMPRESS_GZIP) pl = gunzipSync(pl);
    try {
      const json = JSON.parse(pl.toString('utf8'));
      const isFinal = seq < 0 || msgFlags === P.FLAG_NEG_SEQUENCE;
      let text = json.result?.text ?? '';
      if (!text && json.result?.utterances)
        text = json.result.utterances.map(u => u.text).join('');
      return { type: 'result', seq, isFinal, text };
    } catch { return null; }
  }
  return { type: 'unknown', msgType };
}

// ─── WebSocket framing ────────────────────────────────────────────────────────

function wsBinaryFrame(payload) {
  const len = payload.length;
  const mask = randomBytes(4);
  let lenBytes;
  if (len <= 125)        lenBytes = Buffer.from([0x80 | len]);
  else if (len <= 65535) { const b = Buffer.alloc(2); b.writeUInt16BE(len); lenBytes = Buffer.concat([Buffer.from([0xfe]), b]); }
  else                   { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(len)); lenBytes = Buffer.concat([Buffer.from([0xff]), b]); }
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
  return Buffer.concat([Buffer.from([0x82]), lenBytes, mask, masked]);
}

function parseWsFrame(buf) {
  if (buf.length < 2) return null;
  const fin = (buf[0] & 0x80) !== 0;
  const op  = buf[0] & 0x0f;
  const lb  = buf[1] & 0x7f;
  let off = 2, plen;
  if (lb <= 125)      { plen = lb; }
  else if (lb === 126){ if (buf.length < 4) return null; plen = buf.readUInt16BE(2); off = 4; }
  else                { if (buf.length < 10) return null; plen = Number(buf.readBigUInt64BE(2)); off = 10; }
  if (buf.length < off + plen) return null;
  return { op, fin, payload: buf.slice(off, off + plen), consumed: off + plen };
}

// ─── Audio: generate once, reuse across sessions ──────────────────────────────

function generateAudio() {
  const aiff = '/tmp/_multi_test.aiff';
  const wav  = '/tmp/_multi_test.wav';
  execSync(`say -o "${aiff}" -v Tingting "你好，这是多次会话的测试，火山语音识别"`);
  execSync(`afconvert -f WAVE -d LEI16@16000 -c 1 "${aiff}" "${wav}"`);
  const wavBuf = readFileSync(wav);
  let pos = 12;
  while (pos + 8 <= wavBuf.length) {
    const id = wavBuf.slice(pos, pos + 4).toString('ascii');
    const sz = wavBuf.readUInt32LE(pos + 4);
    if (id === 'data') return wavBuf.slice(pos + 8, pos + 8 + sz);
    pos += 8 + sz;
  }
  throw new Error('WAV data chunk not found');
}

// ─── Single ASR session ───────────────────────────────────────────────────────

const CHUNK_BYTES = 3200; // 100 ms at 16 kHz × 2 bytes

function runSession(creds, pcm, sessionNum) {
  return new Promise((resolve, reject) => {
    const requestId = randomBytes(16).toString('hex');
    const wsKey     = randomBytes(16).toString('base64');
    console.log(`\n── Session ${sessionNum} ──────────────────────────────`);
    console.log(`   requestId: ${requestId.slice(0, 16)}...`);

    const tls = connect(443, 'openspeech.bytedance.com', { servername: 'openspeech.bytedance.com' });
    let rawBuf = Buffer.alloc(0);
    let wsBuf  = Buffer.alloc(0);
    let done   = false;
    let seq    = 1;
    let sentChunks = 0;
    let finishSeq  = 0;

    tls.on('error', err => { if (!done) { done = true; reject(err); } });

    tls.on('secureConnect', () => {
      tls.write([
        `GET /api/v3/sauc/bigmodel HTTP/1.1`,
        `Host: openspeech.bytedance.com`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${wsKey}`,
        `Sec-WebSocket-Version: 13`,
        `X-Api-App-Key: ${creds.appId}`,
        `X-Api-Access-Key: ${creds.accessToken}`,
        `X-Api-Resource-Id: ${creds.resourceId}`,
        `X-Api-Connect-Id: ${requestId}`,
        '', '',
      ].join('\r\n'));
    });

    tls.on('data', chunk => {
      if (rawBuf !== null) {
        rawBuf = Buffer.concat([rawBuf, chunk]);
        const end = rawBuf.indexOf('\r\n\r\n');
        if (end === -1) return;
        const hdr = rawBuf.slice(0, end).toString();
        if (!hdr.includes('101')) {
          done = true;
          tls.destroy();
          reject(new Error('WS upgrade failed: ' + hdr.split('\r\n')[0]));
          return;
        }
        wsBuf  = rawBuf.slice(end + 4);
        rawBuf = null; // signal: handshake done

        // Send init (seq=1)
        console.log(`   ↑ init seq=${seq}`);
        tls.write(wsBinaryFrame(buildInitRequest(seq)));
        seq = 2;

        // Send audio chunks with 50ms delay between each (simulate real-time)
        // We simulate a ~1.5s recording then stop
        const MAX_CHUNKS = Math.min(15, Math.ceil(pcm.length / CHUNK_BYTES));
        let chunkIdx = 0;

        function sendNextChunk() {
          if (chunkIdx >= MAX_CHUNKS) {
            // All regular audio sent — now send EMPTY finish packet
            // finishSeq = seq = the NEXT sequence number (server expects this negated)
            finishSeq = seq;
            console.log(`   ↑ finish (empty) seq=-${finishSeq}  [total audio chunks: ${sentChunks}]`);
            tls.write(wsBinaryFrame(buildEmptyFinish(finishSeq)));
            return;
          }
          const offset = chunkIdx * CHUNK_BYTES;
          const end    = Math.min(offset + CHUNK_BYTES, pcm.length);
          const pcmSlice = pcm.slice(offset, end);
          tls.write(wsBinaryFrame(buildAudioChunk(pcmSlice, seq)));
          seq++;
          sentChunks++;
          chunkIdx++;
          setTimeout(sendNextChunk, 50); // 50ms inter-chunk delay
        }
        setTimeout(sendNextChunk, 50);

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
        if (frame.op === 0x8) {
          if (!done) { done = true; tls.destroy(); resolve(null); }
          return;
        }
        if (frame.op === 0x2 || frame.op === 0x0) {
          const msg = parseMsg(frame.payload);
          if (!msg) continue;
          if (msg.type === 'ack') {
            // ACK is fine
          } else if (msg.type === 'error') {
            console.error(`   ✗ SERVER ERROR code=${msg.code}: ${msg.error}`);
            if (!done) { done = true; tls.destroy(); reject(new Error(msg.error)); }
            return;
          } else if (msg.type === 'result') {
            const tag = msg.isFinal ? '[FINAL]' : '[interim]';
            if (msg.text) console.log(`   ↓ ${tag} "${msg.text}"`);
            if (msg.isFinal) {
              if (!done) {
                done = true;
                tls.destroy();
                resolve(msg.text || '');
              }
            }
          }
        }
      }
    }

    // Timeout safety net
    setTimeout(() => {
      if (!done) {
        done = true;
        tls.destroy();
        reject(new Error(`Session ${sessionNum} timed out after 15s`));
      }
    }, 15_000);
  });
}

// ─── Main: run N sessions ─────────────────────────────────────────────────────

async function main() {
  const env  = loadEnv();
  const creds = {
    appId:      env.VITE_VOLCENGINE_APP_ID,
    accessToken: env.VITE_VOLCENGINE_ACCESS_TOKEN,
    resourceId:  env.VITE_VOLCENGINE_RESOURCE_ID || 'volc.bigasr.sauc.duration',
  };
  if (!creds.appId || !creds.accessToken) {
    console.error('Missing credentials in .env'); process.exit(1);
  }

  console.log('Generating test audio...');
  const pcm = generateAudio();
  console.log(`Audio: ${pcm.length} bytes ≈ ${(pcm.length / 32000).toFixed(2)}s`);

  const SESSIONS = 3;
  const results  = [];

  for (let i = 1; i <= SESSIONS; i++) {
    try {
      const text = await runSession(creds, pcm, i);
      results.push({ session: i, ok: true, text });
      console.log(`   ✓ Session ${i} passed: "${text}"`);
    } catch (err) {
      results.push({ session: i, ok: false, error: err.message });
      console.error(`   ✗ Session ${i} failed: ${err.message}`);
    }
    // Brief pause between sessions (like the 800ms idle delay in the app)
    if (i < SESSIONS) await new Promise(r => setTimeout(r, 200));
  }

  console.log('\n─────────────────────────────────────────────');
  const pass = results.filter(r => r.ok).length;
  console.log(`Result: ${pass}/${SESSIONS} sessions passed`);
  if (pass < SESSIONS) process.exit(1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });

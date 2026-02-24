import { useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { VolcengineClient } from '../asr/volcengine-client';
import type { ASRResult, ASRStatus } from '../asr/types';
import { flog } from '../utils/log';

const LLM_SYSTEM_PROMPT =
  '你是一个文本归整助手。将用户输入的语音识别文本整理成流畅的书面语，' +
  '修正标点、大小写和口语化表达，不改变原意，不添加任何解释，只输出归整后的文本。';

const LLM_TIMEOUT_MS = 10_000;

interface LLMConfig {
  llm_enabled: boolean;
  llm_base_url: string;
  llm_model: string;
  llm_api_key: string;
}

async function polishWithLLM(text: string, cfg: LLMConfig): Promise<string> {
  if (!cfg.llm_enabled || !cfg.llm_base_url) return text;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), LLM_TIMEOUT_MS);
  try {
    const res = await fetch(`${cfg.llm_base_url}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(cfg.llm_api_key ? { Authorization: `Bearer ${cfg.llm_api_key}` } : {}),
      },
      body: JSON.stringify({
        model: cfg.llm_model,
        messages: [
          { role: 'system', content: LLM_SYSTEM_PROMPT },
          { role: 'user', content: text },
        ],
        stream: false,
      }),
      signal: controller.signal,
    });
    if (!res.ok) return text;
    const data = await res.json() as { choices?: Array<{ message?: { content?: string } }> };
    return data?.choices?.[0]?.message?.content?.trim() || text;
  } catch {
    return text;
  } finally {
    clearTimeout(timer);
  }
}

export function usePushToTalk() {
  const [status, setStatus] = useState<ASRStatus>('idle');
  const [result, setResult] = useState<ASRResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const clientRef = useRef<VolcengineClient | null>(null);
  const resultRef = useRef<ASRResult | null>(null);
  const isSessionActive = useRef(false);
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const peakRmsRef = useRef(0);
  const llmConfigRef = useRef<LLMConfig | null>(null);

  const LEVEL_COUNT = 16;
  const [audioLevels, setAudioLevels] = useState<number[]>(new Array(LEVEL_COUNT).fill(0));
  const levelsBufferRef = useRef<number[]>(new Array(LEVEL_COUNT).fill(0));

  function cleanupSession() {
    clientRef.current?.disconnect();
    clientRef.current = null;
    isSessionActive.current = false;
    if (idleTimerRef.current !== null) {
      clearTimeout(idleTimerRef.current);
      idleTimerRef.current = null;
    }
  }

  useEffect(() => {
    const cleanup: Array<() => void> = [];

    // Forward Rust audio chunks to Volcengine client
    listen<number[]>('audio:chunk', (event) => {
      const client = clientRef.current;
      if (client) {
        console.log('[audio:chunk] received, len=', event.payload.length);
        const buf = new Int16Array(event.payload).buffer;
        client.sendAudio(buf);
      }
      // Compute RMS for waveform visualization
      if (isSessionActive.current) {
        const samples = event.payload;
        const rms = samples.length > 0
          ? Math.sqrt(samples.reduce((s, x) => s + x * x, 0) / samples.length) / 32768
          : 0;
        const level = Math.min(1, rms * 20);
        console.log('[audio:chunk] rms=', rms.toFixed(4), 'level=', level.toFixed(4));
        if (rms > peakRmsRef.current) peakRmsRef.current = rms;
        const next = [...levelsBufferRef.current.slice(1), level];
        levelsBufferRef.current = next;
        if (isSessionActive.current) {
          setAudioLevels(next);
        }
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:start', async () => {
      flog(`ptt:start isSessionActive=${isSessionActive.current}`);
      if (isSessionActive.current) {
        flog('ptt:start IGNORED (session already active)');
        return;
      }
      isSessionActive.current = true;

      // Cancel any pending idle timer from the previous session
      if (idleTimerRef.current !== null) {
        clearTimeout(idleTimerRef.current);
        idleTimerRef.current = null;
      }

      levelsBufferRef.current = new Array(LEVEL_COUNT).fill(0);
      setAudioLevels(new Array(LEVEL_COUNT).fill(0));
      peakRmsRef.current = 0;
      setStatus('connecting');
      setResult(null);
      setError(null);
      resultRef.current = null;

      try {
        const rawConfig = await invoke<{
          api_app_id: string;
          api_access_token: string;
          api_resource_id: string;
          asr_language: string;
          asr_enable_punc: boolean;
          asr_enable_itn: boolean;
          asr_enable_ddc: boolean;
          asr_vocabulary: string;
          llm_enabled: boolean;
          llm_base_url: string;
          llm_model: string;
          llm_api_key: string;
        }>('get_config');
        const client = new VolcengineClient({
          appId: rawConfig.api_app_id,
          accessToken: rawConfig.api_access_token,
          resourceId: rawConfig.api_resource_id,
          language: rawConfig.asr_language,
          enablePunc: rawConfig.asr_enable_punc,
          enableItn: rawConfig.asr_enable_itn,
          enableDdc: rawConfig.asr_enable_ddc,
          vocabulary: rawConfig.asr_vocabulary || undefined,
        });
        clientRef.current = client;

        llmConfigRef.current = {
          llm_enabled: rawConfig.llm_enabled,
          llm_base_url: rawConfig.llm_base_url,
          llm_model: rawConfig.llm_model,
          llm_api_key: rawConfig.llm_api_key,
        };

        client.on('result', (r: ASRResult) => {
          setResult(r);
          resultRef.current = r;
        });

        client.on('error', (err: Error) => {
          setError(err.message);
          setStatus('error');
          cleanupSession();
          idleTimerRef.current = setTimeout(() => {
            idleTimerRef.current = null;
            setStatus('idle');
            setError(null);
          }, 1500);
        });

        await client.connect();
        flog('ptt:start connect() succeeded');
        setStatus('listening');
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        flog(`ptt:start connect() FAILED: ${msg}`);
        setError(msg);
        setStatus('error');
        cleanupSession();
        idleTimerRef.current = setTimeout(() => {
          idleTimerRef.current = null;
          setStatus('idle');
          setError(null);
        }, 1500);
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:stop', async () => {
      flog(`ptt:stop isSessionActive=${isSessionActive.current} hasClient=${clientRef.current !== null}`);
      if (!isSessionActive.current) {
        flog('ptt:stop IGNORED (no active session)');
        return;
      }

      setStatus('processing');

      // Grab and clear clientRef immediately to stop audio:chunk forwarding
      const client = clientRef.current;
      clientRef.current = null;
      isSessionActive.current = false;

      if (!client) {
        isSessionActive.current = false;
        setStatus('idle');
        return;
      }

      client.finishAudio();

      const finalResult = await new Promise<ASRResult | null>((resolve) => {
        const timeout = setTimeout(() => {
          flog('ptt:stop 3s timeout fired');
          resolve(resultRef.current);
        }, 3_000);

        client.on('result', (r: ASRResult) => {
          if (r.isFinal) {
            flog(`ptt:stop got isFinal result: len=${r.text.length}`);
            clearTimeout(timeout);
            resolve(r);
          }
        });

        client.on('status', (s: ASRStatus) => {
          if (s === 'done' || s === 'idle') {
            clearTimeout(timeout);
            resolve(resultRef.current);
          }
        });
      });

      client.disconnect();
      // clientRef.current and isSessionActive were already cleared at the top of this handler.
      // Do NOT re-assign them here — a new ptt:start may have already set them for the next session.

      if (finalResult?.text) {
        let textToInsert = finalResult.text;
        const llmCfg = llmConfigRef.current;
        if (llmCfg?.llm_enabled && llmCfg.llm_base_url) {
          setStatus('polishing');
          textToInsert = await polishWithLLM(finalResult.text, llmCfg);
        }
        flog(`ptt:stop insert_text: len=${textToInsert.length} polished=${textToInsert !== finalResult.text}`);
        try {
          await invoke('insert_text', { text: textToInsert });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }

      // Only transition to done/idle if no new session has started
      if (!isSessionActive.current) {
        setStatus('done');
        idleTimerRef.current = setTimeout(() => {
          idleTimerRef.current = null;
          if (!isSessionActive.current) {
            setStatus('idle');
            setResult(null);
          }
        }, 800);
      }
      flog(`ptt:stop done finalText.len=${finalResult?.text?.length ?? 0} peakRms=${peakRmsRef.current.toFixed(4)}`);
    }).then((unlisten) => cleanup.push(unlisten));

    return () => {
      cleanup.forEach((fn) => fn());
      cleanupSession();
    };
  }, []);

  return { status, result, error, audioLevels };
}

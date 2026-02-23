import { useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { VolcengineClient } from '../asr/volcengine-client';
import type { ASRResult, ASRStatus } from '../asr/types';

export function usePushToTalk() {
  const [status, setStatus] = useState<ASRStatus>('idle');
  const [result, setResult] = useState<ASRResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const clientRef = useRef<VolcengineClient | null>(null);
  const resultRef = useRef<ASRResult | null>(null);
  const isSessionActive = useRef(false);
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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
      console.log('[audio:chunk] received, len=', event.payload.length, 'active=', isSessionActive.current);
      const client = clientRef.current;
      if (client) {
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
        const next = [...levelsBufferRef.current.slice(1), level];
        levelsBufferRef.current = next;
        if (isSessionActive.current) {
          setAudioLevels(next);
        }
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:start', async () => {
      if (isSessionActive.current) return;
      isSessionActive.current = true;

      // Cancel any pending idle timer from the previous session
      if (idleTimerRef.current !== null) {
        clearTimeout(idleTimerRef.current);
        idleTimerRef.current = null;
      }

      levelsBufferRef.current = new Array(LEVEL_COUNT).fill(0);
      setAudioLevels(new Array(LEVEL_COUNT).fill(0));
      setStatus('connecting');
      setResult(null);
      setError(null);
      resultRef.current = null;

      try {
        const rawConfig = await invoke<{
          api_app_id: string;
          api_access_token: string;
          api_resource_id: string;
        }>('get_config');
        const client = new VolcengineClient({
          appId: rawConfig.api_app_id,
          accessToken: rawConfig.api_access_token,
          resourceId: rawConfig.api_resource_id,
        });
        clientRef.current = client;

        client.on('result', (r: ASRResult) => {
          setResult(r);
          resultRef.current = r;
        });

        client.on('error', (err: Error) => {
          setError(err.message);
          setStatus('error');
          cleanupSession();
        });

        await client.connect();
        setStatus('listening');
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
        setStatus('error');
        cleanupSession();
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:stop', async () => {
      if (!isSessionActive.current) return;

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
        const timeout = setTimeout(() => resolve(resultRef.current), 3_000);

        client.on('result', (r: ASRResult) => {
          if (r.isFinal) {
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
      clientRef.current = null;
      isSessionActive.current = false;

      if (finalResult?.text) {
        try {
          await invoke('insert_text', { text: finalResult.text });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }

      setStatus('done');
      idleTimerRef.current = setTimeout(() => {
        idleTimerRef.current = null;
        setStatus('idle');
        setResult(null);
      }, 800);
    }).then((unlisten) => cleanup.push(unlisten));

    return () => {
      cleanup.forEach((fn) => fn());
      cleanupSession();
    };
  }, []);

  return { status, result, error, audioLevels };
}

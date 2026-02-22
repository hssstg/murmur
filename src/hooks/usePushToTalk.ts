import { useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { AudioRecorder } from '../asr/audio-recorder';
import { VolcengineClient, loadConfig } from '../asr/volcengine-client';
import type { ASRResult, ASRStatus } from '../asr/types';

export function usePushToTalk() {
  const [status, setStatus] = useState<ASRStatus>('idle');
  const [result, setResult] = useState<ASRResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const recorderRef = useRef<AudioRecorder | null>(null);
  const clientRef = useRef<VolcengineClient | null>(null);
  const resultRef = useRef<ASRResult | null>(null);

  useEffect(() => {
    const cleanup: Array<() => void> = [];

    listen<void>('ptt:start', async () => {
      setStatus('connecting');
      setResult(null);
      setError(null);
      resultRef.current = null;

      try {
        const config = loadConfig();
        const client = new VolcengineClient(config);
        clientRef.current = client;

        client.on('result', (r: ASRResult) => {
          setResult(r);
          resultRef.current = r;
        });

        client.on('error', (err: Error) => {
          setError(err.message);
          setStatus('error');
        });

        await client.connect();
        setStatus('listening');

        const recorder = new AudioRecorder((chunk) => {
          client.sendAudio(chunk);
        });
        recorderRef.current = recorder;
        await recorder.start();
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
        setStatus('error');
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:stop', async () => {
      setStatus('processing');

      recorderRef.current?.stop();
      recorderRef.current = null;

      const client = clientRef.current;
      client?.finishAudio();

      if (!client) {
        setStatus('idle');
        return;
      }

      // Wait for final result (max 10s)
      const finalResult = await new Promise<ASRResult | null>((resolve) => {
        const timeout = setTimeout(() => resolve(resultRef.current), 10_000);

        client.on('result', (r: ASRResult) => {
          if (r.isFinal) {
            clearTimeout(timeout);
            resolve(r);
          }
        });

        client.on('status', (s: ASRStatus) => {
          if (s === 'done') {
            clearTimeout(timeout);
            resolve(resultRef.current);
          }
        });
      });

      clientRef.current = null;

      if (finalResult?.text) {
        try {
          await invoke('insert_text', { text: finalResult.text });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }

      setStatus('done');
      setTimeout(() => {
        setStatus('idle');
        setResult(null);
      }, 800);
    }).then((unlisten) => cleanup.push(unlisten));

    return () => {
      cleanup.forEach((fn) => fn());
    };
  }, []);

  return { status, result, error };
}

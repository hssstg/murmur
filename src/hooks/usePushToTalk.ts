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
  // Guard: ignore ptt:start if a session is already active
  const isSessionActive = useRef(false);

  function cleanupSession() {
    recorderRef.current?.stop();
    recorderRef.current = null;
    clientRef.current?.disconnect();
    clientRef.current = null;
    isSessionActive.current = false;
  }

  useEffect(() => {
    const cleanup: Array<() => void> = [];

    listen<void>('ptt:start', async () => {
      // Fix 3: Ignore if already recording
      if (isSessionActive.current) return;
      isSessionActive.current = true;

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

        // Fix 4: Cleanup everything on error
        client.on('error', (err: Error) => {
          setError(err.message);
          setStatus('error');
          cleanupSession();
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
        cleanupSession();
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:stop', async () => {
      if (!isSessionActive.current) return;

      setStatus('processing');

      recorderRef.current?.stop();
      recorderRef.current = null;

      const client = clientRef.current;
      if (!client) {
        isSessionActive.current = false;
        setStatus('idle');
        return;
      }

      client.finishAudio();

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

      // Fix 2: Disconnect client before clearing ref
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
      setTimeout(() => {
        setStatus('idle');
        setResult(null);
      }, 800);
    }).then((unlisten) => cleanup.push(unlisten));

    return () => {
      cleanup.forEach((fn) => fn());
      cleanupSession();
    };
  }, []);

  return { status, result, error };
}

import { useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { usePushToTalk } from '../hooks/usePushToTalk';
import { WaveformVisualizer } from './WaveformVisualizer';
import './floating-window.css';

export function FloatingWindow() {
  const { status, result, audioLevels } = usePushToTalk();

  useEffect(() => {
    const win = getCurrentWindow();
    if (status === 'idle') {
      void win.hide();
    } else {
      void win.show();
    }
  }, [status]);

  const fading = status === 'processing';

  return (
    <div className="floating-window">
      <div className="pill">
        {(status === 'done' || status === 'processing') && result?.text ? (
          <span className="pill__result">{result.text}</span>
        ) : (
          <WaveformVisualizer levels={audioLevels} fading={fading} />
        )}
        {import.meta.env.DEV && (
          <span className="pill__debug">{status}{result?.text ? ` · "${result.text}"` : ''}</span>
        )}
      </div>
    </div>
  );
}

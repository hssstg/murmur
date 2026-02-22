import { useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { usePushToTalk } from '../hooks/usePushToTalk';
import { StatusIndicator } from './StatusIndicator';
import { WaveformVisualizer } from './WaveformVisualizer';
import { ErrorDisplay } from './ErrorDisplay';
import './floating-window.css';

export function FloatingWindow() {
  const { status, error, audioLevels } = usePushToTalk();

  useEffect(() => {
    const win = getCurrentWindow();
    if (status === 'idle') {
      void win.hide();
    } else {
      void win.show();
    }
  }, [status]);

  const showWaveform =
    status === 'connecting' || status === 'listening' || status === 'processing';
  const waveformFading = status === 'processing';

  return (
    <div className="floating-window">
      <div className="floating-window__content">
        <StatusIndicator status={status} />
        {showWaveform && (
          <WaveformVisualizer levels={audioLevels} fading={waveformFading} />
        )}
        {error && <ErrorDisplay message={error} />}
      </div>
    </div>
  );
}

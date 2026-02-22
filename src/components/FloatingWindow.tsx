import { useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { usePushToTalk } from '../hooks/usePushToTalk';
import { StatusIndicator } from './StatusIndicator';
import { TranscriptDisplay } from './TranscriptDisplay';
import { ErrorDisplay } from './ErrorDisplay';
import './floating-window.css';

export function FloatingWindow() {
  const { status, result, error } = usePushToTalk();

  useEffect(() => {
    const win = getCurrentWindow();
    if (status === 'idle') {
      void win.hide();
    } else {
      void win.show();
    }
  }, [status]);

  const hasTranscript =
    Boolean(result?.text) &&
    (status === 'listening' || status === 'processing' || status === 'done');

  return (
    <div className="floating-window">
      <div className="floating-window__content">
        <StatusIndicator status={status} />
        {hasTranscript && result && (
          <TranscriptDisplay text={result.text} interim={!result.isFinal} />
        )}
        {error && <ErrorDisplay message={error} />}
      </div>
    </div>
  );
}

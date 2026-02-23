import { useState } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { FloatingWindow } from './components/FloatingWindow';
import SettingsWindow from './settings/SettingsWindow';

export default function App() {
  const [windowLabel] = useState<string>(() => getCurrentWindow().label);

  if (windowLabel === 'settings') return <SettingsWindow />;
  return <FloatingWindow />;
}

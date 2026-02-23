import { invoke } from '@tauri-apps/api/core';

export function flog(msg: string): void {
  invoke('append_log', { line: msg }).catch(() => {/* ignore */});
}

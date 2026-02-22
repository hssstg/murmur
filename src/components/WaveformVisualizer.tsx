interface WaveformVisualizerProps {
  levels: number[];   // 16 values, each 0–1
  fading: boolean;    // true during processing state → triggers CSS fade-out
}

export function WaveformVisualizer({ levels, fading }: WaveformVisualizerProps) {
  return (
    <div className={`waveform${fading ? ' waveform--fading' : ''}`}>
      {levels.map((level, i) => (
        <div
          key={i}
          className="waveform__bar"
          style={{ height: `${Math.max(3, level * 40)}px` }}
        />
      ))}
    </div>
  );
}

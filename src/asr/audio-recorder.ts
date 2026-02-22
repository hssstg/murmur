import { AUDIO_CONFIG } from './constants';
import { float32ToArrayBuffer } from './pcm-converter';
import type { AudioChunkCallback } from './types';

interface AudioResources {
  stream: MediaStream;
  audioContext: AudioContext;
  sourceNode: MediaStreamAudioSourceNode;
  processorNode: ScriptProcessorNode;
}

export class AudioRecorder {
  private resources: AudioResources | null = null;
  private onAudioChunk: AudioChunkCallback;

  constructor(onAudioChunk: AudioChunkCallback) {
    this.onAudioChunk = onAudioChunk;
  }

  get isRecording(): boolean {
    return this.resources !== null;
  }

  async start(): Promise<void> {
    if (this.resources) return;

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: AUDIO_CONFIG.sampleRate,
        channelCount: AUDIO_CONFIG.channelCount,
        echoCancellation: true,
        noiseSuppression: true,
      },
    });

    const audioContext = new AudioContext({ sampleRate: AUDIO_CONFIG.sampleRate });
    const sourceNode = audioContext.createMediaStreamSource(stream);
    const processorNode = audioContext.createScriptProcessor(
      AUDIO_CONFIG.bufferSize,
      AUDIO_CONFIG.channelCount,
      AUDIO_CONFIG.channelCount
    );

    const onChunk = this.onAudioChunk;
    processorNode.onaudioprocess = (e: AudioProcessingEvent) => {
      onChunk(float32ToArrayBuffer(e.inputBuffer.getChannelData(0)));
    };

    sourceNode.connect(processorNode);
    processorNode.connect(audioContext.destination);

    this.resources = { stream, audioContext, sourceNode, processorNode };
    console.log('[AudioRecorder] started');
  }

  stop(): void {
    if (!this.resources) return;
    const { processorNode, sourceNode, stream, audioContext } = this.resources;
    processorNode.disconnect();
    sourceNode.disconnect();
    stream.getTracks().forEach((t) => t.stop());
    void audioContext.close();
    this.resources = null;
    console.log('[AudioRecorder] stopped');
  }
}

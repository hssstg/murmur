import { describe, it, expect } from 'vitest';
import { float32ToInt16, int16ToArrayBuffer, float32ToArrayBuffer } from './pcm-converter';

describe('float32ToInt16', () => {
  it('converts silence (0.0) to 0', () => {
    const input = new Float32Array([0.0]);
    expect(float32ToInt16(input)[0]).toBe(0);
  });

  it('converts full positive (1.0) to 32767', () => {
    const input = new Float32Array([1.0]);
    expect(float32ToInt16(input)[0]).toBe(0x7fff);
  });

  it('converts full negative (-1.0) to -32768', () => {
    const input = new Float32Array([-1.0]);
    expect(float32ToInt16(input)[0]).toBe(-0x8000);
  });

  it('clamps values above 1.0', () => {
    const input = new Float32Array([2.0]);
    expect(float32ToInt16(input)[0]).toBe(0x7fff);
  });

  it('clamps values below -1.0', () => {
    const input = new Float32Array([-2.0]);
    expect(float32ToInt16(input)[0]).toBe(-0x8000);
  });

  it('converts a multi-sample array', () => {
    const input = new Float32Array([0.0, 0.5, -0.5, 1.0, -1.0]);
    const output = float32ToInt16(input);
    expect(output.length).toBe(5);
    expect(output[0]).toBe(0);
    expect(output[1]).toBeGreaterThan(0);
    expect(output[2]).toBeLessThan(0);
  });

  it('preserves array length', () => {
    const input = new Float32Array(1024);
    expect(float32ToInt16(input).length).toBe(1024);
  });
});

describe('int16ToArrayBuffer', () => {
  it('returns correct byte length (2 bytes per sample)', () => {
    const input = new Int16Array(4);
    expect(int16ToArrayBuffer(input).byteLength).toBe(8);
  });

  it('preserves sample values', () => {
    const input = new Int16Array([100, -200, 32767, -32768]);
    const buf = int16ToArrayBuffer(input);
    const readback = new Int16Array(buf);
    expect(readback[0]).toBe(100);
    expect(readback[1]).toBe(-200);
    expect(readback[2]).toBe(32767);
    expect(readback[3]).toBe(-32768);
  });

  it('returns a copy, not the original buffer', () => {
    const input = new Int16Array([1, 2, 3]);
    const buf = int16ToArrayBuffer(input);
    input[0] = 999;
    expect(new Int16Array(buf)[0]).toBe(1);
  });
});

describe('float32ToArrayBuffer', () => {
  it('produces correct byte length', () => {
    const input = new Float32Array(512);
    expect(float32ToArrayBuffer(input).byteLength).toBe(1024);
  });

  it('silence converts to all-zero buffer', () => {
    const input = new Float32Array(4);
    const buf = float32ToArrayBuffer(input);
    const bytes = new Uint8Array(buf);
    expect(bytes.every(b => b === 0)).toBe(true);
  });
});

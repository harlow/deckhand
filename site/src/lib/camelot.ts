// Same Camelot colors as the Mac app's KeyChip: hue follows the wheel; minor (A) keys are deeper.
function hsb(h: number, s: number, b: number): string {
  const f = (n: number) => {
    const k = (n + h * 6) % 6;
    return Math.round(255 * (b - b * s * Math.max(0, Math.min(k, 4 - k, 1))));
  };
  return `rgb(${f(5)} ${f(3)} ${f(1)})`;
}

export function camelotColor(key: string): string {
  const n = parseInt(key, 10);
  const minor = key.endsWith("A");
  const hue = ((n * 30 + 150) % 360) / 360;
  return minor ? hsb(hue, 0.55, 0.88) : hsb(hue, 0.35, 0.97);
}

/** Deterministic pseudo-random numbers, so the generated waveforms are the same every build. */
export function seeded(seed: number) {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296;
    return s / 4294967296;
  };
}

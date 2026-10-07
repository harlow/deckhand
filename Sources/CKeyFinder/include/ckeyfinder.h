#ifndef CKEYFINDER_H
#define CKEYFINDER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Key of mono audio via libKeyFinder. Returns 0–23 in libKeyFinder order
/// (A major, A minor, Bb major, Bb minor, ... Ab minor), 24 for silence, or -1 on error.
int kf_key(const float *mono, int sampleCount, int sampleRate);

#ifdef __cplusplus
}
#endif

#endif

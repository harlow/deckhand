#ifndef CKEYFINDER_H
#define CKEYFINDER_H

#ifdef __cplusplus
extern "C" {
#endif

/// libKeyFinder's chromagram: `*hopsOut` rows of 72 bands (C1 … B6, semitone spacing), for audio
/// already low-passed below ~2.2 kHz and decimated (e.g. 5 kHz). Skips libKeyFinder's own
/// filtering/resampling, which dominated its cost. Caller frees `*out` with free().
/// Returns 0 on success, -1 on error.
int kf_chromagram_prefiltered(const float *mono, int sampleCount, int sampleRate, double **out, int *hopsOut);

#ifdef __cplusplus
}
#endif

#endif

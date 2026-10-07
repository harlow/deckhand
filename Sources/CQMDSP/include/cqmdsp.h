#ifndef CQMDSP_H
#define CQMDSP_H

#ifdef __cplusplus
extern "C" {
#endif

/// Onset detection function (qm-dsp complex spectral difference). Value `i` describes the
/// frame centered at `i * stepSeconds`. Returns 0 on success; free `*dfOut` with qm_free.
int qm_onset_function(const float *mono, int sampleCount, int sampleRate,
                      double **dfOut, int *countOut, double *stepSecondsOut);

/// Beat tracking over an onset function (qm-dsp TempoTrackV2). Sets `*beatsOut` to beat
/// times in seconds. Returns 0 on success; free `*beatsOut` with qm_free.
int qm_beats_from_onsets(const double *df, int count, int sampleRate, double stepSeconds,
                         double **beatsOut, int *beatCountOut);

void qm_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif

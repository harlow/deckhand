#include "cqmdsp.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "dsp/onsets/DetectionFunction.h"
#include "dsp/tempotracking/TempoTrackV2.h"
#include "maths/MathUtilities.h"

namespace {

// Same parameters Mixxx uses with qm-dsp: ~11.6 ms steps, ~50 Hz bins.
const double kStepSeconds = 0.01161;
const int kMaxBinHz = 50;

template <typename T>
T *copyOut(const std::vector<T> &v) {
    T *p = static_cast<T *>(std::malloc(sizeof(T) * (v.empty() ? 1 : v.size())));
    if (p && !v.empty()) std::memcpy(p, v.data(), sizeof(T) * v.size());
    return p;
}

} // namespace

extern "C" int qm_onset_function(const float *mono, int sampleCount, int sampleRate,
                                 double **dfOut, int *countOut, double *stepSecondsOut) {
    if (!mono || sampleCount <= 0 || sampleRate <= 0) return -1;

    const int step = static_cast<int>(sampleRate * kStepSeconds);
    const int window = MathUtilities::nextPowerOfTwo(sampleRate / kMaxBinHz);

    DFConfig config;
    config.DFType = DF_COMPLEXSD;
    config.stepSize = step;
    config.frameLength = window;
    config.dbRise = 3;
    config.adaptiveWhitening = false;
    config.whiteningRelaxCoeff = -1;
    config.whiteningFloor = -1;
    DetectionFunction detector(config);

    // Frames centered on multiples of `step` (zero padded at both ends).
    std::vector<double> frame(window);
    std::vector<double> df;
    df.reserve(sampleCount / step + 2);
    for (long center = 0; center < sampleCount; center += step) {
        long start = center - window / 2;
        if (start >= 0 && start + window <= sampleCount) {
            for (int i = 0; i < window; ++i) frame[i] = mono[start + i];
        } else {
            for (int i = 0; i < window; ++i) {
                long idx = start + i;
                frame[i] = (idx >= 0 && idx < sampleCount) ? mono[idx] : 0.0;
            }
        }
        df.push_back(detector.processTimeDomain(frame.data()));
    }

    *dfOut = copyOut(df);
    *countOut = static_cast<int>(df.size());
    *stepSecondsOut = step / static_cast<double>(sampleRate);
    return *dfOut ? 0 : -1;
}

extern "C" int qm_beats_from_onsets(const double *df, int count, int sampleRate, double stepSeconds,
                                    double **beatsOut, int *beatCountOut) {
    if (!df || count <= 0 || sampleRate <= 0) return -1;
    const int step = static_cast<int>(stepSeconds * sampleRate + 0.5);

    // The first values respond to the start of the signal rather than to onsets.
    const int skip = 2;
    if (count <= skip + 8) {
        *beatsOut = copyOut(std::vector<double>());
        *beatCountOut = 0;
        return 0;
    }
    std::vector<double> trimmed(df + skip, df + count);

    TempoTrackV2 tracker(static_cast<float>(sampleRate), step);
    std::vector<double> beatPeriod(trimmed.size());
    std::vector<double> tempi;
    tracker.calculateBeatPeriod(trimmed, beatPeriod, tempi);
    std::vector<double> beats;
    tracker.calculateBeats(trimmed, beatPeriod, beats);

    std::vector<double> seconds;
    seconds.reserve(beats.size());
    for (double b : beats) seconds.push_back((b + skip) * stepSeconds);

    *beatsOut = copyOut(seconds);
    *beatCountOut = static_cast<int>(seconds.size());
    return *beatsOut ? 0 : -1;
}

extern "C" void qm_free(void *pointer) { std::free(pointer); }

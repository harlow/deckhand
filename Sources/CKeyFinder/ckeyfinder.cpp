#include "ckeyfinder.h"

#include "spectrumanalyser.h"
#include <cmath>
#include <cstdlib>

extern "C" int kf_chromagram_prefiltered(const float *mono, int sampleCount, int sampleRate, double **out, int *hopsOut) {
    if (!mono || sampleCount <= 0 || sampleRate <= 0 || !out || !hopsOut) return -1;
    // Factories cache transforms/windows per rate and are internally synchronized.
    static KeyFinder::ChromaTransformFactory ctFactory;
    static KeyFinder::TemporalWindowFactory twFactory;
    try {
        KeyFinder::AudioData audio;
        audio.setFrameRate(sampleRate);
        audio.setChannels(1);
        // Zero-pad to whole frames, as KeyFinder::finalChromagram does.
        unsigned int hopCount = (unsigned int)std::ceil(sampleCount / (double)HOPSIZE);
        unsigned int length = FFTFRAMESIZE + (hopCount - 1) * HOPSIZE;
        audio.addToSampleCount(length);
        for (int i = 0; i < sampleCount; ++i) audio.setSample(i, mono[i]);
        KeyFinder::FftAdapter fft(FFTFRAMESIZE);
        KeyFinder::SpectrumAnalyser sa(sampleRate, &ctFactory, &twFactory);
        KeyFinder::Chromagram *c = sa.chromagramOfWholeFrames(audio, &fft);
        int hops = static_cast<int>(c->getHops());
        double *buf = static_cast<double *>(std::malloc(sizeof(double) * (hops > 0 ? hops : 1) * BANDS));
        if (!buf) { delete c; return -1; }
        for (int h = 0; h < hops; ++h)
            for (int b = 0; b < BANDS; ++b) buf[h * BANDS + b] = c->getMagnitude(h, b);
        delete c;
        *out = buf;
        *hopsOut = hops;
        return 0;
    } catch (...) {
        return -1;
    }
}

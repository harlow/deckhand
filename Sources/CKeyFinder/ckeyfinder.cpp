#include "ckeyfinder.h"

#include "keyfinder.h"

extern "C" int kf_key(const float *mono, int sampleCount, int sampleRate) {
    if (!mono || sampleCount <= 0 || sampleRate <= 0) return -1;
    try {
        KeyFinder::AudioData audio;
        audio.setFrameRate(sampleRate);
        audio.setChannels(1);
        audio.addToSampleCount(sampleCount);
        for (int i = 0; i < sampleCount; ++i) audio.setSample(i, mono[i]);
        KeyFinder::KeyFinder finder;
        return static_cast<int>(finder.keyOfAudio(audio));
    } catch (...) {
        return -1;
    }
}

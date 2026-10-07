// Accelerate (vDSP) implementation of libKeyFinder's FFT adapters, replacing the FFTW version.
// Same interface and output conventions as libkeyfinder/fftadapter.cpp (GPL-3.0).

#include "fftadapter.h"

#include <Accelerate/Accelerate.h>
#include <cmath>
#include <vector>

namespace KeyFinder {

  class FftAdapterPrivate {
  public:
    vDSP_DFT_SetupD setup;
    std::vector<double> inReal, inImag, outReal, outImag;
  };

  FftAdapter::FftAdapter(unsigned int inFrameSize) : priv(new FftAdapterPrivate) {
    frameSize = inFrameSize;
    priv->setup = vDSP_DFT_zop_CreateSetupD(nullptr, frameSize, vDSP_DFT_FORWARD);
    if (!priv->setup) throw Exception("Unsupported FFT frame size");
    priv->inReal.assign(frameSize, 0.0);
    priv->inImag.assign(frameSize, 0.0);
    priv->outReal.assign(frameSize, 0.0);
    priv->outImag.assign(frameSize, 0.0);
  }

  FftAdapter::~FftAdapter() {
    vDSP_DFT_DestroySetupD(priv->setup);
    delete priv;
  }

  unsigned int FftAdapter::getFrameSize() const {
    return frameSize;
  }

  void FftAdapter::setInput(unsigned int i, double real) {
    if (i >= frameSize) throw Exception("Cannot set out-of-bounds sample");
    if (!std::isfinite(real)) throw Exception("Cannot set sample to NaN");
    priv->inReal[i] = real;
  }

  double FftAdapter::getOutputReal(unsigned int i) const {
    if (i >= frameSize) throw Exception("Cannot get out-of-bounds sample");
    // FFTW's r2c output only populates bins 0...n/2.
    return i <= frameSize / 2 ? priv->outReal[i] : 0.0;
  }

  double FftAdapter::getOutputImaginary(unsigned int i) const {
    if (i >= frameSize) throw Exception("Cannot get out-of-bounds sample");
    return i <= frameSize / 2 ? priv->outImag[i] : 0.0;
  }

  double FftAdapter::getOutputMagnitude(unsigned int i) const {
    return std::hypot(getOutputReal(i), getOutputImaginary(i));
  }

  void FftAdapter::execute() {
    vDSP_DFT_ExecuteD(priv->setup, priv->inReal.data(), priv->inImag.data(),
                      priv->outReal.data(), priv->outImag.data());
  }

  // ================================= INVERSE =================================

  class InverseFftAdapterPrivate {
  public:
    vDSP_DFT_SetupD setup;
    std::vector<double> inReal, inImag, outReal, outImag;
  };

  InverseFftAdapter::InverseFftAdapter(unsigned int inFrameSize) : priv(new InverseFftAdapterPrivate) {
    frameSize = inFrameSize;
    priv->setup = vDSP_DFT_zop_CreateSetupD(nullptr, frameSize, vDSP_DFT_INVERSE);
    if (!priv->setup) throw Exception("Unsupported FFT frame size");
    priv->inReal.assign(frameSize, 0.0);
    priv->inImag.assign(frameSize, 0.0);
    priv->outReal.assign(frameSize, 0.0);
    priv->outImag.assign(frameSize, 0.0);
  }

  InverseFftAdapter::~InverseFftAdapter() {
    vDSP_DFT_DestroySetupD(priv->setup);
    delete priv;
  }

  unsigned int InverseFftAdapter::getFrameSize() const {
    return frameSize;
  }

  void InverseFftAdapter::setInput(unsigned int i, double real, double imag) {
    if (i >= frameSize) throw Exception("Cannot set out-of-bounds sample");
    if (!std::isfinite(real) || !std::isfinite(imag)) throw Exception("Cannot set sample to NaN");
    priv->inReal[i] = real;
    priv->inImag[i] = imag;
  }

  double InverseFftAdapter::getOutput(unsigned int i) const {
    if (i >= frameSize) throw Exception("Cannot get out-of-bounds sample");
    return priv->outReal[i] / frameSize;
  }

  void InverseFftAdapter::execute() {
    // Match FFTW's c2r: only bins 0...n/2 are used; the rest follow Hermitian symmetry.
    std::vector<double> re(priv->inReal), im(priv->inImag);
    for (unsigned int k = 1; k < frameSize / 2; ++k) {
      re[frameSize - k] = re[k];
      im[frameSize - k] = -im[k];
    }
    im[0] = 0.0;
    im[frameSize / 2] = 0.0;
    vDSP_DFT_ExecuteD(priv->setup, re.data(), im.data(), priv->outReal.data(), priv->outImag.data());
  }

}

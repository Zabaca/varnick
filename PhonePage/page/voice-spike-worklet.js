// The Voice mode spike's meter (voicespike.ts): runs on the audio thread, so a hidden page's timer throttling can't move it. Once a second of
// audio it posts the level of what the microphone gave: the root mean square and the peak, and how many frames had no input at all.
class Meter extends AudioWorkletProcessor {
  constructor() {
    super();
    this.reset();
  }

  reset() {
    this.sum = 0;
    this.peak = 0;
    this.counted = 0;
    this.frames = 0;
    this.blank = 0;
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (let i = 0; i < channel.length; i++) {
        const sample = channel[i];
        this.sum += sample * sample;
        const size = Math.abs(sample);
        if (size > this.peak) this.peak = size;
      }
      this.counted += channel.length;
      this.frames += channel.length;
    } else {
      // The graph gave no input: counted apart from silence, which is input of zeros.
      this.blank += 128;
      this.frames += 128;
    }
    if (this.frames >= sampleRate) {
      this.port.postMessage({ rms: this.counted > 0 ? Math.sqrt(this.sum / this.counted) : 0, peak: this.peak, blank: this.blank });
      this.reset();
    }
    return true;
  }
}

registerProcessor("spike-meter", Meter);

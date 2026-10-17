// Voice mode's microphone reader (option 05 of phone-page-is-only-a-browser-tab): runs on the audio thread, so a page the browser throttles doesn't
// delay it. It turns the microphone's samples into 16 kHz 16-bit mono blocks of 100 ms and posts each with its level (the root mean square), for the
// page to find where a request begins and ends and to send.

const target = 16000;
export const blockSamples = 1600;

/** Averages input samples down to `to` Hz: every output sample is the mean of the `from / to` input samples that fall in it. Not for upsampling. */
export class Downsampler {
  constructor(from, to = target) {
    this.ratio = Math.max(1, from / to);
    this.into = 0;
    this.sum = 0;
    this.count = 0;
  }

  /** Appends the input's downsampled samples to `out` (an array of numbers). */
  push(input, out) {
    for (let i = 0; i < input.length; i++) {
      this.sum += input[i];
      this.count += 1;
      this.into += 1;
      if (this.into >= this.ratio) {
        this.into -= this.ratio;
        out.push(this.sum / this.count);
        this.sum = 0;
        this.count = 0;
      }
    }
  }
}

/** A block of float samples as 16-bit, and its level. */
export function block(samples) {
  const pcm = new Int16Array(samples.length);
  let sum = 0;
  for (let i = 0; i < samples.length; i++) {
    const clipped = Math.max(-1, Math.min(1, samples[i]));
    pcm[i] = Math.round(clipped * 32767);
    sum += clipped * clipped;
  }
  return { pcm, rms: samples.length > 0 ? Math.sqrt(sum / samples.length) : 0 };
}

if (typeof registerProcessor === "function") {
  registerProcessor("voice-capture", class extends AudioWorkletProcessor {
    constructor() {
      super();
      this.down = new Downsampler(sampleRate);
      this.pending = [];
    }

    process(inputs) {
      const channel = inputs[0] && inputs[0][0];
      if (channel) this.down.push(channel, this.pending);
      while (this.pending.length >= blockSamples) {
        const { pcm, rms } = block(this.pending.splice(0, blockSamples));
        this.port.postMessage({ pcm, rms }, [pcm.buffer]);
      }
      return true;
    }
  });
}

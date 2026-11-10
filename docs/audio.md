# audio

Audio uses six voices numbered 1–6. Each voice plays a wavetable oscillator or a loaded WAV sound. Available waveforms are `"sine"`, `"square"`, `"sawtooth"`, `"triangle"`, and `"noise"`.

| API | Behavior |
| --- | --- |
| `audio.start(voice, frequency [, waveform])` | Start a wavetable voice. The waveform defaults to `"sine"`. |
| `audio.stop([voice])` | Stop a voice. When omitted or `nil`, discard pending audio commands and reliably queue a stop for all voices, including when the queue was full. |
| `audio.set_frequency(voice, frequency)` | Change an active wavetable voice's frequency. Stopped voices and WAV playback are unaffected. |
| `audio.set_waveform(voice, waveform)` | Change an active wavetable voice's waveform while preserving its frequency, volume, and envelope. Stopped voices and WAV playback are unaffected. |
| `audio.set_volume(voice, volume)` | Set a voice's gain. |
| `audio.set_master_volume(volume)` | Set the overall output gain. |
| `audio.load(path)` | Load an 8-bit PCM WAV at 22050 Hz, mono or stereo. Return a sound object, or `nil, error` on failure. |
| `audio.play(voice, sound)` | Play a loaded sound once. A `nil` voice selects the first idle voice when the command is processed, or drops the sound if all voices are busy. |

Frequencies must be above 0 and below 11025 Hz. Volumes are linear gains from 0 to 1. Playback and setter calls return whether the command was queued; this does not guarantee that a sound assigned to an idle voice will play.

---@meta

---@alias audio.Waveform
---| "sine"
---| "square"
---| "sawtooth"
---| "triangle"
---| "noise"

---An opaque loaded WAV sound. Memory is released by garbage collection.
---@class audio.Sound

---TabOS audio: six voices (1–6), each playing a wavetable oscillator or WAV sound.
---Playback and setter calls return whether the command was queued.
audio = {}

---Start a wavetable voice. The waveform defaults to "sine".
---@param voice integer Voice number (1–6).
---@param frequency number Frequency in Hz, strictly above 0 and below 11025.
---@param waveform? audio.Waveform
---@return boolean queued
function audio.start(voice, frequency, waveform) end

---Stop a voice, or all voices when omitted or nil.
---@param voice? integer Voice number (1–6); nil stops all voices.
---@return boolean queued
function audio.stop(voice) end

---Change an active wavetable voice's frequency. Stopped voices and WAV playback are unaffected.
---@param voice integer Voice number (1–6).
---@param frequency number Frequency in Hz, strictly above 0 and below 11025.
---@return boolean queued
function audio.set_frequency(voice, frequency) end

---Change an active wavetable voice's waveform, preserving frequency, volume, and envelope.
---Stopped voices and WAV playback are unaffected.
---@param voice integer Voice number (1–6).
---@param waveform audio.Waveform
---@return boolean queued
function audio.set_waveform(voice, waveform) end

---Set a voice's gain.
---@param voice integer Voice number (1–6).
---@param volume number Linear gain (0–1).
---@return boolean queued
function audio.set_volume(voice, volume) end

---Set the overall output gain.
---@param volume number Linear gain (0–1).
---@return boolean queued
function audio.set_master_volume(volume) end

---Load an 8-bit PCM WAV at 22050 Hz, mono or stereo.
---@param path string WAV filesystem path.
---@return audio.Sound? sound Loaded sound, or nil on failure.
---@return string? error Error message on failure.
function audio.load(path) end

---Play a loaded sound once. A nil voice selects the first idle voice when processed.
---If all voices are busy, automatic selection drops the sound even if it was queued.
---@param voice integer|nil Voice number (1–6), or nil for automatic selection.
---@param sound audio.Sound
---@return boolean queued
function audio.play(voice, sound) end

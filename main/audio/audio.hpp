#pragma once

#include <cstddef>

#include "lua/lua_vm.hpp"

namespace tabos::audio {

class Sound;

inline constexpr std::size_t voice_count = 6;
inline constexpr std::size_t all_voices = voice_count;
inline constexpr unsigned sample_rate = 22050;

enum class Action { Start, Stop, SetFrequency, SetVolume, Play };
enum class Waveform { Sine, Square, Sawtooth, Count };

// Initialize once after M5.begin() and before starting Lua.
bool init();

// Voice is zero-based. all_voices stops every voice or sets the master volume.
// The value is Hz for Start and SetFrequency, or a linear gain (0..1) for SetVolume.
bool post(Action action, std::size_t voice, double value = 0, Waveform waveform = Waveform::Sine);
// all_voices selects the first idle voice at dispatch, or drops the sound if all are busy.
bool play(std::size_t voice, Sound& sound);
lua_vm::Module lua_module();

}

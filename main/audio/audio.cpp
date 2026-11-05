#include "audio.hpp"
#include "sound.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <numbers>

#include "M5Unified.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

namespace tabos::audio {
namespace {

constexpr const char* tag = "audio";
constexpr int audio_core = 0;
constexpr UBaseType_t speaker_priority = 3;
constexpr int speaker_channel = 0;
constexpr std::size_t block_samples = 64; // Frames per PCM block and DMA buffer.
constexpr std::size_t queue_depth = 32;
constexpr unsigned table_bits = 10;
constexpr unsigned phase_fraction_bits = 32 - table_bits;
constexpr int table_size = 1u << table_bits;
constexpr int voice_peak = INT8_MAX;
constexpr int mix_divisor = 8; // Keep roughly the same output level and leave headroom.
constexpr int pcm_scale = 256; // Expand signed 8-bit levels into the 16-bit PCM range.
static_assert(voice_count <= mix_divisor);
constexpr int envelope_max = sample_rate / 100; // 10 ms release at one unit per sample.
constexpr int attack_step = 2; // 5 ms attack.
constexpr int gain_max = 4096;

struct Command {
    Action action;
    std::size_t voice;
    double value;
    Waveform waveform;
    Sound* sound = nullptr; // The queue owns one reference for a Play command.
};

using Wavetable = std::array<int8_t, table_size>;
using Wavetables = std::array<Wavetable, static_cast<std::size_t>(Waveform::Count)>;

struct Voice {
    uint32_t phase = 0;
    uint32_t phase_step = 0;
    int envelope = 0;
    Waveform waveform = Waveform::Sine;
    Waveform next_waveform = Waveform::Sine;
    SoundRef sound;
    SoundRef next_sound;
    std::size_t sound_position = 0;
    int volume = gain_max;
    bool playing = false;
    bool wants_sound = false;

    void apply(const Command& command)
    {
        switch (command.action) {
        case Action::Start:
            if (envelope == 0) {
                phase = 0;
            }
            playing = true;
            wants_sound = false;
            next_sound.reset();
            next_waveform = command.waveform;
            set_frequency(command.value);
            break;
        case Action::Play:
            next_sound.reset(command.sound);
            wants_sound = true;
            playing = true;
            break;
        case Action::Stop:
            playing = false;
            next_sound.reset();
            break;
        case Action::SetFrequency:
            if (playing && !wants_sound) {
                set_frequency(command.value);
            }
            break;
        case Action::SetVolume:
            volume = std::lround(command.value * gain_max);
            break;
        }
    }

    int8_t sample(const Wavetables& tables)
    {
        if (envelope == 0) {
            if (!playing) {
                sound.reset();
                return 0;
            }
            if (next_sound) {
                sound = std::move(next_sound);
                sound_position = 0;
            } else if (!wants_sound) {
                sound.reset();
                waveform = next_waveform;
            }
        }

        const bool switching = next_sound || (!wants_sound && (sound || waveform != next_waveform));
        int source;
        int level = envelope;
        if (sound) {
            source = sound->sample(sound_position++);
            const auto remaining = sound->size() - sound_position;
            if (remaining == 0) {
                sound.reset();
                envelope = 0;
                playing = playing && switching;
                return 0;
            }
            // End a one-shot at zero gain even when the file ends on a nonzero sample.
            level = std::min<std::size_t>(level, remaining);
        } else {
            source = tables[static_cast<std::size_t>(waveform)][phase >> phase_fraction_bits];
            phase += phase_step;
        }

        if (playing && !switching) {
            envelope = std::min(envelope + attack_step, envelope_max);
        } else {
            // Bring a running voice down to zero before switching its source.
            envelope = std::max(envelope - (playing ? attack_step : 1), 0);
        }
        return static_cast<int8_t>(source * level * volume / (envelope_max * gain_max));
    }

private:
    void set_frequency(double frequency)
    {
        constexpr double phase_per_hz = 4294967296.0 / sample_rate;
        phase_step = std::max(uint32_t{1}, static_cast<uint32_t>(frequency * phase_per_hz));
    }
};

QueueHandle_t commands = nullptr;
SemaphoreHandle_t command_gate = nullptr;
std::atomic<bool> ready{false};

bool enqueue(const Command& command)
{
    if (!command_gate || xSemaphoreTake(command_gate, 0) != pdTRUE) {
        return false;
    }
    const bool queued = ready.load() && xQueueSend(commands, &command, 0) == pdPASS;
    xSemaphoreGive(command_gate);
    return queued;
}

void discard_pending_commands()
{
    // Close the queue to producers before releasing its sound references.
    xSemaphoreTake(command_gate, portMAX_DELAY);
    ready.store(false);
    xSemaphoreGive(command_gate);
    Command command;
    while (xQueueReceive(commands, &command, 0) == pdPASS) {
        if (command.sound) {
            command.sound->release();
        }
    }
}

void task(void* context)
{
    auto config = M5.Speaker.config();
    config.sample_rate = sample_rate;
    config.dma_buf_len = block_samples;
    config.dma_buf_count = 4;
    config.task_pinned_core = audio_core;
    config.task_priority = speaker_priority;
    config.magnification = 8;
    M5.Speaker.config(config);
    M5.Speaker.setVolume(255);

    static Wavetables tables;
    auto& [sine, square, sawtooth] = tables;
    for (int i = 0; i < table_size; ++i) {
        sine[i] = std::lround(voice_peak * std::sin(2 * std::numbers::pi * i / table_size));
        square[i] = i < table_size / 2 ? voice_peak : -voice_peak;
        sawtooth[i] = std::lround(voice_peak * (2.0 * i / (table_size - 1) - 1));
    }

    const bool started = M5.Speaker.begin();
    if (!started) {
        M5.Speaker.end();
    }
    ready.store(started);
    xTaskNotify(static_cast<TaskHandle_t>(context), started, eSetValueWithOverwrite);
    if (started) {
        std::array<Voice, voice_count> voices;
        int master_volume = gain_max;
        // The speaker can hold two blocks at once. Render into a third block so
        // the next playRaw call can wait for a slot without overwriting PCM.
        std::array<std::array<int16_t, block_samples>, 3> buffers;
        for (std::size_t block = 0;; block = (block + 1) % buffers.size()) {
            Command command;
            for (std::size_t i = 0; i < queue_depth && xQueueReceive(commands, &command, 0); ++i) {
                if (command.voice != all_voices) {
                    voices[command.voice].apply(command);
                } else if (command.action == Action::Play) {
                    const auto idle = std::find_if(voices.begin(), voices.end(), [](const Voice& voice) {
                        return !voice.playing && voice.envelope == 0;
                    });
                    if (idle != voices.end()) {
                        idle->apply(command);
                    } else {
                        command.sound->release();
                    }
                } else if (command.action == Action::SetVolume) {
                    master_volume = std::lround(command.value * gain_max);
                } else {
                    for (auto& voice : voices) {
                        voice.apply(command);
                    }
                }
            }

            auto& buffer = buffers[block];
            for (auto& sample : buffer) {
                int mix = 0;
                for (auto& voice : voices) {
                    mix += voice.sample(tables);
                }
                sample = static_cast<int16_t>(mix * master_volume * pcm_scale / (gain_max * mix_divisor));
            }

            if (!M5.Speaker.playRaw(buffer.data(), buffer.size(), sample_rate, false, 1, speaker_channel)) {
                discard_pending_commands();
                ESP_LOGE(tag, "Could not queue PCM for playback");
                // Release the speaker's references before the buffers go out of scope.
                M5.Speaker.end();
                break;
            }
        }
    }
    vTaskDelete(nullptr);
}

}

bool init()
{
    commands = xQueueCreate(queue_depth, sizeof(Command));
    if (!commands) {
        return false;
    }
    command_gate = xSemaphoreCreateMutex();
    if (command_gate) {
        if (xTaskCreatePinnedToCore(task, "audio", 6144, xTaskGetCurrentTaskHandle(),
                                    speaker_priority + 1, nullptr, audio_core) == pdPASS) {
            uint32_t started = 0;
            xTaskNotifyWait(0, UINT32_MAX, &started, portMAX_DELAY);
            if (started) {
                return true;
            }
        }
        vSemaphoreDelete(command_gate);
        command_gate = nullptr;
    }
    vQueueDelete(commands);
    commands = nullptr;
    return false;
}

bool post(Action action, std::size_t voice, double value, Waveform waveform)
{
    const bool whole_mix = voice == all_voices && (action == Action::Stop || action == Action::SetVolume);
    const bool uses_frequency = action == Action::Start || action == Action::SetFrequency;
    if ((!whole_mix && voice >= voice_count) ||
        (uses_frequency && !(value > 0 && value < sample_rate / 2)) ||
        (action == Action::SetVolume && !(value >= 0 && value <= 1)) ||
        (action == Action::Start && (waveform < Waveform::Sine || waveform >= Waveform::Count)) ||
        action == Action::Play) {
        return false;
    }
    const Command command{action, voice, value, waveform};
    return enqueue(command);
}

bool play(std::size_t voice, Sound& sound)
{
    if (voice > all_voices) {
        return false;
    }
    sound.retain();
    if (enqueue({Action::Play, voice, 0, Waveform::Sine, &sound})) {
        return true;
    }
    sound.release();
    return false;
}

}

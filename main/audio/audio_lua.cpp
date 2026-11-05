#include "audio.hpp"
#include "sound.hpp"

#include <cstring>

#include "lua/module_definition.hpp"

extern "C" {
#include "lauxlib.h"
}

namespace tabos::audio {
namespace {

constexpr const char* sound_type = "audio.Sound";

std::size_t check_voice(lua_State* state)
{
    const auto index = luaL_checkinteger(state, 1);
    luaL_argcheck(state, index >= 1 && index <= static_cast<lua_Integer>(voice_count), 1,
                  lua_pushfstring(state, "expected voice 1..%d", static_cast<int>(voice_count)));
    return index - 1;
}

int release_sound(lua_State* state)
{
    auto** sound = static_cast<Sound**>(luaL_checkudata(state, 1, sound_type));
    if (*sound) {
        (*sound)->release();
        *sound = nullptr;
    }
    return 0;
}

int load_sound(lua_State* state)
{
    std::size_t length;
    const char* path = luaL_checklstring(state, 1, &length);
    luaL_argcheck(state, std::strlen(path) == length, 1, "invalid WAV path");

    auto** sound = static_cast<Sound**>(lua_newuserdatauv(state, sizeof(Sound*), 0));
    *sound = nullptr;
    luaL_setmetatable(state, sound_type);
    const char* error = nullptr;
    *sound = load_wav(path, error);
    if (!*sound) {
        lua_pushnil(state);
        lua_pushstring(state, error);
        return 2;
    }
    return 1;
}

int play_sound(lua_State* state)
{
    const auto voice = lua_isnil(state, 1) ? all_voices : check_voice(state);
    auto** sound = static_cast<Sound**>(luaL_checkudata(state, 2, sound_type));
    luaL_argcheck(state, *sound != nullptr, 2, "invalid sound");
    lua_pushboolean(state, play(voice, **sound));
    return 1;
}

double check_volume(lua_State* state, int argument)
{
    const auto volume = luaL_checknumber(state, argument);
    luaL_argcheck(state, volume >= 0 && volume <= 1, argument, "expected volume from 0 to 1");
    return volume;
}

template <Action action>
int command(lua_State* state)
{
    std::size_t voice = all_voices;
    if (action != Action::Stop || !lua_isnoneornil(state, 1)) {
        voice = check_voice(state);
    }

    double value = 0;
    if constexpr (action == Action::SetVolume) {
        value = check_volume(state, 2);
    } else if constexpr (action != Action::Stop) {
        value = luaL_checknumber(state, 2);
        constexpr int frequency_limit = sample_rate / 2;
        luaL_argcheck(state, value > 0 && value < frequency_limit, 2,
                      lua_pushfstring(state, "expected frequency above 0 and below %d Hz", frequency_limit));
    }

    auto waveform = Waveform::Sine;
    if constexpr (action == Action::Start) {
        const char* const options[] = {"sine", "square", "sawtooth", nullptr};
        waveform = static_cast<Waveform>(luaL_checkoption(state, 3, "sine", options));
    }

    lua_pushboolean(state, post(action, voice, value, waveform));
    return 1;
}

int set_master_volume(lua_State* state)
{
    lua_pushboolean(state, post(Action::SetVolume, all_voices, check_volume(state, 1)));
    return 1;
}

int push_audio_table(lua_State* state)
{
    if (luaL_newmetatable(state, sound_type)) {
        lua_pushcfunction(state, release_sound);
        lua_setfield(state, -2, "__gc");
        lua_pushstring(state, sound_type);
        lua_setfield(state, -2, "__metatable");
    }
    lua_pop(state, 1);

    const luaL_Reg functions[] = {
        {"load", load_sound},
        {"play", play_sound},
        {"start", command<Action::Start>},
        {"stop", command<Action::Stop>},
        {"set_frequency", command<Action::SetFrequency>},
        {"set_volume", command<Action::SetVolume>},
        {"set_master_volume", set_master_volume},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}

}

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"audio", push_audio_table};
    return lua_vm::Module{definition};
}

}

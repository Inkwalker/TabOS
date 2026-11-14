#include "module_definition.hpp"
#include "lua_memory.hpp"

#include <algorithm>
#include <cstdio>
#include <memory>
#include <new>
#include <string_view>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace lua_vm {
namespace {
constexpr const char* tag = "lua_vm";
constexpr TickType_t updates_per_second = 30;
constexpr TickType_t ticks_per_second = configTICK_RATE_HZ;
static_assert(ticks_per_second >= updates_per_second);

#if CONFIG_LUA_USE_PSRAM
struct LuaMemory {
    memory::Usage allocations;
    bool warnings_enabled = true;
    bool warning_continues = false;
};

int lua_panic(lua_State* state)
{
    const char* message = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : nullptr;
    std::fprintf(stderr, "PANIC: unprotected error in call to Lua API (%s)\n",
                 message ? message : "error object is not a string");
    return 0;
}

void lua_warning(void* context, const char* message, int to_continue)
{
    auto& memory = *static_cast<LuaMemory*>(context);
    if (!memory.warning_continues && !to_continue && message[0] == '@') {
        const std::string_view control(message);
        if (control == "@on") memory.warnings_enabled = true;
        if (control == "@off") memory.warnings_enabled = false;
        return;
    }
    if (memory.warnings_enabled) {
        if (!memory.warning_continues) std::fputs("Lua warning: ", stderr);
        std::fputs(message, stderr);
        if (!to_continue) std::fputc('\n', stderr);
        memory.warning_continues = to_continue != 0;
    }
}
#endif

struct Startup {
    ScriptKind kind;
    size_t script_size;
    std::unique_ptr<char[]> script;
    size_t count;
    std::unique_ptr<Module::Definition[]> definitions;
};

int load_boot_script(lua_State* state)
{
    luaL_openselectedlibs(state, LUA_GLIBK | LUA_LOADLIBK | LUA_IOLIBK | LUA_MATHLIBK | LUA_STRLIBK | LUA_TABLIBK, 0);

    const auto& startup = *static_cast<const Startup*>(lua_touserdata(state, 1));
    for (size_t i = 0; i < startup.count; ++i) {
        const auto& module = startup.definitions[i];
        lua_pushcfunction(state, module.push_table);
        lua_call(state, 0, 1);
        lua_setglobal(state, module.name);
    }

    const int status = startup.kind == ScriptKind::File
        ? luaL_loadfilex(state, startup.script.get(), "t")
        : luaL_loadbufferx(state, startup.script.get(), startup.script_size, "=startup", "t");
    if (status != LUA_OK) {
        return lua_error(state);
    }
    lua_call(state, 0, 0);

    lua_getglobal(state, "init");
    if (lua_isnil(state, -1)) {
        lua_pop(state, 1);
    } else {
        if (!lua_isfunction(state, -1)) {
            return luaL_error(state, "Startup script init must be a function");
        }
        lua_call(state, 0, 0);
    }

    lua_getglobal(state, "update");
    if (!lua_isnil(state, -1) && !lua_isfunction(state, -1)) {
        return luaL_error(state, "Startup script update must be a function");
    }
    return 1;
}

void run(lua_State* state, std::unique_ptr<Startup>& startup)
{
    lua_pushcfunction(state, load_boot_script);
    lua_pushlightuserdata(state, startup.get());
    const int status = lua_pcall(state, 1, 1, 0);
    startup.reset();
    if (status != LUA_OK) {
        const char* message = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : nullptr;
        ESP_LOGE(tag, "Boot failed: %s", message ? message : "(no error message)");
        return;
    }

    if (lua_isnil(state, 1)) {
        return;
    }

    ESP_LOGI(tag, "Running Lua update loop on core %d", static_cast<int>(xPortGetCoreID()));
    auto previous = esp_timer_get_time();
    auto wake = xTaskGetTickCount();
    TickType_t tick_remainder = 0;
    for (;;) {
        const auto now = esp_timer_get_time();
        const auto dt = static_cast<lua_Number>(now - previous) / 1000000;
        previous = now;

        lua_pushvalue(state, 1);
        lua_pushnumber(state, dt);
        if (lua_pcall(state, 1, 0, 0) != LUA_OK) {
            const char* message = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : nullptr;
            ESP_LOGE(tag, "Update failed: %s", message ? message : "(no error message)");
            return;
        }

        // Carry fractional ticks forward to maintain the average update cadence.
        tick_remainder += ticks_per_second;
        const auto frame_ticks = tick_remainder / updates_per_second;
        tick_remainder %= updates_per_second;
        if (xTaskDelayUntil(&wake, frame_ticks) == pdFALSE) {
            vTaskDelay(1);
            wake = xTaskGetTickCount();
            tick_remainder = 0;
        }
    }
}

void task(void* context)
{
    std::unique_ptr<Startup> startup(static_cast<Startup*>(context));

#if CONFIG_LUA_USE_PSRAM
    LuaMemory lua_memory;
    auto* state = lua_newstate(memory::allocate, &lua_memory.allocations, luaL_makeseed(nullptr));
#else
    auto* state = luaL_newstate();
#endif
    if (state) {
#if CONFIG_LUA_USE_PSRAM
        lua_atpanic(state, lua_panic);
        lua_setwarnf(state, lua_warning, &lua_memory);
#endif
        run(state, startup);
        lua_close(state);
    } else {
        ESP_LOGE(tag, "Could not allocate a Lua state");
    }
    startup.reset();
    vTaskDelete(nullptr);
}
}

bool start(ScriptKind kind, std::string_view script, std::initializer_list<Module> modules)
{
    if (kind == ScriptKind::File && (script.empty() || script.find('\0') != std::string_view::npos)) {
        return false;
    }
    std::unique_ptr<Startup> pending(new (std::nothrow) Startup{kind, script.size(), {}, modules.size(), {}});
    if (!pending) {
        return false;
    }
    pending->script.reset(new (std::nothrow) char[script.size() + 1]);
    if (!pending->script) {
        return false;
    }
    std::copy(script.begin(), script.end(), pending->script.get());
    pending->script[script.size()] = '\0';
    if (pending->count != 0) {
        pending->definitions.reset(new (std::nothrow) Module::Definition[pending->count]);
        if (!pending->definitions) {
            return false;
        }
        size_t i = 0;
        for (const auto& module : modules) {
            pending->definitions[i++] = module.definition_;
        }
    }
    auto* context = pending.release();
    if (xTaskCreatePinnedToCore(task, "lua_vm", 8192, context,
                                uxTaskPriorityGet(nullptr), nullptr, xPortGetCoreID()) != pdPASS) {
        delete context;
        return false;
    }
    return true;
}
}

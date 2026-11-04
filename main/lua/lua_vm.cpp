#include "module_definition.hpp"

#include <algorithm>
#include <memory>
#include <new>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace lua_vm {
namespace {
constexpr const char* tag = "lua_vm";
constexpr TickType_t updates_per_second = 60;
constexpr TickType_t ticks_per_second = configTICK_RATE_HZ;
static_assert(ticks_per_second >= updates_per_second);

struct Startup {
    ScriptKind kind;
    size_t script_size;
    std::unique_ptr<char[]> script;
    size_t count;
    std::unique_ptr<Module::Definition[]> definitions;
};

int load_boot_script(lua_State* state)
{
    luaL_openselectedlibs(state, LUA_GLIBK | LUA_LOADLIBK | LUA_MATHLIBK, 0);

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

    if (auto* state = luaL_newstate()) {
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

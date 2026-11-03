#include "module_definition.hpp"

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

extern const char boot_start[] asm("_binary_boot_lua_start");
extern const char boot_end[] asm("_binary_boot_lua_end");
}

namespace lua_vm {
namespace {
constexpr const char* tag = "lua_vm";
constexpr TickType_t updates_per_second = 60;
constexpr TickType_t ticks_per_second = configTICK_RATE_HZ;
static_assert(ticks_per_second >= updates_per_second);

struct PendingModules {
    size_t count;
    std::unique_ptr<Module::Definition[]> definitions;
};

int load_boot_script(lua_State* state)
{
    luaL_requiref(state, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_pop(state, 1);

    const auto& modules = *static_cast<const PendingModules*>(lua_touserdata(state, 1));
    for (size_t i = 0; i < modules.count; ++i) {
        const auto& module = modules.definitions[i];
        lua_pushcfunction(state, module.push_table);
        lua_call(state, 0, 1);
        lua_setglobal(state, module.name);
    }

    if (luaL_loadbufferx(state, boot_start, boot_end - boot_start, "@boot.lua", "t") != LUA_OK) {
        return lua_error(state);
    }
    lua_call(state, 0, 0);

    lua_getglobal(state, "init");
    if (lua_isnil(state, -1)) {
        lua_pop(state, 1);
    } else {
        if (!lua_isfunction(state, -1)) {
            return luaL_error(state, "boot.lua init must be a function");
        }
        lua_call(state, 0, 0);
    }

    lua_getglobal(state, "update");
    if (!lua_isnil(state, -1) && !lua_isfunction(state, -1)) {
        return luaL_error(state, "boot.lua update must be a function");
    }
    return 1;
}

void run(lua_State* state, std::unique_ptr<PendingModules>& modules)
{
    lua_pushcfunction(state, load_boot_script);
    lua_pushlightuserdata(state, modules.get());
    const int status = lua_pcall(state, 1, 1, 0);
    modules.reset();
    if (status != LUA_OK) {
        const char* message = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : nullptr;
        ESP_LOGE(tag, "Boot failed: %s", message ? message : "(no error message)");
        return;
    }

    if (lua_isnil(state, 1)) {
        return;
    }

    ESP_LOGI(tag, "Running boot.lua on core %d", static_cast<int>(xPortGetCoreID()));
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
    std::unique_ptr<PendingModules> modules(static_cast<PendingModules*>(context));

    if (auto* state = luaL_newstate()) {
        run(state, modules);
        lua_close(state);
    } else {
        ESP_LOGE(tag, "Could not allocate a Lua state");
    }
    modules.reset();
    vTaskDelete(nullptr);
}
}

bool start(std::initializer_list<Module> modules)
{
    auto* pending = new (std::nothrow) PendingModules{modules.size(), {}};
    if (!pending) {
        return false;
    }
    if (pending->count != 0) {
        pending->definitions.reset(new (std::nothrow) Module::Definition[pending->count]);
        if (!pending->definitions) {
            delete pending;
            return false;
        }
        size_t i = 0;
        for (const auto& module : modules) {
            pending->definitions[i++] = module.definition_;
        }
    }
    if (xTaskCreatePinnedToCore(task, "lua_vm", 8192, pending,
                                uxTaskPriorityGet(nullptr), nullptr, xPortGetCoreID()) != pdPASS) {
        delete pending;
        return false;
    }
    return true;
}
}

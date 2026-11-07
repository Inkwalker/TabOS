#include "M5Unified.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "audio/audio.hpp"
#include "gfx/gfx.hpp"
#include "input/input.hpp"
#include "lua/lua_vm.hpp"
#include "storage/fs_lua.hpp"
#include "storage/storage.hpp"
#include "system/system.hpp"

extern "C" void app_main()
{
    auto config = M5.config();
    config.internal_imu = true;
    config.internal_rtc = true;
    config.internal_mic = false;
    // Configure the Tab5 speaker pins and codec callback before audio::init().
    config.internal_spk = true;
    config.external_display_value = 0;
    M5.begin(config);
    M5.Display.setBrightness(128);

    if (!tabos::audio::init()) {
        ESP_LOGW("tabos", "Could not initialize audio");
    }

    tabos::storage::init();

    if (!tabos::system::init()) {
        ESP_LOGW("tabos", "Could not initialize keyboard LED custom mode");
    }

    if (!gfx::init()) {
        ESP_LOGE("tabos", "Could not initialize graphics");
        return;
    }

    const esp_vfs_fat_mount_config_t recovery_config = VFS_FAT_MOUNT_DEFAULT_CONFIG();
    const esp_err_t recovery_status =
        esp_vfs_fat_spiflash_mount_ro("/rec", "recovery", &recovery_config);
    if (recovery_status != ESP_OK) {
        ESP_LOGE("tabos", "Could not mount /rec: %s", esp_err_to_name(recovery_status));
        return;
    }

    if (!lua_vm::start(lua_vm::ScriptKind::File, "/rec/boot.lua",
                       {gfx::lua_module(), tabos::system::lua_module(), tabos::input::lua_module(),
                        tabos::fs::lua_module(), tabos::audio::lua_module()})) {
        ESP_LOGE("tabos", "Could not start the Lua VM task");
    }
}

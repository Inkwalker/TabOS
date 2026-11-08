idf_component_register(SRCS "main.cpp" "lua/lua_vm.cpp" "gfx/gfx.cpp" "gfx/gfx_lua.cpp"
                        "gfx/sprite.cpp"
                        "system/system_lua.cpp" "input/input_lua.cpp"
                        "storage/storage.cpp" "storage/fs_lua.cpp"
                        "audio/audio.cpp" "audio/audio_lua.cpp" "audio/sound.cpp"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES esp_hw_support esp_mm esp_lcd esp_timer esp_psram
                                  esp_driver_sdmmc fatfs m5unit_keyboard)

fatfs_create_rawflash_image(
    recovery
    "${CMAKE_CURRENT_LIST_DIR}/../recovery_files"
    FLASH_IN_PROJECT
)

set_source_files_properties(gfx/gfx.cpp PROPERTIES COMPILE_OPTIONS "-O3")

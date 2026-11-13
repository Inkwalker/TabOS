idf_component_register(SRCS "main.cpp" "lua/lua_vm.cpp" "gfx/gfx.cpp" "gfx/gfx_lua.cpp"
                        "gfx/sprite.cpp"
                        "system/system_lua.cpp" "input/input_lua.cpp"
                        "storage/storage.cpp" "storage/fs_lua.cpp" "storage/fs_table.cpp"
                        "audio/audio.cpp" "audio/audio_lua.cpp" "audio/sound.cpp"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES esp_hw_support esp_mm esp_lcd esp_timer esp_psram
                                  esp_driver_sdmmc fatfs m5unit_keyboard)

# esp_tinyusb 3.0.0 puts TinyUSB's weak MTP stubs and the real transport
# callbacks in one archive. Force archive extraction so the strong callbacks
# override the stubs; otherwise USB enumerates but MTP commands fail.
if(CONFIG_TINYUSB_MTP_ENABLED)
    idf_component_set_property(espressif__esp_tinyusb WHOLE_ARCHIVE TRUE)
endif()

fatfs_create_rawflash_image(
    recovery
    "${CMAKE_CURRENT_LIST_DIR}/../recovery_files"
    FLASH_IN_PROJECT
)

set_source_files_properties(gfx/gfx.cpp PROPERTIES COMPILE_OPTIONS "-O3")
set_source_files_properties(storage/fs_table.cpp PROPERTIES COMPILE_OPTIONS "-Os")

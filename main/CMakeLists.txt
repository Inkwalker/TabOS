idf_component_register(SRCS "main.cpp" "lua/lua_vm.cpp" "gfx/gfx.cpp" "gfx/gfx_lua.cpp"
                         "system/system_lua.cpp"
                    EMBED_FILES "lua/boot.lua"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES esp_hw_support esp_mm esp_lcd esp_timer esp_psram m5unit_keyboard)

set_source_files_properties(gfx/gfx.cpp PROPERTIES COMPILE_OPTIONS "-O3")

idf_component_register(SRCS "main.c" "gfx/gfx.cpp" "gfx/gfx_lua.cpp"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES esp_hw_support esp_mm esp_lcd)

set_source_files_properties(gfx/gfx.cpp PROPERTIES COMPILE_OPTIONS "-O3")

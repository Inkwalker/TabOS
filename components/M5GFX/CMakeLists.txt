# LGFX_PPA's upstream CMake requires the legacy component name "M5GFX".
# Forward it to our managed M5GFX, and expose the IDF headers LGFX_PPA uses.
idf_component_register(
    REQUIRES m5stack__m5gfx esp_driver_ppa esp_mm
)

idf_component_register(REQUIRES m5stack__M5UnitUnified)

# Upstream does not provide an ESP-IDF component for the keyboard library.
include(FetchContent)
FetchContent_Declare(m5unit_keyboard
    GIT_REPOSITORY https://github.com/m5stack/M5Unit-KEYBOARD.git
    GIT_TAG 003a83e98a5b0b0dbd975bc4e77e52f0d4e73973)
FetchContent_MakeAvailable(m5unit_keyboard)

file(GLOB_RECURSE keyboard_sources CONFIGURE_DEPENDS "${m5unit_keyboard_SOURCE_DIR}/src/*.cpp")
add_library(tabos_m5unit_keyboard STATIC ${keyboard_sources})
target_include_directories(tabos_m5unit_keyboard PUBLIC "${m5unit_keyboard_SOURCE_DIR}/src")
target_link_libraries(tabos_m5unit_keyboard PUBLIC idf::m5stack__M5UnitUnified)
target_link_libraries(${COMPONENT_LIB} INTERFACE tabos_m5unit_keyboard)

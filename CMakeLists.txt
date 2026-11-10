# The following five lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# LGFX_PPA selects dependencies during IDF's early requirement scan, before
# Kconfig values are available. Match sdkconfig.defaults for that scan too.
idf_build_set_property(CONFIG_LGFX_PPA_USE_GFX ON)
idf_build_set_property(CONFIG_LGFX_PPA_USE_LOVYANGFX OFF)
idf_build_set_property(CONFIG_LGFX_PPA_USE_M5GFX ON)
project(TabOS)

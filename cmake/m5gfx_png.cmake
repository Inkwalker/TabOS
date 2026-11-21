# Build a guarded copy of LGFXBase.cpp and keep the managed component intact.
idf_component_get_property(tabos_m5gfx_lib m5stack__m5gfx COMPONENT_LIB)
idf_component_get_property(tabos_m5gfx_dir m5stack__m5gfx COMPONENT_DIR)
set(tabos_m5gfx_original "${tabos_m5gfx_dir}/src/lgfx/v1/LGFXBase.cpp")
set(tabos_m5gfx_generated "${CMAKE_BINARY_DIR}/m5gfx_png/LGFXBase.cpp")
set(tabos_m5gfx_generator "${CMAKE_CURRENT_LIST_DIR}/../tools/prepare_m5gfx_png_source.py")
execute_process(COMMAND "${PYTHON}" "${tabos_m5gfx_generator}"
    "${tabos_m5gfx_original}" "${tabos_m5gfx_generated}"
    RESULT_VARIABLE tabos_m5gfx_generate_status)
if(NOT tabos_m5gfx_generate_status EQUAL 0)
    message(FATAL_ERROR "Could not prepare M5GFX PNG allocation guards")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${tabos_m5gfx_original}" "${tabos_m5gfx_generator}")

get_target_property(tabos_m5gfx_sources ${tabos_m5gfx_lib} SOURCES)
set(tabos_m5gfx_prepared_sources "")
set(tabos_m5gfx_replaced 0)
foreach(tabos_m5gfx_source IN LISTS tabos_m5gfx_sources)
    get_filename_component(tabos_m5gfx_absolute "${tabos_m5gfx_source}" ABSOLUTE
        BASE_DIR "${tabos_m5gfx_dir}")
    if(tabos_m5gfx_absolute STREQUAL tabos_m5gfx_original)
        list(APPEND tabos_m5gfx_prepared_sources "${tabos_m5gfx_generated}")
        math(EXPR tabos_m5gfx_replaced "${tabos_m5gfx_replaced} + 1")
    else()
        list(APPEND tabos_m5gfx_prepared_sources "${tabos_m5gfx_absolute}")
    endif()
endforeach()
if(NOT tabos_m5gfx_replaced EQUAL 1)
    message(FATAL_ERROR "Expected one LGFXBase.cpp in M5GFX, found ${tabos_m5gfx_replaced}")
endif()
set_property(TARGET ${tabos_m5gfx_lib} PROPERTY SOURCES "${tabos_m5gfx_prepared_sources}")
target_include_directories(${tabos_m5gfx_lib} PRIVATE "${tabos_m5gfx_dir}/src/lgfx/v1")

find_library(BSM_LIBRARY bsm REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
find_library(IOSURFACE_FRAMEWORK IOSurface REQUIRED)
find_path(XCB_INCLUDE_DIR xcb/xcb.h
    HINTS
        /opt/local/include
)
find_library(XCB_LIBRARY xcb
    HINTS
        /opt/local/lib
)

if(NOT XCB_INCLUDE_DIR OR NOT XCB_LIBRARY)
    message(FATAL_ERROR "libxcb was not found. Install xorg-libxcb first.")
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(CODESIGN_EXECUTABLE codesign REQUIRED)

add_library(FramebufferLib STATIC
    FramebufferLib/api.m
    FramebufferLib/iomfb.m
)

target_compile_options(FramebufferLib PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

target_include_directories(FramebufferLib PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/FramebufferLib"
)

target_link_libraries(FramebufferLib PUBLIC
    "${FOUNDATION_FRAMEWORK}"
    "${COREFOUNDATION_FRAMEWORK}"
    "${COREGRAPHICS_FRAMEWORK}"
    "${IMAGEIO_FRAMEWORK}"
    "${IOKIT_FRAMEWORK}"
    "${IOSURFACE_FRAMEWORK}"
)

add_library(LibRenderServer STATIC
    LibRenderServer/render_server.c
)

target_include_directories(LibRenderServer PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/LibRenderServer"
)

target_include_directories(LibRenderServer PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/FramebufferLib"
    "${XCB_INCLUDE_DIR}"
)

target_link_libraries(LibRenderServer PUBLIC
    FramebufferLib
    "${XCB_LIBRARY}"
)

set_target_properties(LibRenderServer PROPERTIES OUTPUT_NAME "RenderServer")

add_executable(loader-macos
    Loader/load.c
)

target_compile_options(loader-macos PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJC>:-fblocks>
)

target_link_libraries(loader-macos PRIVATE
    "${BSM_LIBRARY}"
    "${FOUNDATION_FRAMEWORK}"
)

set_target_properties(loader-macos PROPERTIES OUTPUT_NAME "loader-macos")

add_executable(MainUserspace
    MainUserspace/main.c
    MainUserspace/launch-wrangler.c
)

target_link_libraries(MainUserspace PRIVATE
    LibRenderServer
)

set_target_properties(MainUserspace PROPERTIES
    OUTPUT_NAME "MainUserspace"
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/OSEntitlements.plist"
)

add_custom_command(TARGET MainUserspace POST_BUILD
    COMMAND "${CODESIGN_EXECUTABLE}"
            --force
            --sign -
            --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/OSEntitlements.plist"
            "$<TARGET_FILE:MainUserspace>"
    VERBATIM
)

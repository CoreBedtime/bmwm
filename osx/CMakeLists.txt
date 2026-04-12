find_library(BSM_LIBRARY bsm REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
find_library(IOSURFACE_FRAMEWORK IOSurface REQUIRED)
find_library(SECURITY_FRAMEWORK Security REQUIRED)
find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_path(XCB_INCLUDE_DIR xcb/xcb.h
    HINTS
        /opt/local/include
)
find_library(XCB_LIBRARY xcb
    HINTS
        /opt/local/lib
)
find_library(XCB_COMPOSITE_LIBRARY xcb-composite HINTS /opt/local/lib REQUIRED)
find_library(XCB_DAMAGE_LIBRARY    xcb-damage    HINTS /opt/local/lib REQUIRED)
find_path(LUAJIT_INCLUDE_DIR luajit.h
    HINTS
        /opt/local/include
        /opt/local/include/luajit-2.1
)
find_library(LUAJIT_LIBRARY luajit-5.1
    HINTS
        /opt/local/lib
)
find_library(RESOLV_LIBRARY resolv REQUIRED)

find_library(CORESYMBOLICATION_FRAMEWORK CoreSymbolication HINTS /System/Library/PrivateFrameworks)

if(NOT XCB_INCLUDE_DIR OR NOT XCB_LIBRARY)
  message(FATAL_ERROR "libxcb was not found. Install xorg-libxcb first.")
endif()
if(NOT LUAJIT_INCLUDE_DIR OR NOT LUAJIT_LIBRARY)
  message(FATAL_ERROR "LuaJIT was not found. Install luajit first.")
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(CODESIGN_EXECUTABLE codesign REQUIRED)

include(FetchContent)
set(DOBBY_VERSION "latest" CACHE STRING "Dobby version to use")
set(DOBBY_REPOSITORY "https://github.com/jmpews/Dobby" CACHE STRING "Dobby repository URL")

FetchContent_Declare(
    dobby
    GIT_REPOSITORY ${DOBBY_REPOSITORY}
    GIT_TAG ${DOBBY_VERSION}
    GIT_SHALLOW TRUE
)

set(DOBBY_BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST OFF CACHE BOOL "" FORCE)
set(DOBBY_GENERATE_SHARED OFF CACHE BOOL "" FORCE)
set(Plugin.SymbolResolver ON CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(dobby)

set(DOBBY_LIBRARY "${dobby_BINARY_DIR}/libdobby.a")

add_library(ApplicatorConfig STATIC
    Config/lua_config.c
)

target_include_directories(ApplicatorConfig PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/Config"
    "${LUAJIT_INCLUDE_DIR}"
)

target_link_libraries(ApplicatorConfig PUBLIC
    "${LUAJIT_LIBRARY}"
)

add_executable(loader-macos
    Loader/load.c
    Loader/amfid_handler.m
    Loader/becomeheadless.m
)

target_compile_options(loader-macos PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJC>:-fblocks>
)

target_link_libraries(loader-macos PRIVATE
    "${BSM_LIBRARY}"
    "${FOUNDATION_FRAMEWORK}"
    "${APPKIT_FRAMEWORK}"
    "${CORESYMBOLICATION_FRAMEWORK}"
)

set_target_properties(loader-macos PROPERTIES OUTPUT_NAME "loader-macos")

find_library(SKYLIGHT_LIBRARY SkyLight HINTS "/System/Library/PrivateFrameworks" REQUIRED)

add_executable(SLXServer
    Headless/slx_server_wrapper.c
)

target_include_directories(SLXServer PRIVATE
    "${dobby_SOURCE_DIR}/include"
)

target_link_libraries(SLXServer PRIVATE
    "${SKYLIGHT_LIBRARY}"
    dobby_static
    "-lc++"
)

set_target_properties(SLXServer PROPERTIES
    OUTPUT_NAME "SLXServer"
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/OSEntitlements.plist"
)

add_custom_command(TARGET SLXServer POST_BUILD
    COMMAND "${CODESIGN_EXECUTABLE}"
            --force
            --sign -
            --entitlements "${CMAKE_SOURCE_DIR}/osx/OSEntitlements.plist"
            "$<TARGET_FILE:SLXServer>"
    VERBATIM
)

find_library(XCB_XTEST_LIBRARY xcb-xtest HINTS /opt/local/lib REQUIRED)
find_library(XCB_RENDER_LIBRARY xcb-render HINTS /opt/local/lib REQUIRED)
find_library(XCB_XFIXES_LIBRARY xcb-xfixes HINTS /opt/local/lib REQUIRED)
find_library(X11_LIBRARY X11 HINTS /opt/local/lib REQUIRED)
find_library(XCURSOR_LIBRARY Xcursor HINTS /opt/local/lib REQUIRED)

add_executable(ApplicationServer
    ApplicationServer/application_server.m
)

target_compile_options(ApplicationServer PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fno-objc-arc>
)

target_include_directories(ApplicationServer PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/ApplicationServer"
    "${XCB_INCLUDE_DIR}"
)

target_link_libraries(ApplicationServer PRIVATE
    ApplicatorConfig
    "${XCB_LIBRARY}"
    "${XCB_XTEST_LIBRARY}"
    "${XCB_RENDER_LIBRARY}"
    "${XCB_XFIXES_LIBRARY}"
    "${XCB_COMPOSITE_LIBRARY}"
    "${X11_LIBRARY}"
    "${XCURSOR_LIBRARY}"
    "${COREGRAPHICS_FRAMEWORK}"
    "${IMAGEIO_FRAMEWORK}"
    "${COREFOUNDATION_FRAMEWORK}"
    "${IOKIT_FRAMEWORK}"
    "${APPKIT_FRAMEWORK}"
)

add_library(AppLaunchRunner SHARED
    AppLaunch/AppLaunchRunner.m
)

target_compile_options(AppLaunchRunner PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

target_include_directories(AppLaunchRunner PRIVATE
)

target_link_libraries(AppLaunchRunner PRIVATE
    "${RESOLV_LIBRARY}"
    "${FOUNDATION_FRAMEWORK}"
    "${IOKIT_FRAMEWORK}"
    "${SECURITY_FRAMEWORK}"
    "${APPKIT_FRAMEWORK}"
)

set_target_properties(AppLaunchRunner PROPERTIES OUTPUT_NAME "AppLaunchRunner")

add_executable(AppLaunch
    AppLaunch/main.m
)

target_compile_options(AppLaunch PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

target_link_libraries(AppLaunch PRIVATE
    "${FOUNDATION_FRAMEWORK}"
    "-framework Security"
)

add_dependencies(AppLaunch AppLaunchRunner)

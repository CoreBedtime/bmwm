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

set(FRIDA_CORE_VERSION "17.9.1" CACHE STRING "Frida release tag to use for the frida-core devkit")
set(FRIDA_CORE_DEVKIT_ROOT "" CACHE PATH "Path to an unpacked frida-core devkit")
set(FRIDA_CORE_PLATFORM "" CACHE STRING "Override the Frida devkit platform suffix")
option(FRIDA_CORE_DOWNLOAD "Download the Frida core devkit from GitHub releases when FRIDA_CORE_DEVKIT_ROOT is not set" ON)

if(FRIDA_CORE_PLATFORM STREQUAL "")
  if(CMAKE_OSX_ARCHITECTURES)
    set(_FRIDA_CORE_ARCHITECTURE "${CMAKE_OSX_ARCHITECTURES}")
  else()
    set(_FRIDA_CORE_ARCHITECTURE "${CMAKE_SYSTEM_PROCESSOR}")
  endif()

  string(TOLOWER "${_FRIDA_CORE_ARCHITECTURE}" _FRIDA_CORE_ARCHITECTURE)
  if(_FRIDA_CORE_ARCHITECTURE MATCHES "arm64e")
    set(FRIDA_CORE_PLATFORM "macos-arm64e")
  elseif(_FRIDA_CORE_ARCHITECTURE MATCHES "arm64|aarch64")
    set(FRIDA_CORE_PLATFORM "macos-arm64")
  elseif(_FRIDA_CORE_ARCHITECTURE MATCHES "x86_64|amd64")
    set(FRIDA_CORE_PLATFORM "macos-x86_64")
  else()
    message(FATAL_ERROR "Unsupported Frida core architecture: ${_FRIDA_CORE_ARCHITECTURE}")
  endif()
endif()

if(FRIDA_CORE_DEVKIT_ROOT STREQUAL "")
  if(NOT FRIDA_CORE_DOWNLOAD)
    message(FATAL_ERROR "Set FRIDA_CORE_DEVKIT_ROOT or enable FRIDA_CORE_DOWNLOAD")
  endif()

  set(FRIDA_CORE_NEEDS_DOWNLOAD ON)
  set(FRIDA_CORE_DOWNLOAD_DIR "${CMAKE_BINARY_DIR}/_deps/frida-core")
  set(FRIDA_CORE_DOWNLOAD_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/frida-core-download.cmake")
  set(FRIDA_CORE_RELEASE_URL "https://github.com/frida/frida/releases/download/${FRIDA_CORE_VERSION}/frida-core-devkit-${FRIDA_CORE_VERSION}-${FRIDA_CORE_PLATFORM}.tar.xz")
  set(FRIDA_CORE_DEVKIT_ROOT "${FRIDA_CORE_DOWNLOAD_DIR}")
  set(FRIDA_CORE_ARCHIVE "${FRIDA_CORE_DOWNLOAD_DIR}/frida-core-devkit-${FRIDA_CORE_VERSION}-${FRIDA_CORE_PLATFORM}.tar.xz")
else()
  set(FRIDA_CORE_NEEDS_DOWNLOAD OFF)
endif()

set(FRIDA_CORE_LIBRARY "${FRIDA_CORE_DEVKIT_ROOT}/libfrida-core.a")
if(EXISTS "${FRIDA_CORE_DEVKIT_ROOT}/libfrida-core.dylib")
  set(FRIDA_CORE_LIBRARY "${FRIDA_CORE_DEVKIT_ROOT}/libfrida-core.dylib")
endif()

if(FRIDA_CORE_NEEDS_DOWNLOAD)
  configure_file(
        FridaCore/download_frida_core.cmake.in
        "${FRIDA_CORE_DOWNLOAD_SCRIPT}"
        @ONLY
    )

  add_custom_command(
        OUTPUT "${FRIDA_CORE_ARCHIVE}"
        COMMAND "${CMAKE_COMMAND}"
                -DFRIDA_CORE_RELEASE_URL=${FRIDA_CORE_RELEASE_URL}
                -DFRIDA_CORE_ARCHIVE=${FRIDA_CORE_ARCHIVE}
                -P "${FRIDA_CORE_DOWNLOAD_SCRIPT}"
        DEPENDS "${FRIDA_CORE_DOWNLOAD_SCRIPT}"
        VERBATIM
    )

  add_custom_command(
        OUTPUT "${FRIDA_CORE_LIBRARY}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${FRIDA_CORE_DOWNLOAD_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E tar xJf "${FRIDA_CORE_ARCHIVE}"
        WORKING_DIRECTORY "${FRIDA_CORE_DOWNLOAD_DIR}"
        DEPENDS "${FRIDA_CORE_ARCHIVE}"
        VERBATIM
    )

  add_custom_target(frida-core-devkit DEPENDS "${FRIDA_CORE_LIBRARY}")
endif()

add_library(FridaCoreDevkit UNKNOWN IMPORTED GLOBAL)
set_target_properties(FridaCoreDevkit PROPERTIES
    IMPORTED_LOCATION "${FRIDA_CORE_LIBRARY}"
)

if(TARGET frida-core-devkit)
  add_dependencies(FridaCoreDevkit frida-core-devkit)
endif()

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
    LibRenderServer/compositing.c
)

target_include_directories(LibRenderServer PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/LibRenderServer"
)

target_include_directories(LibRenderServer PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/FramebufferLib"
    "${XCB_INCLUDE_DIR}"
)

target_link_libraries(LibRenderServer PUBLIC
    ApplicatorConfig
    FramebufferLib
    "${XCB_LIBRARY}"
    "${XCB_COMPOSITE_LIBRARY}"
    "${XCB_DAMAGE_LIBRARY}"
)

set_target_properties(LibRenderServer PROPERTIES OUTPUT_NAME "RenderServer")

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

add_executable(MainUserspace
    MainUserspace/main.c
    MainUserspace/dog_satisfy.m
)

target_compile_options(MainUserspace PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJC>:-fblocks>
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

find_library(XCB_XTEST_LIBRARY xcb-xtest HINTS /opt/local/lib REQUIRED)
find_library(XCB_RENDER_LIBRARY xcb-render HINTS /opt/local/lib REQUIRED)
find_library(XCB_XFIXES_LIBRARY xcb-xfixes HINTS /opt/local/lib REQUIRED)
find_library(X11_LIBRARY X11 HINTS /opt/local/lib REQUIRED)
find_library(XCURSOR_LIBRARY Xcursor HINTS /opt/local/lib REQUIRED)

# bwm — standalone reparenting X11 window manager with HID input
# Connects to an existing $DISPLAY; no dependency on FramebufferLib / IOMFB.
add_executable(bwm
    WindowManager/main.c
    WindowManager/bwm_wm.c
    WindowManager/config.c
    WindowManager/client.c
    WindowManager/focus.c
    WindowManager/events.c
    WindowManager/input.c
)

target_include_directories(bwm PRIVATE
    "${XCB_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/WindowManager"
)

target_link_libraries(bwm PRIVATE
    ApplicatorConfig
    "${XCB_LIBRARY}"
    "${XCB_XTEST_LIBRARY}"
    "${XCB_RENDER_LIBRARY}"
    "${XCB_XFIXES_LIBRARY}"
    "${X11_LIBRARY}"
    "${XCURSOR_LIBRARY}"
    "${COREGRAPHICS_FRAMEWORK}"
    "${IMAGEIO_FRAMEWORK}"
    "${COREFOUNDATION_FRAMEWORK}"
    "${IOKIT_FRAMEWORK}"
)

set_target_properties(bwm PROPERTIES OUTPUT_NAME "bwm")

add_custom_command(TARGET bwm POST_BUILD
    COMMAND "${CODESIGN_EXECUTABLE}"
            --force
            --sign -
            --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/OSEntitlements.plist"
            "$<TARGET_FILE:bwm>"
    VERBATIM
)

add_library(AppLaunchRunner SHARED
    AppLaunch/AppLaunchRunner.m
)

find_program(FRIDA_COMPILE_EXECUTABLE
    NAMES frida-compile
    HINTS /Library/Frameworks/Python.framework/Versions/3.10/bin
)

if(NOT FRIDA_COMPILE_EXECUTABLE)
  message(FATAL_ERROR "frida-compile is required to bundle AppLaunchRunner")
endif()

set(APP_LAUNCH_SCRIPT_ENTRY "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/AppLaunchRunner.entry.js")
set(APP_LAUNCH_SCRIPT_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/AppLaunchRunner.script.js")
set(APP_LAUNCH_BUNDLED_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/AppLaunchRunner.bundle.js")

add_custom_command(
    OUTPUT "${APP_LAUNCH_BUNDLED_SCRIPT}"
    COMMAND "${FRIDA_COMPILE_EXECUTABLE}" "${APP_LAUNCH_SCRIPT_ENTRY}" -o "${APP_LAUNCH_BUNDLED_SCRIPT}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch"
    DEPENDS
        "${APP_LAUNCH_SCRIPT_ENTRY}"
        "${APP_LAUNCH_SCRIPT_SOURCE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/vendor/frida-objc-bridge/index.js"
        "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/vendor/frida-objc-bridge/lib/api.js"
        "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/vendor/frida-objc-bridge/lib/fastpaths.js"
        "${CMAKE_CURRENT_SOURCE_DIR}/AppLaunch/vendor/frida-objc-bridge/package.json"
    VERBATIM
)

add_custom_target(AppLaunchRunnerBundle DEPENDS "${APP_LAUNCH_BUNDLED_SCRIPT}")
add_dependencies(AppLaunchRunner AppLaunchRunnerBundle)

target_compile_options(AppLaunchRunner PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

target_link_options(AppLaunchRunner PRIVATE
    "-Wl,-sectcreate,__TEXT,__app_launch_js,${APP_LAUNCH_BUNDLED_SCRIPT}"
)

set_target_properties(AppLaunchRunner PROPERTIES
    LINK_DEPENDS "${APP_LAUNCH_BUNDLED_SCRIPT}"
)

target_include_directories(AppLaunchRunner PRIVATE
    "${FRIDA_CORE_DEVKIT_ROOT}/include"
    "${FRIDA_CORE_DEVKIT_ROOT}"
)

target_link_libraries(AppLaunchRunner PRIVATE
    FridaCoreDevkit
    "${RESOLV_LIBRARY}"
    "${FOUNDATION_FRAMEWORK}"
    "${IOKIT_FRAMEWORK}"
    "${SECURITY_FRAMEWORK}"
    "${APPKIT_FRAMEWORK}"
)

if(TARGET frida-core-devkit)
  add_dependencies(AppLaunchRunner frida-core-devkit)
endif()

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

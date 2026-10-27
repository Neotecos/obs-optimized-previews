cmake_minimum_required(VERSION 3.28...3.30)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/common/bootstrap.cmake" NO_POLICY_SCOPE)

project(${_name} VERSION ${_version} LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "${_name} solo es compatible con macOS")
endif()

option(ENABLE_FRONTEND_API "Use obs-frontend-api for UI functionality" ON)
option(ENABLE_QT "Use Qt functionality" ON)

if(NOT ENABLE_FRONTEND_API OR NOT ENABLE_QT)
  message(FATAL_ERROR "${_name} necesita obs-frontend-api y Qt (los docks son widgets Qt)")
endif()

include(compilerconfig)
include(defaults)
include(helpers)

add_library(${CMAKE_PROJECT_NAME} MODULE)

find_package(libobs REQUIRED)
find_package(obs-frontend-api REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Widgets)

target_link_libraries(
  ${CMAKE_PROJECT_NAME}
  PRIVATE
    OBS::libobs
    OBS::obs-frontend-api
    Qt6::Core
    Qt6::Widgets
    "$<LINK_LIBRARY:FRAMEWORK,AppKit.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,QuartzCore.framework>"
)

target_compile_options(
  ${CMAKE_PROJECT_NAME}
  PRIVATE $<$<C_COMPILER_ID:Clang,AppleClang>:-Wno-quoted-include-in-framework-header -Wno-comma>
)
# OpenGL está obsoleto en macOS, pero es el renderizador que usa OBS.
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE GL_SILENCE_DEPRECATION)
target_compile_features(${CMAKE_PROJECT_NAME} PRIVATE cxx_std_20)

set_target_properties(
  ${CMAKE_PROJECT_NAME}
  PROPERTIES AUTOMOC ON XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

target_sources(
  ${CMAKE_PROJECT_NAME}
  PRIVATE
    src/canvas-tracker.hpp
    src/canvas-tracker.mm
    src/gl-scaler.hpp
    src/gl-scaler.mm
    src/native-integration.hpp
    src/native-integration.mm
    src/plugin-main.mm
    src/preview-dock.hpp
    src/preview-dock.mm
    src/preview-coordinator.hpp
    src/preview-coordinator.mm
    src/preview-renderer.hpp
    src/preview-renderer.mm
    src/preview-shared.hpp
    src/settings-dialog.hpp
    src/settings-dialog.mm
)

set_target_properties_plugin(${CMAKE_PROJECT_NAME} PROPERTIES OUTPUT_NAME ${_name})

# Banco de pruebas del renderizador: libobs sin interfaz con el OpenGL de OBS.app.
option(OP_BUILD_TESTS "Compila op-render-test" ON)
set(OP_OBS_APP "/Applications/OBS.app" CACHE PATH "OBS.app cuyas bibliotecas usa op-render-test")
if(OP_BUILD_TESTS)
  add_executable(
    op-render-test
    tests/render-test.mm
    src/gl-scaler.mm
    src/preview-coordinator.mm
    src/preview-renderer.mm
  )
  target_include_directories(op-render-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(
    op-render-test
    PRIVATE
      OBS::libobs
      plugin-support
      "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,Foundation.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
  )
  target_compile_definitions(op-render-test PRIVATE GL_SILENCE_DEPRECATION)
  target_compile_features(op-render-test PRIVATE cxx_std_20)
  set_target_properties(
    op-render-test
    PROPERTIES
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
      # Sin hardened runtime para poder cargar las bibliotecas firmadas de OBS.app.
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${OP_OBS_APP}/Contents/Frameworks"
      BUILD_RPATH "${OP_OBS_APP}/Contents/Frameworks"
  )

  add_executable(
    op-dock-test
    tests/dock-test.mm
    src/gl-scaler.mm
    src/preview-coordinator.mm
    src/preview-dock.hpp
    src/preview-dock.mm
    src/preview-renderer.mm
  )
  target_include_directories(op-dock-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(
    op-dock-test
    PRIVATE
      OBS::libobs
      plugin-support
      Qt6::Core
      Qt6::Widgets
      "$<LINK_LIBRARY:FRAMEWORK,AppKit.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,QuartzCore.framework>"
  )
  target_compile_options(op-dock-test PRIVATE -Wno-quoted-include-in-framework-header -Wno-comma)
  target_compile_definitions(op-dock-test PRIVATE GL_SILENCE_DEPRECATION)
  target_compile_features(op-dock-test PRIVATE cxx_std_20)
  set_target_properties(
    op-dock-test
    PROPERTIES
      AUTOMOC ON
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${OP_OBS_APP}/Contents/Frameworks"
      BUILD_RPATH "${OP_OBS_APP}/Contents/Frameworks"
  )

  add_executable(
    op-integration-test
    tests/integration-test.mm
    src/native-integration.hpp
    src/native-integration.mm
    src/preview-dock.hpp
    src/preview-dock.mm
  )
  target_include_directories(op-integration-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(
    op-integration-test
    PRIVATE
      OBS::libobs
      OBS::obs-frontend-api
      plugin-support
      Qt6::Core
      Qt6::Widgets
      "$<LINK_LIBRARY:FRAMEWORK,AppKit.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,QuartzCore.framework>"
  )
  target_compile_options(op-integration-test PRIVATE -Wno-quoted-include-in-framework-header -Wno-comma)
  target_compile_features(op-integration-test PRIVATE cxx_std_20)
  set_target_properties(
    op-integration-test
    PROPERTIES
      AUTOMOC ON
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${OP_OBS_APP}/Contents/Frameworks"
      BUILD_RPATH "${OP_OBS_APP}/Contents/Frameworks"
  )

  add_executable(op-copy-probe tests/copy-probe.mm)
  target_link_libraries(
    op-copy-probe
    PRIVATE
      OBS::libobs
      "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,Foundation.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
  )
  target_compile_definitions(op-copy-probe PRIVATE GL_SILENCE_DEPRECATION)
  target_compile_features(op-copy-probe PRIVATE cxx_std_20)
  set_target_properties(
    op-copy-probe
    PROPERTIES
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${OP_OBS_APP}/Contents/Frameworks"
      BUILD_RPATH "${OP_OBS_APP}/Contents/Frameworks"
  )
endif()

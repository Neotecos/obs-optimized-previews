cmake_minimum_required(VERSION 3.28...3.30)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/common/bootstrap.cmake" NO_POLICY_SCOPE)

project(${_name} VERSION ${_version} LANGUAGES C CXX)

if(APPLE)
  enable_language(OBJC)
  enable_language(OBJCXX)
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
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Widgets Network)

# Qt 6.8's OpenGL wrapper still lists AGL, removed from recent Apple SDKs.
# Qt Widgets and this plugin use OpenGL.framework; no AGL API is used.
if(APPLE AND TARGET WrapOpenGL::WrapOpenGL)
  get_target_property(_op_gl_libraries WrapOpenGL::WrapOpenGL INTERFACE_LINK_LIBRARIES)
  list(FILTER _op_gl_libraries EXCLUDE REGEX "AGL")
  set_property(TARGET WrapOpenGL::WrapOpenGL PROPERTY INTERFACE_LINK_LIBRARIES "${_op_gl_libraries}")
endif()

if(DEFINED libobs_VERSION AND libobs_VERSION VERSION_LESS 31.1.0)
  message(FATAL_ERROR "OBS Studio 31.1.0 or newer is required (canvas API)")
endif()

target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE OBS::libobs OBS::obs-frontend-api Qt6::Core Qt6::Widgets Qt6::Network)
target_compile_features(${CMAKE_PROJECT_NAME} PRIVATE cxx_std_20)
set_target_properties(${CMAKE_PROJECT_NAME} PROPERTIES AUTOMOC ON)

target_sources(${CMAKE_PROJECT_NAME} PRIVATE
  src/canvas-tracker.cpp src/canvas-tracker.hpp
  src/native-integration.cpp src/native-integration.hpp
  src/plugin-main.cpp
  src/preview-dock.hpp src/preview-shared.hpp
  src/settings-dialog.cpp src/settings-dialog.hpp
  src/update-checker.cpp src/update-checker.hpp
  src/version-compare.cpp src/version-compare.hpp)

if(APPLE)
  target_sources(${CMAKE_PROJECT_NAME} PRIVATE
    src/gl-scaler.mm src/gl-scaler.hpp
    src/preview-coordinator.mm src/preview-coordinator.hpp
    src/preview-dock.mm src/preview-renderer.mm src/preview-renderer.hpp)
  target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE
    "$<LINK_LIBRARY:FRAMEWORK,AppKit.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,QuartzCore.framework>")
  target_compile_options(${CMAKE_PROJECT_NAME} PRIVATE -Wno-quoted-include-in-framework-header -Wno-comma)
  target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE GL_SILENCE_DEPRECATION)
  set_target_properties(${CMAKE_PROJECT_NAME} PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES)
else()
  target_sources(${CMAKE_PROJECT_NAME} PRIVATE src/portable/preview-coordinator.cpp src/portable/preview-coordinator.hpp
    src/portable/preview-dock.cpp)
  if(WIN32)
    target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE d3d11)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
  else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)
    target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE PkgConfig::EPOXY)
  endif()
endif()

set_target_properties_plugin(${CMAKE_PROJECT_NAME} PROPERTIES OUTPUT_NAME ${_name})

# La versión visible es la de buildspec.json (la que muestra «Manage plugins»,
# que lee manifest.json); la interna del bundle es el número de compilación.
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE PLUGIN_VISIBLE_VERSION_STRING="${PLUGIN_VERSION}")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/manifest.json.in" "${CMAKE_CURRENT_BINARY_DIR}/manifest.json" @ONLY)
target_add_resource(${CMAKE_PROJECT_NAME} "${CMAKE_CURRENT_BINARY_DIR}/manifest.json")

# Banco de pruebas del renderizador: libobs sin interfaz con el OpenGL de OBS.app.
option(OP_BUILD_TESTS "Build local macOS renderer tests" OFF)
set(OP_OBS_APP "/Applications/OBS.app" CACHE PATH "OBS.app cuyas bibliotecas usa op-render-test")
if(OP_BUILD_TESTS AND APPLE)
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
    src/native-integration.cpp
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

  add_executable(op-version-compare-test tests/version-compare-test.cpp src/version-compare.cpp)
  target_include_directories(op-version-compare-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(op-version-compare-test PRIVATE Qt6::Core)
  target_compile_features(op-version-compare-test PRIVATE cxx_std_20)
  set_target_properties(
    op-version-compare-test
    PROPERTIES
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      BUILD_RPATH "${OP_OBS_APP}/Contents/Frameworks"
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${OP_OBS_APP}/Contents/Frameworks"
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

include(packaging)

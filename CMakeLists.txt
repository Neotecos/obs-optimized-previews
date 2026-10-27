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
    src/plugin-main.mm
    src/preview-dock.hpp
    src/preview-dock.mm
    src/preview-renderer.hpp
    src/preview-renderer.mm
    src/preview-shared.hpp
)

set_target_properties_plugin(${CMAKE_PROJECT_NAME} PROPERTIES OUTPUT_NAME ${_name})

# Banco de pruebas del renderizador: libobs sin interfaz con el OpenGL de OBS.app.
option(NBP_BUILD_TESTS "Compila nbp-render-test" ON)
set(NBP_OBS_APP "/Applications/OBS.app" CACHE PATH "OBS.app cuyas bibliotecas usa nbp-render-test")
if(NBP_BUILD_TESTS)
  add_executable(nbp-render-test tests/render-test.mm src/preview-renderer.mm)
  target_include_directories(nbp-render-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(
    nbp-render-test
    PRIVATE
      OBS::libobs
      plugin-support
      "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,Foundation.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,OpenGL.framework>"
  )
  target_compile_definitions(nbp-render-test PRIVATE GL_SILENCE_DEPRECATION NBP_RENDERER_TIMING)
  target_compile_features(nbp-render-test PRIVATE cxx_std_20)
  set_target_properties(
    nbp-render-test
    PROPERTIES
      XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
      # Sin hardened runtime para poder cargar las bibliotecas firmadas de OBS.app.
      XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
      XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "${NBP_OBS_APP}/Contents/Frameworks"
      BUILD_RPATH "${NBP_OBS_APP}/Contents/Frameworks"
  )
endif()

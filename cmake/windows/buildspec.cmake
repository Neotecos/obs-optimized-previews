# CMake Windows build dependencies module

include_guard(GLOBAL)

include(buildspec_common)

# _check_dependencies_windows: Set up Windows slice for _check_dependencies
function(_check_dependencies_windows)
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/buildspec.json" buildspec)
  string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" arch)
  set(platform windows-${arch})

  string(JSON sdk_version GET ${buildspec} dependencies obs-studio version)
  set(dependencies_dir "${CMAKE_CURRENT_SOURCE_DIR}/.deps/sdk-${sdk_version}-${CMAKE_SYSTEM_PROCESSOR}-${CMAKE_OSX_ARCHITECTURES}${CMAKE_VS_PLATFORM_NAME}")
  string(REPLACE ";" "_" dependencies_dir "${dependencies_dir}")
  set(prebuilt_filename "windows-deps-VERSION-ARCH-REVISION.zip")
  set(prebuilt_destination "obs-deps-VERSION-ARCH")
  set(qt6_filename "windows-deps-qt6-VERSION-ARCH-REVISION.zip")
  set(qt6_destination "obs-deps-qt6-VERSION-ARCH")
  set(obs-studio_filename "VERSION.zip")
  set(obs-studio_destination "obs-studio-VERSION")
  set(dependencies_list prebuilt qt6 obs-studio)

  _check_dependencies()

  # OBS's ARM64 Qt package is cross-compiled and uses matching x64 host
  # tools, including on native Windows ARM runners (x64 emulation).
  if(arch STREQUAL arm64 AND NOT QT_HOST_PATH)
    string(JSON qt_version GET ${buildspec} dependencies qt6 version)
    string(JSON qt_url GET ${buildspec} dependencies qt6 baseUrl)
    string(JSON qt_hash GET ${buildspec} dependencies qt6 hashes windows-x64)
    set(qt_archive "${dependencies_dir}/windows-deps-qt6-${qt_version}-x64.zip")
    set(qt_host "${dependencies_dir}/obs-deps-qt6-${qt_version}-x64")
    if(EXISTS "${qt_archive}")
      file(SHA256 "${qt_archive}" cached_qt_hash)
      if(NOT cached_qt_hash STREQUAL qt_hash)
        file(REMOVE "${qt_archive}")
        file(REMOVE_RECURSE "${qt_host}")
      endif()
    endif()
    if(NOT EXISTS "${qt_archive}")
      file(DOWNLOAD "${qt_url}/${qt_version}/windows-deps-qt6-${qt_version}-x64.zip"
        "${qt_archive}" EXPECTED_HASH SHA256=${qt_hash} STATUS qt_download)
      list(GET qt_download 0 qt_error)
      if(qt_error)
        file(REMOVE "${qt_archive}")
        message(FATAL_ERROR "Could not download matching Qt x64 host tools: ${qt_download}")
      endif()
    endif()
    if(NOT EXISTS "${qt_host}/lib/cmake/Qt6CoreTools/Qt6CoreToolsConfig.cmake")
      file(ARCHIVE_EXTRACT INPUT "${qt_archive}" DESTINATION "${qt_host}")
    endif()
    set(QT_HOST_PATH "${qt_host}" CACHE PATH "Matching Qt host tools for Windows ARM64")
  endif()
endfunction()

_check_dependencies_windows()

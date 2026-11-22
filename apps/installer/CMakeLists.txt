# WiiCompiled Installer: the app players download (signed with a Developer ID and notarized by
# tools/release.sh). It builds the game from their disc at a GitHub release tag and installs it on
# their Apple TVs, through tools/tvos/port; Sparkle updates the installer itself. A project of its
# own (the game's runtime/ is cross-compiled for tvOS by the engine), configured with the presets in
# CMakePresets.json: installer-xcode builds the app (the Xcode generator only: it embeds
# Sparkle.framework), installer-ninja its logic tests.

cmake_minimum_required(VERSION 3.25)

# The version: tools/release.sh passes the release (with any -rc suffix); local builds read port.json.
file(READ "${CMAKE_CURRENT_LIST_DIR}/../../port.json" _port_json)
string(JSON _port_version GET "${_port_json}" version)
set(WIICOMPILED_VERSION "${_port_version}" CACHE STRING "Release version, with any -rc suffix")
set(WIICOMPILED_COMMIT "" CACHE STRING "Commit the installer was built from")
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" _numeric "${WIICOMPILED_VERSION}")
if(NOT _numeric)
    message(FATAL_ERROR "WIICOMPILED_VERSION ${WIICOMPILED_VERSION} is not major.minor.patch")
endif()
# Before project(), which would otherwise leave it empty (and Info.plist's LSMinimumSystemVersion too).
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "Oldest macOS the installer runs on")
project(WiiCompiledInstaller VERSION ${_numeric} LANGUAGES Swift)
math(EXPR WIICOMPILED_BUILD_NUMBER
     "${PROJECT_VERSION_MAJOR} * 10000 + ${PROJECT_VERSION_MINOR} * 100 + ${PROJECT_VERSION_PATCH}")

# The logic without the UI, tested with any generator.
set(WIICOMPILED_INSTALLER_LOGIC_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/PortEvent.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Releases.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/SemVer.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Workspace.swift")
add_subdirectory(../../tests/installertest "${CMAKE_CURRENT_BINARY_DIR}/installertest")
if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
    return()
endif()

include(FetchContent)

# Sparkle, pinned: the release tarball's SHA-256 is GitHub's digest for it.
FetchContent_Declare(sparkle
    URL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
    URL_HASH SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR no-cmake)
FetchContent_MakeAvailable(sparkle)
set(WIICOMPILED_SPARKLE_DIR "${sparkle_SOURCE_DIR}" CACHE INTERNAL "Sparkle's framework and tools (bin/)")

set(WIICOMPILED_INSTALLER_BUNDLE_ID "com.vanillacoffeesoft.WiiCompiledInstaller"
    CACHE STRING "Bundle identifier for WiiCompiled Installer")
# Ad hoc for local builds; tools/release.sh signs with "Developer ID Application".
set(WIICOMPILED_INSTALLER_SIGN_IDENTITY "-" CACHE STRING "Code signing identity for WiiCompiled Installer")
set(WIICOMPILED_DEVELOPMENT_TEAM "" CACHE STRING "Team of the signing identity (tools/release.sh sets it)")
# Sparkle's public EdDSA key (generate_keys prints it). Empty in local builds, which then never
# offer to update themselves.
set(WIICOMPILED_SPARKLE_PUBLIC_KEY "" CACHE STRING "Sparkle's public EdDSA key for the installer's updates")

set(_sources
    Sources/AppModel.swift
    Sources/Doctor.swift
    Sources/InstallerApp.swift
    Sources/PortEvent.swift
    Sources/Releases.swift
    Sources/SemVer.swift
    Sources/Shell.swift
    Sources/Source.swift
    Sources/Views.swift
    Sources/Workspace.swift)
add_executable(WiiCompiledInstaller MACOSX_BUNDLE ${_sources} AppIcon.icns)
set_source_files_properties(AppIcon.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

set_target_properties(WiiCompiledInstaller PROPERTIES
    OUTPUT_NAME "WiiCompiled Installer"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${WIICOMPILED_INSTALLER_BUNDLE_ID}"
    MACOSX_BUNDLE_BUNDLE_NAME "WiiCompiled Installer"
    MACOSX_BUNDLE_BUNDLE_VERSION "${WIICOMPILED_BUILD_NUMBER}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_ICON_FILE AppIcon
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${WIICOMPILED_INSTALLER_BUNDLE_ID}"
    XCODE_ATTRIBUTE_SWIFT_VERSION 5.0
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE Manual
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "${WIICOMPILED_INSTALLER_SIGN_IDENTITY}"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${WIICOMPILED_DEVELOPMENT_TEAM}"
    XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME YES
    XCODE_ATTRIBUTE_OTHER_CODE_SIGN_FLAGS "--timestamp"
    XCODE_ATTRIBUTE_FRAMEWORK_SEARCH_PATHS "${sparkle_SOURCE_DIR}"
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/../Frameworks"
    XCODE_EMBED_FRAMEWORKS "${sparkle_SOURCE_DIR}/Sparkle.framework"
    XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY YES
    XCODE_EMBED_FRAMEWORKS_REMOVE_HEADERS_ON_COPY YES
    XCODE_GENERATE_SCHEME ON)
if(WIICOMPILED_INSTALLER_SIGN_IDENTITY STREQUAL "-")
    # No timestamp server for ad hoc signatures.
    set_target_properties(WiiCompiledInstaller PROPERTIES XCODE_ATTRIBUTE_OTHER_CODE_SIGN_FLAGS "")
endif()

target_link_libraries(WiiCompiledInstaller PRIVATE
    "${sparkle_SOURCE_DIR}/Sparkle.framework"
    "-framework AppKit"
    "-framework SwiftUI")

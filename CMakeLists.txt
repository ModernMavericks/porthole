cmake_minimum_required(VERSION 3.16)

# Porthole -- the app-agnostic viewer-generator ENGINE, built as its own top-level product:
# `cmake -S . -B build` produces Porthole.app with no product repo and no container. Per-app
# name/icon are resolved at RUNTIME by `porthole materialize`, never baked here. Product repos
# historically add_subdirectory(<porthole>/viewer) directly; this root is what porthole's OWN
# build + CI use.

# 10.9 target/arch, set before project() so they reach the viewer sub-build.
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "x86_64" CACHE STRING "Target architectures")

# Porthole is its own upstream, versioned by DATE: a release is <YYYYMMDD>.N (N per day). release.yml
# stamps VERSION (a gitignored build product) with it. A dev build with no VERSION falls back to the
# committed UPSTREAM_VERSION (the bare date), then 0.0.0 -- so the standalone build stays hermetic.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" PORTHOLE_VERSION LIMIT_COUNT 1)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/UPSTREAM_VERSION")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/UPSTREAM_VERSION" PORTHOLE_VERSION LIMIT_COUNT 1)
else()
  set(PORTHOLE_VERSION "0.0.0")
endif()
project(porthole VERSION ${PORTHOLE_VERSION} LANGUAGES OBJC)

# Porthole's OWN identity (not a per-app viewer). The viewer sub-build defaults these to
# 1Password for the legacy product-include path; setting them here first makes these win.
set(PORTHOLE_APP_NAME "Porthole" CACHE STRING "Display name for the engine app")
set(PORTHOLE_APP_SLUG "porthole" CACHE STRING "App identity slug")

# Porthole ships a GENERIC icon for now -- a deliberate, explicit decision (the forced-icon
# doctrine forbids a silent default). A materialized "Linux <App>.app" gets its icon at
# runtime, so no per-app icon is baked. TODO: replace with a real Porthole.icns brand asset
# (its own follow-up; tracked in the Porthole-as-product spec).
set(MAVERICKS_ALLOW_GENERIC_ICON ON)

# Shared mavericks-* build conventions (github.com/ModernMavericks/shared-cmake): installed
# once via `cmake --install` (self-registers in the user package registry), or the @v1 action
# in CI. Found with no CMAKE_PREFIX_PATH.
find_package(MavericksSharedCMake REQUIRED)
set(MAVERICKS_REQUIRE_LANGS OBJC)
include(Mavericks)

enable_testing()
find_program(BATS_EXECUTABLE bats)

# The native Cocoa Xpra viewer (app bundle, headless probe, codec + unit ctests).
add_subdirectory(viewer)

# Engine BATS suites: the generator, the recovery watcher, the example launchers, and the
# standalone-build guard. Registered per-suite so ctest reports them individually.
if(BATS_EXECUTABLE)
  file(GLOB _ebats "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.bats")
  foreach(_b IN LISTS _ebats)
    get_filename_component(_leaf "${_b}" NAME)
    if(_leaf MATCHES "^\\._")   # skip AppleDouble sidecars on the HGFS share
      continue()
    endif()
    get_filename_component(_name "${_b}" NAME_WE)
    add_test(NAME ${_name} COMMAND ${BATS_EXECUTABLE} "${_b}")
    set_tests_properties(${_name} PROPERTIES WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
  endforeach()
else()
  message(STATUS "bats not found -- BATS suites won't run via ctest (install bats to enable)")
endif()

# --- Sparkle auto-update helper (release-time) --------------------------------------------
# Gated OFF so the default build stays hermetic: building the updater fetches the Sparkle
# framework over the network. The release workflow configures with -DPORTHOLE_BUILD_UPDATER=ON,
# then stages + signs + appcasts it (shared-cmake scripts/stage_updater.sh + sign_and_appcast.sh
# -- CI shell steps, EdDSA-secret-gated). Single native x86_64/10.9 variant (this whole project
# targets 10.9); the Sparkle slice is auto-derived from CMAKE_OSX_ARCHITECTURES.
option(PORTHOLE_BUILD_UPDATER "Build the Sparkle auto-update helper app (fetches Sparkle; release-time)" OFF)
if(PORTHOLE_BUILD_UPDATER)
  include(MavericksSparkle)
  mavericks_add_updater_app(
    NAME PortholeUpdater
    PRODUCT_NAME "Porthole"
    BUNDLE_ID dev.modernmavericks.PortholeUpdater
    FEED_URL "https://github.com/ModernMavericks/porthole/releases/download/feed-porthole/appcast.xml"
    ICON "${CMAKE_CURRENT_SOURCE_DIR}/packaging/macos/Porthole.icns"
    VERSION "${PROJECT_VERSION}"
    LOG_PREFIX "PortholeUpdater"
    CONFIRM_TITLE "Porthole updated"
    CONFIRM_BODY "Porthole was updated. Relaunch your Linux apps to use the new viewer engine."
    RELAUNCH_MARKER "/tmp/.porthole-updater-relaunched"
    # no PANE_HINT_KEY -> a background-found update posts an NSUserNotification.
  )
endif()

# Cross-build the skarnet viewer transport (skalibs -> s6, static, no execline) as x86_64/10.9
# binaries staged in the build tree; build_pkg.sh installs them into the engine. Kept out of the
# default build so `cmake --build` stays fast/hermetic; the pkg target depends on it.
set(PORTHOLE_TRANSPORT_DIR "${CMAKE_BINARY_DIR}/engine-bin")
set(PORTHOLE_TRANSPORT_STAMP "${PORTHOLE_TRANSPORT_DIR}/s6-ipcserver")
add_custom_command(
  OUTPUT "${PORTHOLE_TRANSPORT_STAMP}"
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/build/fetch-s6.sh" "${PORTHOLE_TRANSPORT_DIR}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/SKALIBS_REF" "${CMAKE_CURRENT_SOURCE_DIR}/SKALIBS_SHA512"
          "${CMAKE_CURRENT_SOURCE_DIR}/S6_REF"       "${CMAKE_CURRENT_SOURCE_DIR}/S6_SHA512"
          "${CMAKE_CURRENT_SOURCE_DIR}/build/fetch-s6.sh"
  COMMENT "Cross-building s6-ipcserver transport (x86_64/10.9)")
add_custom_target(transport DEPENDS "${PORTHOLE_TRANSPORT_STAMP}")

# `cmake --build . --target pkg` builds the Porthole installer from the freshly built
# Porthole.app (the shared viewer engine), with the engine CLI + templates staged inside it.
add_custom_target(pkg
  COMMAND ${CMAKE_COMMAND} -E env "PORTHOLE_TRANSPORT_DIR=${PORTHOLE_TRANSPORT_DIR}"
             sh "${CMAKE_CURRENT_SOURCE_DIR}/packaging/macos/build_pkg.sh"
             "${PROJECT_VERSION}" "porthole-${PROJECT_VERSION}.pkg"
             "$<TARGET_BUNDLE_DIR:Porthole>"
  DEPENDS Porthole transport
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  USES_TERMINAL
  COMMENT "Building porthole-${PROJECT_VERSION}.pkg")

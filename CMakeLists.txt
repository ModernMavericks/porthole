cmake_minimum_required(VERSION 3.16)

# Porthole -- the app-agnostic viewer-generator ENGINE, built as its own top-level product:
# `cmake -S . -B build` produces Porthole.app with no product repo and no container. Per-app
# name/icon are resolved at RUNTIME by `porthole materialize`, never baked here. Product repos
# historically add_subdirectory(<porthole>/viewer) directly; this root is what porthole's OWN
# build + CI use.

# 10.9 target/arch, set before project() so they reach the viewer sub-build.
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "x86_64" CACHE STRING "Target architectures")

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" PORTHOLE_VERSION LIMIT_COUNT 1)
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

# `cmake --build . --target pkg` builds the Porthole installer from the freshly built
# Porthole.app (the shared viewer engine), with the engine CLI + templates staged inside it.
add_custom_target(pkg
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/packaging/macos/build_pkg.sh"
             "${PROJECT_VERSION}" "porthole-${PROJECT_VERSION}.pkg"
             "$<TARGET_BUNDLE_DIR:Porthole>"
  DEPENDS Porthole
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  USES_TERMINAL
  COMMENT "Building porthole-${PROJECT_VERSION}.pkg")

# Porthole -- native Cocoa Xpra viewer. A component of the top-level
# mavericks-1password project (which owns project(), the mavericks-shared-cmake
# setup, and enable_testing()). Configure/build from the repo root.

find_library(COCOA_LIBRARY Cocoa REQUIRED)
find_library(FOUNDATION_LIBRARY Foundation REQUIRED)
# Carbon: RegisterEventHotKey for the global Quick Access hotkey (Cmd-Shift-Space).
find_library(CARBON_LIBRARY Carbon REQUIRED)
# AudioToolbox: decode + play forwarded app audio (AudioFileStream + AudioQueue).
find_library(AUDIOTOOLBOX_LIBRARY AudioToolbox REQUIRED)
# QuartzCore + IOSurface: the GPU-composited pixel path (CALayer + IOSurface backing).
find_library(QUARTZCORE_LIBRARY QuartzCore REQUIRED)
find_library(IOSURFACE_LIBRARY IOSurface REQUIRED)

# Xpra backend + protocol core, shared by the app, the headless probe, and any
# tool that speaks the remote_display interface.
set(RDS_XPRA_SOURCES
  src/PortholeProtocol.m
  src/PortholeTransport.m
  src/PortholeClient.m)

# --- app identity ---
# This repo is a Mac-like app-specific-viewer GENERATOR: the Porthole engine is
# app-agnostic and the name/icon are per-app parameters, defaulting to 1Password
# (this repo's reference instance).
set(PORTHOLE_APP_NAME "1Password" CACHE STRING "Display name for the generated viewer app")
set(PORTHOLE_APP_SLUG "1password" CACHE STRING "App identity slug: bundle-id suffix + per-app behavior key (never the display name)")

# App icon: a FORCED explicit decision, wired below via shared-cmake's
# mavericks_require_icon (after the target exists). There is NO engine default -- a
# product DECLARES its icon source (container + glob; the PNG is pulled from the running
# container at configure time and never committed), or opts into a generic icon
# (-DMAVERICKS_ALLOW_GENERIC_ICON=ON). No silent 1Password / iconless fallback: an
# undeclared or unresolved icon is a hard FATAL_ERROR.
set(_porthole_icns "${CMAKE_CURRENT_BINARY_DIR}/AppIcon.icns")
set(PORTHOLE_ICON_CONTAINER "" CACHE STRING "Container to extract the app icon from (per-app; required unless generic)")
set(PORTHOLE_ICON_GLOB "" CACHE STRING "Glob (in the container) for the app icon PNG (per-app)")
if(PORTHOLE_ICON_CONTAINER AND PORTHOLE_ICON_GLOB)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
            "ONEP_CONTAINER=${PORTHOLE_ICON_CONTAINER}"
            "PORTHOLE_ICON_GLOB=${PORTHOLE_ICON_GLOB}"
            sh "${CMAKE_CURRENT_SOURCE_DIR}/cmake/extract-app-icns.sh" "${_porthole_icns}"
    RESULT_VARIABLE _porthole_icon_rc OUTPUT_QUIET ERROR_QUIET)
endif()

# --- app bundle (the native Cocoa shell) ---
add_executable(Porthole MACOSX_BUNDLE
  src/main.m
  src/PortholeWindow.m
  src/PortholeAudioPlayer.m
  src/PortholeBlit.m
  src/PortholeLayerPresenter.m
  src/PortholeBgSample.m
  src/PortholeMenuModel.m
  src/PortholeStaticMenuProducer.m
  src/PortholeRemoteMenuProducer.m
  src/PortholeMenuController.m
  src/PortholeMenuGlyph.m
  ${RDS_XPRA_SOURCES})
target_include_directories(Porthole PRIVATE src)
target_link_libraries(Porthole PRIVATE ${COCOA_LIBRARY} ${CARBON_LIBRARY} ${AUDIOTOOLBOX_LIBRARY}
  ${QUARTZCORE_LIBRARY} ${IOSURFACE_LIBRARY})
# Per-app menu manifest (apps/<slug>.menu.json) -> Resources/menu.json; Porthole reads it at
# launch and inserts the app's menus. Absent = the default App/Edit/Window only.
set(PORTHOLE_MENU_JSON "" CACHE FILEPATH "Per-app menu manifest bundled as Resources/menu.json")
if(PORTHOLE_MENU_JSON AND EXISTS "${PORTHOLE_MENU_JSON}")
  configure_file("${PORTHOLE_MENU_JSON}" "${CMAKE_CURRENT_BINARY_DIR}/menu.json" COPYONLY)
  target_sources(Porthole PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/menu.json")
  set_source_files_properties("${CMAKE_CURRENT_BINARY_DIR}/menu.json"
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
  message(STATUS "Porthole: bundling menu manifest ${PORTHOLE_MENU_JSON}")
endif()
# Per-app bundle id so two viewers (1Password, Signal, ...) are DISTINCT apps to
# LaunchServices -- otherwise single-instance would treat them as one and reactivate
# the wrong viewer.
set_target_properties(Porthole PROPERTIES
  OUTPUT_NAME Porthole
  MACOSX_BUNDLE_BUNDLE_NAME "${PORTHOLE_APP_NAME}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "dev.modernmavericks.porthole.${PORTHOLE_APP_SLUG}"
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in)

# Forced icon decision (shared-cmake mavericks_require_icon). It wires the extracted
# icns into the bundle (MACOSX_BUNDLE_ICON_FILE), or FATAL_ERRORs when the decision is
# missing/unresolved -- never a silent default. A declared-but-unresolved icon (the
# container was down at configure) is fatal too, unless generic is opted into.
if(PORTHOLE_ICON_CONTAINER AND PORTHOLE_ICON_GLOB)
  if(EXISTS "${_porthole_icns}")
    mavericks_require_icon(TARGET Porthole ICNS "${_porthole_icns}")
  elseif(MAVERICKS_ALLOW_GENERIC_ICON)
    mavericks_require_icon(TARGET Porthole ALLOW_GENERIC)
  else()
    message(FATAL_ERROR "Porthole: an icon source is declared (${PORTHOLE_ICON_CONTAINER}:${PORTHOLE_ICON_GLOB}) but extraction produced no icon -- is the container running? Start it and re-configure, or set -DMAVERICKS_ALLOW_GENERIC_ICON=ON to ship a generic icon on purpose.")
  endif()
else()
  mavericks_require_icon(TARGET Porthole)   # no icon source declared -> generic-or-FATAL
endif()

# Prove the shipped binary stays 10.9-safe (x86_64, min-10.9, no post-10.9 imports).
mavericks_assert_binary_compatible(Porthole)

# --- headless protocol probe (drives the remote_display C API, no window server) ---
add_executable(porthole-probe tools/probe.m ${RDS_XPRA_SOURCES})
target_include_directories(porthole-probe PRIVATE src)
target_link_libraries(porthole-probe PRIVATE ${COCOA_LIBRARY})

# --- IOSurface render-confirm tool (manual; needs the screen awake) ---
add_executable(iosurface-probe tools/iosurface-probe.m)
target_link_libraries(iosurface-probe PRIVATE ${COCOA_LIBRARY} ${QUARTZCORE_LIBRARY} ${IOSURFACE_LIBRARY})

# --- off-device codec test (registers with the top-level ctest) ---
add_executable(test_protocol tests/test_protocol.m src/PortholeProtocol.m)
target_include_directories(test_protocol PRIVATE src)
target_link_libraries(test_protocol PRIVATE ${FOUNDATION_LIBRARY})
add_test(NAME protocol COMMAND test_protocol)

# --- menu model unit test ---
add_executable(test_menu_model tests/test_menu_model.m
  src/PortholeMenuModel.m src/PortholeStaticMenuProducer.m)
target_include_directories(test_menu_model PRIVATE src)
target_link_libraries(test_menu_model PRIVATE ${FOUNDATION_LIBRARY})
add_test(NAME menu_model COMMAND test_menu_model)

# --- menu controller unit test (Cocoa: builds NSMenus, no run loop) ---
add_executable(test_menu_controller tests/test_menu_controller.m
  src/PortholeMenuController.m src/PortholeMenuModel.m)
target_include_directories(test_menu_controller PRIVATE src)
target_link_libraries(test_menu_controller PRIVATE ${COCOA_LIBRARY})
add_test(NAME menu_controller COMMAND test_menu_controller)

# --- menu wire unit test (socketpair; no container) ---
add_executable(test_menu_wire tests/test_menu_wire.m
  src/PortholeRemoteMenuProducer.m src/PortholeMenuModel.m)
target_include_directories(test_menu_wire PRIVATE src)
target_link_libraries(test_menu_wire PRIVATE ${COCOA_LIBRARY})
add_test(NAME menu_wire COMMAND test_menu_wire)

# --- transport disconnect unit test (AF_UNIX listener; no container) ---
add_executable(test_transport_disconnect tests/test_transport_disconnect.m
  src/PortholeTransport.m src/PortholeProtocol.m)
target_include_directories(test_transport_disconnect PRIVATE src)
target_link_libraries(test_transport_disconnect PRIVATE ${COCOA_LIBRARY})
add_test(NAME transport_disconnect COMMAND test_transport_disconnect)

# --- IOSurface patch-writer unit test (plain C, compiled as ObjC; no WindowServer) ---
add_executable(test_iosurface_blit tests/test_iosurface_blit.m src/PortholeBlit.m)
target_include_directories(test_iosurface_blit PRIVATE src)
add_test(NAME iosurface_blit COMMAND test_iosurface_blit)

# --- layer presenter math unit test ---
add_executable(test_layer_presenter tests/test_layer_presenter.m src/PortholeLayerPresenter.m)
target_include_directories(test_layer_presenter PRIVATE src)
target_link_libraries(test_layer_presenter PRIVATE ${COCOA_LIBRARY} ${QUARTZCORE_LIBRARY} ${IOSURFACE_LIBRARY})
add_test(NAME layer_presenter COMMAND test_layer_presenter)

# --- background-colour sampler unit test (plain C, compiled as ObjC) ---
add_executable(test_bg_sample tests/test_bg_sample.m src/PortholeBgSample.m)
target_include_directories(test_bg_sample PRIVATE src)
target_link_libraries(test_bg_sample PRIVATE ${FOUNDATION_LIBRARY})
add_test(NAME bg_sample COMMAND test_bg_sample)

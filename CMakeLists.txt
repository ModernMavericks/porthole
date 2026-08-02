# Porthole -- the app-agnostic viewer-generator engine (an in-repo build ingredient).
# Contents: the native Cocoa viewer (viewer/), the generator (bin/generate-viewer) +
# templates/, the recovery watcher, the menu daemon, and example app definitions.
# At Stage 1d this whole directory is `git subtree split` into ModernMavericks/porthole,
# where it becomes the repo root. It is included by the product's top-level CMakeLists.

# The native Cocoa Xpra viewer (app bundle, headless probe, codec ctest).
add_subdirectory(viewer)

# Engine BATS suites: the generator, the recovery watcher, and the example launchers.
# (BATS_EXECUTABLE is found by the parent before this add_subdirectory.)
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
endif()

# Checks the installer's logic without its UI: versions, the releases list, its saved state and the
# build script's events.
add_executable(wiicompiled_installertest EXCLUDE_FROM_ALL main.swift ${WIICOMPILED_INSTALLER_LOGIC_SOURCES})
set_target_properties(wiicompiled_installertest PROPERTIES Swift_LANGUAGE_VERSION 5)

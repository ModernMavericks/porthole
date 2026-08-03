# Porthole shared BASE image -- the app-agnostic, redistributable runtime every viewer needs:
# xpra (pinned), Xvfb, the common desktop/runtime libs, the menu daemon, and the Mac-font alias.
# NO vendor application and NO vendor icon live here -- those install from the vendor on the user's
# Mac (Porthole redistributes nothing vendor-owned). Built in CI, pushed to
# ghcr.io/modernmavericks/porthole-base:<porthole-version>; per-app recipes FROM it, so the heavy
# common layer is pulled (shared across all apps) instead of rebuilt on every user's machine.
FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      dbus dbus-x11 util-linux \
      python3-dbus python3-lz4 \
      gnome-keyring libsecret-1-0 socat \
      at-spi2-core python3-pyatspi \
    # xpra (the display server the Porthole client speaks to) is not in Debian; pull from xpra.org
    # and PIN it -- the native client is written against a specific xpra wire protocol, so an
    # unpinned install could drift to an incompatible xpra. xpra.org's trixie repo retains old
    # versions, so the pin is stable. Bump it only together with the viewer (op's compat check).
    && curl -sS https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc \
    && echo 'deb [signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/ trixie main' \
       > /etc/apt/sources.list.d/xpra.list \
    && apt-get update \
    && apt-get install -y xpra=6.5.2-r0-1 xvfb \
    && rm -rf /var/lib/apt/lists/*

# The AT-SPI menu daemon (ours) + the Mac/CSS system-font alias (no font data). Present in every
# viewer; a per-app recipe only enables the daemon (MENU_PRODUCER) -- it does not re-ship these.
COPY porthole-menu-daemon.py /usr/local/bin/porthole-menu-daemon.py
RUN chmod 755 /usr/local/bin/porthole-menu-daemon.py
COPY mac-fonts.conf /etc/fonts/conf.d/09-mac-fonts.conf

#ifndef REMOTE_DISPLAY_H
#define REMOTE_DISPLAY_H

#include <stddef.h>
#include <stdint.h>

/*
 * remote_display: a thin, protocol-neutral interface to a remote
 * display-sharing session.
 *
 * The native shell (Cocoa, today) drives input, geometry and clipboard through
 * the rds_* operations, and receives windows, pixel draws and clipboard through
 * the `rds_callbacks`. It never sees the wire protocol.
 *
 * Xpra is the only backend today (`rds_xpra_create`). The interface is
 * deliberately protocol-agnostic and plain-C so that future backends (RFB,
 * RDP, ...) can be implemented as portable C behind this same seam, and a
 * native shell on any platform can drive them without change.
 *
 * Ownership/threading: a session is single-threaded; call the operations and
 * receive the callbacks on the same run loop the session was created on.
 */

typedef struct rds_session rds_session;

/* Events delivered from the backend to the native shell. */
typedef struct rds_callbacks {
    void *ctx;   /* opaque; passed back to every callback */

    /* A new top-level appeared at its server-side (root) position (x,y) with
     * size (w,h). `override_redirect` marks unmanaged surfaces (menus/popovers)
     * that should be borderless and never take focus. `title` is the window's
     * title (may be NULL/empty; the shell falls back to the app name). */
    void (*new_window)(void *ctx, long wid, int x, int y, int w, int h,
                       int override_redirect, const char *title);

    /* A pixel region for a window. `encoding` is a generic image format name
     * ("jpeg", "png", "rgb24", "rgb32"); (pixels,len) is the payload; rowstride
     * is the source byte stride (0 if not applicable). The backend acknowledges
     * the frame itself -- the shell just renders it. */
    void (*draw)(void *ctx, long wid, int x, int y, int w, int h,
                 const char *encoding, const void *pixels, size_t len,
                 int rowstride);

    /* A window went away. */
    void (*lost_window)(void *ctx, long wid);

    /* The remote clipboard now holds this UTF-8 text -> copy it to the local
     * clipboard. */
    void (*clipboard_set_text)(void *ctx, const char *utf8, size_t len);

    /* The remote side is pasting and wants our clipboard -> the shell must
     * answer (synchronously) with rds_provide_clipboard_text(). */
    void (*clipboard_wants_text)(void *ctx);

    /* A link was activated inside the remote app; open it in the local
     * browser. `url` is the target (typically http/https/mailto). The shell is
     * responsible for vetting the scheme before handing it to the OS. May be
     * NULL, in which case the backend drops the request. */
    void (*open_url)(void *ctx, const char *url);

    /* The remote app posted a desktop notification; show it locally. `summary`
     * is the title, `body` the message (either may be empty, never NULL). Icons
     * and actions are intentionally not surfaced yet. */
    void (*notify)(void *ctx, const char *summary, const char *body);

    /* The remote app wants a file opened locally (a download/attachment). The
     * backend has already assembled the whole file; (data,len) is its content,
     * `filename` a base name (drives the type/extension), `mimetype` may be
     * empty. The shell writes it somewhere safe and hands it to the OS -- and,
     * as with open_url, is responsible for refusing dangerous types. */
    void (*open_file)(void *ctx, const char *filename, const char *mimetype,
                      const void *data, size_t len);

    /* The remote app wants a document printed (it chose Print). The backend has
     * assembled the whole file; (data,len) is its content (typically PDF or
     * PostScript), `filename`/`mimetype` describe it. The shell sends it to the
     * local print system. */
    void (*print_file)(void *ctx, const char *filename, const char *mimetype,
                       const void *data, size_t len);

    /* The remote pointer cursor changed shape (e.g. text I-beam, resize, hand).
     * `bgra` is width*height premultiplied BGRA pixels; (xhot,yhot) is the
     * hotspot. The shell shows this as the pointer over its windows. */
    void (*set_cursor)(void *ctx, int width, int height, int xhot, int yhot,
                       const void *bgra, size_t len);
    /* Revert to the platform's default (arrow) cursor. */
    void (*reset_cursor)(void *ctx);

    /* The remote app created a system-tray icon (`wid` identifies it; the icon is
     * w x h). The shell should present it as a native menu-bar item; its icon
     * pixels arrive as normal `draw` callbacks for this same `wid`, and it goes
     * away via `lost_window`. Clicks are sent back with rds_button() on `wid`. */
    void (*new_tray)(void *ctx, long wid, int w, int h);

    /* The remote app is playing sound. (data,len) is one chunk of an encoded audio
     * stream; `codec` names the format ("mp3"). The shell decodes + plays it. A
     * (NULL,0) chunk (codec="") signals the stream stopped -> flush/reset. Unlike the
     * request/response bridges above this is a stream: many chunks arrive over time. */
    void (*audio_out)(void *ctx, const char *codec, const void *data, size_t len);

    /* The session ended: the backend lost its connection to the remote (the server
     * exited, the container/VM went away, or the socket bridge dropped). Fired at
     * most once. After this the session delivers no further events and input is a
     * no-op -- the shell should tear down (there is no reconnect), typically by
     * terminating so a fresh launch reconnects. Optional (may be NULL). */
    void (*disconnected)(void *ctx);
} rds_callbacks;

/* ---- lifecycle ---- */
void rds_start(rds_session *s);
void rds_destroy(rds_session *s);

/* ---- input (shell -> remote), coordinates are window-local ---- */
void rds_pointer_move(rds_session *s, long wid, int x, int y);
void rds_button(rds_session *s, long wid, int button, int pressed, int x, int y);
void rds_key(rds_session *s, long wid, const char *keysym, uint32_t keyval,
             const char *text, const char *const *modifiers,
             size_t modifier_count, int pressed);

/* ---- focus / geometry (shell -> remote) ---- */
/* Report native key-window transitions; the backend coordinates the remote
 * focus (and any protocol-specific popup dismissal) from these. */
void rds_window_focus_gained(rds_session *s, long wid);
void rds_window_focus_lost(rds_session *s, long wid);
/* The shell resized a window; ask the remote to reflow to (w,h). */
void rds_configure_window(rds_session *s, long wid, int w, int h);

/* ---- clipboard (shell -> remote) ---- */
/* The local clipboard changed (a local copy) -> claim the remote clipboard. */
void rds_clipboard_changed(rds_session *s);
/* Answer a clipboard_wants_text callback; pass utf8=NULL/len=0 for "nothing". */
void rds_provide_clipboard_text(rds_session *s, const char *utf8, size_t len);

/* ---- backends ---- */
/* socket_path is an AF_UNIX socket the backend connects to (the local end of the
 * launcher's bridge to the container's xpra Unix socket). */
rds_session *rds_xpra_create(const char *socket_path, const rds_callbacks *cb);

#endif /* REMOTE_DISPLAY_H */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXPORT __attribute__((visibility("default")))

EXPORT void cw_nswindow_remove_titlebar(void *ns_window);

typedef struct {
  double x;
  double y;
  double w;
  double h;
} cw_rect_t;

typedef struct {
  double w;
  double h;
} cw_size_t;

EXPORT void cw_nswindow_update_draggable_areas(void *ns_window,
                                               cw_rect_t *exclude,
                                               size_t exclude_count);

EXPORT void cw_nswindow_disable_draggable_areas(void *ns_window);

typedef enum {
  CW_APPEARANCE_AUTO,
  CW_APPEARANCE_LIGHT,
  CW_APPEARANCE_DARK,
} cw_appearance_t;

typedef struct {
  double offset_x;
  double offset_y;
  cw_appearance_t appearance;
  bool custom_inactive_traffic_light;
  int64_t inactive_background_color;
  int64_t inactive_border_color;
  double inactive_border_width;
  bool show_as_inactive_in_key_window;
} cw_traffic_light_config_t;

EXPORT void
cw_nswindow_update_traffic_light(void *ns_window,
                                 const cw_traffic_light_config_t *config);

EXPORT cw_size_t cw_nswindow_traffic_light_size(void *ns_window);

EXPORT void cw_nswindow_request_close(void *ns_window);

EXPORT void cw_nswindow_set_style_mask(void *ns_window,
                                       unsigned long style_mask);

EXPORT unsigned long cw_nswindow_get_style_mask(void *ns_window);

EXPORT void
cw_nswindow_set_collection_behavior(void *ns_window,
                                    unsigned long collection_behavior);

EXPORT unsigned long cw_nswindow_get_collection_behavior(void *ns_window);

typedef struct {
  cw_size_t (*on_window_will_resize)(cw_size_t new_size);
  void (*on_window_will_start_live_resize)();
  void (*on_window_did_end_live_resize)();
  void (*on_window_will_close)();
  void (*on_window_will_enter_fullscreen)();
  void (*on_window_did_enter_fullscreen)();
  void (*on_window_will_exit_fullscreen)();
  void (*on_window_did_exit_fullscreen)();
  cw_rect_t (*on_window_will_use_standard_frame)(cw_rect_t default_frame);
} cw_delegate_config_t;

EXPORT void cw_nswindow_init_delegate(void *ns_window,
                                      cw_delegate_config_t config);

EXPORT void cw_nswindow_set_frame(void *ns_window, cw_rect_t frame);
EXPORT cw_rect_t cw_nswindow_get_frame(void *ns_window);

typedef struct {
  void *ns_window;
  double origin_x;
  double origin_y;
  cw_size_t content_size;
} cw_tile_entry_t;

// Resizes each window's content area to `content_size` and moves its frame
// origin to (`origin_x`, `origin_y`), on the main queue, after the current
// call stack has unwound.
//
// The deferral is mandatory, not an optimisation. `-[NSWindow setContentSize:]`
// makes Flutter's resize synchronizer spin on the platform thread until the
// raster thread presents a frame at the new size. On macOS the platform and UI
// threads are merged, so a resize issued from Dart blocks the very thread that
// has to produce that frame: the wait can only end in its 1-second timeout
// ("Resize timed out"), once per window. Running the same calls from a main
// queue block leaves no Dart frame on the stack, so the synchronizer's message
// pump can drive the frame pipeline and the resize commits in one frame.
//
// `entries` is copied, so the caller may free it as soon as this returns.
//
// `on_applied` runs at the end of that same block, once every window has its
// new geometry. It may be NULL. Callers that watch windows for user-driven
// moves should arm those watchers from here: `-[NSWindow setFrameOrigin:]`
// posts `NSWindowDidMoveNotification` like any other move, so a watcher armed
// before this point cannot tell our placement from the user's.
EXPORT void cw_nswindow_tile_async(const cw_tile_entry_t *entries, size_t count,
                                   void (*on_applied)(void));

#ifdef __cplusplus
}
#endif
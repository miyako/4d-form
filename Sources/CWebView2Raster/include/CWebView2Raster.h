#ifndef CWEBVIEW2_RASTER_H
#define CWEBVIEW2_RASTER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Maps the shared canvas size (points) to exact output pixels. Returns 0 on
/// success; on failure returns nonzero and may set *error (malloc'd UTF-8).
typedef int (*fourdform_size_callback)(void *context, double width, double height,
                                       int *pixel_width, int *pixel_height, char **error);

/// Renders trusted upstream HTML in a private, network-blocked WebView2 and
/// returns an 8-bit RGBA sRGB PNG of exactly the callback's pixel size.
/// `prepare_js` is an async function body returning {width, height};
/// `resize_js` is an async function body receiving `width` and `height`.
/// Returns 0 on success. Free *png and *error with fourdform_free.
int fourdform_webview2_png(const char *html, size_t html_length,
                           const char *prepare_js, const char *resize_js,
                           fourdform_size_callback size_callback, void *context,
                           double timeout_seconds,
                           unsigned char **png, size_t *png_length, char **error);

/// Independent WIC decoder used for verification: returns tightly packed RGBA.
int fourdform_wic_decode_png(const unsigned char *png, size_t png_length,
                             int *width, int *height, unsigned char **rgba, char **error);

void fourdform_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif

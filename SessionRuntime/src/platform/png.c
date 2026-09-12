#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <pthread.h>
#include <ghostty/vt.h>

#define PNG_INPUT_LIMIT (16u * 1024u * 1024u)
#define PNG_PIXEL_LIMIT (16u * 1024u * 1024u)
#define PNG_WORK_LIMIT (64u * 1024u * 1024u)

// Per-decode accounting prevents a compressed image from making unbounded live
// allocations. The returned Ghostty buffer has its own allocator ownership.
static _Thread_local size_t live_bytes;
static _Thread_local int decoding;
typedef union { size_t bytes; max_align_t alignment; } Allocation;

static void *png_allocate(size_t count) {
  if (!decoding || count > PNG_WORK_LIMIT - sizeof(Allocation)) return NULL;
  const size_t total = sizeof(Allocation) + count;
  if (total > PNG_WORK_LIMIT - live_bytes) return NULL;
  Allocation *block = malloc(total);
  if (!block) return NULL;
  block->bytes = total;
  live_bytes += total;
  return block + 1;
}
static void png_release(void *pointer) {
  if (!pointer) return;
  Allocation *block = (Allocation *)pointer - 1;
  live_bytes -= block->bytes;
  free(block);
}
static void *png_resize(void *pointer, size_t count) {
  if (!pointer) return png_allocate(count);
  Allocation *old = (Allocation *)pointer - 1;
  const size_t prior = old->bytes;
  if (count > PNG_WORK_LIMIT - sizeof(Allocation)) return NULL;
  const size_t total = sizeof(Allocation) + count;
  if (total > PNG_WORK_LIMIT - (live_bytes - prior)) return NULL;
  Allocation *block = realloc(old, total);
  if (!block) return NULL;
  block->bytes = total;
  live_bytes = live_bytes - prior + total;
  return block + 1;
}

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_FAILURE_STRINGS
#define STBI_MAX_DIMENSIONS 16384
#define STBI_MALLOC(n) png_allocate(n)
#define STBI_REALLOC(p,n) png_resize(p,n)
#define STBI_FREE(p) png_release(p)
#include "stb_image.h"

static bool decode_png(void *userdata, const GhosttyAllocator *allocator,
                       const uint8_t *data, size_t length, GhosttySysImage *out) {
  (void)userdata;
  memset(out, 0, sizeof(*out));
  if (decoding || !data || length == 0 || length > PNG_INPUT_LIMIT || length > INT_MAX) return false;
  static const unsigned char signature[8] = {137,80,78,71,13,10,26,10};
  if (length < 8 || memcmp(data, signature, 8) != 0) return false;
  decoding = 1;
  live_bytes = 0;
  int width = 0, height = 0, channels = 0;
  bool result = false;
  unsigned char *decoded = NULL;
  if (!stbi_info_from_memory(data, (int)length, &width, &height, &channels)) goto done;
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
      (size_t)width > PNG_PIXEL_LIMIT / 4 / (size_t)height) goto done;
  const int expected_width = width, expected_height = height;
  const size_t bytes = (size_t)width * (size_t)height * 4;
  decoded = stbi_load_from_memory(data, (int)length, &width, &height, &channels, 4);
  if (!decoded || width != expected_width || height != expected_height) goto done;
  uint8_t *pixels = ghostty_alloc(allocator, bytes);
  if (!pixels) goto done;
  memcpy(pixels, decoded, bytes);
  out->width = (uint32_t)width;
  out->height = (uint32_t)height;
  out->data = pixels;
  out->data_len = bytes;
  result = true;
done:
  stbi_image_free(decoded);
  decoding = 0;
  return result;
}

static pthread_once_t install_once = PTHREAD_ONCE_INIT;
static GhosttyResult install_result = GHOSTTY_INVALID_VALUE;
static void install(void) {
  install_result = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void *)decode_png);
}
int session_install_png_decoder(void) {
  return pthread_once(&install_once, install) == 0 && install_result == GHOSTTY_SUCCESS;
}

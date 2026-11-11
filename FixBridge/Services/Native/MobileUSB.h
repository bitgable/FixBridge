#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

typedef struct FBUSB FBUSB;

// Detects a wired device without opening a pairing or accessory session.
CFArrayRef fb_usb_copy_identifiers(void) CF_RETURNS_RETAINED;
// 1 = enumerated over USB, 0 = absent, -1 = discovery unavailable.
int fb_usb_device_presence(CFStringRef identifier);
const char *fb_usb_last_error(FBUSB *usb);
// Returns a stable, non-sensitive diagnostic on failure.
FBUSB *fb_usb_open(CFStringRef identifier, const char **error, uint32_t *status);
void fb_usb_close(FBUSB *usb);
// Read returns 0 on timeout and -1 on disconnect/error.
int fb_usb_read(FBUSB *usb, void *buffer, size_t length, int timeout_ms);
int fb_usb_write(FBUSB *usb, const void *buffer, size_t length);


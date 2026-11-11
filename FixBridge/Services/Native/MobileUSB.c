#include "MobileUSB.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/time.h>

typedef struct {
    CFArrayRef (*device_list)(void);
    int (*interface_type)(CFTypeRef);
    CFStringRef (*device_identifier)(CFTypeRef);
    int (*connect)(CFTypeRef);
    int (*disconnect)(CFTypeRef);
    int (*validate)(CFTypeRef);
    int (*start_session)(CFTypeRef);
    int (*stop_session)(CFTypeRef);
    int (*start_service)(CFTypeRef, CFStringRef, CFDictionaryRef, CFTypeRef *);
    int (*socket)(CFTypeRef);
    int (*invalidate)(CFTypeRef);
    int (*send)(CFTypeRef, const void *, size_t);
    int (*receive)(CFTypeRef, void *, size_t);
} MobileDevice;

struct FBUSB {
    CFTypeRef device;
    CFTypeRef service;
    int fd;
    int connected;
    int session;
    char last_error[192];
};

static MobileDevice api;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load_mobile_device(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
                             RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return;
    MobileDevice loaded;
#define LOAD(field, symbol) \
    loaded.field = dlsym(framework, #symbol); \
    if (!loaded.field) goto fail
    LOAD(device_list, AMDCreateDeviceList);
    LOAD(interface_type, AMDeviceGetInterfaceType);
    LOAD(device_identifier, AMDeviceCopyDeviceIdentifier);
    LOAD(connect, AMDeviceConnect);
    LOAD(disconnect, AMDeviceDisconnect);
    LOAD(validate, AMDeviceValidatePairing);
    LOAD(start_session, AMDeviceStartSession);
    LOAD(stop_session, AMDeviceStopSession);
    LOAD(start_service, AMDeviceSecureStartService);
    LOAD(socket, AMDServiceConnectionGetSocket);
    LOAD(invalidate, AMDServiceConnectionInvalidate);
    LOAD(send, AMDServiceConnectionSend);
    LOAD(receive, AMDServiceConnectionReceive);
#undef LOAD
    // Keep the framework loaded while the app monitors devices or runs a session.
    api = loaded;
    return;

fail:
    dlclose(framework);
}

CFArrayRef fb_usb_copy_identifiers(void) {
    pthread_once(&load_once, load_mobile_device);
    if (!api.device_list) return NULL;
    CFArrayRef devices = api.device_list();
    if (!devices) return NULL;
    CFMutableArrayRef identifiers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (identifiers) {
        for (CFIndex index = 0; index < CFArrayGetCount(devices); ++index) {
            CFTypeRef device = CFArrayGetValueAtIndex(devices, index);
            if (api.interface_type(device) != 1) continue;
            CFStringRef identifier = api.device_identifier(device);
            if (!identifier) continue;
            CFArrayAppendValue(identifiers, identifier);
            CFRelease(identifier);
        }
    }
    CFRelease(devices);
    return identifiers;
}

static CFTypeRef find_wired_device(CFStringRef identifier) {
    CFArrayRef devices = api.device_list();
    if (!devices) return NULL;
    CFTypeRef match = NULL;
    for (CFIndex index = 0; index < CFArrayGetCount(devices); ++index) {
        CFTypeRef device = CFArrayGetValueAtIndex(devices, index);
        if (api.interface_type(device) != 1) continue;
        CFStringRef candidate = api.device_identifier(device);
        if (!candidate) continue;
        bool matches = CFEqual(candidate, identifier);
        CFRelease(candidate);
        if (matches) {
            match = CFRetain(device);
            break;
        }
    }
    CFRelease(devices);
    return match;
}

int fb_usb_device_presence(CFStringRef identifier) {
    if (!identifier) return -1;
    CFArrayRef identifiers = fb_usb_copy_identifiers();
    if (!identifiers) return -1;
    int present = CFArrayContainsValue(identifiers,
        CFRangeMake(0, CFArrayGetCount(identifiers)), identifier) ? 1 : 0;
    CFRelease(identifiers);
    return present;
}

const char *fb_usb_last_error(FBUSB *usb) { return usb->last_error; }

void fb_usb_close(FBUSB *usb) {
    if (!usb) return;
    if (usb->service) {
        api.invalidate(usb->service);
        CFRelease(usb->service);
    }
    if (usb->session) api.stop_session(usb->device);
    if (usb->connected) api.disconnect(usb->device);
    if (usb->device) CFRelease(usb->device);
    free(usb);
}

FBUSB *fb_usb_open(CFStringRef identifier, const char **error, uint32_t *status) {
    *status = 0;
    *error = "The MobileDevice interface is unavailable on this Mac.";
    pthread_once(&load_once, load_mobile_device);
    if (!api.device_list) return NULL;
    FBUSB *usb = calloc(1, sizeof(*usb));
    if (!usb) return NULL;

    usb->device = find_wired_device(identifier);
    if (!usb->device) {
        *error = "The selected USB iPhone is no longer connected.";
        goto fail;
    }
    *error = "Could not connect to the iPhone over USB. Keep the iPhone unlocked.";
    if ((*status = api.connect(usb->device))) goto fail;
    usb->connected = 1;
    *error = "The iPhone has not trusted this Mac. Select it in Finder and complete the trust prompt.";
    if ((*status = api.validate(usb->device))) goto fail;
    if ((*status = api.start_session(usb->device))) goto fail;
    usb->session = 1;
    *error = "Could not open the iPhone’s CarKit accessory service.";
    if ((*status = api.start_service(usb->device, CFSTR("com.apple.carkit.service"),
                                     NULL, &usb->service))) goto fail;
    if (!usb->service || (usb->fd = api.socket(usb->service)) < 0) goto fail;

    const int enabled = 1;
    const struct timeval timeout = { .tv_sec = 2 };
    if (setsockopt(usb->fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0 ||
        setsockopt(usb->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        setsockopt(usb->fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) {
        *error = "Could not configure the USB accessory connection.";
        goto fail;
    }
    return usb;

fail:
    fb_usb_close(usb);
    return NULL;
}

int fb_usb_read(FBUSB *usb, void *buffer, size_t length, int timeout_ms) {
    struct pollfd fd = { .fd = usb->fd, .events = POLLIN };
    int ready;
    do {
        ready = poll(&fd, 1, timeout_ms);
    } while (ready < 0 && errno == EINTR);
    if (ready == 0) return 0;
    if (ready < 0 || !(fd.revents & POLLIN)) {
        snprintf(usb->last_error, sizeof(usb->last_error),
                 "read poll result=%d revents=0x%X errno=%d", ready, fd.revents, ready < 0 ? errno : 0);
        return -1;
    }
    errno = 0;
    int received = api.receive(usb->service, buffer, length);
    if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    if (received <= 0 || (size_t)received > length) {
        snprintf(usb->last_error, sizeof(usb->last_error),
                 "service receive result=%d errno=%d revents=0x%X", received, errno, fd.revents);
    }
    return received > 0 && (size_t)received <= length ? received : -1;
}

int fb_usb_write(FBUSB *usb, const void *buffer, size_t length) {
    const unsigned char *cursor = buffer;
    while (length) {
        errno = 0;
        int sent = api.send(usb->service, cursor, length);
        if (sent <= 0 || (size_t)sent > length) {
            snprintf(usb->last_error, sizeof(usb->last_error), "service send result=%d errno=%d", sent, errno);
            return -1;
        }
        cursor += sent;
        length -= (size_t)sent;
    }
    return 0;
}

// Compile the actual bridge against fault-injected service functions; no iPhone access.
#include "../FixBridge/Services/Native/MobileUSB.c"
#include <assert.h>
#include <string.h>
#include <unistd.h>
static int read_result = 1, read_errno = 0;
static int receive_test(CFTypeRef service, void *buffer, size_t length) {
    (void)service; (void)buffer; (void)length;
    errno = read_errno;
    return read_result;
}
static int send_result = 2, send_calls = 0;
static int send_test(CFTypeRef service, const void *buffer, size_t length) {
    (void)service; (void)buffer;
    ++send_calls;
    return send_result <= 0 ? send_result : (int)(length < (size_t)send_result ? length : (size_t)send_result);
}
int main(void) {
    int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    FBUSB usb = { .fd = sockets[0] };
    api.receive = receive_test; api.send = send_test;
    char buffer[8];
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == 0);
    assert(write(sockets[1], "x", 1) == 1);
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == 1);
    read_result = -1; read_errno = EAGAIN;
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == 0);
    read_errno = EINTR;
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == 0);
    read_errno = 0; read_result = 0;
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == -1);
    assert(strstr(fb_usb_last_error(&usb), "receive result=0"));
    read_result = 9;
    assert(fb_usb_read(&usb, buffer, sizeof(buffer), 1) == -1);
    assert(fb_usb_write(&usb, "hello", 5) == 0 && send_calls == 3);
    send_result = -1;
    assert(fb_usb_write(&usb, "x", 1) == -1);
    assert(strstr(fb_usb_last_error(&usb), "send result=-1"));
    close(sockets[0]); close(sockets[1]);
    puts("USB I/O checks passed: timeout, transient read, EOF, invalid size, partial writes, errors.");
    return 0;
}

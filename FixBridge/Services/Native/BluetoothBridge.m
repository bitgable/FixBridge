// Raw RFCOMM bridge for a previously paired, explicitly selected device.
// stdout is binary protocol traffic; diagnostics go to stderr.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

@interface Bridge : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property BOOL done;
@property BOOL sdpDone;
@property BOOL opened;
@property IOReturn openStatus;
@property IOReturn sdpStatus;
@end

@implementation Bridge
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    self.openStatus = status;
    if (status == kIOReturnSuccess) {
        // Prefix the byte stream with a local readiness byte before forwarding RFCOMM data.
        const uint8_t ready = 1;
        if (write(STDOUT_FILENO, &ready, sizeof(ready)) != sizeof(ready)) {
            self.openStatus = kIOReturnError;
        }
    }
    self.opened = YES;
}

- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    self.sdpStatus = status;
    self.sdpDone = YES;
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    if (!self.opened || self.openStatus != kIOReturnSuccess) return;
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(STDOUT_FILENO, (char *)data + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { self.done = YES; return; }
        offset += count;
    }
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    fprintf(stderr, "RFCOMM channel closed\n");
    self.done = YES;
}
@end

static void tick(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static NSString *normalizedAddress(NSString *address) {
    return [address.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
        if (!controller || controller.powerState != kBluetoothHCIPowerStateON) return 2;
        if (argc == 2 && strcmp(argv[1], "--controller") == 0) {
            NSString *address = controller.addressAsString;
            if (!address) { fprintf(stderr, "Bluetooth controller unavailable\n"); return 2; }
            puts(address.UTF8String);
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--list") == 0) {
            NSMutableDictionary *devices = [NSMutableDictionary dictionary];
            for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
                NSString *address = normalizedAddress(device.addressString);
                if (!device.isPaired || address.length == 0) continue;
                if (!devices[address] || device.isConnected) {
                    devices[address] = @{@"name": device.name ?: @"", @"address": address,
                                         @"connected": @(device.isConnected)};
                }
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:devices.allValues options:0 error:NULL];
            fwrite(json.bytes, 1, json.length, stdout);
            putchar('\n');
            return 0;
        }
        if (argc != 2) { fprintf(stderr, "usage: bluetooth-bridge DEVICE-MAC | --list\n"); return 2; }
        NSString *target = normalizedAddress(@(argv[1]));
        IOBluetoothDevice *device = nil;
        for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
            if (paired.isPaired && [normalizedAddress(paired.addressString) isEqualToString:target]) {
                device = paired;
                if (paired.isConnected) break;
            }
        }
        if (!device || !device.isPaired) {
            fprintf(stderr, "Pair the selected iPhone in macOS Bluetooth settings first\n");
            return 2;
        }
        Bridge *bridge = [Bridge new];
        // Apple's accessory-to-phone iAP2 service; obtain its current channel via SDP.
        const uint8_t uuidBytes[16] = {0,0,0,0,0xde,0xca,0xfa,0xde,0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xfe};
        IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:uuidBytes length:16];
        IOBluetoothSDPServiceRecord *record = [device getServiceRecordForUUID:uuid];
        IOReturn status = kIOReturnSuccess;
        if (!record) {
            status = [device performSDPQuery:bridge uuids:@[uuid]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
            while (status == kIOReturnSuccess && !bridge.sdpDone && deadline.timeIntervalSinceNow > 0) tick();
            if (!bridge.sdpDone || bridge.sdpStatus != kIOReturnSuccess) {
                fprintf(stderr, "SDP query failed: start=0x%08x completion=0x%08x received=%d\n", status, bridge.sdpStatus, bridge.sdpDone);
                return 3;
            }
            record = [device getServiceRecordForUUID:uuid];
        }
        BluetoothRFCOMMChannelID channelID = 0;
        if (!record || [record getRFCOMMChannelID:&channelID] != kIOReturnSuccess) {
            fprintf(stderr, "Paired device does not advertise the iAP2 RFCOMM service\n"); return 3;
        }
        IOBluetoothRFCOMMChannel *channel = nil;
        status = [device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:bridge];
        fprintf(stderr, "RFCOMM async start=0x%08x channel=%u\n", status, channelID);
        NSDate *openDeadline = [NSDate dateWithTimeIntervalSinceNow:12];
        while (status == kIOReturnSuccess && !bridge.opened && openDeadline.timeIntervalSinceNow > 0) tick();
        if (status != kIOReturnSuccess || !bridge.opened || bridge.openStatus != kIOReturnSuccess) {
            fprintf(stderr, "RFCOMM async result: callback=%d completion=0x%08x connected=%d\n",
                    bridge.opened, bridge.openStatus, device.isConnected);
            return 4;
        }
        fprintf(stderr, "RFCOMM connected, channel=%u\n", channelID);
        int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
        if (flags == -1 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == -1) {
            [channel closeChannel];
            return 5;
        }
        uint8_t input[4096];
        int result = 0;
        while (!bridge.done) {
            tick();
            ssize_t size = read(STDIN_FILENO, input, sizeof(input));
            if (size == 0) break;
            if (size < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                result = 5; break;
            }
            size_t mtu = MAX(1, channel.getMTU);
            for (size_t offset = 0; offset < size; offset += mtu) {
                UInt16 count = (UInt16)MIN(mtu, size - offset);
                if ([channel writeSync:input + offset length:count] != kIOReturnSuccess) {
                    result = 5; bridge.done = YES; break;
                }
            }
        }
        fcntl(STDIN_FILENO, F_SETFL, flags);
        [channel closeChannel];
        return result;
    }
}

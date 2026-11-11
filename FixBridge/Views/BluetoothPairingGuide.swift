import AppKit
import SwiftUI

struct BluetoothPairingGuide: View {
    @State private var showingRecovery = false
    @State private var copied = false

    static let resetCommand = #"""
        /bin/sh <<'FIXBRIDGE_BLUETOOTH_RESET'
        set -eu
        backup_dir=$(mktemp -d "$HOME/Desktop/FixBridge-Bluetooth-Backup.XXXXXX")
        find "$HOME/Library/Preferences" -maxdepth 1 -type f \
          -iname 'com.apple.bluetooth*.plist' -print \
          -exec /bin/mv -n {} "$backup_dir/" \;
        printf 'Backup folder: %s\n' "$backup_dir"
        FIXBRIDGE_BLUETOOTH_RESET
        """#

    var body: some View {
        ConnectionGuideSheet {
            ConnectionGuideSection {
                Text("Bluetooth Pairing Guide").font(.headline)
                Text("1. Keep your iPhone unlocked nearby with Settings → Bluetooth open.")
                Text(
                    "2. On your Mac, open System Settings → Bluetooth, find your iPhone, and click Connect. Confirm the matching pairing code on both devices if prompted."
                )
                Button("Open Mac Bluetooth Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text(
                    "3. Return to FixBridge and close this guide. Select your iPhone from the refreshed list and wait for the connection and MFi checks to pass."
                )
            }

            ConnectionGuideSection {
                DisclosureGroup("Pairing keeps failing?", isExpanded: $showingRecovery) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Reset Bluetooth preferences").font(.body.bold())
                        Text(
                            "Copy the command, quit FixBridge and any pairing apps, then paste it into Terminal. It moves matching preference files to a backup folder on your Desktop."
                        )
                        ScrollView(.horizontal) {
                            Text(verbatim: Self.resetCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                        Button(copied ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(Self.resetCommand, forType: .string)
                        }
                        Text(
                            "This resets Bluetooth preferences for your Mac user. Other Bluetooth accessories may need to be reconnected."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text("Restart, then forget the old devices").font(.body.bold())
                        Text("Restart your Mac after running the command. You can reopen this guide afterward.")
                        Text(
                            "On iPhone, open Settings → Bluetooth, tap the information button next to your Mac, then tap Forget This Device."
                        )
                        Text(
                            "On Mac, open System Settings → Bluetooth and forget the old iPhone entry if it is still listed."
                        )
                        Text("Pair again in System Settings").font(.body.bold())
                        Text("Repeat the pairing steps above in Mac System Settings, then return to FixBridge.")
                        Text("This recovery sequence is a community workaround for repeated pairing failures.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

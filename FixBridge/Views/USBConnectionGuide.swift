import SwiftUI

struct USBConnectionGuide: View {
    @State private var showingTroubleshooting = false

    var body: some View {
        ConnectionGuideSheet {
            ConnectionGuideSection {
                Text("USB Connection Guide").font(.headline)
                Text("1. Connect your iPhone directly to your Mac using a USB cable that supports data transfer.")
                Text(
                    "2. Unlock your iPhone. If asked to trust this computer, tap Trust and enter your iPhone passcode.")
                Text("3. If your Mac asks to allow the accessory to connect, click Allow.")
                Text(
                    "4. Return to FixBridge and close this guide. Select your iPhone when it appears and wait for the connection and MFi checks to pass."
                )
            }

            ConnectionGuideSection {
                DisclosureGroup("iPhone not appearing?", isExpanded: $showingTroubleshooting) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Keep your iPhone unlocked, disconnect the cable, then reconnect it. Try another data cable or USB port, and connect directly without a hub."
                        )
                        Text(
                            "Open Finder and look for your iPhone under Locations. Select it and complete any Trust prompts on your Mac and iPhone."
                        )
                        Text(
                            "If Finder cannot see your iPhone either, restart your iPhone and Mac, then reconnect and try again."
                        )
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

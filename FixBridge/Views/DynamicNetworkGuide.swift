import SwiftUI

struct DynamicNetworkGuide: View {
    @State private var copiedHosts = false
    @State private var copiedDNS = false

    private static let hosts = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com",
    ]
    private static let hostnames = hosts.joined(separator: "\n")
    private static let dnsExample = hosts.map { "127.0.0.1 \($0)" }.joined(separator: "\n")

    var body: some View {
        ConnectionGuideSheet {
            ConnectionGuideSection {
                Text("Dynamic Mode Network Setup").font(.headline)
                Text(
                    "iPhone combines GPS, Bluetooth, Wi-Fi and cellular information to determine its location. Network-based location services can interfere with accessory updates, causing a moving location to stall or return to the real position."
                )
                Text(
                    "The goal is to prevent connections to the five hosts below. You can use domain-blocking rules or DNS overrides; neither a specific app nor DNS is required. This does not disable all location sources. Normal mode needs no network rules."
                )
            }
            ConnectionGuideSection {
                Text("Hosts to Block").font(.headline)
                ScrollView(.horizontal) {
                    Text(verbatim: Self.hostnames)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button(copiedHosts ? "Copied" : "Copy Hostnames") {
                    NSPasteboard.general.clearContents()
                    copiedHosts = NSPasteboard.general.setString(Self.hostnames, forType: .string)
                }
                DisclosureGroup("DNS Override Example") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "This hosts-format example maps the domains to loopback addresses. Adapt it to your tool’s syntax; DNS overrides are optional if you use connection-blocking rules instead."
                        )
                        ScrollView(.horizontal) {
                            Text(verbatim: Self.dnsExample)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button(copiedDNS ? "Copied" : "Copy DNS Rules") {
                            NSPasteboard.general.clearContents()
                            copiedDNS = NSPasteboard.general.setString(Self.dnsExample, forType: .string)
                        }
                        Text(
                            "Also block IPv6 access or map IPv6 results to ::1. Do not set 127.0.0.1 or ::1 as your DNS server address."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            ConnectionGuideSection {
                Text("iPhone: Connection Blocking").font(.headline)
                Text(
                    "Tools such as Surge, Loon, Stash, Quantumult X and Shadowrocket can apply domain rules. Add reject or block rules for these hostnames using your tool’s syntax, covering both Wi-Fi and cellular data. Routing traffic through a proxy alone does not block it."
                )
            }
            ConnectionGuideSection {
                Text("iPhone: Local DNS Filtering").font(.headline)
                Text(
                    "AdGuard Pro or AdGuard Premium supports local DNS filtering without a remote proxy server. Use the DNS example above with the AdGuard implementation, which uses a local VPN. Native mode cannot apply local rules."
                )
                Text(
                    "[AdGuard DNS guide](https://adguard.com/kb/adguard-for-ios/features/dns-protection/)"
                )
            }
            ConnectionGuideSection {
                Text("Wi-Fi: Router DNS").font(.headline)
                Text(
                    "Configure the DNS overrides on your router using the example above, and make sure your iPhone uses that DNS resolver. This covers only that Wi-Fi network, not cellular data."
                )
            }
            ConnectionGuideSection {
                Text("Testing and Recovery").font(.headline)
                Text(
                    "Enable the rules before clicking Start, follow FixBridge’s location refresh guide, and keep the rules active until the session stops."
                )
                Text(
                    "If the position stalls or returns to the real location, check that the rules apply to the current network, then click Refresh iPhone Location. If that does not help, stop FixBridge, restart your iPhone, and reconnect."
                )
                Text(
                    "After testing, disable the rules to restore access to these services. FixBridge does not configure or verify the rules."
                )
            }
        }
    }
}

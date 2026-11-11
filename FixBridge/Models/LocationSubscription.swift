import Foundation

/// AIS R2 §26.9: the interval applies to whole LocationInformation messages.
struct LocationSubscription {
    let requestedMilliseconds: UInt32
    let sentenceIDs: [Int]

    init?(parameters: [(Int, [UInt8])]) {
        let intervals = parameters.filter { $0.0 == 0 }
        guard intervals.count == 1, intervals[0].1.count == 4 else { return nil }
        for id in 1...3 {
            let flags = parameters.filter { $0.0 == id }
            guard flags.count <= 1, flags.allSatisfy({ $0.1.isEmpty }) else { return nil }
        }
        requestedMilliseconds = intervals[0].1.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        sentenceIDs = parameters.filter { (1...2).contains($0.0) }.map(\.0).sorted()
    }

    // Retain the existing 1 Hz ceiling when the phone permits more frequent updates.
    var sendInterval: TimeInterval { max(1, Double(requestedMilliseconds) / 1000) }
}

struct LocationSendSchedule {
    var subscription: LocationSubscription?
    private var lastCompletedSend: TimeInterval?

    func isDue(at time: TimeInterval) -> Bool {
        guard let subscription, !subscription.sentenceIDs.isEmpty else { return false }
        guard let lastCompletedSend else { return true }
        return time - lastCompletedSend >= subscription.sendInterval
    }

    mutating func sent(at time: TimeInterval) {
        // Measuring from completion conservatively includes time spent waiting for the ACK.
        lastCompletedSend = time
    }
}

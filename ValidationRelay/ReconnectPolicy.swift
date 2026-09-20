import Foundation

struct RelayReconnectPolicy {
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    private(set) var nextDelay: TimeInterval

    init(initialDelay: TimeInterval = 2, maximumDelay: TimeInterval = 64) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        nextDelay = initialDelay
    }

    mutating func consumeDelay() -> TimeInterval {
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, maximumDelay)
        return delay
    }

    mutating func reset() {
        nextDelay = initialDelay
    }
}

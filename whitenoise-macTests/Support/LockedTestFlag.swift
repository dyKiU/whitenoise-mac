import Synchronization

nonisolated final class LockedTestFlag: Sendable {
    private let storage: Mutex<Bool>

    init(_ value: Bool) {
        storage = Mutex(value)
    }

    var value: Bool {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

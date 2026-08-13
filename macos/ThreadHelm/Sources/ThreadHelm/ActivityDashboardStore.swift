import Foundation

final class ActivityDashboardStore {
    typealias Observer = (ActivityDashboardSnapshot) -> Void

    private(set) var snapshot: ActivityDashboardSnapshot
    private var observers: [UUID: Observer] = [:]

    init(snapshot: ActivityDashboardSnapshot = ActivityDashboardSnapshot()) {
        self.snapshot = snapshot
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        precondition(Thread.isMainThread)
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: token)
    }

    func update(_ mutation: (inout ActivityDashboardSnapshot) -> Void) {
        precondition(Thread.isMainThread)
        let previous = snapshot
        mutation(&snapshot)
        guard snapshot != previous else { return }
        for observer in observers.values {
            observer(snapshot)
        }
    }
}

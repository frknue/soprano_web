import AppKit

/// The change observers of one store. Every window subscribes with
/// `observe` and keeps the returned token; the handler runs on every
/// `notify` until the token is cancelled or released. Handlers capture
/// their owner weakly, so a store never keeps a window alive.
@MainActor
final class BrowserObservers<Value> {
    private struct Entry {
        weak var token: BrowserObservation?
        let handler: (Value) -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Subscription order, so observers run in the order they subscribed.
    private var order: [ObjectIdentifier] = []

    init() {}

    /// Live subscriptions.
    var count: Int {
        entries.values.filter { $0.token != nil }.count
    }

    func observe(_ handler: @escaping (Value) -> Void) -> BrowserObservation {
        let token = BrowserObservation()
        let key = ObjectIdentifier(token)
        entries[key] = Entry(token: token, handler: handler)
        order.append(key)
        token.onCancel = { [weak self] in self?.remove(key) }
        return token
    }

    func notify(_ value: Value) {
        for key in order {
            guard let entry = entries[key] else { continue }
            guard entry.token != nil else {
                // Released without `cancel()`.
                remove(key)
                continue
            }
            entry.handler(value)
        }
    }

    private func remove(_ key: ObjectIdentifier) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }
}

extension BrowserObservers where Value == Void {
    func notify() {
        notify(())
    }
}

/// One subscription to a `BrowserObservers`. Cancel it, or release it, to
/// stop the handler.
@MainActor
final class BrowserObservation {
    fileprivate var onCancel: (() -> Void)?

    fileprivate init() {}

    func cancel() {
        let onCancel = onCancel
        self.onCancel = nil
        onCancel?()
    }
}

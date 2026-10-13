// SPDX-License-Identifier: MIT OR Apache-2.0
// NotificationCenter.notifications(named:object:): a center's notifications as an
// async sequence (Apple's overlay API since macOS 12). The sequence observes from
// the moment it's made and keeps what's posted until an iterator takes it; the
// observer goes when the sequence does. As Apple's, the iterator's next() isn't
// mutating, so iterators share the sequence's buffer.

extension NotificationCenter {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func notifications(named name: Notification.Name, object: AnyObject? = nil) -> Notifications {
        Notifications(center: self, name: name, object: object)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public final class Notifications: AsyncSequence, @unchecked Sendable {
        public typealias Element = Notification

        private let center: NotificationCenter
        private var token: NSObjectProtocol?
        fileprivate let buffer = _Buffer()

        fileprivate init(center: NotificationCenter, name: Notification.Name, object: AnyObject?) {
            self.center = center
            let buffer = self.buffer
            token = center.addObserver(forName: name, object: object, queue: nil) { buffer.post($0) }
        }

        deinit {
            if let token { center.removeObserver(token) }
            buffer.finish()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        public struct Iterator: AsyncIteratorProtocol {
            public typealias Element = Notification
            fileprivate let sequence: Notifications

            public func next() async -> Notification? {
                await sequence.buffer.take()
            }
        }

        public __consuming func makeAsyncIterator() -> Iterator {
            Iterator(sequence: self)
        }

        /// What's been posted and not yet taken, and the tasks waiting for more.
        fileprivate final class _Buffer: @unchecked Sendable {
            private let lock = NSLock()
            private var pending: [Notification] = []
            private var waiting: [CheckedContinuation<Notification?, Never>] = []
            private var finished = false

            func post(_ n: Notification) {
                lock.lock()
                if !waiting.isEmpty {
                    let c = waiting.removeFirst()
                    lock.unlock()
                    c.resume(returning: n)
                    return
                }
                pending.append(n)
                lock.unlock()
            }

            func finish() {
                lock.lock()
                finished = true
                let all = waiting
                waiting = []
                lock.unlock()
                for c in all { c.resume(returning: nil) }
            }

            func take() async -> Notification? {
                await withCheckedContinuation { (c: CheckedContinuation<Notification?, Never>) in
                    lock.lock()
                    if !pending.isEmpty {
                        let n = pending.removeFirst()
                        lock.unlock()
                        c.resume(returning: n)
                    } else if finished || Task.isCancelled {
                        lock.unlock()
                        c.resume(returning: nil)
                    } else {
                        waiting.append(c)
                        lock.unlock()
                    }
                }
            }
        }
    }
}

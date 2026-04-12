//! Queue — point-to-point. One producer, one consumer. The atom.

use crossbeam::channel::{self, Receiver, Sender, TryRecvError};
use std::fmt;

/// Error returned when sending fails (receiver dropped).
#[derive(Debug, PartialEq, Eq)]
pub struct SendError<T>(pub T);

impl<T> fmt::Display for SendError<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "sending on a disconnected queue")
    }
}

/// Error returned when receiving fails (sender dropped, queue empty).
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum RecvError {
    Disconnected,
}

impl fmt::Display for RecvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "receiving on a disconnected queue")
    }
}

/// The producer's handle.
pub struct QueueSender<T>(Sender<T>);

/// The consumer's handle.
pub struct QueueReceiver<T>(Receiver<T>);

impl<T> QueueSender<T> {
    /// Send a value. Blocks if bounded and full.
    pub fn send(&self, value: T) -> Result<(), SendError<T>> {
        self.0.send(value).map_err(|e| SendError(e.0))
    }
}

impl<T> QueueReceiver<T> {
    /// Blocking receive. Returns Disconnected when sender is dropped and queue is empty.
    pub fn recv(&self) -> Result<T, RecvError> {
        self.0.recv().map_err(|_| RecvError::Disconnected)
    }

    /// Non-blocking receive. Returns the crossbeam TryRecvError directly —
    /// Empty (no message yet) or Disconnected (sender dropped). Not wrapped
    /// because try_recv is used internally by composing programs (cache select
    /// loops) where the crossbeam type is already in scope.
    pub fn try_recv(&self) -> Result<T, TryRecvError> {
        self.0.try_recv()
    }

    /// Access the underlying crossbeam receiver. Used by composing programs
    /// (cache, mailbox) that need crossbeam::Select across multiple receivers.
    /// pub(crate) — only visible within this crate, not to external consumers.
    pub(crate) fn inner(&self) -> &Receiver<T> {
        &self.0
    }
}

/// Create a bounded queue. Sender blocks when capacity is reached.
pub fn queue_bounded<T>(capacity: usize) -> (QueueSender<T>, QueueReceiver<T>) {
    let (tx, rx) = channel::bounded(capacity);
    (QueueSender(tx), QueueReceiver(rx))
}

/// Create an unbounded queue. No backpressure.
pub fn queue_unbounded<T>() -> (QueueSender<T>, QueueReceiver<T>) {
    let (tx, rx) = channel::unbounded();
    (QueueSender(tx), QueueReceiver(rx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn send_and_receive_one_message() {
        let (tx, rx) = queue_unbounded();
        tx.send(42).unwrap();
        assert_eq!(rx.recv().unwrap(), 42);
    }

    #[test]
    fn multiple_messages_in_order() {
        let (tx, rx) = queue_unbounded();
        for i in 0..100 {
            tx.send(i).unwrap();
        }
        for i in 0..100 {
            assert_eq!(rx.recv().unwrap(), i);
        }
    }

    #[test]
    fn bounded_backpressure() {
        let (tx, rx) = queue_bounded(2);
        tx.send(1).unwrap();
        tx.send(2).unwrap();

        // Sender should block — spawn a thread to unblock it.
        let handle = thread::spawn(move || {
            tx.send(3).unwrap(); // blocks until space available
        });

        thread::sleep(Duration::from_millis(50));
        assert_eq!(rx.recv().unwrap(), 1); // frees one slot
        handle.join().unwrap();
        assert_eq!(rx.recv().unwrap(), 2);
        assert_eq!(rx.recv().unwrap(), 3);
    }

    #[test]
    fn shutdown_sender_dropped() {
        let (tx, rx) = queue_unbounded::<i32>();
        drop(tx);
        assert_eq!(rx.recv(), Err(RecvError::Disconnected));
    }
}

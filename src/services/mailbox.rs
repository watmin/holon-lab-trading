//! Mailbox — fan-in. N producers, one consumer.
//! Multiple senders clone the tx. One receiver reads all.

use crossbeam::channel::{self, Receiver, Sender, TryRecvError};
use std::fmt;

/// Error returned when sending to a mailbox fails (receiver dropped).
#[derive(Debug, PartialEq, Eq)]
pub struct SendError<T>(pub T);

impl<T> fmt::Display for SendError<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "sending on a disconnected mailbox")
    }
}

/// Error returned when receiving from a mailbox fails.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum RecvError {
    Disconnected,
}

impl fmt::Display for RecvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "receiving on a disconnected mailbox")
    }
}

/// A producer's handle. Cloneable — each producer gets its own clone.
#[derive(Clone)]
pub struct MailboxSender<T>(Sender<T>);

/// The single consumer's handle.
pub struct MailboxReceiver<T>(Receiver<T>);

impl<T> MailboxSender<T> {
    /// Send a value to the mailbox.
    pub fn send(&self, value: T) -> Result<(), SendError<T>> {
        self.0.send(value).map_err(|e| SendError(e.0))
    }
}

impl<T> MailboxReceiver<T> {
    /// Blocking receive. Returns Disconnected when all senders are dropped.
    pub fn recv(&self) -> Result<T, RecvError> {
        self.0.recv().map_err(|_| RecvError::Disconnected)
    }

    /// Non-blocking receive.
    pub fn try_recv(&self) -> Result<T, TryRecvError> {
        self.0.try_recv()
    }
}

/// Create an unbounded mailbox. The sender is cloneable for N producers.
pub fn mailbox_unbounded<T: Send + 'static>() -> (MailboxSender<T>, MailboxReceiver<T>) {
    let (tx, rx) = channel::unbounded();
    (MailboxSender(tx), MailboxReceiver(rx))
}

/// Create a bounded mailbox. The sender is cloneable for N producers.
pub fn mailbox_bounded<T: Send + 'static>(capacity: usize) -> (MailboxSender<T>, MailboxReceiver<T>) {
    let (tx, rx) = channel::bounded(capacity);
    (MailboxSender(tx), MailboxReceiver(rx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::thread;

    #[test]
    fn multiple_senders_one_receiver() {
        let (tx, rx) = mailbox_unbounded();

        let tx2 = tx.clone();
        let tx3 = tx.clone();

        tx.send(1).unwrap();
        tx2.send(2).unwrap();
        tx3.send(3).unwrap();

        let mut received = HashSet::new();
        received.insert(rx.recv().unwrap());
        received.insert(rx.recv().unwrap());
        received.insert(rx.recv().unwrap());

        assert_eq!(received, HashSet::from([1, 2, 3]));
    }

    #[test]
    fn messages_from_different_threads_interleave() {
        let (tx, rx) = mailbox_unbounded();

        let handles: Vec<_> = (0..5)
            .map(|i| {
                let sender = tx.clone();
                thread::spawn(move || {
                    for j in 0..10 {
                        sender.send(i * 100 + j).unwrap();
                    }
                })
            })
            .collect();

        // Drop original sender so only thread senders remain.
        drop(tx);

        for h in handles {
            h.join().unwrap();
        }

        // Collect all 50 messages.
        let mut received = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            received.push(msg);
        }
        assert_eq!(received.len(), 50);

        // All expected values present.
        let set: HashSet<_> = received.into_iter().collect();
        for i in 0..5 {
            for j in 0..10 {
                assert!(set.contains(&(i * 100 + j)));
            }
        }
    }

    #[test]
    fn shutdown_all_senders_dropped() {
        let (tx, rx) = mailbox_unbounded::<i32>();
        let tx2 = tx.clone();
        drop(tx);
        drop(tx2);
        assert_eq!(rx.recv(), Err(RecvError::Disconnected));
    }
}

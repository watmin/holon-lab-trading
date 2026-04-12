//! Topic — fan-out. One producer, N consumers.
//! The producer writes once. All consumers receive a clone.

use crossbeam::channel::{self, Receiver, Sender, TryRecvError};
use std::fmt;
use std::thread;

/// Error returned when sending to a topic fails (fan-out thread exited).
#[derive(Debug, PartialEq, Eq)]
pub struct SendError<T>(pub T);

impl<T> fmt::Display for SendError<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "sending on a disconnected topic")
    }
}

/// Error returned when receiving from a topic fails.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum RecvError {
    Disconnected,
}

impl fmt::Display for RecvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "receiving on a disconnected topic")
    }
}

/// The producer's handle.
pub struct TopicSender<T>(Sender<T>);

/// A consumer's handle.
pub struct TopicReceiver<T>(Receiver<T>);

/// Handle to the fan-out thread. Dropping this does NOT stop the thread —
/// the thread exits when the sender is dropped.
pub struct TopicHandle {
    _handle: thread::JoinHandle<()>,
}

impl<T: Send + Clone + 'static> TopicSender<T> {
    /// Send a value to all subscribers.
    pub fn send(&self, value: T) -> Result<(), SendError<T>> {
        self.0.send(value).map_err(|e| SendError(e.0))
    }
}

impl<T> TopicReceiver<T> {
    /// Blocking receive.
    pub fn recv(&self) -> Result<T, RecvError> {
        self.0.recv().map_err(|_| RecvError::Disconnected)
    }

    /// Non-blocking receive.
    pub fn try_recv(&self) -> Result<T, TryRecvError> {
        self.0.try_recv()
    }
}

/// Create a bounded topic with a fixed number of subscribers.
/// Spawns a fan-out thread that reads from the internal channel and
/// sends a clone to each subscriber's channel.
///
/// Returns (sender, receivers, handle). The handle keeps the thread alive.
/// Dropping the sender causes all receivers to eventually get Disconnected.
pub fn topic_bounded<T: Send + Clone + 'static>(
    capacity: usize,
    num_subscribers: usize,
) -> (TopicSender<T>, Vec<TopicReceiver<T>>, TopicHandle) {
    let (in_tx, in_rx) = channel::bounded::<T>(capacity);

    let mut receivers = Vec::with_capacity(num_subscribers);
    let mut out_txs = Vec::with_capacity(num_subscribers);

    for _ in 0..num_subscribers {
        let (tx, rx) = channel::bounded(capacity);
        out_txs.push(tx);
        receivers.push(TopicReceiver(rx));
    }

    let handle = thread::spawn(move || {
        while let Ok(msg) = in_rx.recv() {
            for tx in &out_txs {
                // If a subscriber has disconnected, skip it.
                let _ = tx.send(msg.clone());
            }
        }
        // Sender dropped — out_txs drop here, causing receivers to disconnect.
    });

    (
        TopicSender(in_tx),
        receivers,
        TopicHandle { _handle: handle },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_message_reaches_all_subscribers() {
        let (tx, receivers, _handle) = topic_bounded(16, 3);
        tx.send(99).unwrap();

        for rx in &receivers {
            assert_eq!(rx.recv().unwrap(), 99);
        }
    }

    #[test]
    fn n_messages_in_order_for_each_subscriber() {
        let (tx, receivers, _handle) = topic_bounded(64, 4);

        let count = 50;
        let send_handle = std::thread::spawn(move || {
            for i in 0..count {
                tx.send(i).unwrap();
            }
        });

        for rx in &receivers {
            for i in 0..count {
                assert_eq!(rx.recv().unwrap(), i);
            }
        }

        send_handle.join().unwrap();
    }

    #[test]
    fn shutdown_sender_dropped() {
        let (tx, receivers, _handle) = topic_bounded::<i32>(16, 2);
        drop(tx);

        for rx in &receivers {
            assert_eq!(rx.recv(), Err(RecvError::Disconnected));
        }
    }
}

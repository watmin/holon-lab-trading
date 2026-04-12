//! Topic — fan-out. One producer, N consumers.
//! COMPOSED of queues. One input queue, N output queues.
//! The producer writes to the input queue. The fan-out thread
//! reads from it and sends a clone to each output queue.

use std::thread;

use crate::services::queue::{self, QueueSender, QueueReceiver};

/// The producer's handle — a queue sender.
pub struct TopicSender<T>(QueueSender<T>);

/// A consumer's handle — a queue receiver.
pub struct TopicReceiver<T>(QueueReceiver<T>);

/// Handle to the fan-out thread. The thread exits when the
/// producer drops its sender (the input queue disconnects).
pub struct TopicHandle {
    _thread: thread::JoinHandle<()>,
}

impl<T: Send + Clone + 'static> TopicSender<T> {
    /// Send a value to all subscribers.
    pub fn send(&self, value: T) -> Result<(), queue::SendError<T>> {
        self.0.send(value)
    }
}

impl<T> TopicReceiver<T> {
    /// Blocking receive.
    pub fn recv(&self) -> Result<T, queue::RecvError> {
        self.0.recv()
    }

    /// Non-blocking receive.
    pub fn try_recv(&self) -> Result<T, crossbeam::channel::TryRecvError> {
        self.0.try_recv()
    }
}

/// Create a bounded topic with a fixed number of subscribers.
/// Composed of queues: one input queue (bounded), N output queues (bounded).
/// Spawns a fan-out thread that reads from the input and clones to all outputs.
///
/// Returns (sender, receivers, handle).
/// Dropping the sender causes all receivers to eventually get Disconnected.
pub fn topic_bounded<T: Send + Clone + 'static>(
    capacity: usize,
    num_subscribers: usize,
) -> (TopicSender<T>, Vec<TopicReceiver<T>>, TopicHandle) {
    // Input queue — the producer writes here
    let (in_tx, in_rx) = queue::queue_bounded::<T>(capacity);

    // Output queues — one per subscriber
    let mut out_txs = Vec::with_capacity(num_subscribers);
    let mut receivers = Vec::with_capacity(num_subscribers);
    for _ in 0..num_subscribers {
        let (tx, rx) = queue::queue_bounded(capacity);
        out_txs.push(tx);
        receivers.push(TopicReceiver(rx));
    }

    // Fan-out thread: read from input, clone to all outputs
    let handle = thread::spawn(move || {
        while let Ok(msg) = in_rx.recv() {
            for tx in &out_txs {
                // If a subscriber disconnected, skip it.
                let _ = tx.send(msg.clone());
            }
        }
        // Input disconnected (producer dropped sender).
        // out_txs drop here → all subscriber queues close → cascade.
    });

    (
        TopicSender(in_tx),
        receivers,
        TopicHandle { _thread: handle },
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
            assert!(rx.recv().is_err());
        }
    }
}

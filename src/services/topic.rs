//! Topic — fan-out. One producer, N consumers.
//! A proxy that writes to N queues. The queues already exist.
//! The kernel creates the queues. The kernel gives the read ends
//! to the programs. The kernel gives the write ends to the topic.
//! The topic is plumbing. The programs see queues. Only queues.

use std::thread;

use crate::services::queue::{self, QueueSender};

/// The producer's proxy — write here, the topic clones to N queues.
/// .send() — same interface as a queue.
pub struct TopicSender<T> {
    tx: QueueSender<T>,
}

/// Handle to the fan-out thread. The thread exits when the
/// producer drops its sender (the input queue disconnects).
pub struct TopicHandle {
    _thread: thread::JoinHandle<()>,
}

impl<T: Send + Clone + 'static> TopicSender<T> {
    /// Send a value to all subscribers.
    pub fn send(&self, value: T) -> Result<(), queue::SendError<T>> {
        self.tx.send(value)
    }
}

/// Create a topic from existing queue senders.
/// The kernel already created the queues. The kernel already gave
/// the receivers to the programs. The topic takes the write ends
/// and fans out to all of them.
///
/// Returns (sender, handle).
/// The sender is the proxy — .send() writes to all queues.
/// Dropping the sender causes all downstream queues to eventually
/// get Disconnected (the fan-out thread exits, dropping the queue senders).
pub fn topic<T: Send + Clone + 'static>(
    capacity: usize,
    outputs: Vec<QueueSender<T>>,
) -> (TopicSender<T>, TopicHandle) {
    // Input queue — the producer writes here, the fan-out thread reads
    let (in_tx, in_rx) = queue::queue_bounded::<T>(capacity);

    // Fan-out thread: read from input, clone to all outputs
    let handle = thread::spawn(move || {
        while let Ok(msg) = in_rx.recv() {
            for tx in &outputs {
                // Bounded send: blocks if this subscriber's queue is full.
                // One slow subscriber stalls all others — intentional
                // backpressure propagation. If a subscriber disconnected,
                // the error is ignored (skipped).
                let _ = tx.send(msg.clone());
            }
        }
        // Input disconnected (producer dropped sender).
        // outputs drop here → all subscriber queues close → cascade.
    });

    (
        TopicSender { tx: in_tx },
        TopicHandle { _thread: handle },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::queue;

    #[test]
    fn one_message_reaches_all_subscribers() {
        // Kernel creates the queues
        let (out_tx_0, out_rx_0) = queue::queue_bounded(16);
        let (out_tx_1, out_rx_1) = queue::queue_bounded(16);
        let (out_tx_2, out_rx_2) = queue::queue_bounded(16);

        // Topic takes the write ends
        let (tx, _handle) = topic(16, vec![out_tx_0, out_tx_1, out_tx_2]);

        tx.send(99).unwrap();

        // Programs hold the read ends — just queues
        assert_eq!(out_rx_0.recv().unwrap(), 99);
        assert_eq!(out_rx_1.recv().unwrap(), 99);
        assert_eq!(out_rx_2.recv().unwrap(), 99);
    }

    #[test]
    fn n_messages_in_order_for_each_subscriber() {
        let mut out_txs = Vec::new();
        let mut out_rxs = Vec::new();
        for _ in 0..4 {
            let (tx, rx) = queue::queue_bounded(64);
            out_txs.push(tx);
            out_rxs.push(rx);
        }

        let (tx, _handle) = topic(64, out_txs);

        let count = 50;
        let send_handle = std::thread::spawn(move || {
            for i in 0..count {
                tx.send(i).unwrap();
            }
        });

        for rx in &out_rxs {
            for i in 0..count {
                assert_eq!(rx.recv().unwrap(), i);
            }
        }

        send_handle.join().unwrap();
    }

    #[test]
    fn shutdown_sender_dropped() {
        let (out_tx_0, out_rx_0) = queue::queue_bounded::<i32>(16);
        let (out_tx_1, out_rx_1) = queue::queue_bounded::<i32>(16);

        let (tx, _handle) = topic(16, vec![out_tx_0, out_tx_1]);
        drop(tx);

        assert!(out_rx_0.recv().is_err());
        assert!(out_rx_1.recv().is_err());
    }
}

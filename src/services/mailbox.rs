//! Mailbox — fan-in. N producers, one consumer.
//! Composed of N independent queues. Each producer gets its OWN sender
//! (contention-free). A fan-in thread selects across N receivers and
//! forwards to one output.

use crate::services::queue::{queue_unbounded, QueueReceiver, QueueSender};
use crossbeam::channel::TryRecvError;
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

/// A producer's handle. NOT cloneable — each producer gets its OWN.
pub struct MailboxSender<T>(QueueSender<T>);

/// The single consumer's handle.
pub struct MailboxReceiver<T>(QueueReceiver<T>);

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

/// Create a mailbox with N independent input queues.
/// Returns N senders (one per producer, contention-free) and one receiver.
/// Spawns a thread that selects across N queue receivers and forwards
/// to the output.
pub fn mailbox<T: Send + 'static>(
    num_producers: usize,
) -> (Vec<MailboxSender<T>>, MailboxReceiver<T>) {
    assert!(num_producers > 0, "mailbox requires at least one producer");

    // Create N input queues — one per producer.
    let mut senders = Vec::with_capacity(num_producers);
    let mut input_rxs = Vec::with_capacity(num_producers);
    for _ in 0..num_producers {
        let (tx, rx) = queue_unbounded();
        senders.push(MailboxSender(tx));
        input_rxs.push(rx);
    }

    // Create one output queue — the consumer reads from this.
    let (out_tx, out_rx) = queue_unbounded();

    // Spawn the fan-in thread — selects across N input receivers.
    std::thread::spawn(move || {
        let mut alive: Vec<QueueReceiver<T>> = input_rxs;
        loop {
            if alive.is_empty() {
                break;
            }
            let mut sel = crossbeam::channel::Select::new();
            for rx in &alive {
                sel.recv(rx.inner());
            }
            let oper = sel.select();
            let idx = oper.index();
            match oper.recv(alive[idx].inner()) {
                Ok(msg) => {
                    // If the consumer (MailboxReceiver) dropped, the send
                    // fails silently. Messages are discarded. Producers
                    // receive no signal — they keep sending until they
                    // themselves drop. This is intentional: the fan-in
                    // thread's lifecycle is governed by its INPUTS, not
                    // its output. When all inputs disconnect, the thread
                    // exits and the output drops.
                    let _ = out_tx.send(msg);
                }
                Err(_) => {
                    alive.remove(idx); // this input disconnected
                }
            }
        }
        // All inputs disconnected. out_tx drops. Consumer sees Disconnected.
    });

    (senders, MailboxReceiver(out_rx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn multiple_senders_one_receiver() {
        let (senders, rx) = mailbox(3);
        let mut senders = senders;

        let s0 = senders.pop().unwrap();
        let s1 = senders.pop().unwrap();
        let s2 = senders.pop().unwrap();

        s0.send(1).unwrap();
        s1.send(2).unwrap();
        s2.send(3).unwrap();

        let mut received = HashSet::new();
        for _ in 0..3 {
            received.insert(rx.recv().unwrap());
        }

        assert_eq!(received, HashSet::from([1, 2, 3]));
    }

    #[test]
    fn messages_from_different_threads_interleave() {
        let (senders, rx) = mailbox(5);

        let handles: Vec<_> = senders
            .into_iter()
            .enumerate()
            .map(|(i, sender)| {
                thread::spawn(move || {
                    for j in 0..10 {
                        sender.send(i * 100 + j).unwrap();
                    }
                })
            })
            .collect();

        for h in handles {
            h.join().unwrap();
        }

        // Collect all 50 messages.
        // Give the fan-in thread a moment to forward everything.
        thread::sleep(Duration::from_millis(50));
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
        let (senders, rx) = mailbox::<i32>(3);
        drop(senders);
        assert_eq!(rx.recv(), Err(RecvError::Disconnected));
    }

    #[test]
    fn partial_sender_drop_still_works() {
        let (mut senders, rx) = mailbox(3);

        let s0 = senders.pop().unwrap();
        let s1 = senders.pop().unwrap();
        let s2 = senders.pop().unwrap();

        // Drop two senders, the third should still work.
        drop(s0);
        drop(s1);

        s2.send(42).unwrap();
        assert_eq!(rx.recv().unwrap(), 42);

        // Now drop the last sender — receiver should see Disconnected.
        drop(s2);
        assert_eq!(rx.recv(), Err(RecvError::Disconnected));
    }
}

//! Mailbox — fan-in. N producers, one consumer.
//! A proxy that reads from N queues. The queues already exist.
//! The kernel creates the queues. The kernel gives the write ends
//! to the programs. The kernel gives the read ends to the mailbox.
//! The mailbox is plumbing. The programs see queues. Only queues.

use crate::services::queue::QueueReceiver;
use crossbeam::channel::TryRecvError;
use std::fmt;

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

/// The single consumer's read proxy. Fans in from N queues.
/// .recv() — same interface as a queue receiver.
pub struct MailboxReceiver<T>(QueueReceiver<T>);

impl<T> MailboxReceiver<T> {
    /// Blocking receive. Returns Disconnected when all producers are dropped.
    pub fn recv(&self) -> Result<T, RecvError> {
        self.0.recv().map_err(|_| RecvError::Disconnected)
    }

    /// Non-blocking receive. Returns crossbeam TryRecvError directly —
    /// see queue.rs for rationale.
    pub fn try_recv(&self) -> Result<T, TryRecvError> {
        self.0.try_recv()
    }
}

/// Create a mailbox from existing queue receivers.
/// The kernel already created the queues. The kernel already gave
/// the senders to the programs. The mailbox takes the read ends
/// and fans them into one receiver.
///
/// Returns a MailboxReceiver — the read proxy.
/// Spawns a fan-in thread that selects across N queue receivers.
/// The thread exits when all input queues disconnect.
pub fn mailbox<T: Send + 'static>(
    inputs: Vec<QueueReceiver<T>>,
) -> MailboxReceiver<T> {
    assert!(!inputs.is_empty(), "mailbox requires at least one input");

    // One output queue — the consumer reads from this.
    let (out_tx, out_rx) = crate::services::queue::queue_bounded(64);

    // Spawn the fan-in thread — selects across N input receivers.
    std::thread::spawn(move || {
        let mut alive: Vec<QueueReceiver<T>> = inputs;
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
                    let _ = out_tx.send(msg);
                }
                Err(_) => {
                    alive.remove(idx);
                }
            }
        }
        // All inputs disconnected. out_tx drops. Consumer sees Disconnected.
    });

    MailboxReceiver(out_rx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::queue::queue_unbounded;
    use std::collections::HashSet;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn multiple_senders_one_receiver() {
        // Kernel creates the queues
        let (tx0, rx0) = queue_unbounded();
        let (tx1, rx1) = queue_unbounded();
        let (tx2, rx2) = queue_unbounded();

        // Mailbox takes the read ends
        let mailbox_rx = mailbox(vec![rx0, rx1, rx2]);

        // Programs hold queue senders — just queues
        tx0.send(1).unwrap();
        tx1.send(2).unwrap();
        tx2.send(3).unwrap();

        let mut received = HashSet::new();
        for _ in 0..3 {
            received.insert(mailbox_rx.recv().unwrap());
        }

        assert_eq!(received, HashSet::from([1, 2, 3]));
    }

    #[test]
    fn messages_from_different_threads_interleave() {
        let mut txs = Vec::new();
        let mut rxs = Vec::new();
        for _ in 0..5 {
            let (tx, rx) = queue_unbounded();
            txs.push(tx);
            rxs.push(rx);
        }

        let mailbox_rx = mailbox(rxs);

        let handles: Vec<_> = txs
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
        thread::sleep(Duration::from_millis(50));
        let mut received = Vec::new();
        while let Ok(msg) = mailbox_rx.try_recv() {
            received.push(msg);
        }
        assert_eq!(received.len(), 50);

        let set: HashSet<_> = received.into_iter().collect();
        for i in 0..5 {
            for j in 0..10 {
                assert!(set.contains(&(i * 100 + j)));
            }
        }
    }

    #[test]
    fn shutdown_all_senders_dropped() {
        let (tx0, rx0) = queue_unbounded::<i32>();
        let (tx1, rx1) = queue_unbounded::<i32>();
        let (tx2, rx2) = queue_unbounded::<i32>();

        let mailbox_rx = mailbox(vec![rx0, rx1, rx2]);

        drop(tx0);
        drop(tx1);
        drop(tx2);

        assert_eq!(mailbox_rx.recv(), Err(RecvError::Disconnected));
    }

    #[test]
    fn partial_sender_drop_still_works() {
        let (tx0, rx0) = queue_unbounded();
        let (tx1, rx1) = queue_unbounded();
        let (tx2, rx2) = queue_unbounded();

        let mailbox_rx = mailbox(vec![rx0, rx1, rx2]);

        // Drop two senders, the third should still work.
        drop(tx0);
        drop(tx1);

        tx2.send(42).unwrap();
        assert_eq!(mailbox_rx.recv().unwrap(), 42);

        // Now drop the last sender — receiver should see Disconnected.
        drop(tx2);
        assert_eq!(mailbox_rx.recv(), Err(RecvError::Disconnected));
    }
}

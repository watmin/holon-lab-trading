//! Console — serialized concurrent output. A program, not a service.
//! Composed from the mailbox core service.
//!
//! N producers, one consumer thread. Each producer gets a ConsoleHandle
//! with `.out()` and `.err()` methods. The console driver is the ONLY
//! thing that touches stdout/stderr. No garbled text. No locks.
//! Pure mailbox serialization. The ownership IS the control.

use std::collections::VecDeque;
use std::io::{self, Write};
use std::thread;

use crate::services::mailbox;
use crate::services::queue::{self, QueueSender};

/// Tagged message — Out goes to stdout, Err goes to stderr.
/// Internal protocol. Not public — only ConsoleHandle is the interface.
enum ConsoleMsg {
    Out(String),
    Err(String),
}

/// A program's handle to the console. Each program gets its own pair.
/// Not cloneable — one per program.
pub struct ConsoleHandle {
    out_tx: QueueSender<ConsoleMsg>,
    err_tx: QueueSender<ConsoleMsg>,
}

impl ConsoleHandle {
    /// Fire-and-forget to stdout.
    pub fn out(&self, msg: String) {
        let _ = self.out_tx.send(ConsoleMsg::Out(msg));
    }

    /// Fire-and-forget to stderr.
    pub fn err(&self, msg: String) {
        let _ = self.err_tx.send(ConsoleMsg::Err(msg));
    }
}

/// Handle to the console driver thread for lifecycle management.
///
/// No Drop impl — drop order is unspecified, so joining in Drop
/// would deadlock if senders are still alive. The cascade IS the
/// shutdown guarantee: senders drop → driver drains → driver exits.
/// Call join() explicitly when you need to wait for the driver.
pub struct ConsoleDriverHandle {
    thread: Option<thread::JoinHandle<()>>,
}

impl ConsoleDriverHandle {
    /// Block until the driver thread exits. The driver exits when
    /// all client handles are dropped.
    pub fn join(mut self) {
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

/// Create a console with the given number of producers.
///
/// Returns N ConsoleHandles (one per program) and a ConsoleDriverHandle.
/// The driver thread exits when all client handles are dropped.
///
/// The mailbox has `num_producers * 2` senders — two per program.
/// Even indices are stdout senders, odd indices are stderr senders.
pub fn console(num_producers: usize) -> (Vec<ConsoleHandle>, ConsoleDriverHandle) {
    assert!(num_producers > 0, "console requires at least one producer");

    // Create queues: two per producer (stdout + stderr).
    // Mailbox gets the receivers. Programs get the senders.
    let total = num_producers * 2;
    let mut senders = VecDeque::with_capacity(total);
    let mut receivers = Vec::with_capacity(total);
    for _ in 0..total {
        let (tx, rx) = queue::queue_unbounded::<ConsoleMsg>();
        senders.push_back(tx);
        receivers.push(rx);
    }
    let rx = mailbox::mailbox(receivers);

    let mut handles = Vec::with_capacity(num_producers);
    for _ in 0..num_producers {
        let out_tx = senders.pop_front().unwrap();
        let err_tx = senders.pop_front().unwrap();
        handles.push(ConsoleHandle { out_tx, err_tx });
    }

    let thread = thread::spawn(move || {
        loop {
            match rx.recv() {
                Ok(ConsoleMsg::Out(msg)) => {
                    writeln!(io::stdout(), "{}", msg).ok();
                    io::stdout().flush().ok();
                }
                Ok(ConsoleMsg::Err(msg)) => {
                    writeln!(io::stderr(), "{}", msg).ok();
                    io::stderr().flush().ok();
                }
                Err(_) => break, // all senders dropped
            }
        }
    });

    (
        handles,
        ConsoleDriverHandle {
            thread: Some(thread),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn out_send_does_not_panic() {
        let (handles, driver) = console(1);
        handles[0].out("hello stdout".to_string());
        drop(handles);
        driver.join();
    }

    #[test]
    fn err_send_does_not_panic() {
        let (handles, driver) = console(1);
        handles[0].err("hello stderr".to_string());
        drop(handles);
        driver.join();
    }

    #[test]
    fn multiple_producers_concurrent() {
        let (handles, driver) = console(4);
        let threads: Vec<_> = handles
            .into_iter()
            .enumerate()
            .map(|(i, h)| {
                thread::spawn(move || {
                    for n in 0..100 {
                        h.out(format!("producer {} msg {}", i, n));
                    }
                })
            })
            .collect();

        for t in threads {
            t.join().unwrap();
        }
        // All handles dropped via moves into threads — driver will exit.
        driver.join();
    }

    #[test]
    fn shutdown_all_handles_dropped_driver_exits() {
        let (handles, driver) = console(3);
        drop(handles);
        // If the driver hangs, this test hangs — that IS the failure signal.
        driver.join();
    }

    #[test]
    fn interleaved_out_and_err_no_panic() {
        let (handles, driver) = console(2);
        let threads: Vec<_> = handles
            .into_iter()
            .map(|h| {
                thread::spawn(move || {
                    for n in 0..50 {
                        if n % 2 == 0 {
                            h.out(format!("out {}", n));
                        } else {
                            h.err(format!("err {}", n));
                        }
                    }
                })
            })
            .collect();

        for t in threads {
            t.join().unwrap();
        }
        driver.join();
    }
}

/// HandlePool — guard against orphaned handles.
///
/// Pop handles as you wire. Call finish() when done.
/// If any remain, finish() panics at wiring time — not at
/// deadlock time. Orphaned handles on mailbox-backed drivers
/// cause the driver to wait forever for inputs that never
/// disconnect. The pool catches this at construction.

/// A pool of handles. Pop them as you wire. Finish when done.
pub struct HandlePool<T> {
    name: String,
    handles: Vec<T>,
}

impl<T> HandlePool<T> {
    /// Create a pool with a name (for diagnostics) and handles.
    pub fn new(name: impl Into<String>, handles: Vec<T>) -> Self {
        Self {
            name: name.into(),
            handles,
        }
    }

    /// Claim one handle. Panics if the pool is empty.
    pub fn pop(&mut self) -> T {
        self.handles
            .pop()
            .unwrap_or_else(|| panic!("{}: no handles left to claim", self.name))
    }

    /// Assert all handles were claimed. Panics if any remain.
    /// Call this after wiring is complete. An orphaned handle
    /// is a deadlock waiting to happen.
    pub fn finish(self) {
        assert!(
            self.handles.is_empty(),
            "{}: {} orphaned handle(s) — deadlock risk",
            self.name,
            self.handles.len()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pop_all_then_finish() {
        let mut pool = HandlePool::new("test", vec![1, 2, 3]);
        assert_eq!(pool.pop(), 3);
        assert_eq!(pool.pop(), 2);
        assert_eq!(pool.pop(), 1);
        pool.finish(); // no panic
    }

    #[test]
    #[should_panic(expected = "no handles left to claim")]
    fn pop_from_empty_panics() {
        let mut pool: HandlePool<i32> = HandlePool::new("test", vec![]);
        pool.pop();
    }

    #[test]
    #[should_panic(expected = "orphaned handle(s)")]
    fn finish_with_remaining_panics() {
        let pool = HandlePool::new("test", vec![1, 2]);
        pool.finish(); // 2 orphaned — panics
    }

    #[test]
    fn partial_pop_then_finish_panics() {
        let mut pool = HandlePool::new("test", vec![1, 2, 3]);
        let _ = pool.pop(); // claim one
        let result = std::panic::catch_unwind(move || pool.finish());
        assert!(result.is_err()); // 2 orphaned
    }
}

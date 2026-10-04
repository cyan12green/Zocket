// Coverage-runner stubs: `export`ed no-op implementations of the
// test-runner↔libfuzzer ABI (`runner_*`) so that a `-ffuzz` (sancov)
// binary WITH a main function links. They are never called — libfuzzer's
// `fuzzer_main` never runs in the server binary; only the inline 8-bit
// counters and the zig-cov atexit writer are live. Built ONLY under
// `-Dcoverage` (see build.zig) for instrumented end-to-end server runs.
const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,
};

export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
    _ = ptr;
    _ = waiters;
    unreachable;
}

export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
    _ = ptr;
    _ = expected;
    unreachable;
}

export fn runner_test_name(i: u32) Slice {
    _ = i;
    unreachable;
}

export fn runner_broadcast_input(test_i: u32, bytes: Slice) void {
    _ = test_i;
    _ = bytes;
    unreachable;
}

export fn runner_start_input_poller() void {
    unreachable;
}

export fn runner_stop_input_poller() void {
    unreachable;
}

export fn runner_test_run(i: u32) void {
    _ = i;
    unreachable;
}

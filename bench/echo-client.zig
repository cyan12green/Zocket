const std = @import("std");
const posix = std.posix;

const payload = "ping-ping-ping-ping-ping-ping-ping-ping-ping-ping!"; // 46 bytes

var total_ok = std.atomic.Value(usize).init(0);
var total_bad = std.atomic.Value(usize).init(0);

const Worker = struct {
    port: u16,
    conns: usize,
    iterations: usize,

    fn run(w: *Worker) void {
        var conns_buf: [256]posix.socket_t = undefined;
        var n_conns: usize = 0;
        for (0..w.conns) |_| {
            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch break;
            var addr: posix.sockaddr = .{ .family = posix.AF.INET, .data = [_]u8{0} ** 14 };
            std.mem.writeInt(u16, addr.data[0..2], w.port, .big);
            std.mem.writeInt(u32, addr.data[2..6], 0x7f000001, .big);
            posix.connect(fd, &addr, 16) catch {
                posix.close(fd);
                break;
            };
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
            conns_buf[n_conns] = fd;
            n_conns += 1;
        }
        if (n_conns == 0) return;

        // Simple pipelined echo: write payload, then read payload back,
        // repeating `iterations` times per connection.
        var buf: [256]u8 = undefined;
        var done = false;
        var iters: [256]usize = [_]usize{0} ** 256;
        while (!done) {
            done = true;
            for (0..n_conns) |i| {
                if (iters[i] >= w.iterations) continue;
                done = false;
                // send
                var rem: []const u8 = payload;
                while (rem.len > 0) {
                    const n = posix.write(conns_buf[i], rem) catch break;
                    rem = rem[n..];
                }
                // read echo
                var got: usize = 0;
                while (got < payload.len) {
                    const n = posix.read(conns_buf[i], buf[got..]) catch break;
                    if (n == 0) break;
                    got += n;
                }
                if (got == payload.len and std.mem.eql(u8, buf[0..got], payload)) {
                    _ = total_ok.fetchAdd(1, .monotonic);
                } else {
                    _ = total_bad.fetchAdd(1, .monotonic);
                }
                iters[i] += 1;
            }
        }
        for (0..n_conns) |i| posix.close(conns_buf[i]);
    }
};

pub fn main() !void {
    const port = std.fmt.parseInt(u16, std.mem.sliceTo(std.os.argv[1], 0), 10) catch 8090;
    const threads = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[2], 0), 10) catch 4;
    const conns = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[3], 0), 10) catch 50;
    const iterations = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[4], 0), 10) catch 2000;

    const start = std.time.Instant.now() catch return;
    var workers: [32]Worker = undefined;
    var handles: [32]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..threads) |i| {
        workers[i] = .{ .port = port, .conns = conns, .iterations = iterations };
        handles[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
        spawned += 1;
    }
    for (0..spawned) |i| handles[i].join();
    const elapsed_ns = (std.time.Instant.now() catch return).since(start);

    const ok = total_ok.load(.monotonic);
    const bad = total_bad.load(.monotonic);
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print("requests={d} bad={d} time={d:.2}s rps={d:.0}\n", .{ ok, bad, secs, @as(f64, @floatFromInt(ok)) / secs });
    if (bad > 0) std.process.exit(1);
}

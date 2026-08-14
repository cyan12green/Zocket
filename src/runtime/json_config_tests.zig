const std = @import("std");
const json_config = @import("json_config.zig");
const router = @import("../dsl/router.zig");

const Match = router.Match;
const Balance = router.Balance;

const testing = std.testing;

// The bigger comptime parses live in their own file: Zig's comptime budget
// (1000 backward branches) is shared by every comptime evaluation analysed
// within the parser's file, so the total cost of every `parse()` in the
// compilation must stay comfortably under it. The fixtures below are kept
// small on purpose; `config.example.json` (parsed in the second test) already
// exercises limits, response templates, modules and static serving, so this
// file only adds the constructs the example lacks (upstreams, balance,
// escapes).

test "comptime parse of upstreams, response headers and escapes" {
    const cfg = json_config.parse(
        \\{
        \\  "routes": [
        \\    { "path": "/h", "match": "exact",
        \\      "response": { "status": 301, "body": "moved\n", "headers": [
        \\        { "name": "Location", "value": "/new" } ] } },
        \\    { "path": "/p", "autoindex": true,
        \\      "upstreams": [ { "host": "127.0.0.1", "port": 8000 } ],
        \\      "balance": "ip_hash", "max_fails": 2, "fail_timeout_seconds": 5 }
        \\  ]
        \\}
    );
    try testing.expectEqual(@as(usize, 2), cfg.routes.len);

    const r0 = cfg.routes[0];
    try testing.expectEqual(Match.exact, r0.match);
    try testing.expectEqual(@as(u16, 301), r0.response.?.status);
    try testing.expectEqualStrings("moved\n", r0.response.?.body);
    try testing.expectEqualStrings("Location", r0.response.?.headers[0].name);
    try testing.expectEqualStrings("/new", r0.response.?.headers[0].value);

    const r1 = cfg.routes[1];
    try testing.expect(r1.autoindex);
    try testing.expectEqual(@as(usize, 1), r1.upstreams.len);
    try testing.expectEqualStrings("127.0.0.1", r1.upstreams[0].host);
    try testing.expectEqual(@as(u16, 8000), r1.upstreams[0].port);
    try testing.expectEqual(Balance.ip_hash, r1.balance);
    try testing.expectEqual(@as(u32, 2), r1.max_fails);
}

test "comptime parse of the shipped example config" {
    const cfg = json_config.parse(@embedFile("../testdata/config.example.json"));
    try testing.expectEqual(@as(usize, 6), cfg.routes.len);
    try testing.expectEqualStrings("/echo", cfg.routes[0].path);
    try testing.expectEqualStrings("/", cfg.routes[5].path);
    try testing.expectEqual(@as(usize, 32), cfg.limits.max_headers);
    try testing.expectEqualStrings("static", cfg.routes[2].modules[0].module);
    try testing.expectEqualStrings("/old", cfg.routes[4].path);
    try testing.expectEqual(@as(u16, 301), cfg.routes[4].response.?.status);
}

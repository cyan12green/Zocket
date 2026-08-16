//! Minimal PEM decoding: RFC 7468 blocks (`-----BEGIN X-----` / base64 /
//! `-----END X-----`). The server needs this for certificate and private-key
//! files. Only the first block of a given label is returned (cert files may
//! hold chains — M17 sends the first certificate only).

const std = @import("std");

pub const Error = error{
    InvalidPemHeader,
    InvalidBase64,
    MissingEndMarker,
    OutOfMemory,
};

/// Decode the first PEM block with the given label (e.g. "CERTIFICATE").
/// Writes the DER bytes into `out` and returns the used length. When the
/// file contains no matching block, `null` is returned (callers treat that
/// as "label not present", e.g. a key file without an encrypted section).
pub fn decodeFirst(
    pem: []const u8,
    comptime label: []const u8,
    out: []u8,
) Error!?usize {
    var pos: usize = 0;
    while (pos < pem.len) {
        const line_end = std.mem.indexOfScalarPos(u8, pem, pos, '\n') orelse pem.len;
        const line = std.mem.trim(u8, pem[pos..line_end], " \t\r");
        pos = line_end + 1;
        if (std.mem.startsWith(u8, line, "-----BEGIN ")) {
            if (!std.mem.endsWith(u8, line, "-----")) return error.InvalidPemHeader;
            const inner = line["-----BEGIN ".len .. line.len - "-----".len];
            if (!std.mem.eql(u8, inner, label)) continue;

            // Base64 body up to the END marker: one continuous stream across
            // lines (padding only at the very end).
            var b64_stream = std.ArrayList(u8).empty;
            defer b64_stream.deinit(std.heap.page_allocator);
            while (pos < pem.len) {
                const end_line_end = std.mem.indexOfScalarPos(u8, pem, pos, '\n') orelse pem.len;
                const end_line = std.mem.trim(u8, pem[pos..end_line_end], " \t\r");
                if (std.mem.startsWith(u8, end_line, "-----END ")) {
                    if (!std.mem.eql(u8, end_line, "-----END " ++ label ++ "-----"))
                        return error.InvalidPemHeader;
                    pos = end_line_end + 1;
                    break;
                }
                for (pem[pos..end_line_end]) |c| {
                    switch (c) {
                        'a'...'z', 'A'...'Z', '0'...'9', '+', '/', '=' =>
                            b64_stream.append(std.heap.page_allocator, c) catch return error.OutOfMemory,
                        ' ', '\t', '\r' => {},
                        else => return error.InvalidBase64,
                    }
                }
                pos = end_line_end + 1;
            } else return error.MissingEndMarker;

            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_stream.items) catch
                return error.InvalidBase64;
            if (decoded_len > out.len) return error.InvalidBase64;
            std.base64.standard.Decoder.decode(out[0..decoded_len], b64_stream.items) catch
                return error.InvalidBase64;
            return decoded_len;
        }
    }
    return null;
}

const testing = std.testing;

test "pem: extracts the DER payload of a certificate block" {
    const pem =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBgjCCASegAwIBAgIUJJXM/gwr5mqc1ciE50yHKkS/Fw0wCgYIKoZIzj0EAwIw
        \\FjEUMBIGA1UEAwwLem9ja2V0LXRlc3QwHhcNMjYwODE2MDQ0NTA0WhcNMzYwODEz
        \\MDQ0NTA0WjAWMRQwEgYDVQQDDAt6b2NrZXQtdGVzdDBZMBMGByqGSM49AgEGCCqG
        \\SM49AwEHA0IABGJx0GzFvloM4k/e+qhMfnR8R1fJdOyLlOCWZT61nouvYszZmOAS
        \\4WpTxVnip8mWoIqkwkCyzw6wdEOMsi+klxejUzBRMB0GA1UdDgQWBBSYhQcTp0GY
        \\6+4EE3N5x+fQPWmy6TAfBgNVHSMEGDAWgBSYhQcTp0GY6+4EE3N5x+fQPWmy6TAP
        \\BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDbwEssj3iI8328T+Rz
        \\cvFtssbDb4kbI2VrKhUcEf+SrQIhAMHLq2MogzpNGWCIKwVp+PGYfS5uT2gOJ1qx
        \\0HyJrl0O
        \\-----END CERTIFICATE-----
    ;
    var out: [2048]u8 = undefined;
    const n = try decodeFirst(pem, "CERTIFICATE", &out);
    try testing.expect(n != null);
    // DER: SEQUENCE tag.
    try testing.expectEqual(@as(u8, 0x30), out[0]);
    try testing.expect(n.? > 100);
}

test "pem: extracts an EC private key block" {
    const pem =
        \\-----BEGIN EC PRIVATE KEY-----
        \\MHcCAQEEIMLJ2ZkEQS31wRzzM7wCwPQEe+Z8Nc1OtBfg40rywd0DoAoGCCqGSM49
        \\AwEHoUQDQgAEYnHQbMW+WgziT976qEx+dHxHV8l07IuU4JZlPrWei69izNmY4BLh
        \\alPFWeKnyZagiqTCQLLPDrB0Q4yyL6SXFw==
        \\-----END EC PRIVATE KEY-----
    ;
    var out: [512]u8 = undefined;
    const n = try decodeFirst(pem, "EC PRIVATE KEY", &out);
    try testing.expect(n != null);
    try testing.expectEqual(@as(u8, 0x30), out[0]);
}
test "pem: missing label returns null" {
    const pem =
        \\\\-----BEGIN PRIVATE KEY-----
        \\\\MGQCAQAwCwYJKoZIhvcNAQELBIJk
        \\\\-----END PRIVATE KEY-----
    ;
    var out: [512]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), try decodeFirst(pem, "CERTIFICATE", &out));
}

test "pem: garbage and truncation fail cleanly" {
    var out: [64]u8 = undefined;
    try testing.expectError(error.MissingEndMarker, decodeFirst("-----BEGIN CERTIFICATE-----\nAAAA", "CERTIFICATE", &out));
    try testing.expectError(error.InvalidBase64, decodeFirst("-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n", "CERTIFICATE", &out));
    try testing.expectError(error.InvalidPemHeader, decodeFirst("-----BEGIN CERTIFICATE\nAAAA\n-----END CERTIFICATE-----\n", "CERTIFICATE", &out));
}

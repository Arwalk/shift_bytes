pub fn shlBytesAlloc(bytes: []const u8, bitShift: usize, comptime size: usize, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    for (buffer) |*b| {
        b.* = 0;
    }
    shlBytes(bytes, bitShift, buffer, size);
    return buffer;
}

pub fn shlBytesInplace(bytes: []u8, bitShift: usize, comptime size: usize) void {
    shlBytes(bytes, bitShift, bytes, size);
    if (bitShift >= 8) {
        const bytesToClear = bitShift / 8;
        for (0..bytesToClear) |i| {
            bytes[bytes.len - i - 1] = 0;
        }
    }
}

pub fn shlBytes(bytes: []const u8, bitShift: usize, out: []u8, comptime size: usize) void {
    const V = @Vector(size, u8);
    const VShift = @Vector(size, u3);
    switch (bitShift) {
        0 => {
            for (bytes, 0..bytes.len) |b, i| {
                out[i] = b;
            }
        },
        1...7 => {
            var tempArr = [_]u8{0} ** (size);
            var remainders = [_]u8{0} ** (size);
            @memcpy(tempArr[0..bytes.len], bytes);
            @memcpy(remainders[0 .. bytes.len - 1], bytes[1..]);

            const temp: V = tempArr;
            const remainderVector: V = remainders;

            const truncatedBitShift = @as(u3, @truncate(bitShift));
            const shifteV: VShift = [_]u3{truncatedBitShift} ** size;

            const shiftRemainderVector: VShift = [_]u3{7 - truncatedBitShift + 1} ** size;
            const shiftRemainder = remainderVector >> shiftRemainderVector;

            var r = temp << shifteV;
            r = r + shiftRemainder;

            const rt: [size]u8 = r;
            @memcpy(out, rt[0..size]);
        },
        else => {
            const bytesToSkip = bitShift / 8;
            @call(.always_tail, shlBytes, .{ bytes[bytesToSkip..], bitShift % 8, out, size });
        },
    }
}

const std = @import("std");

const ShlTestInput = struct {
    comptime size: usize = 8,
    bytes: []const u8,
    bitShift: usize,
    expected: []const u8,
};

const shl_test_inputs = [_]ShlTestInput{
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 0, .expected = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 1, .expected = &[_]u8{ 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 2, .expected = &[_]u8{ 0x04, 0x08, 0x0c, 0x10, 0x14, 0x18, 0x1c, 0x20 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 3, .expected = &[_]u8{ 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 4, .expected = &[_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 8, .expected = &[_]u8{ 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 9, .expected = &[_]u8{ 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10, 0x00 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .bitShift = 1, .expected = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
    .{ .size = 8, .bytes = &[_]u8{ 0x80, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80 }, .bitShift = 1, .expected = &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00 } },
};

fn test_shl_bytes_alloc(input: ShlTestInput) !void {
    const buffer = try shlBytesAlloc(input.bytes[0..], input.bitShift, input.size, std.testing.allocator);
    defer std.testing.allocator.free(buffer);
    try std.testing.expectEqualSlices(u8, input.expected, buffer);
}

fn test_shl_bytes_inplace(input: ShlTestInput) !void {
    var buffer = [_]u8{0} ** input.size;
    @memcpy(buffer[0..input.size], input.bytes);
    shlBytesInplace(buffer[0..], input.bitShift, input.size);
    try std.testing.expectEqualSlices(u8, input.expected, &buffer);
}

fn test_shl_bytes(input: ShlTestInput) !void {
    const buffer = try std.testing.allocator.alloc(u8, input.size);
    for (buffer) |*b| {
        b.* = 0;
    }
    defer std.testing.allocator.free(buffer);
    shlBytes(input.bytes[0..], input.bitShift, buffer, input.size);
    try std.testing.expectEqualSlices(u8, input.expected, buffer);
}

test "shl_bytes" {
    inline for (shl_test_inputs) |input| {
        _ = struct {
            test {
                try test_shl_bytes(input);
            }
        };
        _ = struct {
            test {
                try test_shl_bytes_alloc(input);
            }
        };
        _ = struct {
            test {
                try test_shl_bytes_inplace(input);
            }
        };
    }
}

inline fn to_bytes(num: u64, out: []u8) void {
    out[0] = @truncate(num >> 56);
    out[1] = @truncate(num >> 48);
    out[2] = @truncate(num >> 40);
    out[3] = @truncate(num >> 32);
    out[4] = @truncate(num >> 24);
    out[5] = @truncate(num >> 16);
    out[6] = @truncate(num >> 8);
    out[7] = @truncate(num);
}

test "fuzz shl" {
    const Context = struct {
        value: u64,

        fn testOne(context: @This(), inputRaw: []const u8) anyerror!void {
            _ = context;
            if (inputRaw.len != 9) {
                return;
            }
            const inputValue: u64 = @as(u64, inputRaw[0]) << 56 | @as(u64, inputRaw[1]) << 48 | @as(u64, inputRaw[2]) << 40 | @as(u64, inputRaw[3]) << 32 | @as(u64, inputRaw[4]) << 24 | @as(u64, inputRaw[5]) << 16 | @as(u64, inputRaw[6]) << 8 | @as(u64, inputRaw[7]);
            const inputBitShift: u6 = @truncate(inputRaw[8]);
            const expected = inputValue << inputBitShift;
            var expectedBytes = [_]u8{0} ** 8;
            to_bytes(expected, &expectedBytes);
            var inputBytes = [_]u8{0} ** 8;
            to_bytes(inputValue, &inputBytes);
            const input = ShlTestInput{
                .size = 8,
                .bytes = &inputBytes,
                .bitShift = inputBitShift,
                .expected = &expectedBytes,
            };
            try test_shl_bytes_alloc(input);
            try test_shl_bytes(input);
            try test_shl_bytes_inplace(input);
        }
    };
    try std.testing.fuzz(Context{ .value = 0 }, Context.testOne, .{});
}

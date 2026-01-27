const std = @import("std");
const assert = std.debug.assert;

fn ShiftVectors(comptime size: usize) type {
    return struct {
        const VectorType = @Vector(size, u3);

        shift: VectorType,
        reverseShift: VectorType,
    };
}

fn buildShlVectors(comptime size: usize, bitShift: usize) ShiftVectors(size) {
    const truncatedBitShift = @as(u3, @truncate(bitShift));
    const reverseShift: u3 = 7 - truncatedBitShift + 1;
    return .{
        .shift = [_]u3{truncatedBitShift} ** size,
        .reverseShift = [_]u3{reverseShift} ** size,
    };
}

fn shlBytes(bytes: []const u8, bitShift: usize, out: []u8, comptime chunkSize: usize) !void {
    comptime {
        if (chunkSize <= 1) {
            @compileError("shlBytes can not shift chunks of size 1 or 0.");
        }
    }
    switch (bitShift) {
        0 => {
            for (bytes, 0..bytes.len) |b, i| {
                out[i] = b;
            }
            return;
        },
        1...7 => {
            var writer = std.Io.Writer.fixed(out);
            var reader = std.Io.Reader.fixed(bytes);
            const shifters = buildShlVectors(chunkSize, bitShift);

            var shouldContinue = true;

            while (shouldContinue) {
                var chunks = [_]u8{0} ** (chunkSize * chunkSize);
                var boundaries = [_]u8{0} ** chunkSize;
                const read = try reader.readSliceShort(&chunks);
                inline for (0..chunkSize) |i| {
                    boundaries[i] = chunks[(i * chunkSize) + 1];
                }
                boundaries[chunkSize - 1] = if (reader.peekByte()) |b| blk: {
                    break :blk b;
                } else |err| blk: {
                    switch (err) {
                        error.EndOfStream => shouldContinue = false,
                        else => return err,
                    }
                    break :blk 0;
                };
                inline for (0..chunkSize) |i| {
                    const lowerBound = i * chunkSize;
                    shlBytesFixedImpl(chunks[lowerBound .. lowerBound + chunkSize], chunks[lowerBound .. lowerBound + chunkSize], chunkSize, shifters);
                }
                boundaries = @as(@Vector(chunkSize, u8), boundaries) >> shifters.reverseShift;
                inline for (1..chunkSize - 1) |i| {
                    chunks[i * chunkSize] = boundaries[i];
                }
                _ = try writer.write(chunks[0..read]);
            }
            try writer.flush();
        },
        else => {
            const bytesToSkip = bitShift / 8;
            return @call(.always_tail, shlBytes, .{ bytes[bytesToSkip..], bitShift % 8, out, chunkSize });
        },
    }
}

fn shlBytesFixedImpl(bytes: []const u8, out: []u8, comptime size: usize, shifters: ShiftVectors(size)) void {
    assert(size >= bytes.len);
    var tempArr = [_]u8{0} ** (size);
    var remainders = [_]u8{0} ** (size);
    @memcpy(tempArr[0..bytes.len], bytes);
    @memcpy(remainders[0 .. bytes.len - 1], bytes[1..]);

    const temp: @Vector(size, u8) = tempArr;
    const remainderVector: @Vector(size, u8) = remainders;

    const shiftRemainder = remainderVector >> shifters.reverseShift;

    var r = temp << shifters.shift;
    r = r + shiftRemainder;

    const rt: [size]u8 = r;
    @memcpy(out, rt[0..out.len]);
}

pub fn shlBytesFixed(bytes: []const u8, bitShift: usize, out: []u8, comptime size: usize) void {
    switch (bitShift) {
        0 => {
            for (bytes, 0..bytes.len) |b, i| {
                out[i] = b;
            }
            return;
        },
        1...7 => {
            assert(size >= bytes.len);
            const shifters: ShiftVectors(size) = buildShlVectors(size, bitShift);
            shlBytesFixedImpl(bytes, out, size, shifters);
        },
        else => {
            const bytesToSkip = bitShift / 8;
            return @call(.always_tail, shlBytesFixed, .{ bytes[bytesToSkip..], bitShift % 8, out, size });
        },
    }
}

pub fn shlBytesAllocFixed(bytes: []const u8, bitShift: usize, comptime size: usize, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    for (buffer) |*b| {
        b.* = 0;
    }
    shlBytesFixed(bytes, bitShift, buffer, size);
    return buffer;
}

pub fn shlBytesInplaceFixed(bytes: []u8, bitShift: usize, comptime size: usize) void {
    shlBytesFixed(bytes, bitShift, bytes, size);
    if (bitShift >= 8) {
        const bytesToClear = bitShift / 8;
        for (0..bytesToClear) |i| {
            bytes[bytes.len - i - 1] = 0;
        }
    }
}

const ShlTestInput = struct {
    comptime size: usize = 8,
    bytes: []const u8,
    bitShift: usize,
    expected: []const u8,
    expectedRemainder: u8,
};

const shl_test_inputs = [_]ShlTestInput{
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 0, .expected = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 1, .expected = &[_]u8{ 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 2, .expected = &[_]u8{ 0x04, 0x08, 0x0c, 0x10, 0x14, 0x18, 0x1c, 0x20 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 3, .expected = &[_]u8{ 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 4, .expected = &[_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 8, .expected = &[_]u8{ 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .bitShift = 9, .expected = &[_]u8{ 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10, 0x00 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .bitShift = 1, .expected = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .expectedRemainder = 0x00 },
    .{ .size = 8, .bytes = &[_]u8{ 0x80, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80 }, .bitShift = 1, .expected = &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00 }, .expectedRemainder = 0x01 },
    .{ .size = 8, .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 }, .bitShift = 2, .expected = &[_]u8{ 0x04, 0x08, 0x0c, 0x10, 0x14, 0x18, 0x1c }, .expectedRemainder = 0x00 },
};

fn test_shl_bytes_alloc(input: ShlTestInput) !void {
    const buffer = try shlBytesAllocFixed(input.bytes[0..], input.bitShift, input.size, std.testing.allocator);
    defer std.testing.allocator.free(buffer);
    try std.testing.expectEqualSlices(u8, input.expected, buffer[0..input.bytes.len]);
}

fn test_shl_bytes_inplace(input: ShlTestInput) !void {
    var buffer = [_]u8{0} ** input.size;
    @memcpy(buffer[0..input.bytes.len], input.bytes);
    _ = shlBytesInplaceFixed(buffer[0..input.bytes.len], input.bitShift, input.size);
    try std.testing.expectEqualSlices(u8, input.expected, buffer[0..input.bytes.len]);
}

fn test_shl_bytes(input: ShlTestInput) !void {
    const buffer = try std.testing.allocator.alloc(u8, input.size);
    for (buffer) |*b| {
        b.* = 0;
    }
    defer std.testing.allocator.free(buffer);
    _ = shlBytesFixed(input.bytes[0..], input.bitShift, buffer, input.size);
    try std.testing.expectEqualSlices(u8, input.expected, buffer[0..input.bytes.len]);
}

fn test_shl_chunked(input: ShlTestInput, comptime chunkSize: usize) !void {
    const buffer = try std.testing.allocator.alloc(u8, input.size);
    for (buffer) |*b| {
        b.* = 0;
    }
    defer std.testing.allocator.free(buffer);
    _ = try shlBytes(input.bytes[0..], input.bitShift, buffer, chunkSize);
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
        inline for (2..8) |i| {
            _ = struct {
                test {
                    try test_shl_chunked(input, i);
                }
            };
        }
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
                .expectedRemainder = expectedBytes[0] >> (7 - @as(u3, @truncate(inputBitShift)) + 1),
            };
            try test_shl_bytes_alloc(input);
            try test_shl_bytes(input);
            try test_shl_bytes_inplace(input);
        }
    };
    try std.testing.fuzz(Context{ .value = 0 }, Context.testOne, .{});
}

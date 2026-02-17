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
        .shift = @splat(truncatedBitShift),
        .reverseShift = @splat(reverseShift),
    };
}

/// Shift all bytes in a stream left by `bitShift` bits, reading in `chunkSize`-sized chunks until `error.EndOfStream`,
/// and write the result to an output stream. Preserves bits crossing byte boundaries; zeroes fill at the end.
///
/// - `bytes`: Pointer to an `std.Io.Reader` providing the raw input bytes.
/// - `bitShift`: How many bits to shift each byte left (must be between 1 and 7 inclusive).
/// - `out`: Pointer to an `std.Io.Writer` that receives the shifted bytes.
/// - `chunkSize`: Compile-time constant controlling the processing chunk size (must be greater than 1).
/// - `chunkCount`: Compile-time constant controlling how many chunks are processed per iteration (must be >= 2).
///   The internal buffer size is `chunkSize * chunkCount` bytes per iteration.
///
/// `chunkSize` may be any value > 1, but note that 32 is probably the best value to use, as it aligns with modern SIMD register sizes.
///
/// The function may buffer input/output and is designed for efficient, chunked SIMD processing.
/// Extra zeroes (up to chunkSize * chunkCount) are splatted to the output to guarantee full boundary shift safety.
///
/// It is safe to pass a writer to pointing to the same starting position than the reader, allowing to bitshift in place.
///
/// If you know in advance the maximum size of the bytes to bitshift, it might be better to use `shlBytesFixed`
///
/// ## Example
/// ```zig
/// const std = @import("std");
/// const shift_bytes = @import("shift_bytes");
///
/// var src = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
/// var dst = [_]u8{0} ** 8;
///
/// var reader : std.Io.Reader = .fixed(&src);
/// var writer : std.Io.Writer = .fixed(&dst);
///
/// // Shift left by 1 bit in chunks of 8 bytes, 2 chunks per iteration
/// try shift_bytes.shlBytes(&reader, 1, &writer, 8, 2);
///
/// // Result in dst: { 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10 }
/// ```
pub fn shlBytes(bytes: *std.Io.Reader, bitShift: usize, out: *std.Io.Writer, comptime chunkSize: usize, comptime chunkCount: usize) !void {
    var skipped: usize = 0;
    try shlBytesImpl(bytes, bitShift, out, chunkSize, chunkCount, &skipped);
    _ = try out.splatByte(0, skipped);
}

fn shlBytesImpl(bytes: *std.Io.Reader, bitShift: usize, out: *std.Io.Writer, comptime chunkSize: usize, comptime chunkCount: usize, skipped: *usize) !void {
    comptime {
        if (chunkSize <= 1) {
            @compileError("shlBytes can not shift chunks of size 1 or 0.");
        }
        if (chunkSize <= 1) {
            @compileError("shlBytes needs chunk counts >= 2. ");
        }
    }

    switch (bitShift) {
        0 => {
            _ = try bytes.streamRemaining(out);
            return;
        },
        1...7 => {
            const shifters = buildShlVectors(chunkSize, bitShift);
            const remainderShifters = buildShlVectors(chunkCount, bitShift);

            var shouldContinue = true;

            while (shouldContinue) {
                var chunks = [_]u8{0} ** (chunkSize * chunkCount);
                var boundaries = [_]u8{0} ** chunkCount;
                const read = try bytes.readSliceShort(&chunks);
                inline for (0..chunkCount - 1) |i| {
                    boundaries[i] = chunks[(i * chunkSize) + chunkSize];
                }
                boundaries[chunkCount - 1] = if (bytes.peekByte()) |b| blk: {
                    break :blk b;
                } else |err| blk: {
                    switch (err) {
                        error.EndOfStream => shouldContinue = false,
                        else => return err,
                    }
                    break :blk 0;
                };
                inline for (0..chunkCount) |i| {
                    const lowerBound = i * chunkSize;
                    const upperBound = lowerBound + chunkSize;
                    shlBytesFixedImpl(chunks[lowerBound..upperBound], chunks[lowerBound..upperBound], chunkSize, shifters);
                }
                const remainderVector: @Vector(chunkCount, u8) = boundaries;
                const remainders = remainderVector >> remainderShifters.reverseShift;

                inline for (0..chunkCount - 1) |i| {
                    chunks[(i * chunkSize) + (chunkSize - 1)] += remainders[i];
                }
                _ = try out.write(chunks[0..read]);
            }
        },
        else => {
            skipped.* = bitShift / 8;
            bytes.toss(skipped.*);
            return @call(.always_tail, shlBytesImpl, .{ bytes, bitShift % 8, out, chunkSize, chunkCount, skipped });
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

/// Shifts the input bytes left by `bitShift` bits and stores the result in `out`.
///
/// Operates on a fixed-size chunk of `size` bytes, performing bitwise shift left
/// across byte boundaries. This means the bits "spill" from one byte to the next
/// higher byte, in big-endian (MSB-first) order.
///
/// - `bytes`: The input byte slice to shift. Its length must not exceed `size`.
/// - `bitShift`: The number of bits to shift left. Can be greater than 8—each full 8 causes a byte skip.
/// - `out`: Output buffer which will receive the shifted bytes. Must be at least `bytes.len` in length.
/// - `size`: The total size in bytes of the shift operation, also determines the SIMD vector width.
///
/// For `bitShift` equal to zero, it simply copies `bytes` to `out`.
/// For `bitShift` greater than 7, this will internally skip bytes as needed.
///
/// This operation does not allocate and requires the caller to provide an appropriately
/// sized output buffer.
///
/// Example:
/// ```zig
/// const bytes = [_]u8{1, 2, 3, 4, 5, 6, 7, 8};
/// var out = [_]u8{0} ** 8;
/// shlBytesFixed(bytes[0..], 1, out[0..], 8);
/// // out == [_]u8{2, 4, 6, 8, 10, 12, 14, 16}
/// ```
///
/// This function is meant to be used when you know that `bytes.len` will never exceed `size`
///
/// Note that using `sizes` > 32 might not be necessarily the most optimal use of this function. Instead use shlBytes
pub fn shlBytesFixed(bytes: []const u8, bitShift: usize, out: []u8, comptime size: usize) void {
    switch (bitShift) {
        0 => {
            assert(size >= bytes.len);
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

/// Allocates a buffer of `size` bytes and stores the result of shifting `bytes` left by `bitShift` bits in it.
///
/// This is a heap-allocating variant of `shlBytesFixed`. The caller must free the returned buffer.
/// The result buffer is always zero-initialized before the shift operation.
///
/// - `bytes`: The input bytes to shift (length must be <= `size`).
/// - `bitShift`: The number of bits to shift. Can be >= 8.
/// - `size`: The fixed size (in bytes) for the result and output buffer.
/// - `allocator`: The allocator to use for memory allocation.
///
/// Returns a `[]u8` buffer of length `size` containing the shifted result.
/// The user is responsible for freeing the returned buffer.
///
/// Example:
/// ```zig
/// const result = try shlBytesAllocFixed(&[_]u8{1,2,3,4}, 3, 8, allocator);
/// defer allocator.free(result);
/// // result == [_]u8{8, 16, 24, 32, 0, 0, 0, 0}
/// ```
pub fn shlBytesAllocFixed(bytes: []const u8, bitShift: usize, comptime size: usize, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    for (buffer) |*b| {
        b.* = 0;
    }
    shlBytesFixed(bytes, bitShift, buffer, size);
    return buffer;
}

/// Shifts the contents of the provided `bytes` buffer left by `bitShift` bits in-place, up to `size` bytes.
///
/// This function modifies the given `bytes` slice by left-shifting its values by the specified `bitShift` amount.
/// Any overflowed bits are truncated, and if `bitShift` is 8 or more, the upper bytes at the end of the array are zeroed out,
/// corresponding to the number of bytes shifted away.
///
/// - `bytes`: The mutable buffer to shift (will be overwritten).
/// - `bitShift`: The number of bits to shift left by. Can be greater than 8.
/// - `size`: The fixed size of the shift window; should be at least `bytes.len`.
///
/// Example:
/// ```zig
/// var buffer = [_]u8{0x01, 0x02, 0x03, 0x04};
/// shlBytesInplaceFixed(&buffer, 4, 4);
/// // buffer == [_]u8{0x10, 0x20, 0x30, 0x40}
/// ```
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
    var reader: std.Io.Reader = .fixed(input.bytes);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try shlBytes(&reader, input.bitShift, &out.writer, chunkSize, 2);
    try std.testing.expectEqualSlices(u8, input.expected, out.written());
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

test "shl_chunked input 0 chunk 2" {
    try test_shl_chunked(shl_test_inputs[0], 2);
}
test "shl_chunked input 0 chunk 3" {
    try test_shl_chunked(shl_test_inputs[0], 3);
}
test "shl_chunked input 0 chunk 4" {
    try test_shl_chunked(shl_test_inputs[0], 4);
}
test "shl_chunked input 0 chunk 5" {
    try test_shl_chunked(shl_test_inputs[0], 5);
}
test "shl_chunked input 0 chunk 6" {
    try test_shl_chunked(shl_test_inputs[0], 6);
}
test "shl_chunked input 0 chunk 7" {
    try test_shl_chunked(shl_test_inputs[0], 7);
}
test "shl_chunked input 0 chunk 8" {
    try test_shl_chunked(shl_test_inputs[0], 8);
}
test "shl_chunked input 1 chunk 2" {
    try test_shl_chunked(shl_test_inputs[1], 2);
}
test "shl_chunked input 1 chunk 3" {
    try test_shl_chunked(shl_test_inputs[1], 3);
}
test "shl_chunked input 1 chunk 4" {
    try test_shl_chunked(shl_test_inputs[1], 4);
}
test "shl_chunked input 1 chunk 5" {
    try test_shl_chunked(shl_test_inputs[1], 5);
}
test "shl_chunked input 1 chunk 6" {
    try test_shl_chunked(shl_test_inputs[1], 6);
}
test "shl_chunked input 1 chunk 7" {
    try test_shl_chunked(shl_test_inputs[1], 7);
}
test "shl_chunked input 1 chunk 8" {
    try test_shl_chunked(shl_test_inputs[1], 8);
}
test "shl_chunked input 2 chunk 2" {
    try test_shl_chunked(shl_test_inputs[2], 2);
}
test "shl_chunked input 2 chunk 3" {
    try test_shl_chunked(shl_test_inputs[2], 3);
}
test "shl_chunked input 2 chunk 4" {
    try test_shl_chunked(shl_test_inputs[2], 4);
}
test "shl_chunked input 2 chunk 5" {
    try test_shl_chunked(shl_test_inputs[2], 5);
}
test "shl_chunked input 2 chunk 6" {
    try test_shl_chunked(shl_test_inputs[2], 6);
}
test "shl_chunked input 2 chunk 7" {
    try test_shl_chunked(shl_test_inputs[2], 7);
}
test "shl_chunked input 2 chunk 8" {
    try test_shl_chunked(shl_test_inputs[2], 8);
}
test "shl_chunked input 3 chunk 2" {
    try test_shl_chunked(shl_test_inputs[3], 2);
}
test "shl_chunked input 3 chunk 3" {
    try test_shl_chunked(shl_test_inputs[3], 3);
}
test "shl_chunked input 3 chunk 4" {
    try test_shl_chunked(shl_test_inputs[3], 4);
}
test "shl_chunked input 3 chunk 5" {
    try test_shl_chunked(shl_test_inputs[3], 5);
}
test "shl_chunked input 3 chunk 6" {
    try test_shl_chunked(shl_test_inputs[3], 6);
}
test "shl_chunked input 3 chunk 7" {
    try test_shl_chunked(shl_test_inputs[3], 7);
}
test "shl_chunked input 3 chunk 8" {
    try test_shl_chunked(shl_test_inputs[3], 8);
}
test "shl_chunked input 4 chunk 2" {
    try test_shl_chunked(shl_test_inputs[4], 2);
}
test "shl_chunked input 4 chunk 3" {
    try test_shl_chunked(shl_test_inputs[4], 3);
}
test "shl_chunked input 4 chunk 4" {
    try test_shl_chunked(shl_test_inputs[4], 4);
}
test "shl_chunked input 4 chunk 5" {
    try test_shl_chunked(shl_test_inputs[4], 5);
}
test "shl_chunked input 4 chunk 6" {
    try test_shl_chunked(shl_test_inputs[4], 6);
}
test "shl_chunked input 4 chunk 7" {
    try test_shl_chunked(shl_test_inputs[4], 7);
}
test "shl_chunked input 4 chunk 8" {
    try test_shl_chunked(shl_test_inputs[4], 8);
}
test "shl_chunked input 5 chunk 2" {
    try test_shl_chunked(shl_test_inputs[5], 2);
}
test "shl_chunked input 5 chunk 3" {
    try test_shl_chunked(shl_test_inputs[5], 3);
}
test "shl_chunked input 5 chunk 4" {
    try test_shl_chunked(shl_test_inputs[5], 4);
}
test "shl_chunked input 5 chunk 5" {
    try test_shl_chunked(shl_test_inputs[5], 5);
}
test "shl_chunked input 5 chunk 6" {
    try test_shl_chunked(shl_test_inputs[5], 6);
}
test "shl_chunked input 5 chunk 7" {
    try test_shl_chunked(shl_test_inputs[5], 7);
}
test "shl_chunked input 5 chunk 8" {
    try test_shl_chunked(shl_test_inputs[5], 8);
}
test "shl_chunked input 6 chunk 2" {
    try test_shl_chunked(shl_test_inputs[6], 2);
}
test "shl_chunked input 6 chunk 3" {
    try test_shl_chunked(shl_test_inputs[6], 3);
}
test "shl_chunked input 6 chunk 4" {
    try test_shl_chunked(shl_test_inputs[6], 4);
}
test "shl_chunked input 6 chunk 5" {
    try test_shl_chunked(shl_test_inputs[6], 5);
}
test "shl_chunked input 6 chunk 6" {
    try test_shl_chunked(shl_test_inputs[6], 6);
}
test "shl_chunked input 6 chunk 7" {
    try test_shl_chunked(shl_test_inputs[6], 7);
}
test "shl_chunked input 6 chunk 8" {
    try test_shl_chunked(shl_test_inputs[6], 8);
}
test "shl_chunked input 7 chunk 2" {
    try test_shl_chunked(shl_test_inputs[7], 2);
}
test "shl_chunked input 7 chunk 3" {
    try test_shl_chunked(shl_test_inputs[7], 3);
}
test "shl_chunked input 7 chunk 4" {
    try test_shl_chunked(shl_test_inputs[7], 4);
}
test "shl_chunked input 7 chunk 5" {
    try test_shl_chunked(shl_test_inputs[7], 5);
}
test "shl_chunked input 7 chunk 6" {
    try test_shl_chunked(shl_test_inputs[7], 6);
}
test "shl_chunked input 7 chunk 7" {
    try test_shl_chunked(shl_test_inputs[7], 7);
}
test "shl_chunked input 7 chunk 8" {
    try test_shl_chunked(shl_test_inputs[7], 8);
}
test "shl_chunked input 8 chunk 2" {
    try test_shl_chunked(shl_test_inputs[8], 2);
}
test "shl_chunked input 8 chunk 3" {
    try test_shl_chunked(shl_test_inputs[8], 3);
}
test "shl_chunked input 8 chunk 4" {
    try test_shl_chunked(shl_test_inputs[8], 4);
}
test "shl_chunked input 8 chunk 5" {
    try test_shl_chunked(shl_test_inputs[8], 5);
}
test "shl_chunked input 8 chunk 6" {
    try test_shl_chunked(shl_test_inputs[8], 6);
}
test "shl_chunked input 8 chunk 7" {
    try test_shl_chunked(shl_test_inputs[8], 7);
}
test "shl_chunked input 8 chunk 8" {
    try test_shl_chunked(shl_test_inputs[8], 8);
}
test "shl_chunked input 9 chunk 2" {
    try test_shl_chunked(shl_test_inputs[9], 2);
}
test "shl_chunked input 9 chunk 3" {
    try test_shl_chunked(shl_test_inputs[9], 3);
}
test "shl_chunked input 9 chunk 4" {
    try test_shl_chunked(shl_test_inputs[9], 4);
}
test "shl_chunked input 9 chunk 5" {
    try test_shl_chunked(shl_test_inputs[9], 5);
}
test "shl_chunked input 9 chunk 6" {
    try test_shl_chunked(shl_test_inputs[9], 6);
}
test "shl_chunked input 9 chunk 7" {
    try test_shl_chunked(shl_test_inputs[9], 7);
}
test "shl_chunked input 9 chunk 8" {
    try test_shl_chunked(shl_test_inputs[9], 8);
}

test "shl 2 bytes" {
    var buffer = [_]u8{ 0x01, 0x02 };
    shlBytesInplaceFixed(&buffer, 2, 2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x08 }, &buffer);
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

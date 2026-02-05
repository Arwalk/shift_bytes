const std = @import("std");
const zbench = @import("zbench");
const shlBytes = @import("shift_bytes").shlBytes;

const BENCHMARK_FILE = "random_file.bin";

fn loadData(allocator: std.mem.Allocator) ![]u8 {
    std.debug.print("Loading data from {s}...\n", .{BENCHMARK_FILE});
    const file = try std.fs.cwd().openFile(BENCHMARK_FILE, .{});
    defer file.close();

    // Get file size and allocate buffer
    const size = (try file.stat()).size;
    std.debug.print("Dataset file size: {d} bytes\n", .{size});

    const buffer = try allocator.alloc(u8, size);

    _ = try file.readAll(buffer); // Read the entire file into the buffer
    std.debug.print("Read file contents\n", .{});
    return buffer;
}

fn bench_shift(comptime chunkSize: usize) void {
    var reader: std.Io.Reader = .fixed(data[0..]);
    var useless = [_]u8{0};
    var writer = std.Io.Writer.Discarding.init(&useless).writer;
    shlBytes(&reader, 17, &writer, chunkSize) catch @panic("unable to shift");
}

fn bench_chunk_8(_: std.mem.Allocator) void {
    bench_shift(8);
}

fn bench_chunk_16(_: std.mem.Allocator) void {
    bench_shift(16);
}

fn bench_chunk_32(_: std.mem.Allocator) void {
    bench_shift(32);
}

fn bench_chunk_64(_: std.mem.Allocator) void {
    bench_shift(64);
}

fn bench_chunk_128(_: std.mem.Allocator) void {
    bench_shift(128);
}

var data: []u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    data = try loadData(arena_allocator);

    var bench = zbench.Benchmark.init(arena_allocator, .{});
    defer bench.deinit();

    try bench.add("shl 8 bytes chunk", bench_chunk_8, .{});
    try bench.add("shl 16 bytes chunk", bench_chunk_16, .{});
    try bench.add("shl 32 bytes chunk", bench_chunk_32, .{});
    try bench.add("shl 64 bytes chunk", bench_chunk_64, .{});
    try bench.add("shl 128 bytes chunk", bench_chunk_128, .{});
    try bench.add("naive implementation", naive_implementation, .{});
    try bench.add("casted u16", casted_16, .{});
    try bench.add("casted u32", casted_32, .{});
    try bench.add("casted u64", casted_64, .{});
    try bench.add("casted u128", casted_128, .{});
    try bench.add("casted u256", casted_256, .{});

    var buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const writer = &stderr.interface;
    try bench.run(writer);
    try writer.flush();
}

fn naive_implementation(_: std.mem.Allocator) void {
    var reader: std.Io.Reader = .fixed(data[0..]);
    var useless = [_]u8{0};
    var writer = std.Io.Writer.Discarding.init(&useless).writer;

    var shouldContinue = true;
    while (shouldContinue) {
        const current = reader.takeByte() catch @panic("should not fail to take a byte");
        const next = if (reader.peekByte()) |b| blk: {
            break :blk b;
        } else |err| blk: {
            switch (err) {
                error.EndOfStream => shouldContinue = false,
                else => @panic("should not fail to peek a byte"),
            }
            break :blk 0;
        };
        writer.writeByte((current << 2) + (next >> 6)) catch @panic("should not fail to write a byte");
    }
}

fn casted_impl(comptime T: type) void {
    var reader: std.Io.Reader = .fixed(data[0..]);
    var useless = [_]u8{0};
    var writer = std.Io.Writer.Discarding.init(&useless).writer;

    var shouldContinue = true;
    while (shouldContinue) {
        var current = reader.takeInt(T, .big) catch @panic("should not fail");
        var next: T = if (reader.peekInt(T, .big)) |b| blk: {
            break :blk b;
        } else |err| blk: {
            switch (err) {
                error.EndOfStream => shouldContinue = false,
                else => @panic("should not fail to peek a byte"),
            }
            break :blk 0;
        };
        current = current << 2;
        next = next >> @bitSizeOf(T) - 2;
        writer.writeInt(T, current + next, .big) catch @panic("should not fail to write");
    }
}

fn casted_16(_: std.mem.Allocator) void {
    casted_impl(u16);
}

fn casted_32(_: std.mem.Allocator) void {
    casted_impl(u32);
}

fn casted_64(_: std.mem.Allocator) void {
    casted_impl(u64);
}

fn casted_128(_: std.mem.Allocator) void {
    casted_impl(u128);
}

fn casted_256(_: std.mem.Allocator) void {
    casted_impl(u256);
}

const std = @import("std");
const zbench = @import("zbench");
const shlBytes = @import("shift_bytes").shlBytes;
const shrBytes = @import("shift_bytes").shrBytes;

const BENCHMARK_FILE = "random_file.bin";

fn loadData(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    std.debug.print("Loading data from {s}...\n", .{BENCHMARK_FILE});
    const file = try std.Io.Dir.cwd().openFile(io, BENCHMARK_FILE, .{});
    defer file.close(io);

    // Get file size and allocate buffer
    const size = (try file.stat(io)).size;
    std.debug.print("Dataset file size: {d} bytes\n", .{size});

    const buffer = try allocator.alloc(u8, size);

    _ = try file.readPositionalAll(io, buffer, 0); // Read the entire file into the buffer
    std.debug.print("Read file contents\n", .{});
    return buffer;
}

fn bench_shift(comptime chunkSize: usize, comptime chunkCount: usize) type {
    return struct {
        fn run(_: std.mem.Allocator) void {
            var reader: std.Io.Reader = .fixed(data[0..]);
            var useless = [_]u8{0};
            var writer = std.Io.Writer.Discarding.init(&useless).writer;
            shlBytes(&reader, 17, &writer, chunkSize, chunkCount) catch @panic("unable to shift");
        }
    };
}

fn bench_shift_right(comptime chunkSize: usize, comptime chunkCount: usize) type {
    return struct {
        fn run(_: std.mem.Allocator) void {
            var reader: std.Io.Reader = .fixed(data[0..]);
            var useless = [_]u8{0};
            var writer = std.Io.Writer.Discarding.init(&useless).writer;
            shrBytes(&reader, 17, &writer, chunkSize, chunkCount) catch @panic("unable to shift");
        }
    };
}

var data: []u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};

    var threaded: std.Io.Threaded = .init(gpa.allocator(), .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    data = try loadData(arena_allocator, io);

    var bench = zbench.Benchmark.init(arena_allocator, .{});
    defer bench.deinit();

    inline for (&[_]usize{ 8, 16, 32, 64, 128 }) |chunk| {
        inline for (&[_]usize{ 2, 4, 8, 16, 32, 64, 128 }) |count| {
            try bench.add(try std.fmt.allocPrint(arena_allocator, "shl {d}x{d}", .{ chunk, count }), bench_shift(chunk, count).run, .{});
        }
    }

    inline for (&[_]usize{ 8, 16, 32, 64, 128 }) |chunk| {
        inline for (&[_]usize{ 2, 4, 8, 16, 32, 64, 128 }) |count| {
            try bench.add(try std.fmt.allocPrint(arena_allocator, "shr {d}x{d}", .{ chunk, count }), bench_shift_right(chunk, count).run, .{});
        }
    }

    try bench.add("naive implementation", naive_implementation, .{});
    try bench.add("casted u16", casted_16, .{});
    try bench.add("casted u32", casted_32, .{});
    try bench.add("casted u64", casted_64, .{});
    try bench.add("casted u128", casted_128, .{});
    try bench.add("casted u256", casted_256, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
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

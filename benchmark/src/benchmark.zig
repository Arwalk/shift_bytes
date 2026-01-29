const std = @import("std");
const zbench = @import("zbench");
const shlBytes = @import("shifters").shlBytes;

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

var data: []u8 = undefined;
var empty: []u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    data = try loadData(arena_allocator);
    empty = try arena_allocator.alloc(u8, data.len);

    var bench = zbench.Benchmark.init(arena_allocator, .{});
    defer bench.deinit();

    try bench.add("shift with 8 bytes chunk", bench_chunk_8, .{});
    try bench.add("shift with 16 bytes chunk", bench_chunk_16, .{});
    try bench.add("shift with 32 bytes chunk", bench_chunk_32, .{});
    try bench.add("shift with 64 bytes chunk", bench_chunk_64, .{});

    var buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const writer = &stderr.interface;
    try bench.run(writer);
    try writer.flush();
}

const std = @import("std");
const builtin = @import("builtin");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !void {
    var buf: [1024 * 1024 * 12]u8 = undefined;
    const arena = init.arena;
    var bfa: std.heap.BufferFirstAllocator = .init(&buf, arena.allocator());

    Cli.run(bfa.allocator(), init.io, init.minimal.args);
}

test {
    std.testing.refAllDecls(@This());
}

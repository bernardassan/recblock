arena: std.mem.Allocator,
db: Lmdb,
//Notice that an iterator initially points at the tip of a blockchain, thus blocks will be obtained from top to bottom, from newest to oldest.
current_hash: [32]u8,

const std = @import("std");
const log = std.log.scoped(.@"src/Iterator.zig");

const Iterator = @This();
const Block = @import("Block.zig");
const Lmdb = @import("Lmdb.zig");
const Blockchain = @import("Blockchain.zig");
const fmtHash = Blockchain.fmtHash;
const BLOCK_DB = Blockchain.BLOCK_DB;

pub fn iterator(fba: std.mem.Allocator, db: Lmdb, last_hash: [32]u8) Iterator {
    return .{ .arena = fba, .db = db, .current_hash = last_hash };
}

///the returned usize is the address of the Block in memory
///the ptr can be obtained with @intToPtr
pub fn next(self: *Iterator) ?Block {
    const txn = self.db.startTxn(.ro, BLOCK_DB);
    defer txn.doneReading();

    if (txn.getAlloc(Block, self.arena, self.current_hash[0..])) |current_block| {
        self.current_hash = current_block.previous_hash;

        return current_block;
        // return @ptrToInt(current_block);
    } else |_| {
        return null;
    }
}

pub fn print(chain_iter: *Iterator) void {
    //TODO:work on converting hashes to Big endian which is usually the expected form for display
    //improve the hex formating
    log.info("starting blockchain iteration\n", .{});
    while (chain_iter.next()) |current_block| {
        // const current_block = @intToPtr(*Block, block);
        log.info("previous hash is '{X}'", .{current_block.previous_hash[0..]});
        log.info("hash of current block is '{X}'", .{current_block.hash[0..]});
        log.info("nonce is {}", .{current_block.nonce});
        log.info("POW: {}\n\n", .{current_block.validate()});
    }
    log.info("done", .{});
}
// const Self = @This();
// const cast = @import("serializer.zig").cast;
//
// ptr: *anyopaque,
// vtable: *const VTable,
//
// pub const VTable = struct { next: fn (ptr: *anyopaque) ?usize };
//
// pub fn init(pointer: anytype) Self {
//     const Ptr = @TypeOf(pointer);
//     const ptr_info = @typeInfo(Ptr);
//
//     if (ptr_info != .Pointer) @compileError("pointer must be of a pointer type");
//     if (ptr_info.Pointer.size != .One) @compileError("pointer must be a single item pointer");
//
//     const alignment = ptr_info.Pointer.alignment;
//
//     const gen = struct {
//         pub fn nextImpl(ptr: *anyopaque) ?usize {
//             const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
//             return @call(.{ .modifier = .always_inline }, ptr_info.Pointer.child.next, .{self});
//         }
//         const vtable = VTable{ .next = nextImpl };
//     };
//
//     return .{ .ptr = pointer, .vtable = &gen.vtable };
// }
//
// pub inline fn next(self: Self) ?usize {
//     return self.vtable.next(self.ptr);
// }

// const SomeVar = struct {
//     fn SomeFunction(SomeArgs) void {
//         DoSomething();
//     }
// }.SomeFunction;

// const expect = @import("std").testing.expect;
//
// const Expr = union(enum) {
//     value: i32,
//     sum: [2]*const Expr,
//     sub: [2]*const Expr,
//     mul: [2]*const Expr,
//     div: [2]*const Expr,
// };
//
// fn eval(e: Expr) i32 {
//     return switch (e) {
//         .value => |x| x,
//         .sum => |es| eval(es[0].*) + eval(es[1].*),
//         .sub => |es| eval(es[0].*) - eval(es[1].*),
//         .mul => |es| eval(es[0].*) * eval(es[1].*),
//         .div => |es| @divFloor(eval(es[0].*), eval(es[1].*)),
//     };
// }
//
// test "(2+3)*(4*5) == 100" {
//     const two = Expr{ .value = 2 };
//     const three = Expr{ .value = 3 };
//     const four = Expr{ .value = 4 };
//     const five = Expr{ .value = 5 };
//
//     const plus = Expr{ .sum = .{ &two, &three } };
//     const mul = Expr{ .mul = .{ &four, &five } };
//     const result = Expr{ .mul = .{ &plus, &mul } };
//
//     try expect(eval(result) == 100);
// }

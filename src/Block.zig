//when the block is created
timestamp: Io.Timestamp,
//Thus miners must discover by brute force the "nonce" that, when included in the block, results in an acceptable hash.
nonce: usize = 0,
//stores the hash of the previous block
previous_hash: [32]u8,
//hash of the current block
hash: [32]u8 = undefined,
//the actual valuable information contained in the block .eg Transactions
transactions: std.ArrayListUnmanaged(Transaction),
//difficulty bits is the block header storing the difficulty at which the block was mined
difficulty_bits: u7 = TARGET_ZERO_BITS, //u7 limit value from 0 to 127 since we can't have a difficult equal in bitsize to the hashsize which is 256

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

const Block = @This();
const Transaction = @import("Transaction.zig");
const Blake3 = std.crypto.hash.Blake3;
//TARGET_ZERO_BITS must be a multiple of 4 and it determines the number of zeros in the target hash which determines difficult
//The higer TARGET_ZERO_BITS the harder or time consuming it is to find a hash
//NOTE: when we define a target adjusting algorithm this won't be a global constant anymore
//it specifies the target hash which is used to check hashes which are valid
//a block is only accepted by the network if its hash meets the network's difficulty target
//the number of leading zeros in the target serves as a good approximation of the current difficult
const TARGET_ZERO_BITS = 8;

///mine a new block
pub fn newBlock(
    arena: mem.Allocator,
    io: std.Io,
    previous_hash: [32]u8,
    transactions: []const Transaction,
) Block {
    var new_block: Block = .{
        .timestamp = .now(io, .real),
        .transactions = .empty,
        .previous_hash = previous_hash,
    };
    new_block.transactions.appendSlice(arena, transactions) catch unreachable;
    const pow_result = new_block.POW();
    new_block.hash = pow_result.hash;
    new_block.nonce = pow_result.nonce;
    return new_block;
}

pub fn genesisBlock(arena: mem.Allocator, io: Io, coinbase: Transaction) Block {
    const null_hash: [32]u8 = @splat(0x00);
    return newBlock(
        arena,
        io,
        null_hash,
        &.{coinbase},
    );
}

///Validate POW
pub fn validate(block: Block) bool {
    const target_hash = getTargetHash(block.difficulty_bits);

    const hash_int = block.hashBlock(block.nonce);

    const is_block_valid = if (hash_int < target_hash) true else false;
    return is_block_valid;
}

fn hashBlock(block: Block, nonce: usize) u256 {
    //TODO : optimize the sizes of these buffers base on the base and use exactly the amount that is needed
    var time_buf: [16]u8 = undefined;
    var timestamp: Io.Writer = .fixed(&time_buf);
    timestamp.printInt(block.timestamp.nanoseconds, 16, .lower, .{}) catch unreachable;

    var bits_buf: [3]u8 = undefined;
    var difficulty_bits: Io.Writer = .fixed(&bits_buf);
    difficulty_bits.printInt(block.difficulty_bits, 16, .lower, .{}) catch unreachable;

    var nonce_buf: [16]u8 = undefined;
    var nonce_val: Io.Writer = .fixed(&nonce_buf);
    nonce_val.printInt(nonce, 16, .lower, .{}) catch unreachable;

    var block_buf: [4096]u8 = undefined;

    //timestamp ,previous_hash and hash form the BlockHeader
    const block_headers = fmt.bufPrint(&block_buf, "{[previous_hash]s}{[transactions]s}{[timestamp]s}{[difficulty_bits]s}{[nonce]s}", .{
        .previous_hash = block.previous_hash,
        .transactions = block.hashTxs(),
        .timestamp = timestamp.buffered(),
        .difficulty_bits = difficulty_bits.buffered(),
        .nonce = nonce_val.buffered(),
    }) catch unreachable;

    var hash: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(block_headers, &hash, .{});

    const hash_int = mem.bytesToValue(u256, hash[0..]);

    return hash_int;
}

fn getTargetHash(target_dificulty: u7) u256 {
    //hast to be compaired with for valid hashes to prove work done
    const @"256bit": u9 = 256; //256 bit is 32 byte which is the size of a Blake3 hash
    const @"1": u256 = 1; //a 32 byte integer with the value of 1
    const difficult: u8 = @intCast(@"256bit" - target_dificulty);
    const target_hash_difficult = @shlExact(@"1", difficult);
    return target_hash_difficult;
}

///Proof of Work mining algorithm
///The usize returned is the nonce with which a valid block was mined
pub fn POW(block: Block) struct { hash: [32]u8, nonce: usize } {
    const target_hash = getTargetHash(block.difficulty_bits);

    var nonce: usize = 0;

    while (nonce < std.math.maxInt(usize)) {
        const hash_int = block.hashBlock(nonce);

        if (hash_int < target_hash) {
            return .{ .hash = @bitCast(hash_int), .nonce = nonce };
        } else {
            nonce += 1;
        }
    }
    unreachable;
}

fn hashTxs(self: Block) [32]u8 {
    var txhashes: []u8 = &.{};

    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    for (self.transactions.items) |txn| {
        txhashes = std.mem.concat(allocator, u8, &[_][]const u8{ txhashes, txn.id[0..] }) catch unreachable;
    }

    var hash: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(txhashes, &hash, .{});
    return hash;
}

test "newBlock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Wallets = @import("Wallets.zig").Wallets;
    const wallet_path = try std.fmt.allocPrint(allocator, "zig-cache/tmp/{s}/wallet.dat", .{tmp.sub_path[0..]});

    var wallets = Wallets.initWallets(allocator, wallet_path);
    const genesis_wallet = wallets.createWallet();

    const coinbase = Transaction.initCoinBaseTx(allocator, genesis_wallet, wallets.wallet_path);
    var genesis_block = Block.genesisBlock(allocator, coinbase);
    var new_block = newBlock(allocator, genesis_block.hash, &.{coinbase});

    try testing.expectEqualSlices(u8, genesis_block.hash[0..], new_block.previous_hash[0..]);
    const result = new_block.POW();
    try testing.expectEqual(result.nonce, new_block.nonce);
    try testing.expectEqualStrings(result.hash[0..], new_block.hash[0..]);
}

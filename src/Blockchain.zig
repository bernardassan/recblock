//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash

last_hash: Transaction.TxID,
db: Lmdb,
io: std.Io,
arena: mem.Allocator,
wallet_path: []const u8,

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"src/Blockchain.zig");
const fmt = std.fmt;
const debug = std.debug;
const heap = std.heap;
const process = std.process;

const BlockChain = @This();
const Block = @import("Block.zig");
const Transaction = @import("Transaction.zig");
const Lmdb = @import("Lmdb.zig");
const Iterator = @import("Iterator.zig");
const Wallets = @import("Wallets.zig");
pub const BLOCK_DB = "blocks";
pub const LAST = "last";
const WALLET = "wallet.dat";
const TxMap = std.AutoHashMap(Transaction.TxID, Transaction.OutputIndex);
const Wallet = Wallets.Wallet;
const Address = Wallets.Address;

pub fn fmtHash(hash: [32]u8) [32]u8 {
    const hash_int: u256 = @bitCast(hash);
    const big_end_hash_int = @byteSwap(hash_int);
    return @bitCast(big_end_hash_int);
}

//TODO:organise and document exit codes
pub fn getChain(db: Lmdb, arena: mem.Allocator, io: std.Io) BlockChain {
    const txn = db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    if (txn.get(Transaction.TxID, LAST)) |last_block_hash| {
        const wallet_path = txn.getAlloc([]const u8, arena, WALLET) catch unreachable;
        return .{
            .arena = arena,
            .io = io,
            .last_hash = last_block_hash,
            .db = db,
            .wallet_path = wallet_path,
        };
    } else |_| {
        log.err("create a blockchain with creatchain command before using any other command", .{});
        process.exit(1);
    }
}

///create a new BlockChain
pub fn newChain(
    db: Lmdb,
    arena: mem.Allocator,
    io: std.Io,
    address: Wallets.Address,
    wallet_path: []const u8,
) BlockChain {
    if (!Wallet.validateAddress(address)) {
        log.err("blockchain address {s} is invalid", .{address});
        process.exit(4);
    }
    var buf: [1024 * 6]u8 = undefined;
    var fba: heap.FixedBufferAllocator = .init(&buf);
    const allocator = fba.allocator();

    const coinbase_tx: Transaction = .initCoinBaseTx(allocator, io, address, wallet_path);
    const genesis_block: Block = .genesisBlock(allocator, io, coinbase_tx);

    const txn = db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    txn.put(LAST, genesis_block.hash) catch |newchain_err| switch (newchain_err) {
        error.KeyAlreadyExist => {
            log.err("Attempting to create new chain at an address '{s}' which already contains a chain", .{address});
            process.exit(1);
        },
        else => unreachable,
    };

    txn.putAlloc(allocator, WALLET, wallet_path) catch unreachable;
    txn.putAlloc(allocator, genesis_block.hash[0..], genesis_block) catch unreachable;

    log.info("new blockchain is create with address '{s}'\nhash of the created blockchain is '{X}'", .{
        address,
        genesis_block.hash[0..],
    });
    log.info("You get a reward of RBC {d} for mining the coinbase transaction", .{Transaction.SUBSIDY});

    return .{
        .last_hash = genesis_block.hash,
        .db = db,
        .io = io,
        .arena = arena,
        .wallet_path = wallet_path,
    };
}

///add a new Block to the BlockChain
pub fn mineBlock(bc: *BlockChain, transactions: []const Transaction) void {
    for (transactions) |tx| {
        debug.assert(bc.verifyTx(tx) == true);
    }

    var buf: [8096]u8 = undefined;
    var fba: heap.FixedBufferAllocator = .init(&buf);
    const allocator = fba.allocator();

    const new_block: Block = .newBlock(
        allocator,
        bc.io,
        bc.last_hash,
        transactions,
    );
    log.info("new transaction is '{X}'", .{new_block.hash[0..]});

    debug.assert(new_block.validate() == true);

    const txn = bc.db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    txn.putAlloc(allocator, new_block.hash[0..], new_block) catch unreachable;
    txn.update(LAST, new_block.hash) catch unreachable;
    bc.last_hash = new_block.hash;
}

///find unspent transactions
//TODO: add test for *UTX* and Tx Output fn's
fn findUTxs(bc: BlockChain, pub_key_hash: Wallets.PublicKeyHash) []const Transaction {
    //TODO: find a way to cap the max stack usage
    //INITIA_IDEA: copy relevant data and free blocks
    var buf: [1024 * 950]u8 = undefined;
    var fba: heap.FixedBufferAllocator = .init(buf[0..]);
    const allocator = fba.allocator();

    var unspent_txos: std.ArrayList(Transaction) = .empty;
    defer unspent_txos.shrinkToLen(bc.arena) catch @panic("OOM");

    var spent_txos: TxMap = .init(allocator);

    var bc_itr: Iterator = .iterator(allocator, bc.db, bc.last_hash);

    while (bc_itr.next()) |block| {
        for (block.transactions.items) |tx| {
            output: for (tx.tx_out.items, 0..) |txoutput, txindex| {
                //was the output spent? We skip those that were referenced in inputs (their values were moved to
                //other outputs, thus we cannot count them)
                if (spent_txos.get(tx.id)) |spent_output_index| {
                    if (spent_output_index.toU64() == txindex) {
                        continue :output;
                    }
                }

                //If an output was locked by the same pub_key_hash we’re searching unspent transaction outputs for,
                //then this is the output we want
                if (txoutput.isLockedWithKey(pub_key_hash)) {
                    unspent_txos.append(bc.arena, tx) catch unreachable;
                }
            }

            //we gather all inputs that could unlock outputs locked with the provided pub_key_hash (this doesn’t apply
            //to coinbase transactions, since they don’t unlock outputs)
            if (!tx.isCoinBaseTx()) {
                for (tx.tx_in.items) |txinput| {
                    if (txinput.usesKey(pub_key_hash)) {
                        spent_txos.putNoClobber(txinput.out_id, txinput.out_index) catch unreachable;
                    }
                }
            }
        }

        if (block.previous_hash[0] == 0x00) {
            break;
        }
    }
    return unspent_txos.toOwnedSliceAssert();
}

///find unspent transaction outputs
fn findUTxOs(self: BlockChain, pub_key_hash: Wallets.PublicKeyHash) []const Transaction.TxOutput {
    var tx_output_list: std.ArrayList(Transaction.TxOutput) = .empty;
    defer tx_output_list.shrinkToLen(self.arena) catch @panic("OOM");

    const unspent_txs = self.findUTxs(pub_key_hash);

    for (unspent_txs) |tx| {
        for (tx.tx_out.items) |output| {
            if (output.isLockedWithKey(pub_key_hash)) {
                tx_output_list.append(self.arena, output) catch @panic("OOM");
            }
        }
    }
    return tx_output_list.toOwnedSliceAssert();
}

///create a new Transaction by moving value from one address to another
fn newUTx(self: BlockChain, amount: Transaction.Coins, from: Wallets.Address, to: Wallets.Address) Transaction {
    var input: std.ArrayListUnmanaged(Transaction.TxInput) = .empty;
    var output: std.ArrayListUnmanaged(Transaction.TxOutput) = .empty;

    //Before creating new outputs, we first have to find all unspent outputs and ensure that they store enough value.
    const spendable_txns = self.findSpendableOutputs(Wallet.getPubKeyHash(from), amount);
    const accumulated_amount = spendable_txns.accumulated_amount;
    var unspent_output = spendable_txns.unspent_output;

    if (accumulated_amount.toU64() < amount.toU64()) {
        log.err("not enough funds to transfer RBC {d} from '{s}' to '{s}'", .{ amount, from, to });
        process.exit(2);
    }

    //Build a list of inputs
    //for each found output an input referencing it is created.
    var itr = unspent_output.iterator();
    const wallets: Wallets = .getWallets(self.arena, self.io, self.wallet_path);
    const froms_wallet = wallets.getWallet(from);

    while (itr.next()) |kv| {
        const txid = kv.key_ptr.*;
        const out_index = kv.value_ptr.*;

        input.append(
            self.arena,
            .{
                .out_id = txid,
                .out_index = out_index,
                .sig = std.mem.zeroes(Wallets.Signature),
                .pub_key = froms_wallet.wallet_keys.public_key,
            },
        ) catch unreachable;
    }

    //Build a list of outputs
    //The output that’s locked with the receiver address. This is the actual transferring of coins to other address.
    output.append(
        self.arena,
        .{ .value = amount, .pub_key_hash = Wallet.getPubKeyHash(to) },
    ) catch unreachable;

    //The output that’s locked with the sender address. This is a change. It’s only created when unspent outputs hold
    //more value than required for the new transaction. Remember: outputs are indivisible.
    if (accumulated_amount.toU64() > amount.toU64()) {
        output.append(self.arena, .{
            .value = accumulated_amount.sub(amount),
            .pub_key_hash = Wallet.getPubKeyHash(from),
        }) catch unreachable;
    }

    var newtx: Transaction = .newTx(input, output);
    //we sign the transaction with the keys of the owner/sender of the value
    self.signTx(&newtx, froms_wallet.wallet_keys);
    return newtx;
}

fn findSpendableOutputs(self: BlockChain, pub_key_hash: Wallets.PublicKeyHash, amount: Transaction.Coins) struct {
    accumulated_amount: Transaction.Coins,
    unspent_output: TxMap,
} {
    var unspent_output = TxMap.init(self.arena);

    const unspentTxs = self.findUTxs(pub_key_hash);

    var accumulated_amount: Transaction.Coins = .zero;

    // //The method iterates over all unspent transactions and accumulates their values.
    spendables: for (unspentTxs) |tx| {
        //When the accumulated value is more or equals to the amount we want to transfer, it stops and returns the
        //accumulated value and output indices grouped by transaction IDs. We don’t want to take more than we’re going to spend.
        for (tx.tx_out.items, 0..) |output, out_index| {
            if (output.isLockedWithKey(pub_key_hash) and accumulated_amount.toU64() < amount.toU64()) {
                accumulated_amount = accumulated_amount.add(output.value);
                unspent_output.putNoClobber(tx.id, .toIndex(out_index)) catch unreachable;

                if (accumulated_amount.toU64() >= amount.toU64()) {
                    break :spendables;
                }
            }
        }
    }

    return .{
        .accumulated_amount = accumulated_amount,
        .unspent_output = unspent_output,
    };
}

///finds a transaction by its ID.This is used to build the `PrevTxMap`
fn findTx(self: BlockChain, tx_id: Transaction.TxID) Transaction {
    var itr = Iterator.iterator(self.arena, self.db, self.last_hash);

    while (itr.next()) |block| {
        for (block.transactions.items) |tx| {
            if (std.mem.eql(u8, tx.id[0..], tx_id[0..])) return tx;
        }
        if (block.previous_hash[0] == '\x00') break;
    }
    unreachable;
}

///take a transaction `tx` finds all previous transactions it references and sign it with KeyPair `wallet_keys`
fn signTx(bc: BlockChain, tx: *Transaction, wallet_keys: Wallet.KeyPair) void {
    var buf: [1024 * 1024]u8 = undefined;
    var fba_: heap.FixedBufferAllocator = .init(&buf);
    const fba = fba_.allocator();

    var prev_txs: Transaction.PrevTxMap = .empty;

    for (tx.tx_in.items) |value_in| {
        const found_tx = bc.findTx(value_in.out_id);
        prev_txs.putNoClobber(fba, value_in.out_id, found_tx) catch unreachable;
    }
    tx.sign(fba, bc.io, wallet_keys, prev_txs);
}

///take a transaction `tx` finds transactions it references and verify it
fn verifyTx(self: BlockChain, tx: Transaction) bool {
    var buf: [1024 * 1024]u8 = undefined;
    var fba_: heap.FixedBufferAllocator = .init(&buf);
    const fba = fba_.allocator();

    var prev_txs: Transaction.PrevTxMap = .empty;

    for (tx.tx_in.items) |value_in| {
        const found_tx = self.findTx(value_in.out_id);
        prev_txs.putNoClobber(fba, value_in.out_id, found_tx) catch unreachable;
    }
    return tx.verify(prev_txs, fba);
}

pub fn getBalance(self: BlockChain, address: Wallets.Address) Transaction.Coins {
    if (!Wallet.validateAddress(address)) {
        log.err("address {s} is invalid", .{address});
        process.exit(4);
    }
    var balance: Transaction.Coins = .zero;
    const utxos = self.findUTxOs(Wallet.getPubKeyHash(address));

    for (utxos) |utxo| {
        balance = balance.add(utxo.value);
    }
    return balance;
}

pub fn sendValue(self: *BlockChain, amount: Transaction.Coins, from: Wallets.Address, to: Wallets.Address) void {
    debug.assert(amount != Transaction.Coins.zero);
    debug.assert(!std.mem.eql(u8, &from, &to));

    if (!Wallet.validateAddress(from)) {
        log.err("sender address {s} is invalid", .{from});
        process.exit(4);
    }
    if (!Wallet.validateAddress(to)) {
        log.err("recipient address {s} is invalid", .{to});
        process.exit(4);
    }
    const new_transaction = self.newUTx(amount, from, to);

    self.mineBlock(&.{new_transaction});
}

test "getBalance , sendValue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var db = Lmdb.initdb(db_path, .rw);
    defer db.deinitdb();

    const wallet_path = try std.fmt.allocPrint(allocator, "zig-cache/tmp/{s}/wallet.dat", .{tmp.sub_path[0..]});
    var wallets: Wallets = .initWallets(allocator, wallet_path);

    const genesis_wallet = wallets.createWallet();
    var bc = newChain(db, allocator, genesis_wallet, wallets.wallet_path);

    //a reward of 10 RBC is given for mining the coinbase
    try std.testing.expectEqual(@as(usize, 10), bc.getBalance(genesis_wallet));

    const my_wallet = wallets.createWallet();
    bc.sendValue(7, genesis_wallet, my_wallet);

    try std.testing.expectEqual(@as(usize, 3), bc.getBalance(genesis_wallet));
    try std.testing.expectEqual(@as(usize, 7), bc.getBalance(my_wallet));

    bc.sendValue(2, my_wallet, genesis_wallet);

    try std.testing.expectEqual(@as(usize, 5), bc.getBalance(my_wallet));
    try std.testing.expectEqual(@as(usize, 5), bc.getBalance(genesis_wallet));
}

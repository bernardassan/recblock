//CHECKOUT: https://arxiv.org/abs/1806.06738 The Evolution of Embedding Metadata in Blockchain Transactions
//by Tooba Faisal, Nicolas Courtois, Antoaneta Serguieva
//USE_AS: further extension to this blockchain to improve anonymity and security even futher
//hash of transaction
id: TxID,
//Inputs of a new transaction reference outputs of a previous transaction
tx_in: InList,
// Outputs are where coins are actually stored.
tx_out: OutList,

const std = @import("std");
const zeroes = mem.zeroes;
const mem = std.mem;
const serializer = @import("serializer.zig");

//Transactions just lock values with a script, which can be unlocked only by the one who locked them.
const Transaction = @This();
const InList = std.ArrayList(TxInput);
const OutList = std.ArrayList(TxOutput);
///previous transaction which are found to contain a specified TxID
pub const PrevTxMap = std.AutoHashMapUnmanaged(TxID, Transaction);
const DefaultCsprng = std.Random.DefaultCsprng;
const Wallets = @import("Wallets.zig");
const Allocator = mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const Wallet = Wallets.Wallet;
pub const TxID = [Blake3.digest_length]u8;
//subsidy is the amount of reward for mining
pub const SUBSIDY = 10;

pub const Coins = enum(u64) {
    _,

    pub const zero: Coins = .toCoin(0);

    pub fn add(to: Coins, amount: Coins) Coins {
        return @enumFromInt(@intFromEnum(to) + @intFromEnum(amount));
    }

    pub fn sub(to: Coins, amount: Coins) Coins {
        return @enumFromInt(@intFromEnum(to) - @intFromEnum(amount));
    }

    pub fn toU64(coins: Coins) u64 {
        return @intFromEnum(coins);
    }

    pub fn toCoin(amount: usize) Coins {
        return @enumFromInt(amount);
    }
};
//TxOutputs are indivisible,meaning you can't reference part of it's value
//When an output is referenced in a new transaction, it’s spent as a whole.
//And if its value is greater than required, a change is generated and sent back to the sender.
pub const TxOutput = struct {
    ///stores actual value of coins
    value: Coins,
    ///coins are stored by locking them with a puzzle/key, which is stored in the pub_key
    pub_key_hash: Wallets.PublicKeyHash,
    ///simply locks an output to an `address` since When we send coins to someone, we know only their address
    pub fn lock(self: *TxOutput, address: Wallets.Address) void {
        const pub_key_hash = Wallet.getPubKeyHash(address);
        self.pub_key_hash = pub_key_hash;
    }

    ///checks if provided public key hash was used to lock the output .ie if the output can be used by the owner of the pubkey
    pub fn isLockedWithKey(self: TxOutput, pub_key_hash: Wallets.PublicKeyHash) bool {
        return mem.eql(u8, self.pub_key_hash[0..], pub_key_hash[0..]);
    }
};

pub const OutputIndex = enum(u64) {
    _,

    pub const coinbase: OutputIndex = .toIndex(std.math.maxInt(u64));

    pub fn toIndex(index: u64) OutputIndex {
        return @enumFromInt(index);
    }

    pub fn toU64(index: OutputIndex) usize {
        return @intFromEnum(index);
    }
};

pub const TxInput = struct {
    ///id of referenced output transaction
    out_id: TxID,
    ///index of an output in the transaction
    out_index: OutputIndex,
    ///provides signature data to be used to unlock an output’s pub_key
    sig: Wallets.Signature,

    pub_key: Wallets.PublicKey,

    ///checks that an input uses a specific key to unlock an output
    pub fn usesKey(self: TxInput, pub_key_hash: Wallets.PublicKeyHash) bool {
        const locking_hash = Wallet.hashPubKey(self.pub_key);
        return mem.eql(u8, locking_hash[0..], pub_key_hash[0..]);
    }
};

//A coinbase transaction is a special type of transactions, which doesn’t require previously existing outputs.
//This is the reward miners get for mining new blocks.
pub fn initCoinBaseTx(arena: Allocator, io: std.Io, to: Wallets.Address, wallet_path: []const u8) Transaction {
    var inlist: InList = .empty;
    const wallets = Wallets.getWallets(arena, io, wallet_path);
    const tos_wallet = wallets.getWallet(to);
    inlist.append(
        arena,
        .{
            .out_id = zeroes(TxID),
            .out_index = .coinbase,
            .sig = zeroes(Wallets.Signature),
            .pub_key = tos_wallet.wallet_keys.public_key,
        },
    ) catch unreachable;

    var outlist: OutList = .empty;
    outlist.append(
        arena,
        .{ .value = .toCoin(SUBSIDY), .pub_key_hash = Wallet.getPubKeyHash(to) },
    ) catch unreachable;

    var tx: Transaction = .{
        .id = undefined,
        .tx_in = inlist,
        .tx_out = outlist,
    };
    tx.setId();

    return tx;
}

///Transactions must be signed because this is the only way in Bitcoin/Recblock to guarantee that one cannot spend coins
///belonging to someone else.Considering that transactions unlock previous outputs, redistribute their values, and lock new outputs,
///the following data must be signed:
///Public key hashes stored in unlocked outputs. This identifies “sender” of a transaction.
///Public key hashes stored in new, locked, outputs. This identifies “recipient” of a transaction.
///Values of new outputs.
///Since we don’t need to sign the public keys stored in inputs. It’s not a transaction that’s signed, but its
///trimmed copy with tx_inputs storing public_key_hash from referenced outputs
///in order to sign a transaction, we need to access the outputs referenced in the inputs of the transaction , thus
///we need the transactions that store these outputs. `prev_txs`
pub fn sign(self: *Transaction, fba: Allocator, io: std.Io, wallet_keys: Wallet.KeyPair, prev_txs: PrevTxMap) void {
    //Coinbase transactions are not signed because they don't contain real inputs
    if (self.isCoinBaseTx()) return;

    //A trimmed copy will be signed, not a full transaction:
    //The copy will include all the inputs and outputs, but TxInput.sig and TxInput.pub_key are empty
    var trimmed_tx_copy = self.trimmedCopy(fba);

    for (trimmed_tx_copy.tx_in.items, 0..) |value_in, in_index| {
        //we use prev_txs because that has signed and verified to help in signing and verifying new transactions
        if (prev_txs.get(value_in.out_id)) |prev_tx| {
            //since the public_key of trimmedCopy is empty we store a copy of the pub_key_hash from the transaction output
            //referenced by the input `value_in`'s out_index which was found to have the same TxID provided by `prev_tx`
            copyHashIntoPubKey(
                &trimmed_tx_copy.tx_in.items[in_index].pub_key,
                prev_tx.tx_out.items[value_in.out_index.toU64()].pub_key_hash,
            );
        }
        trimmed_tx_copy.setId();

        var secret_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
        io.randomSecure(&secret_seed) catch unreachable;

        var cspring = DefaultCsprng.init(secret_seed);
        const random = cspring.random();

        var noise: [Wallets.Ed25519.noise_length]u8 = undefined;
        random.bytes(&noise);

        const signature = wallet_keys.sign(trimmed_tx_copy.id[0..], noise) catch unreachable;

        self.tx_in.items[in_index].sig = signature;
    }
}

fn copyHashIntoPubKey(pub_key: *Wallets.PublicKey, pub_key_hash: Wallets.PublicKeyHash) void {
    //copy 0..20 of pub_key_hash into the beginning of pub_key
    @memcpy(pub_key.bytes[0..20], pub_key_hash[0..]);
    //recopy 12 bytes from pub_key_hash into 21..end of pub_key
    @memcpy(pub_key.bytes[@sizeOf(Wallets.PublicKeyHash)..], pub_key_hash[0 .. @sizeOf(Wallets.PublicKey) - @sizeOf(Wallets.PublicKeyHash)]);
}

pub fn verify(self: Transaction, prev_txs: PrevTxMap, fba: Allocator) bool {
    var trimmed_tx_copy = self.trimmedCopy(fba);

    for (self.tx_in.items, 0..) |value_in, in_index| {
        if (prev_txs.get(value_in.out_id)) |prev_tx|
            copyHashIntoPubKey(
                &trimmed_tx_copy.tx_in.items[in_index].pub_key,
                prev_tx.tx_out.items[value_in.out_index.toU64()].pub_key_hash,
            );
        trimmed_tx_copy.setId();
        if (value_in.sig.verify(trimmed_tx_copy.id[0..], value_in.pub_key)) |_| {} else |err| {
            std.log.info("public key has a value of {}", .{value_in});
            std.log.err("{t} occured while verifying the transaction", .{err});
            return false;
        }
    }
    return true;
}

fn trimmedCopy(self: Transaction, fba: Allocator) Transaction {
    var inlist: InList = .empty;
    var outlist: OutList = .empty;

    for (self.tx_in.items) |value_in| {
        inlist.append(fba, .{
            .out_id = value_in.out_id,
            .out_index = value_in.out_index,
            .pub_key = zeroes(Wallets.PublicKey),
            .sig = zeroes(Wallets.Signature),
        }) catch unreachable;
    }

    for (self.tx_out.items) |value_out| {
        outlist.append(fba, TxOutput{ .value = value_out.value, .pub_key_hash = value_out.pub_key_hash }) catch unreachable;
    }

    //At this moment, all transactions but the current one are “empty”,
    //i.e. their .sig and .pub_key fields are set to zeroes.
    return .{
        .id = self.id,
        .tx_in = inlist,
        .tx_out = outlist,
    };
}

pub fn newTx(input: InList, output: OutList) Transaction {
    var tx: Transaction = .{
        .id = undefined,
        .tx_in = input,
        .tx_out = output,
    };
    tx.setId();
    return tx;
}

pub fn isCoinBaseTx(self: Transaction) bool {
    return self.tx_in.items.len == 1 and
        self.tx_in.items[0].out_index == Transaction.OutputIndex.coinbase and
        mem.eql(u8, self.tx_in.items[0].out_id[0..], zeroes(TxID)[0..]);
}

///set Id of transaction
fn setId(self: *Transaction) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const serialized_data = serializer.serializeAlloc(fba.allocator(), self);

    var hash: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(serialized_data[0..], &hash, .{});
    self.id = hash;
}

test "isCoinBaseTx" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const wallet_path = try std.fmt.allocPrint(allocator, "zig-cache/tmp/{s}/wallet.dat", .{tmp.sub_path[0..]});
    var wallets = Wallets.initWallets(allocator, wallet_path);
    const test_coinbase = wallets.createWallet();

    const coinbase = initCoinBaseTx(allocator, test_coinbase, wallets.wallet_path);
    try std.testing.expect(isCoinBaseTx(coinbase));
}

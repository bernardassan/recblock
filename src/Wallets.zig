///to keep a collection of wallets, save them to a file, and load them from it when needed
wallets: WalleltMap,
///path to storage for wallets
wallet_path: []const u8,
arena: mem.Allocator,
io: std.Io,

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const base64 = std.base64;
const serializer = @import("s2s");

pub const Wallets = @This();
const WalleltMap = std.array_hash_map.Auto(Address, Wallet);
pub const Ed25519 = crypto.sign.Ed25519;
const Blake3 = crypto.hash.Blake3;
const Blake2b160 = crypto.hash.blake2.Blake2b160;
pub const ADDR_CKSUM_LEN = 4; //meaning 4 u8 values making up 32bit
pub const PUB_KEY_HASH_LEN = Blake2b160.digest_length;
//version of the address generation algorithm
pub const VERSION_LEN = 1;
const VERSION = '\x01';
pub const PUB_KEY_LEN = Ed25519.public_length;
pub const ADDRESS_SIZE = encodedAddressLenght();
pub const PrivateKey = Ed25519.SecretKey;
pub const PublicKey = Ed25519.PublicKey;
pub const Signature = Ed25519.Signature;
pub const Address = [ADDRESS_SIZE]u8;
pub const PublicKeyHash = [PUB_KEY_HASH_LEN]u8;
pub const Checksum = [ADDR_CKSUM_LEN]u8;
const VersionedHash = [VERSION_LEN + PUB_KEY_HASH_LEN]u8;
const RawAddress = [VERSION_LEN + PUB_KEY_HASH_LEN + ADDR_CKSUM_LEN]u8;

///use to initialize `Wallets`
pub fn initWallets(arena: mem.Allocator, wallet_path: []const u8) Wallets {
    return .{
        .wallets = .empty,
        .wallet_path = wallet_path,
        .arena = arena,
    };
}

fn newWallet(wallets: *Wallets) Address {
    const wallet: Wallet = .initWallet();
    const wallet_address = wallet.address();
    wallets.wallets.putNoClobber(wallets.arena, wallet_address, wallet) catch unreachable;
    return wallet_address;
}

///create a new wallet and save it into `wallet_path`
pub fn createWallet(wallets: Wallets) Address {
    var wallets_ = getWallets(wallets.arena, wallets.wallet_path);
    const wallet_address = wallets_.newWallet();
    wallets_.saveWallets();
    return wallet_address;
}

//TODO: optimize so that not all wallets are loaded into memory this is a potentially expensive operation
///return previous wallets from `wallet_path` else return a new empty wallet
pub fn getWallets(arena: mem.Allocator, wallet_path: []const u8) Wallets {
    var wallets = initWallets(arena, wallet_path);
    wallets.loadWallets();
    return wallets;
}

pub fn getAddresses(wallets: Wallets) []const Address {
    return wallets.wallets.keys();
}

///get the wallet associated with this address
pub fn getWallet(self: Wallets, address: Address) Wallet {
    return self.wallets.get(address).?;
}

///load saved wallet data
fn loadWallets(wallets: *Wallets) void {
    const file = std.Io.Dir.cwd().openFile(wallets.io, wallets.wallet_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => unreachable,
    };
    defer file.close(wallets.io);

    var buf: [1024]u8 = undefined;
    var fr = file.reader(wallets.io, &buf);
    const fri = &fr.interface;

    while (true) {
        const wallet_key = serializer.deserialize(fri, Address) catch |err| switch (err) {
            error.EndOfStream => return,
            else => unreachable,
        };
        const wallet_value = serializer.deserialize(fri, Wallet) catch unreachable;

        wallets.wallets.putNoClobber(wallets.arena, wallet_key, wallet_value) catch unreachable;
    }
}
//TODO: oraganize exit codes
//TODO: a way to efficiently save wallets .ie something like write only part which aren't already in the file
///save wallets to `wallet_path` field
fn saveWallets(self: Wallets) void {
    const file = std.fs.cwd().openFile(self.wallet_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => std.fs.cwd().createFile(self.wallet_path, .{}) catch unreachable,
        else => unreachable,
    };
    defer file.close();

    var bwriter = std.io.bufferedWriter(file.writer());
    defer bwriter.flush() catch unreachable;
    const writer = bwriter.writer();

    var itr = self.wallets.iterator();

    while (itr.next()) |key_value| {
        serializer.serialize(writer, Address, key_value.key_ptr.*) catch unreachable;
        serializer.serialize(writer, Wallet, key_value.value_ptr.*) catch unreachable;
    }
}

///A wallet is nothing but a key/value pair.
pub const Wallet = struct {
    //https://security.stackexchange.com/questions/50878/ecdsa-vs-ecdh-vs-ed25519-vs-curve25519
    //deviete from bitcoin which uses ecdsa
    pub const KeyPair = Ed25519.KeyPair;
    wallet_keys: KeyPair,

    ///use to initialize `Wallet` ie. the public and private keys
    pub fn initWallet() Wallet {
        return .{ .wallet_keys = Ed25519.KeyPair.generate() };
    }

    pub fn address(self: Wallet) Address {
        const pub_key_hash = hashPubKey(self.wallet_keys.public_key);

        const versioned_payload = version(VERSION, pub_key_hash);

        const checksum_payload = checksum(versioned_payload);

        return encodeBase64(versioned_payload, checksum_payload);
    }

    ///check and make sure `wallet_address` is a valid wallet address
    pub fn validateAddress(wallet_address: Address) bool {
        const decoded_address = decodeBase64(wallet_address);
        const decoded_version = decoded_address[0];
        const decoded_pub_key_hash = decoded_address[VERSION_LEN .. PUB_KEY_HASH_LEN + 1].*;
        const cksum_start = VERSION_LEN + PUB_KEY_HASH_LEN;
        const actual_cksum = decoded_address[cksum_start..].*;

        const target_chksum = checksum(version(decoded_version, decoded_pub_key_hash));

        return mem.eql(u8, actual_cksum[0..], target_chksum[0..]);
    }

    //use base64 instead of bitcoins base58 for encoding address payload
    fn encodeBase64(versioned_payload: VersionedHash, checksum_payload: Checksum) Address {
        var buf: RawAddress = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);

        const address_to_encode = mem.concat(fba.allocator(), u8, &.{ &versioned_payload, &checksum_payload }) catch unreachable;

        const encoder = comptime base64.Base64Encoder.init(base64.url_safe_alphabet_chars, null);
        var dest_buf: Address = undefined;
        _ = encoder.encode(&dest_buf, address_to_encode[0..]);

        return dest_buf;
    }

    fn decodeBase64(wallet_address: Address) RawAddress {
        var buf: [100]u8 = undefined;
        const decoder = base64.Base64Decoder.init(base64.url_safe_alphabet_chars, null);
        const decoded_buf = buf[0 .. decoder.calcSizeForSlice(wallet_address[0..]) catch unreachable];
        decoder.decode(decoded_buf, wallet_address[0..]) catch unreachable;
        return mem.bytesAsSlice(RawAddress, decoded_buf)[0];
    }

    pub fn getPubKeyHash(wallet_address: Address) PublicKeyHash {
        const decoded_address = decodeBase64(wallet_address);

        return (decoded_address[VERSION_LEN .. PUB_KEY_HASH_LEN + 1]).*;
    }

    fn version(wallet_version: u8, pub_key_hash: PublicKeyHash) VersionedHash {
        var versioned_payload_buf: VersionedHash = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&versioned_payload_buf);

        _ = mem.concat(fba.allocator(), u8, &.{ &.{wallet_version}, pub_key_hash[0..] }) catch unreachable;
        return versioned_payload_buf;
    }

    pub fn hashPubKey(pub_key: PublicKey) PublicKeyHash {
        //https://linuxadictos.com/en/blake3-a-fast-and-parallelizable-secure-cryptographic-hash-function.html
        //replaces sha256 with Blake3 which is also 256 and faster in software
        var pk_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(pub_key.toBytes()[0..], &pk_hash, .{});

        //use Blake2b160 as a replacement for bitcoins ripemd-160 https://en.bitcoin.it/wiki/RIPEMD-160
        //smaller bit lenght for easy readability for user
        var final_hash: PublicKeyHash = undefined;
        Blake2b160.hash(pk_hash[0..], &final_hash, .{});

        return final_hash;
    }

    //checksum is the first four bytes of the resulted hash
    fn checksum(versioned_payload: VersionedHash) Checksum {
        var first_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(versioned_payload[0..], &first_hash, .{});

        var final_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(first_hash[0..], &final_hash, .{});

        return (final_hash[0..ADDR_CKSUM_LEN]).*;
    }
};

fn encodedAddressLenght() usize {
    const encoder = base64.Base64Encoder.init(base64.url_safe_alphabet_chars, null);
    return encoder.calcSize(VERSION_LEN + PUB_KEY_HASH_LEN + ADDR_CKSUM_LEN);
}

test "Wallet.address,Wallet.getPubKeyHash" {
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(seed[0..], "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const key_pair = try Ed25519.KeyPair.create(seed);

    var secret_key: [64]u8 = undefined;
    const secret_key_hex = "8052030376D47112BE7F73ED7A019293DD12AD910B654455798B4667D73DE1662D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083";
    _ = try std.fmt.hexToBytes(&secret_key, secret_key_hex);

    var public_key: [32]u8 = undefined;
    const public_key_hex = "2D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083";
    _ = try std.fmt.hexToBytes(&public_key, public_key_hex);

    var expected_address: [34]u8 = undefined;
    const expected_address_hex = "416430745F41506746466E4B684967655739423938752D41554E6A557A6439766467";
    _ = try std.fmt.hexToBytes(&expected_address, expected_address_hex);

    const actual_address = Wallet.address(.{ .wallet_keys = .{ .secret_key = key_pair.secret_key, .public_key = key_pair.public_key } });

    try std.testing.expectEqualStrings(expected_address[0..], actual_address[0..]);

    try std.testing.expectEqualStrings(Wallet.decodeBase64(expected_address)[VERSION_LEN .. PUB_KEY_HASH_LEN + 1], Wallet.getPubKeyHash(expected_address)[0..]);
}

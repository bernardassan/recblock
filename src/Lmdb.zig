db_env: *Env,
txn: ?*Txn = null,
txn_type: TxnType,
db_handle: DbHandle = undefined,

const std = @import("std");
const mdb = @import("mdb");
const panic = std.debug.panic;
const assert = std.debug.assert;
const info = std.log.info;
const testing = std.testing;
const err = std.posix.E;
const serializer = @import("serializer.zig");

pub const Lmdb = @This();
const Env = mdb.MDB_env;
const Key = mdb.MDB_val;
const Val = mdb.MDB_val;
const Txn = mdb.MDB_txn;
const DbHandle = mdb.MDB_dbi;
const TxnType = enum { rw, ro };
const BLOCK_DB = @import("Transaction.zig").BLOCK_DB;

///`db_path` is the directory in which the database files reside. This directory must already exist and be writable.
///initialize db environment (mmap file) specifing the db mode `.rw/.ro`
///make sure to start a transaction .ie startTxn() fn before calling any db manipulation fn's
///a maximum of two named db's are allowed
pub fn initdb(io: std.Io, db_path: []const u8, txn_type: TxnType) Lmdb {
    var db_env: ?*Env = undefined;
    const env_state = mdb.mdb_env_create(&db_env);
    checkState(env_state) catch unreachable;
    const max_num_of_dbs = 2;

    const db_limit_state = mdb.mdb_env_set_maxdbs(db_env, max_num_of_dbs);
    checkState(db_limit_state) catch unreachable;

    //if .ro open the environment in read-only mode. No write operations will be allowed.
    const db_flags: c_uint = if (txn_type == .ro) mdb.MDB_RDONLY else 0;
    const permissions: c_uint = 0o0600; //octal permissions for created files in db_dir
    const open_state = mdb.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
    checkState(open_state) catch |open_err| switch (open_err) {
        error.NoSuchFileOrDirectory => {
            std.Io.Dir.cwd().createDirPath(io, "db") catch unreachable;
            const new_open_state = mdb.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
            checkState(new_open_state) catch unreachable;
        },
        else => unreachable,
    };

    return .{
        .db_env = db_env.?,
        .txn_type = txn_type,
    };
}

///close all opened db environment
pub fn deinitdb(lmdb: Lmdb) void {
    mdb.mdb_env_close(lmdb.db_env);
}

///start a transaction in rw/ro mode and get a db handle for db manipulation
///commit changes with commitTxns() if .rw / doneReading() if .ro
pub fn startTxn(lmdb: Lmdb, txn_type: TxnType, db_name: []const u8) Lmdb {
    const txn = beginTxn(lmdb, txn_type);
    const handle = openDb(.{ .db_env = lmdb.db_env, .txn = txn, .txn_type = txn_type }, db_name);
    return .{
        .db_env = lmdb.db_env,
        .txn = txn,
        .txn_type = txn_type,
        .db_handle = handle,
    };
}

///open a different db in an already open transaction
pub fn openNewDb(lmdb: Lmdb, db_name: []const u8) Lmdb {
    //make sure a transaction has been created already
    ensureValidState(lmdb);
    const handle = openDb(lmdb, db_name);
    return .{
        .db_env = lmdb.db_env,
        .txn = lmdb.txn.?,
        .txn_type = lmdb.txn_type,
        .db_handle = handle,
    };
}

fn beginTxn(lmdb: Lmdb, txn_type: TxnType) *Txn {
    // This transaction will not perform any write operations if ro.
    const flags: c_uint = if (txn_type == .ro) mdb.MDB_RDONLY else 0;
    if (flags != mdb.MDB_RDONLY and lmdb.txn_type == .ro) {
        panic("Cannot begin a read-write transaction in a read-only environment", .{});
    }
    const parent = null; //no parent
    var txn: ?*Txn = undefined; //where the new #MDB_txn handle will be stored
    const txn_state = mdb.mdb_txn_begin(lmdb.db_env, parent, flags, &txn);
    checkState(txn_state) catch unreachable;

    return txn.?;
}

//TODO:may be support other flags for db like MDB_DUPSORT && MDB_DUPFIXED
fn openDb(lmdb: Lmdb, db_name: []const u8) DbHandle {
    //Create the named database if it doesn't exist. This option is not allowed in a read-only transaction or a read-only environment.
    const db_flags: c_uint = if (lmdb.txn_type == .rw) mdb.MDB_CREATE else 0;

    var db_handle: mdb.MDB_dbi = undefined; //dbi Address where the new #MDB_dbi handle will be stored
    const db_state = mdb.mdb_dbi_open(lmdb.txn.?, db_name.ptr, db_flags, &db_handle);
    checkState(db_state) catch unreachable;
    return db_handle;
}

inline fn ensureValidState(lmdb: Lmdb) void {
    assert(lmdb.txn != null);
    assert(lmdb.db_handle != undefined);
}

///delete entry in db with key `key_val`
///if db was opened with MDB_DUPSORT use `delDups` instead
pub fn del(lmdb: Lmdb, key_val: []const u8) !void {
    ensureValidState(lmdb);
    const del_state = mdb.mdb_del(lmdb.txn.?, lmdb.db_handle, &key(key_val), null);
    try checkState(del_state);
}

///Use If the database supports sorted duplicate data items (MDB_DUPSORT) else the data parameter is ignored.
///because If the database supports sorted duplicates and the data parameter is NULL, all of the duplicate data items
///for the key will be deleted. While, if the data parameter is non-NULL only the matching data item will be deleted.
pub fn delDups(_: Lmdb, _: []const u8, _: anytype) void {
    //This function will return MDB_NOTFOUND if the specified key/data pair is not in the database.
    panic("TODO");
}

//TODO:when MDB_DUPSORT is supported then support MDB_NODUPDATA flag
fn insert(lmdb: Lmdb, serialized_data: []const u8, key_val: []const u8) !void {
    const insert_flags: c_uint = mdb.MDB_NOOVERWRITE; // don't overwrite data if key already exist

    const put_state = mdb.mdb_put(
        lmdb.txn.?,
        lmdb.db_handle,
        key(key_val),
        value(serialized_data[0..]),
        insert_flags,
    );
    try checkState(put_state);
}

///insert new key/data pair without overwriting already inserted pair
///if `data` contains pointers or slices use `putAlloc`
pub fn put(lmdb: Lmdb, key_val: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serialize(data);
    try insert(lmdb, serialized_data[0..], key_val);
}

///use `putAlloc` when data contains slices or pointers
///recommend you use fixedBufferAllocator or ArenaAllocator
pub fn putAlloc(lmdb: Lmdb, fba: std.mem.Allocator, key_val: []const u8, data: anytype) !void {
    ensureValidState(lmdb);
    const serialized_data = serializer.serializeAlloc(fba, data);

    try insert(lmdb, serialized_data[0..], key_val);
}

///insert/update already existing key/data pair
pub fn update(lmdb: Lmdb, key_val: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    const update_flag: c_uint = 0; //allow overwriting data

    const serialized_data = serializer.serialize(data);

    const update_state = mdb.mdb_put(
        lmdb.txn.?,
        lmdb.db_handle,
        key(key_val),
        value(serialized_data[0..]),
        update_flag,
    );
    try checkState(update_state);
}

///commit all transaction on the current db handle
///should usually be called before the end of fn's to save db changes
pub fn commitTxns(lmdb: Lmdb) void {
    ensureValidState(lmdb);

    const commit_state = mdb.mdb_txn_commit(lmdb.txn.?);
    checkState(commit_state) catch unreachable;
}

///put db in a consistent state after performing a read-only transaction
pub fn doneReading(lmdb: Lmdb) void {
    ensureValidState(lmdb);
    abortTxns(lmdb);
}

///update the read state of a read-only transaction
///this fn should be called after performing a read-write operation in a different transaction
///it will update the current read-only transaction to see the changes made in the read-write transaction
pub fn updateRead(lmdb: Lmdb) void {
    ensureValidState(lmdb);
    mdb.mdb_txn_reset(lmdb.txn.?);
    const rewew_state = mdb.mdb_txn_renew(lmdb.txn.?);
    checkState(rewew_state) catch unreachable;
}

///cancel/discard all transaction on the current db handle
pub fn abortTxns(lmdb: Lmdb) void {
    mdb.mdb_txn_abort(lmdb.txn.?);
}

///get `key_val` as `T` when it doesn't require allocation
pub fn get(lmdb: Lmdb, comptime T: type, key_val: []const u8) !T {
    ensureValidState(lmdb);

    var data: Val = undefined;
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        key(key_val),
        &data,
    );

    try checkState(get_state);
    return serializer.deserialize(T, data.mv_data, data.mv_size);
}

///get the `key_val` as `T` when it requires allocation .ie it contains pointers/slices
///recommend using fixedBufferAllocator or ArenaAllocator
pub fn getAlloc(lmdb: Lmdb, comptime T: type, fba: std.mem.Allocator, key_val: []const u8) !T {
    ensureValidState(lmdb);

    var data: Val = undefined;
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        key(key_val),
        &data,
    );
    try checkState(get_state);
    return serializer.deserializeAlloc(T, fba, data.mv_data, data.mv_size);
}

fn key(data: []const u8) *Key {
    return value(data);
}

fn value(data: []const u8) *Val {
    return @constCast(&Val{
        .mv_size = data.len,
        .mv_data = @ptrCast(@constCast(data.ptr)),
    });
}

///check state of operation to make sure there where no errors
fn checkState(state: c_int) !void {
    switch (state) {
        //lmdb  errors  Return Codes
        //Successful result */
        mdb.MDB_SUCCESS => {},
        //key/data pair already exists */
        mdb.MDB_KEYEXIST => {
            return error.KeyAlreadyExist;
        },
        //key/data pair not found (EOF) */
        mdb.MDB_NOTFOUND => {
            return error.KeyNotFound;
        },
        //Requested page not found - this usually indicates corruption */
        mdb.MDB_PAGE_NOTFOUND => {
            return error.RequestedPageNotFound;
        },
        //Located page was wrong type */
        mdb.MDB_CORRUPTED => {
            return error.WrongPageType;
        },
        //Update of meta page failed or environment had fatal error */
        mdb.MDB_PANIC => {
            return error.EnvFatalError;
        },
        //Environment version mismatch */
        mdb.MDB_VERSION_MISMATCH => {
            return error.EnvVersionMismatch;
        },
        //File is not a valid LMDB file */
        mdb.MDB_INVALID => {
            return error.InvalidDbFile;
        },
        //Environment mapsize reached */
        mdb.MDB_MAP_FULL => {
            return error.EnvMapsizeFull;
        },
        //Environment maxdbs reached */
        mdb.MDB_DBS_FULL => {
            return error.EnvMaxDbsOpened;
        },
        //Environment maxreaders reached */
        mdb.MDB_READERS_FULL => {
            return error.EnvMaxReaders;
        },
        //Too many TLS keys in use - Windows only */
        mdb.MDB_TLS_FULL => {
            return error.ManyTlsKeysUsed;
        },
        //Txn has too many dirty pages */
        mdb.MDB_TXN_FULL => {
            return error.ManyTxnDirtyPages;
        },
        //Cursor stack too deep - internal error */
        mdb.MDB_CURSOR_FULL => {
            return error.DeepCursorStack;
        },
        //Page has not enough space - internal error */
        mdb.MDB_PAGE_FULL => {
            return error.NotEnoughPageSpace;
        },
        //Database contents grew beyond environment mapsize */
        mdb.MDB_MAP_RESIZED => {
            return error.DbSizeGtEnvMapsize;
        },
        //Operation and DB incompatible, or DB type changed. This can mean:
        //The operation expects an #MDB_DUPSORT /#MDB_DUPFIXED database.
        //Opening a named DB when the unnamed DB has #MDB_DUPSORT /#MDB_INTEGERKEY.
        //Accessing a data record as a database, or vice versa.
        //The database was dropped and recreated with different flags.
        mdb.MDB_INCOMPATIBLE => {
            return error.OpAndDbIncompatible;
        },
        //Invalid reuse of reader locktable slot */
        mdb.MDB_BAD_RSLOT => {
            return error.InvalidReaderSlotReuse;
        },
        //Transaction must abort, has a child, or is invalid */
        mdb.MDB_BAD_TXN => {
            return error.InvalidTxn;
        },
        //Unsupported size of key/DB name/data, or wrong DUPFIXED size */
        mdb.MDB_BAD_VALSIZE => {
            return error.UnsupportedComponentSize;
        },
        //The specified DBI was changed unexpectedly */
        mdb.MDB_BAD_DBI => {
            return error.InvalidDbHandle;
        },
        //out of memory.
        @intFromEnum(err.NOENT) => {
            return error.NoSuchFileOrDirectory;
        },
        //don't have adecuate permissions to perform operation
        @intFromEnum(err.ACCES) => {
            return error.PermissionDenied;
        },
        //the environment was locked by another process.
        @intFromEnum(err.AGAIN) => {
            return error.EnvLockedTryAgain;
        },
        @intFromEnum(err.NOMEM) => {
            return error.OutOfMemory;
        },
        //an invalid parameter was specified.
        @intFromEnum(err.INVAL) => {
            return error.InvalidArgument;
        },
        //a low-level I/O error occurred
        @intFromEnum(err.IO) => {
            return error.IOFailed;
        },
        //no more disk space on device.
        @intFromEnum(err.NOSPC) => {
            return error.DiskSpaceFull;
        },
        else => panic("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) }),
    }
}

test "test db key:str / value:str" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var dbh = initdb(db_path, .rw);
    defer deinitdb(dbh);

    const wtxn = dbh.startTxn(.rw, BLOCK_DB);

    const val: [5]u8 = "value".*;
    {
        try wtxn.put("key", val);
        defer wtxn.commitTxns();
    }

    const rtxn = dbh.startTxn(.ro, BLOCK_DB);
    defer rtxn.doneReading();
    try testing.expectEqualSlices(u8, "value", (try rtxn.get([5]u8, "key"))[0..]);
}

test "test db update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var dbh = initdb(db_path, .rw);
    defer deinitdb(dbh);

    const txn = dbh.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    const Data = struct {
        char: [21]u8,
        int: u8,
        ochar: [21]u8,
    };
    const data = Data{
        .char = "is my data still here".*,
        .int = 254,
        .ochar = "is my data still here".*,
    };

    try txn.put("data_key", data);
    const gotten_data = try txn.get(Data, "data_key");

    try testing.expectEqualSlices(u8, data.char[0..], gotten_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], gotten_data.ochar[0..]);
    try testing.expect(data.int == gotten_data.int);
}

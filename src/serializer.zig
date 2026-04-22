const std = @import("std");
const s2s = @import("s2s");
const mem = std.mem;
const Io = std.Io;

pub const HASH_SIZE = 8; //size of std.hash.Fnv1a_64 is 64bit which is 8 byte

///caller must free the returned slice
///it is recommend you use either a fixedBufferAllocator or AreanAllocator
pub fn serializeAlloc(allocator: mem.Allocator, data: anytype) []const u8 {
    var list_stream: Io.Writer.Allocating = .init(allocator);

    s2s.serialize(&list_stream.writer, @TypeOf(data), data) catch unreachable;
    return list_stream.written();
}

///serialize data with a comptime known size
pub fn serialize(data: anytype) [HASH_SIZE + @sizeOf(@TypeOf(data))]u8 {
    var serialized_data: [HASH_SIZE + @sizeOf(@TypeOf(data))]u8 = undefined;
    var fbw: Io.Writer = .fixed(&serialized_data);
    s2s.serialize(&fbw, @TypeOf(data), data) catch unreachable;
    return serialized_data;
}

fn getRawBytes(data: ?*anyopaque, start: usize, size: usize) []const u8 {
    return @as([*]u8, @ptrCast(data.?))[start..size];
}

///deserialize bytes representing data as `T`
///use when no allocation is required .ie data doesn't contain ptr or slice
pub fn deserialize(comptime T: type, data: ?*anyopaque, size: usize) T {
    // return std.mem.bytesAsSlice(T, getBytes(data.?, size))[0];
    const serialized_data = getRawBytes(data, 0, size);

    var fbr: Io.Reader = .fixed(serialized_data);
    return s2s.deserialize(&fbr, T) catch unreachable;
}

///deserialize types with require allocation
///recommend you use a `fixedBufferAllocator`
pub fn deserializeAlloc(comptime T: type, fballocator: std.mem.Allocator, data: ?*anyopaque, size: usize) T {
    // return std.mem.bytesAsSlice(T, getBytes(data.?, size))[0];
    const serialized_data = getRawBytes(data, 0, size);

    var fbr: Io.Reader = .fixed(serialized_data);
    return s2s.deserializeAlloc(&fbr, T, fballocator) catch unreachable;
}

//IDEAS: consider maybe json serialization but prefer binnary serialization
//READ: read into Google Protocol Buffers ,Thrift and Avro in I want to use well established serialization tools

//Serialization takes an in-memory data structure and converts it into a series of bytes that can be stored and transferred.
//Deserialization takes a series of bytes and converts it to an in-memory data structure that can be consumed programmatically.

//TODO: try to implement a way to convert slices into arrays for easy serialization
//IDEAS: 🤔 maybe reify the slice type but with a .field_type of [N]u8 take inspiration from std.meta.Sentinel
//REF: https://stackoverflow.com/questions/15707933/how-to-serialize-a-struct-in-c  , serialization framework https://github.com/getty-zig/getty
//REF: https://stackoverflow.com/questions/9778806/serializing-a-class-with-a-pointer-in-c https://www.boost.org/doc/libs/1_78_0/libs/serialization/doc/tutorial.html#pointers
//REF: https://stackoverflow.com/questions/523872/how-do-you-serialize-an-object-in-c/ https://accu.org/journals/overload/24/136/ignatchenko_2317/
//REF: https://github.com/srwalter/dbus-serialize

/// serialized a type in memory
fn inMemSerialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
    @memcpy(serialized_buf, type_to_serialize);
}

/// deserialize data from memory
fn inMemDeserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
    return @bitCast(serialized_t);
}

// test "simple serialization/deserialization with other data interleved " {
//     const Data = packed struct {
//         char: [21]u8 = "is my data still here".*,
//         int: u8 = 254,
//         ochar: [21]u8 = "is my data still here".*,
//     };
//     const data = Data{};
//     // var serialized_data: [@sizeOf(Data)]u8 = undefined;
//     // simpleSerialize(data, &serialized_data);
//
//     const SerializedData = try std.fs.cwd().createFile("serialized-1.data", .{ .read = true });
//     defer SerializedData.close();
//     const writer = SerializedData.writer();
//     try writer.writeStruct(data);
//     // try writer.writeAll(serialized_data[0..]);
//     try SerializedData.seekTo(0);
//
//     // var deserialized_buf: [@sizeOf(Data)]u8 = undefined;
//     const reader = SerializedData.reader();
//     const deserialized_data = try reader.readStruct(Data);
//     // const deserialized_data = simpleDeserialize(Data, serialized_data);
//     // try testing.expectEqualSlices(u8, serialized_data[0..], deserialized_buf[0..]);
//     std.debug.print("\ndata {}\ndserialized data {}\n", .{ data, deserialized_data });
//
//     // try testing.expectEqualSlices(u8, data.char[0..], deserialized_data.char[0..]);
//     // try testing.expectEqualSlices(u8, data.ochar[0..], deserialized_data.ochar[0..]);
//     // try testing.expect(std.mem.eql(u8, data.char[0..], deserialized_data.char[0..]));
//     // try testing.expect(std.mem.eql(u8, @ptrCast([*][]u8, &data)[0], @ptrCast([*][]u8, &deserialized_data)));
//     // std.debug.print("\nchar is {s}\n", .{deserialized_data.char[0..]});
//     try testing.expect(data.int == deserialized_data.int);
// }

// //TODO: test output of serialized [N]T output with []T output
// //when serializing slice don't forget to set the len field also
// pub fn sliceSerialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
//     const @"type" = @TypeOf(type_to_serialize);
//     const fields = comptime std.meta.fields(@"type");
//     debug("size of {} is {}", .{ @"type", @sizeOf(@"type") });
//     var size: usize = 0;
//     const manyptr_to_serialize = @ptrCast([*]const u8, &type_to_serialize);
//     //TODO: use std.mem.alignInBytes for aligning fields in struct during deserialization
//     //take pointers to fields and ptrCast to bytes for modification
//     inline for (fields) |field| {
//         if (std.meta.trait.isSlice(field.field_type)) {
//             const size_of_slice = @sizeOf(field.field_type);
//             debug("The field {s} is a slice", .{field.name});
//             debug("size of {s} slice is {}", .{ field.name, size_of_slice });
//             debug("{s} has {s}", .{ field.name, field });
//             const slice = @bitCast([]const u8, manyptr_to_serialize[size .. size + size_of_slice]);
//             debug("slice ptr contains {s}", .{slice});
//             @memcpy(serialized_buf[size..].ptr, slice.ptr, slice.len);
//             size += size_of_slice;
//         } else {
//             const type_size = comptime blk: {
//                 const size_of_type = @sizeOf(field.field_type);
//                 if (size_of_type < 8) {
//                     const new_size = @sizeOf(field.field_type) * 8;
//                     //multiple size by 8 to properly align
//                     // debug("size was initially {} but is now ", .{ size_of_type, new_size });
//                     break :blk new_size;
//                 } else break :blk size_of_type;
//             };
//             //since size might have been modified
//             const actual_size = @sizeOf(field.field_type);
//             debug("The field {s} is not a slice", .{field.name});
//             debug("size of {s} is {}", .{ field.name, actual_size });
//             debug("{s} has {s}", .{ field.name, field });
//             @memcpy(serialized_buf[size..].ptr, manyptr_to_serialize[size .. size + actual_size].ptr, type_size);
//             size += type_size;
//         }
//         debug("{} bytes copied", .{size});
//     }
//     //     // @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
// }
//
//  pub fn deserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
//      return @bitCast(T, serialized_t);
//  var des_type: T = undefined;
//  const fields = std.meta.fields(T);
//  var size: usize = 0;
//  inline for (fields) |field| {
//      if (std.meta.trait.isSlice(field.field_type)) {
//          const size_of_slice = @sizeOf(field.field_type);
//          @memcpy(cast([*]u8, des_type.character.ptr), serialized_t[size .. size + size_of_slice].ptr, size_of_slice);
//          size += size_of_slice;
//      } else {
//          const type_size = comptime blk: {
//              const size_of_type = @sizeOf(field.field_type);
//              if (size_of_type < 8) {
//                  const new_size = @sizeOf(field.field_type) * 8;
//                  break :blk new_size;
//              } else break :blk size_of_type;
//          };
//          //since size might have been modified
//          const actual_size = @sizeOf(field.field_type);
//          @memcpy(des_type.integer, serialized_t[size .. size + actual_size].ptr, actual_size);
//          size += type_size;
//      }
//  }
//  return des_type;
//  }
//

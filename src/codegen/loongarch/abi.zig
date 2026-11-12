const std = @import("std");
const InternPool = @import("../../InternPool.zig");
const Type = @import("../../Type.zig");
const Zcu = @import("../../Zcu.zig");

pub const Class = union(enum) {
    ignored,
    gar,
    far,
    /// A struct whose only member is a float, passed in a FAR when one is left.
    member: Member,
    /// A struct of two members, at least one of them a float, passed in FARs (and a GAR) when
    /// enough are left.
    member_pair: [2]Member,
    memory_gar,
    memory_gar_pair,
    address,

    pub const Member = struct {
        ty: Type,
        /// Byte offset of the member within the struct.
        offset: u64,
    };
};

pub fn classifyType(ty: Type, zcu: *Zcu) Class {
    return Classifier.init(zcu).classifyType(ty);
}

/// The class of `ty` when it is passed in GARs or memory only, such as a `.member` or
/// `.member_pair` struct when there are not enough argument registers left, or a variadic argument.
pub fn classifyMemory(ty: Type, zcu: *Zcu) Class {
    return Classifier.init(zcu).classifyMemory(ty);
}

const Classifier = struct {
    zcu: *Zcu,
    target: *const std.Target,
    grlen: u8,
    frlen: u8,

    fn init(zcu: *Zcu) Classifier {
        const target = zcu.getTarget();
        return .{
            .zcu = zcu,
            .target = target,
            .grlen = switch (target.cpu.arch) {
                else => unreachable,
                .loongarch32 => 32,
                .loongarch64 => 64,
            },
            .frlen = switch (target.abi) {
                .gnusf, .muslsf => 0,
                .gnuf32, .muslf32 => 32,
                else => 64,
            },
        };
    }

    fn classifyType(c: Classifier, ty: Type) Class {
        switch (ty.zigTypeTag(c.zcu)) {
            .type,
            .comptime_float,
            .comptime_int,
            .undefined,
            .null,
            .error_union,
            .error_set,
            .@"fn",
            .@"opaque",
            .frame,
            .@"anyframe",
            .enum_literal,
            .spirv,
            => unreachable,
            .void, .noreturn => return .ignored,
            .bool => return .gar,
            .int, .@"enum" => {
                const bits = ty.intInfo(c.zcu).bits;
                if (bits == 0) return .ignored;
                if (bits <= c.grlen) return .gar;
                if (bits <= 2 * c.grlen) return .memory_gar_pair;
                return .address;
            },
            .float => {
                const bits = ty.floatBits(c.target);
                if (bits <= c.frlen) return .far;
                if (bits <= c.grlen) return .gar;
                if (bits <= 2 * c.grlen) return .memory_gar_pair;
                return .address;
            },
            .pointer, .optional => return .gar,
            .array => {},
            .@"struct" => switch (ty.containerLayout(c.zcu)) {
                .auto => unreachable,
                .@"extern" => {
                    var members: [2]Class.Member = undefined;
                    var members_len: usize = 0;
                    if (c.flatten(ty, 0, &members, &members_len)) switch (members_len) {
                        0 => {},
                        1 => if (members[0].ty.isRuntimeFloat()) return .{ .member = members[0] },
                        2 => return .{ .member_pair = members },
                        else => unreachable,
                    };
                },
                .@"packed" => return c.classifyType(ty.backingIntType(c.zcu)),
            },
            .@"union" => switch (ty.containerLayout(c.zcu)) {
                .auto => unreachable,
                .@"extern" => {},
                .@"packed" => return c.classifyType(ty.backingIntType(c.zcu)),
            },
            .vector => {},
        }
        return c.classifyMemory(ty);
    }

    fn classifyMemory(c: Classifier, ty: Type) Class {
        const size = ty.abiSize(c.zcu);
        if (size <= @divExact(c.grlen, 8)) return .memory_gar;
        if (size <= @divExact(2 * c.grlen, 8)) return .memory_gar_pair;
        return .address;
    }

    /// Appends the scalar members of `ty`, found at byte `offset`, to `members`. Returns false if
    /// `ty` cannot be part of a struct passed in FARs: it has a member that is not an integer or a
    /// float, an integer wider than GRLEN, a float wider than FRLEN, two integers, or more than
    /// two members.
    fn flatten(c: Classifier, ty: Type, offset: u64, members: *[2]Class.Member, members_len: *usize) bool {
        const zcu = c.zcu;
        if (!ty.hasRuntimeBits(zcu)) return true;
        switch (ty.zigTypeTag(zcu)) {
            .bool, .int, .@"enum" => {
                if (ty.bitSize(zcu) > c.grlen) return false;
                if (members_len.* == 1 and !members[0].ty.isRuntimeFloat()) return false;
            },
            .float => if (ty.floatBits(c.target) > c.frlen) return false,
            .array => {
                const elem_ty = ty.childType(zcu);
                const elem_size = elem_ty.abiSize(zcu);
                for (0..std.math.lossyCast(usize, ty.arrayLenIncludingSentinel(zcu))) |elem_index| {
                    if (!c.flatten(elem_ty, offset + elem_index * elem_size, members, members_len)) return false;
                }
                return true;
            },
            .@"struct" => switch (ty.containerLayout(zcu)) {
                .auto => unreachable,
                .@"extern" => {
                    for (0..ty.structFieldCount(zcu)) |field_index| {
                        const field_offset = offset + ty.structFieldOffset(field_index, zcu);
                        if (!c.flatten(ty.fieldType(field_index, zcu), field_offset, members, members_len)) return false;
                    }
                    return true;
                },
                .@"packed" => return c.flatten(ty.backingIntType(zcu), offset, members, members_len),
            },
            else => return false,
        }
        if (members_len.* == members.len) return false;
        members[members_len.*] = .{ .ty = ty, .offset = offset };
        members_len.* += 1;
        return true;
    }
};

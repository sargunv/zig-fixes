//! Usage: check <Mach-O file> sdk|stub
//! `sdk`: built against the fake SDK in sdk/ (SDK version 42.7, libSystem
//! current version 4242, and `_fake_sdk_marker` imported).
//! `stub`: built against Zig's bundled libSystem stub instead.

const std = @import("std");
const macho = std.macho;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.BadUsage;
    const want_sdk = std.mem.eql(u8, args[2], "sdk");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(64 * 1024 * 1024));
    const header = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    if (header.magic != macho.MH_MAGIC_64) return error.NotMachO;

    var sdk: ?u32 = null;
    var libsystem_version: ?u32 = null;
    var imports_marker = false;
    var offset: usize = @sizeOf(macho.mach_header_64);
    for (0..header.ncmds) |_| {
        const lc = std.mem.bytesToValue(macho.load_command, bytes[offset..][0..@sizeOf(macho.load_command)]);
        switch (lc.cmd) {
            .BUILD_VERSION => {
                const cmd = std.mem.bytesToValue(macho.build_version_command, bytes[offset..][0..@sizeOf(macho.build_version_command)]);
                if (cmd.platform != .IOS) return error.WrongPlatform;
                sdk = cmd.sdk;
            },
            .LOAD_DYLIB => {
                const cmd = std.mem.bytesToValue(macho.dylib_command, bytes[offset..][0..@sizeOf(macho.dylib_command)]);
                const name = std.mem.sliceTo(bytes[offset + cmd.dylib.name ..][0 .. lc.cmdsize - cmd.dylib.name], 0);
                if (std.mem.eql(u8, name, "/usr/lib/libSystem.B.dylib")) libsystem_version = cmd.dylib.current_version;
            },
            .SYMTAB => {
                const cmd = std.mem.bytesToValue(macho.symtab_command, bytes[offset..][0..@sizeOf(macho.symtab_command)]);
                const syms = std.mem.bytesAsSlice(macho.nlist_64, bytes[cmd.symoff..][0 .. cmd.nsyms * @sizeOf(macho.nlist_64)]);
                for (syms) |sym| {
                    const sym_name = std.mem.sliceTo(bytes[cmd.stroff + sym.n_strx ..], 0);
                    if (sym.n_type.bits.type == .undf and std.mem.eql(u8, sym_name, "_fake_sdk_marker")) imports_marker = true;
                }
            },
            else => {},
        }
        offset += lc.cmdsize;
    }

    const fake_sdk: u32 = 42 << 16 | 7 << 8;
    const fake_libsystem: u32 = 4242 << 16;
    if (want_sdk) {
        if (sdk != fake_sdk) return error.WrongSdkVersion;
        if (libsystem_version != fake_libsystem) return error.WrongLibSystem;
        if (!imports_marker) return error.MarkerNotImported;
    } else {
        if (sdk == null or sdk == fake_sdk) return error.WrongSdkVersion;
        if (libsystem_version == null or libsystem_version == fake_libsystem) return error.WrongLibSystem;
    }
}

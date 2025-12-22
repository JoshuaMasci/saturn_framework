const std = @import("std");

const Self = @This();

const BUFFER_SIZE: usize = 31;
buffer: [BUFFER_SIZE]u8,
len: u8,

pub fn init(str: []const u8) Self {
    std.debug.assert(str.len + 1 <= BUFFER_SIZE);
    var self: Self = undefined;
    @memcpy(self.buffer[0..str.len], str);
    self.buffer[str.len] = 0;
    self.len = @intCast(str.len);
    return self;
}

pub fn initFmt(comptime fmt: []const u8, args: anytype) Self {
    var self: Self = undefined;
    const str = std.fmt.bufPrintZ(&self.buffer, fmt, args) catch |err| std.debug.panic("Failed to format string: {}", .{err});
    self.len = @intCast(str.len);
    return self;
}

pub fn initCStr(str: [:0]const u8) Self {
    std.debug.assert(str.len + 1 <= BUFFER_SIZE);
    var self: Self = undefined;
    @memcpy(self.buffer[0..str.len], str);
    self.buffer[str.len] = 0;
    self.len = @intCast(str.len);
    return self;
}

pub fn getCStr(self: *const @This()) [:0]const u8 {
    return self.buffer[0..self.len :0];
}

pub fn format(
    self: Self,
    writer: *std.Io.Writer,
) !void {
    return writer.print("{s}", .{self.buffer});
}

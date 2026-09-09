const std = @import("std");

pub const Hello = struct {
    type: enum { hello },
    protocolMajor: u16,
    protocolMinor: u16,
    serverID: []const u8,
    serverEpoch: []const u8,
    sessionID: []const u8,
    platform: enum { @"macos-aarch64", @"macos-x86_64", @"linux-aarch64", @"linux-x86_64" },
    capabilities: []const []const u8,

    pub const required = [_][]const u8{ "session_snapshot", "terminal_control", "surface_interest", "health_check" };

    pub fn validate(self: Hello) !void {
        for ([_][]const u8{ self.serverID, self.serverEpoch, self.sessionID }) |id| {
            if (id.len != 36) return error.InvalidHandshake;
            for (id, 0..) |byte, i| {
                if (i == 8 or i == 13 or i == 18 or i == 23) {
                    if (byte != '-') return error.InvalidHandshake;
                } else if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidHandshake;
            }
        }
        if (self.capabilities.len > 128) return error.InvalidHandshake;
        for (self.capabilities, 0..) |capability, i| {
            if (capability.len == 0 or capability.len > 64 or capability[0] < 'a' or capability[0] > 'z') return error.InvalidHandshake;
            for (capability) |byte| {
                if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_')) return error.InvalidHandshake;
            }
            for (self.capabilities[0..i]) |previous| {
                if (std.mem.eql(u8, previous, capability)) return error.InvalidHandshake;
            }
        }
    }

    /// Optional capabilities are retained, but all required ones gate input.
    pub fn negotiate(self: Hello) !void {
        return self.negotiateRequired(&required);
    }

    pub fn negotiateRequired(self: Hello, needed: []const []const u8) !void {
        try self.validate();
        if (self.protocolMajor != 1) return error.IncompatibleMajor;
        for (needed) |capability| {
            var present = false;
            for (self.capabilities) |available| {
                if (std.mem.eql(u8, available, capability)) {
                    present = true;
                    break;
                }
            }
            if (!present) return error.MissingCapabilities;
        }
    }
};

test "handshake shared fixtures preserve version and capability rules" {
    const allocator = std.testing.allocator;
    const json = try std.fs.cwd().readFileAlloc(allocator, "protocol/hello-fixtures.json", 65536);
    defer allocator.free(json);
    const Case = struct { name: []const u8, hello: Hello, result: []const u8 };
    const cases = try std.json.parseFromSlice([]Case, allocator, json, .{ .ignore_unknown_fields = true });
    defer cases.deinit();
    for (cases.value) |case| {
        const result: []const u8 = if (case.hello.negotiate()) |_| "ok" else |err| switch (err) {
            error.InvalidHandshake => "invalidHandshake",
            error.IncompatibleMajor => "incompatibleMajor",
            error.MissingCapabilities => "missingCapabilities",
        };
        try std.testing.expectEqualStrings(case.result, result);
    }
}

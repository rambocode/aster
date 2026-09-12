const std = @import("std");

pub const inactivity_ms: u64 = 15_000;
pub const ID = [36]u8;
pub const Owner = struct { client_id: ID, connection_generation: u64 };
/// Wire representation is leaseID/leaseEpoch; ownership stays on the server.
pub const Lease = struct { lease_id: ID, lease_epoch: u64 };
pub const Grant = struct { owner: Owner, lease: Lease, last_activity_ms: u64 };
pub const Transfer = struct { revoked: ?Grant, granted: Grant };

/// One instance per terminal, confined to the service reactor. All timestamps
/// use one monotonic clock. Callers authenticate Owner from the connection, mint
/// fresh UUID tokens, and publish returned revoked grants to previous writers.
/// No mutex is needed when mutations execute on the reactor owner thread.
pub const WriterLease = struct {
    current: ?Grant = null,
    epoch: u64 = 0,
    last_clock_ms: u64 = 0,

    /// Observation never acquires or renews a lease. Inspect after expire().
    pub fn peek(self: *const WriterLease) ?Grant {
        return self.current;
    }

    pub fn acquire(self: *WriterLease, owner: Owner, token: ID, now_ms: u64) !Grant {
        try validate(owner, token);
        try self.clock(now_ms);
        _ = self.expireUnchecked(now_ms);
        if (self.current != null) return error.LeaseBusy;
        return self.grant(owner, token, now_ms);
    }

    /// Atomically compare the previously observed epoch before replacing it, including idle state.
    /// The wire adapter must supply a client-observed expected epoch; taking a
    /// fresh peek inside the handler would defeat concurrent takeover fencing.
    pub fn takeover(self: *WriterLease, owner: Owner, token: ID, expected_epoch: u64, now_ms: u64) !Transfer {
        try validate(owner, token);
        try self.clock(now_ms);
        _ = self.expireUnchecked(now_ms);
        if (self.epoch != expected_epoch) return error.LeaseLost;
        const previous = self.current;
        if (previous) |active| {
            if (std.mem.eql(u8, &token, &active.lease.lease_id)) return error.InvalidLeaseToken;
        }
        const next = try self.grant(owner, token, now_ms);
        return .{ .revoked = previous, .granted = next };
    }

    /// Accepted writer activity renews the 15-second inactivity deadline. Wrong
    /// client, connection generation, token or epoch never refreshes it.
    pub fn renew(self: *WriterLease, owner: Owner, lease: Lease, now_ms: u64) !Grant {
        try self.check(owner, lease, now_ms);
        self.current.?.last_activity_ms = now_ms;
        return self.current.?;
    }

    pub fn check(self: *WriterLease, owner: Owner, lease: Lease, now_ms: u64) !void {
        try self.clock(now_ms);
        _ = self.expireUnchecked(now_ms);
        const active = self.current orelse return error.LeaseLost;
        if (!sameOwner(active.owner, owner) or !sameLease(active.lease, lease)) return error.LeaseLost;
    }

    /// Release is fenced by the attachment's owner and grant. Resolve these from
    /// attachmentID in the adapter; do not accept another client's attachment.
    pub fn release(self: *WriterLease, owner: Owner, lease: Lease, now_ms: u64) !Grant {
        try self.check(owner, lease, now_ms);
        const previous = self.current.?;
        self.current = null;
        return previous;
    }

    /// Disconnection releases immediately; a delayed old-generation close cannot
    /// revoke a replacement connection's grant. PTY lifetime is unaffected.
    pub fn disconnect(self: *WriterLease, owner: Owner) ?Grant {
        const active = self.current orelse return null;
        if (!sameOwner(active.owner, owner)) return null;
        self.current = null;
        return active;
    }

    pub fn expire(self: *WriterLease, now_ms: u64) !?Grant {
        try self.clock(now_ms);
        return self.expireUnchecked(now_ms);
    }

    fn clock(self: *WriterLease, now_ms: u64) !void {
        if (now_ms < self.last_clock_ms) return error.NonMonotonicLeaseClock;
        self.last_clock_ms = now_ms;
    }
    fn expireUnchecked(self: *WriterLease, now_ms: u64) ?Grant {
        const active = self.current orelse return null;
        if (now_ms - active.last_activity_ms < inactivity_ms) return null;
        self.current = null;
        return active;
    }
    fn grant(self: *WriterLease, owner: Owner, token: ID, now_ms: u64) !Grant {
        if (self.epoch == std.math.maxInt(u64)) return error.LeaseEpochExhausted;
        self.epoch += 1;
        const next: Grant = .{ .owner = owner, .lease = .{ .lease_id = token, .lease_epoch = self.epoch }, .last_activity_ms = now_ms };
        self.current = next;
        return next;
    }
};

fn sameOwner(a: Owner, b: Owner) bool {
    return a.connection_generation == b.connection_generation and std.mem.eql(u8, &a.client_id, &b.client_id);
}
fn sameLease(a: Lease, b: Lease) bool {
    return a.lease_epoch == b.lease_epoch and std.mem.eql(u8, &a.lease_id, &b.lease_id);
}
fn validate(owner: Owner, token: ID) !void {
    if (!validID(owner.client_id) or !validID(token)) return error.InvalidLeaseIdentity;
}
fn validID(id: ID) bool {
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}
fn testID(n: u8) ID {
    var value = "00000000-0000-4000-8000-000000000000".*;
    value[35] = n;
    return value;
}
fn testOwner(n: u8, generation: u64) Owner {
    return .{ .client_id = testID(n), .connection_generation = generation };
}

test "writer lease single owner and every identity dimension fences activity" {
    var state: WriterLease = .{};
    const first = try state.acquire(testOwner('1', 1), testID('a'), 0);
    try std.testing.expectError(error.LeaseBusy, state.acquire(testOwner('2', 1), testID('b'), 1));
    try std.testing.expectError(error.LeaseLost, state.renew(testOwner('2', 1), first.lease, 2));
    try std.testing.expectError(error.LeaseLost, state.renew(testOwner('1', 2), first.lease, 3));
    var stale = first.lease;
    stale.lease_epoch += 1;
    try std.testing.expectError(error.LeaseLost, state.renew(first.owner, stale, 4));
    stale = first.lease;
    stale.lease_id = testID('f');
    try std.testing.expectError(error.LeaseLost, state.renew(first.owner, stale, 5));
    try std.testing.expectEqual(@as(u64, 0), state.peek().?.last_activity_ms);
}

test "writer lease exact expiry and renewed inactivity deadline" {
    var state: WriterLease = .{};
    const first = try state.acquire(testOwner('1', 1), testID('a'), 50);
    try std.testing.expect(try state.expire(15049) == null);
    _ = try state.renew(first.owner, first.lease, 15049);
    try std.testing.expect(try state.expire(30048) == null);
    try std.testing.expect(try state.expire(30049) != null);
    try std.testing.expectError(error.LeaseLost, state.renew(first.owner, first.lease, 30049));
    const next = try state.acquire(first.owner, testID('b'), 30049);
    try std.testing.expect(next.lease.lease_epoch > first.lease.lease_epoch);
    try std.testing.expectError(error.LeaseLost, state.check(first.owner, first.lease, 30049));
}

test "writer lease concurrent takeover CAS has exactly one winner" {
    var state: WriterLease = .{};
    const first = try state.acquire(testOwner('1', 1), testID('a'), 0);
    const transfer = try state.takeover(testOwner('2', 1), testID('b'), first.lease.lease_epoch, 1);
    try std.testing.expectEqualDeep(first, transfer.revoked.?);
    try std.testing.expectError(error.LeaseLost, state.takeover(testOwner('3', 1), testID('c'), first.lease.lease_epoch, 1));
    try std.testing.expectError(error.LeaseLost, state.release(first.owner, first.lease, 1));
    try state.check(transfer.granted.owner, transfer.granted.lease, 1);
}

test "writer lease disconnect release and late old connection are isolated" {
    var state: WriterLease = .{};
    const first = try state.acquire(testOwner('1', 1), testID('a'), 0);
    try std.testing.expect(state.disconnect(testOwner('2', 1)) == null);
    try std.testing.expect(state.disconnect(first.owner) != null);
    const second = try state.acquire(testOwner('1', 2), testID('b'), 0);
    try std.testing.expect(state.disconnect(first.owner) == null);
    _ = try state.release(second.owner, second.lease, 1);
    try std.testing.expect(state.peek() == null);
}

test "writer lease overflow and backwards clock cannot replace owner" {
    var state: WriterLease = .{};
    const first = try state.acquire(testOwner('1', 1), testID('a'), 10);
    try std.testing.expectError(error.NonMonotonicLeaseClock, state.renew(first.owner, first.lease, 9));
    state.epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.LeaseEpochExhausted, state.takeover(testOwner('2', 1), testID('b'), state.epoch, 10));
    try std.testing.expectEqualDeep(first, state.peek().?);
    try std.testing.expectError(error.InvalidLeaseToken, state.takeover(testOwner('2', 1), testID('a'), state.epoch, 10));
    var invalid = testID('1');
    invalid[0] = 'Z';
    try std.testing.expectError(error.InvalidLeaseIdentity, state.acquire(.{ .client_id = invalid, .connection_generation = 1 }, testID('a'), 10));
}

test "writer lease idle takeover compares retained epoch" {
    var state: WriterLease = .{};
    const first = try state.takeover(testOwner('1', 1), testID('a'), 0, 0);
    try std.testing.expect(first.revoked == null);
    _ = try state.release(first.granted.owner, first.granted.lease, 1);
    try std.testing.expectEqual(@as(u64, 1), state.epoch);
    try std.testing.expectError(error.LeaseLost, state.takeover(testOwner('2', 1), testID('b'), 0, 1));
    const second = try state.takeover(testOwner('2', 1), testID('b'), 1, 1);
    try std.testing.expectEqual(@as(u64, 2), second.granted.lease.lease_epoch);
    try std.testing.expectError(error.LeaseLost, state.takeover(testOwner('3', 1), testID('c'), 1, 1));
}

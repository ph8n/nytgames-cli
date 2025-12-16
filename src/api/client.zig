const std = @import("std");
const curl = @import("curl");

const models = @import("models.zig");

pub const Error = error{
    UnexpectedStatusCode,
};

pub fn fetchWordle(allocator: std.mem.Allocator, date: []const u8) !std.json.Parsed(models.WordleData) {
    try curl.globalInit();
    defer curl.globalDeinit();

    var ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();

    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
        .default_user_agent = "nytg-cli",
    });
    defer easy.deinit();

    try easy.setFollowLocation(true);
    try easy.setMaxRedirects(3);

    const url_unterminated = try std.fmt.allocPrint(
        allocator,
        "https://www.nytimes.com/svc/wordle/v2/{s}.json",
        .{date},
    );
    defer allocator.free(url_unterminated);

    const url = try allocator.dupeZ(u8, url_unterminated);
    defer allocator.free(url);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const resp = try easy.fetch(url, .{
        .method = .GET,
        .writer = &body.writer,
    });
    if (resp.status_code != 200) return error.UnexpectedStatusCode;

    return std.json.parseFromSlice(models.WordleData, allocator, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn fetchConnections(allocator: std.mem.Allocator, date: []const u8) !std.json.Parsed(models.ConnectionsData) {
    try curl.globalInit();
    defer curl.globalDeinit();

    var ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();

    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
        .default_user_agent = "nytg-cli",
    });
    defer easy.deinit();

    try easy.setFollowLocation(true);
    try easy.setMaxRedirects(3);

    const url_unterminated = try std.fmt.allocPrint(
        allocator,
        "https://www.nytimes.com/svc/connections/v2/{s}.json",
        .{date},
    );
    defer allocator.free(url_unterminated);

    const url = try allocator.dupeZ(u8, url_unterminated);
    defer allocator.free(url);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const resp = try easy.fetch(url, .{
        .method = .GET,
        .writer = &body.writer,
    });
    if (resp.status_code != 200) return error.UnexpectedStatusCode;

    return std.json.parseFromSlice(models.ConnectionsData, allocator, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn fetchSpellingBee(allocator: std.mem.Allocator, date: []const u8) !std.json.Parsed(models.SpellingBeeData) {
    try curl.globalInit();
    defer curl.globalDeinit();

    var ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();

    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
        .default_user_agent = "nytg-cli",
    });
    defer easy.deinit();

    try easy.setFollowLocation(true);
    try easy.setMaxRedirects(3);

    const url_unterminated = try std.fmt.allocPrint(
        allocator,
        "https://www.nytimes.com/svc/spelling-bee/v1/{s}.json",
        .{date},
    );
    defer allocator.free(url_unterminated);

    const url = try allocator.dupeZ(u8, url_unterminated);
    defer allocator.free(url);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const resp = try easy.fetch(url, .{
        .method = .GET,
        .writer = &body.writer,
    });
    if (resp.status_code != 200) return error.UnexpectedStatusCode;

    return std.json.parseFromSlice(models.SpellingBeeData, allocator, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test {
    std.testing.refAllDecls(@This());
}

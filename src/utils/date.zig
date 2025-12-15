const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("time.h");
});

pub const Date = struct {
    year: std.time.epoch.Year,
    month: u8, // 1-12
    day: u8, // 1-31
};

pub const YyyyMmDd = [10]u8;

pub fn utcDateFromUnixTimestampSeconds(timestamp_seconds: i64) error{NegativeTimestamp}!Date {
    if (timestamp_seconds < 0) return error.NegativeTimestamp;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .year = year_day.year,
        .month = @intCast(month_day.month.numeric()),
        .day = @intCast(month_day.day_index + 1),
    };
}

pub fn todayUtc() error{NegativeTimestamp}!Date {
    return utcDateFromUnixTimestampSeconds(std.time.timestamp());
}

pub fn localDateFromUnixTimestampSeconds(timestamp_seconds: i64) error{NegativeTimestamp}!Date {
    if (timestamp_seconds < 0) return error.NegativeTimestamp;

    if (builtin.os.tag == .windows) {
        @compileError("localDateFromUnixTimestampSeconds is not implemented for Windows yet.");
    }

    var t: c.time_t = @intCast(timestamp_seconds);
    var tm: c.tm = undefined;
    const tm_ptr = c.localtime_r(&t, &tm);
    if (tm_ptr == null) return error.NegativeTimestamp;

    const year: i32 = tm.tm_year + 1900;
    if (year < 0) return error.NegativeTimestamp;

    return .{
        .year = @intCast(year),
        .month = @intCast(tm.tm_mon + 1),
        .day = @intCast(tm.tm_mday),
    };
}

pub fn todayLocal() error{NegativeTimestamp}!Date {
    return localDateFromUnixTimestampSeconds(std.time.timestamp());
}

pub fn formatYYYYMMDD(buf: *YyyyMmDd, date: Date) void {
    _ = std.fmt.bufPrint(buf[0..], "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year,
        date.month,
        date.day,
    }) catch unreachable;
}

pub fn todayUtcYYYYMMDD() error{NegativeTimestamp}!YyyyMmDd {
    var buf: YyyyMmDd = undefined;
    formatYYYYMMDD(&buf, try todayUtc());
    return buf;
}

pub fn todayLocalYYYYMMDD() error{NegativeTimestamp}!YyyyMmDd {
    var buf: YyyyMmDd = undefined;
    formatYYYYMMDD(&buf, try todayLocal());
    return buf;
}

test "utc date + formatting" {
    const date = try utcDateFromUnixTimestampSeconds(0);
    try std.testing.expectEqual(@as(std.time.epoch.Year, 1970), date.year);
    try std.testing.expectEqual(@as(u8, 1), date.month);
    try std.testing.expectEqual(@as(u8, 1), date.day);

    var buf: YyyyMmDd = undefined;
    formatYYYYMMDD(&buf, date);
    try std.testing.expectEqualStrings("1970-01-01", buf[0..]);
}

test "negative timestamp fails" {
    try std.testing.expectError(error.NegativeTimestamp, utcDateFromUnixTimestampSeconds(-1));
}

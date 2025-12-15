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

pub fn parseYYYYMMDD(s: []const u8) ?Date {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;

    const year = std.fmt.parseInt(std.time.epoch.Year, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;

    const m: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
    const days_in_month: u8 = @intCast(std.time.epoch.getDaysInMonth(year, m));
    if (day < 1 or day > days_in_month) return null;

    return .{ .year = year, .month = month, .day = day };
}

pub fn dateFromEpochDay(epoch_day: std.time.epoch.EpochDay) Date {
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = @intCast(month_day.month.numeric()),
        .day = @intCast(month_day.day_index + 1),
    };
}

pub fn epochDayFromDate(d: Date) error{InvalidDate}!std.time.epoch.EpochDay {
    if (d.year < std.time.epoch.epoch_year) return error.InvalidDate;
    if (d.month < 1 or d.month > 12) return error.InvalidDate;

    const m: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(d.month)));
    const days_in_month: u8 = @intCast(std.time.epoch.getDaysInMonth(d.year, m));
    if (d.day < 1 or d.day > days_in_month) return error.InvalidDate;

    var days: u64 = 0;
    var y: std.time.epoch.Year = std.time.epoch.epoch_year;
    while (y < d.year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }

    var month: u8 = 1;
    while (month < d.month) : (month += 1) {
        const mm: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
        days += std.time.epoch.getDaysInMonth(d.year, mm);
    }

    days += @as(u64, d.day) - 1;
    return .{ .day = @intCast(days) };
}

pub fn epochDayFromYYYYMMDD(s: []const u8) error{InvalidDate}!std.time.epoch.EpochDay {
    const parsed = parseYYYYMMDD(s) orelse return error.InvalidDate;
    return try epochDayFromDate(parsed);
}

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

pub fn formatYYYYMMDDFromEpochDay(buf: *YyyyMmDd, epoch_day: std.time.epoch.EpochDay) void {
    formatYYYYMMDD(buf, dateFromEpochDay(epoch_day));
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

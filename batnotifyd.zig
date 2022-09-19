const std = @import("std");
const c = @cImport({
    @cInclude("libnotify/notify.h");
    @cInclude("libudev.h");
});

const clap = @import("clap");

const POWER_SUPPLY_SUBSYSTEM_DEVTYPE = "power_supply";
const POWER_SUPPLY_SUBSYSTEM_PATH = "/sys/class/" ++ POWER_SUPPLY_SUBSYSTEM_DEVTYPE ++ "/";

const ATTR_TYPE = "type";
const TYPE_BATTERY = "Battery";
const TYPE_POWER_SUPPLY = "Mains";

// Common battery and power supply device names to search for, in order of priority
const PRIMARY_BATTERY_NAMES = [_][]const u8{ "BAT0", "BAT1" };
const PRIMARY_POWER_SUPPLY_NAMES = [_][]const u8{ "AC", "ACAD", "ADP0" };

const PROP_CHARGE_NOW = "POWER_SUPPLY_CHARGE_NOW";
const PROP_CHARGE_FULL = "POWER_SUPPLY_CHARGE_FULL";
const PROP_CAPACITY = "POWER_SUPPLY_CAPACITY";
const PROP_ONLINE = "POWER_SUPPLY_ONLINE";
const PROP_STATUS = "POWER_SUPPLY_STATUS";

const APPLICATION_NAME = "batnotifyd";

const DEFAULT_POLL_INTERVAL = 60; // seconds
const DEFAULT_NOTIFICATION_TIMEOUT = 0; // seconds, 0 for no timeout

const DEFAULT_LOW_THRESHOLD = 0.15;
const LOW_MESSAGE_FORMAT = "Battery is at {d:.0}%";

const DEFAULT_CRITICAL_THRESHOLD = 0.05;
const CRITICAL_MESSAGE_FORMAT = "Battery is at {d:.0}%";

const Options = struct {
    poll_interval: u32, // seconds
    notification_timeout: u32, // seconds
    low_threshold: f32,
    critical_threshold: f32,
};

const Battery = struct {
    power_supply_path: ?[]const u8,
    battery_path: []const u8,
    notification: ?*c.NotifyNotification = null,
    low_shown: bool = false,
    critical_shown: bool = false,
    battery_dev: ?*c.udev_device = null,
};

/// If the user specifies a battery or power supply that starts with a '/', assume it's a full path to the device under /sys/. Otherwise, prepend "/sys/class/power_supply/". Returns a newly-allocated string regardless.
fn expand_power_supply_path(allocator: *std.mem.Allocator, user_path: []const u8) ![:0]const u8 {
    if (user_path.len >= 1 and user_path[0] == '/') {
        return try allocator.dupeZ(u8, user_path);
    }
    return try std.fmt.allocPrintZ(allocator.*, POWER_SUPPLY_SUBSYSTEM_PATH ++ "{s}", .{user_path});
}

/// Show a new notification or reuse the existing one.
fn notify(options: *Options, battery: *Battery, summary: []const u8, body: []const u8, icon: []const u8, force_show: bool) void {
    const timeout_ms = blk: {
        if (options.notification_timeout == 0) {
            break :blk c.NOTIFY_EXPIRES_NEVER;
        }
        break :blk @intCast(c_int, 1000 * options.notification_timeout);
    };
    if (battery.notification == null) {
        battery.notification = c.notify_notification_new(summary.ptr, body.ptr, icon.ptr);
        _ = c.notify_notification_set_timeout(battery.notification, timeout_ms);
        _ = c.notify_notification_show(battery.notification, null);
    } else {
        _ = c.notify_notification_update(battery.notification, summary.ptr, body.ptr, icon.ptr);
        const reason = c.notify_notification_get_closed_reason(battery.notification);
        if (reason == -1 or force_show) {
            _ = c.notify_notification_show(battery.notification, null);
        }
    }
}

/// Returns an f32 from 0.0 to 1.0.
fn get_battery_charge(battery: *Battery) !f32 {
    const charge_now_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CHARGE_NOW);
    const charge_full_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CHARGE_FULL);

    // If POWER_SUPPLY_CHARGE_NOW and POWER_SUPPLY_CHARGE_FULL properties are
    // available, use those. Otherwise, fall back to POWER_SUPPLY_CAPACITY
    if (charge_now_str != null and charge_full_str != null) {
        const charge_now = try std.fmt.parseInt(u32, std.mem.span(charge_now_str), 10);
        const charge_full = try std.fmt.parseInt(u32, std.mem.span(charge_full_str), 10);
        return @intToFloat(f32, charge_now) / @intToFloat(f32, charge_full);
    }

    const capacity_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CAPACITY);
    if (capacity_str == null) {
        std.log.err("Couldn't read the capacity of battery {s}", .{battery.battery_path});
        return error.LoggedError;
    }
    const capacity = try std.fmt.parseInt(u32, std.mem.span(capacity_str), 10);
    return @intToFloat(f32, capacity) / 100;
}

/// Get the charging status from the power supply, or, if that fails, the
/// battery. We prefer reading the state of the power supply because it's
/// (usually?) the one generating udev events, and it will know about a state
/// change before the battery does.
fn is_battery_charging(udev: ?*c.udev, battery: *Battery) !bool {
    if (battery.power_supply_path == null) {
        // AC power supply device is not available, get the charging status
        // from the battery instead
        const status_str = c.udev_device_get_property_value(battery.battery_dev, PROP_STATUS);
        const is_charging = std.mem.eql(u8, std.mem.span(status_str), "Charging");
        return is_charging;
    }

    const power_supply_dev = c.udev_device_new_from_syspath(udev, battery.power_supply_path.?.ptr);
    defer _ = c.udev_device_unref(power_supply_dev);

    if (power_supply_dev == null) {
        std.log.err("Couldn't open the power supply at {s}", .{battery.power_supply_path.?});
        return error.LoggedError;
    }

    const online_str = c.udev_device_get_property_value(power_supply_dev, PROP_ONLINE);
    const is_charging = std.mem.eql(u8, std.mem.span(online_str), "1");

    return is_charging;
}

/// Update the notification based on the state of the power supply and battery
fn update(allocator: *std.mem.Allocator, options: *Options, udev: ?*c.udev, battery: *Battery) !void {
    battery.battery_dev = c.udev_device_new_from_syspath(udev, battery.battery_path.ptr);

    if (battery.battery_dev == null) {
        std.log.err("Couldn't open the udev device at {s}", .{battery.battery_path});
        return error.LoggedError;
    }

    defer {
        battery.battery_dev = null;
        _ = c.udev_device_unref(battery.battery_dev);
    }

    const charge = try get_battery_charge(battery);
    const is_charging = try is_battery_charging(udev, battery);

    if (is_charging) {
        battery.critical_shown = false;
        battery.low_shown = false;
        if (battery.notification != null) {
            _ = c.notify_notification_close(battery.notification, null);
        }
    } else {
        if (charge <= options.critical_threshold) {
            const force_show = !battery.critical_shown;
            const charge_percent = std.math.ceil(100 * charge);
            const critical_message = try std.fmt.allocPrintZ(allocator.*, CRITICAL_MESSAGE_FORMAT, .{charge_percent});
            defer allocator.free(critical_message);
            notify(options, battery, critical_message, "", "battery-low", force_show);
            battery.critical_shown = true;
        } else if (charge <= options.low_threshold) {
            const force_show = !battery.low_shown;
            const charge_percent = std.math.ceil(100 * charge);
            const low_message = try std.fmt.allocPrintZ(allocator.*, LOW_MESSAGE_FORMAT, .{charge_percent});
            defer allocator.free(low_message);
            notify(options, battery, low_message, "", "battery-low", force_show);
            battery.low_shown = true;
        }
    }
}

/// Monitor the power_supply subsystem for state changes. Also do periodic
/// polling in case we miss any events
fn monitor(allocator: *std.mem.Allocator, options: *Options, udev: ?*c.udev, battery: *Battery) !void {
    const mon = c.udev_monitor_new_from_netlink(udev, "udev");
    defer _ = c.udev_monitor_unref(mon);
    _ = c.udev_monitor_filter_add_match_subsystem_devtype(mon, POWER_SUPPLY_SUBSYSTEM_DEVTYPE, null);
    _ = c.udev_monitor_enable_receiving(mon);

    const udev_fd = c.udev_monitor_get_fd(mon);
    const udev_pollfd = std.os.pollfd{
        .fd = udev_fd,
        .events = std.os.linux.POLL.IN | std.os.linux.POLL.PRI,
        .revents = 0,
    };

    const timer_fd_u64 = std.os.linux.timerfd_create(0, std.os.linux.CLOCK.REALTIME);
    const timer_fd = @truncate(u16, timer_fd_u64);
    const itimerspec = std.os.linux.itimerspec{
        .it_interval = std.os.timespec{ .tv_sec = options.poll_interval, .tv_nsec = 0 },
        .it_value = std.os.timespec{ .tv_sec = options.poll_interval, .tv_nsec = 0 },
    };
    _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
    const timer_pollfd = std.os.pollfd{
        .fd = timer_fd,
        .events = std.os.linux.POLL.IN | std.os.linux.POLL.PRI,
        .revents = 0,
    };

    var pollfds = [_]std.os.pollfd{ timer_pollfd, udev_pollfd };

    var timer_buffer = [_]u8{0} ** 8;

    while (true) {
        try update(allocator, options, udev, battery);

        _ = std.os.poll(&pollfds, -1) catch unreachable;

        if (c.udev_monitor_receive_device(mon) == null) {
            _ = try std.os.read(timer_fd, &timer_buffer);
        } else {
            // reset poll timeout on udev event
            _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
        }
    }
}

/// Deallocate a Battery
fn battery_free(allocator: *std.mem.Allocator, battery: *Battery) void {
    allocator.free(battery.battery_path);
    if (battery.power_supply_path) |path| {
        allocator.free(path);
    }
}

/// Get a Battery from the user-supplied device path or try to find the
/// "primary" battery of the system
fn get_battery(allocator: *std.mem.Allocator, udev: ?*c.udev, user_battery_path: ?[:0]const u8, user_power_supply_path: ?[:0]const u8) !Battery {
    var battery_path: ?[:0]const u8 = null;
    var power_supply_path: ?[:0]const u8 = null;

    errdefer {
        if (battery_path) |path| {
            _ = allocator.free(path);
        }
        if (power_supply_path) |path| {
            _ = allocator.free(path);
        }
    }

    if (user_battery_path) |path| {
        battery_path = try allocator.dupeZ(u8, path);
    }
    if (user_power_supply_path) |path| {
        power_supply_path = try allocator.dupeZ(u8, path);
    }

    if (battery_path == null or power_supply_path == null) {
        const udev_enum = c.udev_enumerate_new(udev);
        defer _ = c.udev_enumerate_unref(udev_enum);
        _ = c.udev_enumerate_add_match_subsystem(udev_enum, POWER_SUPPLY_SUBSYSTEM_DEVTYPE);
        _ = c.udev_enumerate_scan_devices(udev_enum);
        var iter = c.udev_enumerate_get_list_entry(udev_enum);
        while (iter != null and (battery_path == null or power_supply_path == null)) {
            const path = c.udev_list_entry_get_name(iter);
            const device = c.udev_device_new_from_syspath(udev, path);
            defer _ = c.udev_device_unref(device);
            const device_type = std.mem.span(c.udev_device_get_sysattr_value(device, "type"));
            if (battery_path == null and std.mem.eql(u8, device_type, TYPE_BATTERY)) {
                const name = std.mem.span(c.udev_device_get_sysname(device));
                for (PRIMARY_BATTERY_NAMES) |primary_battery_name| {
                    if (std.mem.eql(u8, name, primary_battery_name)) {
                        battery_path = try allocator.dupeZ(u8, std.mem.span(path));
                        break;
                    }
                }
            } else if (power_supply_path == null and std.mem.eql(u8, device_type, TYPE_POWER_SUPPLY)) {
                const name = std.mem.span(c.udev_device_get_sysname(device));
                for (PRIMARY_POWER_SUPPLY_NAMES) |primary_power_supply_name| {
                    if (std.mem.eql(u8, name, primary_power_supply_name)) {
                        power_supply_path = try allocator.dupeZ(u8, std.mem.span(path));
                        break;
                    }
                }
            }
            iter = c.udev_list_entry_get_next(iter);
        }
    }

    if (battery_path == null) {
        if (user_battery_path) |user_path| {
            std.log.err("Couldn't open the battery at {s}", .{user_path});
        } else {
            const battery_names = try std.mem.join(allocator.*, ", ", &PRIMARY_BATTERY_NAMES);
            defer _ = allocator.free(battery_names);
            std.log.err("No battery found! Tried {s}", .{battery_names});
        }
        return error.LoggedError;
    }

    const battery_device = c.udev_device_new_from_syspath(udev, battery_path.?);
    defer _ = c.udev_device_unref(battery_device);
    if (battery_device == null) {
        // std.log.err("Couldn't open the battery at {s}", .{battery_path});
        return error.LoggedError;
    }

    if (power_supply_path) |path| {
        const power_supply_device = c.udev_device_new_from_syspath(udev, path);
        defer _ = c.udev_device_unref(power_supply_device);
        if (power_supply_device == null) {
            if (user_power_supply_path) |user_path| {
                std.log.err("Couldn't open the power supply at {s}", .{user_path});
                return error.LoggedError;
            }
            power_supply_path = null;
        }
    }

    return Battery{
        .battery_path = battery_path.?,
        .power_supply_path = power_supply_path,
    };
}

fn run_g_main_loop(g_main_loop: ?*c.GMainLoop) void {
    _ = c.g_main_loop_run(g_main_loop);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.assert(!leaked);
    }
    const allocator = &gpa.backing_allocator;

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                     Display this help and exit.") catch unreachable,
        clap.parseParam("-b, --battery <string>            Name of the battery device to monitor, e.g. BAT0, or its full path, e.g. /sys/class/power_supply/BAT0. If not supplied, a device will be selected automatically.") catch unreachable,
        clap.parseParam("-p, --power_supply <string>       Name of the power supply device connected to the battery, e.g. AC, or its full path, e.g. /sys/class/power_supply/AC. If not supplied, a device will be selected automatically.") catch unreachable,
        clap.parseParam("-i, --interval <u32>           Interval in seconds at which to poll the battery in case any udev events are missed. Default is 60.") catch unreachable,
        clap.parseParam("-l, --low_threshold <f32>      Percentage capacity at which the battery is \"low\". Default is 15.") catch unreachable,
        clap.parseParam("-c, --critical_threshold <f32> Percentage capacity at which the battery is critically low. Default is 5.") catch unreachable,
        clap.parseParam("-t, --timeout <u32>            Notification timeout in seconds. Default is 0 (notifications stay until dismissed)") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return;
    };
    defer res.deinit();

    if (res.args.help) {
        clap.help(
            std.io.getStdErr().writer(),
            clap.Help,
            &params,
            .{},
        ) catch unreachable;
        return;
    }

    const poll_interval = if (res.args.interval) |arg| arg else DEFAULT_POLL_INTERVAL;
    const notification_timeout = if (res.args.timeout) |arg| arg else DEFAULT_NOTIFICATION_TIMEOUT;
    const low_threshold = blk: {
        if (res.args.low_threshold) |arg| {
            if (!(0.0 <= arg and arg <= 100.0)) {
                std.log.err("Invalid low threshold {d}. Should be a numeric percentage, like \"20\".", .{arg});
                return;
            }
            break :blk arg / 100.0;
        }
        break :blk DEFAULT_LOW_THRESHOLD;
    };

    const critical_threshold = blk: {
        if (res.args.critical_threshold) |arg| {
            if (!(0.0 <= arg and arg <= 100.0)) {
                std.log.err("Invalid critical threshold {d}. Should be a numeric percentage, like \"20\".", .{arg});
                return;
            }
            break :blk arg / 100.0;
        }
        break :blk DEFAULT_CRITICAL_THRESHOLD;
    };

    const user_battery_path: ?[:0]const u8 = blk: {
        if (res.args.battery) |arg| {
            break :blk expand_power_supply_path(allocator, arg) catch unreachable;
        } else {
            break :blk null;
        }
    };
    const user_power_supply_path: ?[:0]const u8 = blk: {
        if (res.args.power_supply) |arg| {
            break :blk expand_power_supply_path(allocator, arg) catch unreachable;
        } else {
            break :blk null;
        }
    };

    defer {
        if (user_battery_path) |path| {
            _ = allocator.free(path);
        }
        if (user_power_supply_path) |path| {
            _ = allocator.free(path);
        }
    }

    var options = Options{
        .poll_interval = poll_interval,
        .low_threshold = low_threshold,
        .critical_threshold = critical_threshold,
        .notification_timeout = notification_timeout,
    };

    if (c.notify_init(APPLICATION_NAME) != 1) {
        std.log.err("Couldn't initialize libnotify!", .{});
        return;
    }

    const udev = c.udev_new();
    defer _ = c.udev_unref(udev);
    if (udev == null) {
        std.log.err("Couldn't initialize udev!", .{});
        return;
    }

    var battery = get_battery(allocator, udev, user_battery_path, user_power_supply_path) catch |err| switch (err) {
        error.LoggedError => return,
        else => unreachable,
    };
    defer _ = battery_free(allocator, &battery);

    const g_main_loop = c.g_main_loop_new(null, 0);
    _ = std.Thread.spawn(std.Thread.SpawnConfig{}, run_g_main_loop, .{g_main_loop}) catch unreachable;

    monitor(allocator, &options, udev, &battery) catch |err| switch (err) {
        error.LoggedError => return,
        else => unreachable,
    };
}

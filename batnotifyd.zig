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
    low_threshold: f32,
    critical_threshold: f32,
    notification_timeout: u32, // seconds
};

const Battery = struct {
    power_supply_path: ?[]const u8,
    battery_path: []const u8,
    notification: ?*c.NotifyNotification = null,
    low_shown: bool = false,
    critical_shown: bool = false,
    battery_dev: ?*c.udev_device = null,
};

fn expand_power_supply_path(allocator: *std.mem.Allocator, user_path: []const u8) ![:0]const u8 {
    for (user_path) |char| {
        if (char == '/') {
            return try allocator.dupeZ(u8, user_path);
        }
    }
    return try std.fmt.allocPrintZ(allocator, POWER_SUPPLY_SUBSYSTEM_PATH ++ "{s}", .{user_path});
}

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

fn get_battery_charge(battery: *Battery) !f32 {
    const charge_now_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CHARGE_NOW);
    const charge_full_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CHARGE_FULL);

    // If POWER_SUPPLY_CHARGE_NOW and POWER_SUPPLY_CHARGE_FULL properties are
    // available, use those. Otherwise, fall back to POWER_SUPPLY_CAPACITY
    if (charge_now_str != null and charge_full_str != null) {
        const charge_now = try std.fmt.parseInt(u32, std.mem.spanZ(charge_now_str), 10);
        const charge_full = try std.fmt.parseInt(u32, std.mem.spanZ(charge_full_str), 10);
        return @intToFloat(f32, charge_now) / @intToFloat(f32, charge_full);
    }

    const capacity_str = c.udev_device_get_property_value(battery.battery_dev, PROP_CAPACITY);
    const capacity = try std.fmt.parseInt(u32, std.mem.spanZ(capacity_str), 10);
    return @intToFloat(f32, capacity) / 100;
}

fn is_battery_charging(udev: ?*c.udev, battery: *Battery) !bool {
    if (battery.power_supply_path == null) {
        // AC power supply device is not available, get the charging status
        // from the battery instead
        const status_str = c.udev_device_get_property_value(battery.battery_dev, PROP_STATUS);
        const is_charging = std.mem.eql(u8, std.mem.spanZ(status_str), "Charging");
        return is_charging;
    }

    const power_supply_dev = c.udev_device_new_from_syspath(udev, battery.power_supply_path.?.ptr);
    defer _ = c.udev_device_unref(power_supply_dev);

    if (power_supply_dev == null) {
        std.log.err("Couldn't open the power supply at {s}", .{battery.power_supply_path.?});
        return error.LoggedError;
    }

    const online_str = c.udev_device_get_property_value(power_supply_dev, PROP_ONLINE);
    const is_charging = std.mem.eql(u8, std.mem.spanZ(online_str), "1");

    return is_charging;
}

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
            const critical_message = try std.fmt.allocPrintZ(allocator, CRITICAL_MESSAGE_FORMAT, .{charge_percent});
            defer allocator.free(critical_message);
            notify(options, battery, critical_message, "", "battery-low", force_show);
            battery.critical_shown = true;
        } else if (charge <= options.low_threshold) {
            const force_show = !battery.low_shown;
            const charge_percent = std.math.ceil(100 * charge);
            const low_message = try std.fmt.allocPrintZ(allocator, LOW_MESSAGE_FORMAT, .{charge_percent});
            defer allocator.free(low_message);
            notify(options, battery, low_message, "", "battery-low", force_show);
            battery.low_shown = true;
        }
    }
}

fn monitor(allocator: *std.mem.Allocator, options: *Options, udev: ?*c.udev, battery: *Battery) !void {
    const mon = c.udev_monitor_new_from_netlink(udev, "udev");
    defer _ = c.udev_monitor_unref(mon);
    _ = c.udev_monitor_filter_add_match_subsystem_devtype(mon, POWER_SUPPLY_SUBSYSTEM_DEVTYPE, null);
    _ = c.udev_monitor_enable_receiving(mon);

    const udev_fd = c.udev_monitor_get_fd(mon);
    const udev_pollfd = std.os.pollfd{
        .fd = udev_fd,
        .events = std.os.POLLIN | std.os.POLLPRI,
        .revents = 0,
    };

    const timer_fd_u64 = std.os.linux.timerfd_create(0, std.os.CLOCK_REALTIME);
    const timer_fd = @truncate(u16, timer_fd_u64);
    const itimerspec = std.os.linux.itimerspec{
        .it_interval = std.os.timespec{ .tv_sec = options.poll_interval, .tv_nsec = 0 },
        .it_value = std.os.timespec{ .tv_sec = options.poll_interval, .tv_nsec = 0 },
    };
    _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
    const timer_pollfd = std.os.pollfd{
        .fd = timer_fd,
        .events = std.os.POLLIN | std.os.POLLPRI,
        .revents = 0,
    };

    var pollfds = [_]std.os.pollfd{ timer_pollfd, udev_pollfd };

    var timer_buffer = [_]u8{0} ** 8;

    while (true) {
        try update(allocator, options, udev, battery);

        const result = std.os.poll(&pollfds, -1);

        if (c.udev_monitor_receive_device(mon) == null) {
            _ = try std.os.read(timer_fd, &timer_buffer);
        } else {
            // reset timeout on udev event
            _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
        }
    }
}

fn battery_free(allocator: *std.mem.Allocator, battery: *Battery) void {
    allocator.free(battery.battery_path);
    if (battery.power_supply_path) |path| {
        allocator.free(path);
    }
}

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
        if (user_battery_path == null) {
            const battery_names = try std.mem.join(allocator, ", ", &PRIMARY_BATTERY_NAMES);
            defer _ = allocator.free(battery_names);
            std.log.err("No battery found! Tried {s}", .{battery_names});
        } else {
            std.log.err("Couldn't open the battery at {s}", .{battery_path});
        }
        return error.LoggedError;
    }

    const battery_device = c.udev_device_new_from_syspath(udev, battery_path.?);
    defer _ = c.udev_device_unref(battery_device);
    if (battery_device == null) {
        return error.LoggedError;
    }

    if (power_supply_path) |path| {
        const power_supply_device = c.udev_device_new_from_syspath(udev, path);
        defer _ = c.udev_device_unref(power_supply_device);
        if (power_supply_device == null) {
            if (user_power_supply_path != null) {
                std.log.err("Couldn't open the power supply at {s}", .{power_supply_path});
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
    const allocator = &gpa.allocator;

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.              ") catch unreachable,
        clap.parseParam("-b, --battery <STR>     An option parameter, which takes a value.") catch unreachable,
        clap.parseParam("-p, --power-supply <STR>") catch unreachable,
        clap.parseParam("-i, --interval <NUM>") catch unreachable,
        clap.parseParam("-l, --low-threshold <NUM>") catch unreachable,
        clap.parseParam("-c, --critical-threshold <NUM>") catch unreachable,
        clap.parseParam("-t, --timeout <NUM>") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        clap.help(
            std.io.getStdErr().writer(),
            &params,
        ) catch unreachable;
        return;
    }

    const poll_interval = blk: {
        if (args.option("--interval")) |arg| {
            break :blk std.fmt.parseInt(u32, arg, 10) catch |err| {
                std.log.err("Couldn't parse interval {s}. Should be an integer number of seconds.", .{arg});
                return;
            };
        } else break :blk DEFAULT_POLL_INTERVAL;
    };
    const notification_timeout = blk: {
        if (args.option("--timeout")) |arg| {
            break :blk std.fmt.parseInt(u32, arg, 10) catch |err| {
                std.log.err("Couldn't parse timeout {s}. Should be an integer number of seconds.", .{arg});
                return;
            };
        } else break :blk DEFAULT_NOTIFICATION_TIMEOUT;
    };
    const low_threshold = blk: {
        if (args.option("--low-threshold")) |arg| {
            const percentage = std.fmt.parseFloat(f32, arg) catch |err| {
                std.log.err("Couldn't parse low threshold {s}. Should be a percentage.", .{arg});
                return;
            };
            break :blk percentage / 100;
        } else break :blk DEFAULT_LOW_THRESHOLD;
    };
    const critical_threshold = blk: {
        if (args.option("--critical-threshold")) |arg| {
            const percentage = std.fmt.parseFloat(f32, arg) catch |err| {
                std.log.err("Couldn't parse critical threshold {s}. Should be a percentage.", .{arg});
                return;
            };
            break :blk percentage / 100;
        } else break :blk DEFAULT_CRITICAL_THRESHOLD;
    };
    const user_battery_path: ?[:0]const u8 = blk: {
        if (args.option("--battery")) |arg| {
            break :blk expand_power_supply_path(allocator, arg) catch unreachable;
        } else break :blk null;
    };
    const user_power_supply_path: ?[:0]const u8 = blk: {
        if (args.option("--power-supply")) |arg| {
            break :blk expand_power_supply_path(allocator, arg) catch unreachable;
        } else break :blk null;
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
    _ = std.Thread.spawn(run_g_main_loop, g_main_loop) catch unreachable;

    monitor(allocator, &options, udev, &battery) catch |err| switch (err) {
        error.LoggedError => return,
        else => unreachable,
    };
}

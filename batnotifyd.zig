const std = @import("std");
const c = @cImport({
    @cInclude("libnotify/notify.h");
    @cInclude("libudev.h");
});

const POWER_SUPPLY_SUBSYSTEM_DEVTYPE = "power_supply";
const POWER_SUPPLY_SUBSYSTEM_PATH = "/sys/class/" ++ POWER_SUPPLY_SUBSYSTEM_DEVTYPE;

const PROP_CHARGE_NOW = "POWER_SUPPLY_CHARGE_NOW";
const PROP_CHARGE_FULL = "POWER_SUPPLY_CHARGE_FULL";
const PROP_CAPACITY = "POWER_SUPPLY_CAPACITY";
const PROP_ONLINE = "POWER_SUPPLY_ONLINE";
const PROP_STATUS = "POWER_SUPPLY_STATUS";

const APPLICATION_NAME = "batnotifyd";

// BEGIN CONFIGURABLE OPTIONS
const POLL_INTERVAL = 60; // seconds

const LOW_THRESHOLD = 1.00;
const LOW_MESSAGE_FORMAT = "Battery is at {d:.0}%";

const CRITICAL_THRESHOLD = 0.05;
const CRITICAL_MESSAGE_FORMAT = "Battery is at {d:.0}%";

const POWER_SUPPLY_PATH = POWER_SUPPLY_SUBSYSTEM_PATH ++ "/AD";
const BATTERY_PATH = POWER_SUPPLY_SUBSYSTEM_PATH ++ "/BAT0";

// END CONFIGURABLE OPTIONS

const BatteryConfig = struct {
    power_supply_path: ?[]const u8,
    battery_path: []const u8,
};

const Battery = struct {
    config: *BatteryConfig,
    notification: ?*c.NotifyNotification = null,
    low_shown: bool = false,
    critical_shown: bool = false,
    battery_dev: ?*c.udev_device = null,
};

fn notify(battery: *Battery, summary: []const u8, body: []const u8, icon: []const u8, force_show: bool) void {
    if (battery.notification == null) {
        battery.notification = c.notify_notification_new(summary.ptr, body.ptr, icon.ptr);
        _ = c.notify_notification_set_timeout(battery.notification, c.NOTIFY_EXPIRES_NEVER);
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
    if (battery.config.power_supply_path == null) {
        // AC power supply device is not available, get the charging status
        // from the battery instead
        const status_str = c.udev_device_get_property_value(battery.battery_dev, PROP_STATUS);
        const is_charging = std.mem.eql(u8, std.mem.spanZ(status_str), "Charging");
        return is_charging;
    }

    const power_supply_dev = c.udev_device_new_from_syspath(udev, battery.config.power_supply_path.?.ptr);

    if (power_supply_dev == null) {
        std.log.err("Couldn't access the power supply at {s}", .{battery.config.power_supply_path.?});
        return error.PowerSupplyOpen;
    }

    defer _ = c.udev_device_unref(power_supply_dev);
    const online_str = c.udev_device_get_property_value(power_supply_dev, PROP_ONLINE);
    const is_charging = std.mem.eql(u8, std.mem.spanZ(online_str), "1");

    return is_charging;
}

fn update(allocator: *std.mem.Allocator, udev: ?*c.udev, batteries: *std.ArrayList(Battery)) !void {
    var battery_idx: usize = 0;
    while (battery_idx < batteries.items.len) : (battery_idx += 1) {
        const battery = &batteries.items[battery_idx];

        battery.battery_dev = c.udev_device_new_from_syspath(udev, battery.config.battery_path.ptr);

        if (battery.battery_dev == null) {
            std.log.err("Couldn't access the battery at {s}", .{battery.config.battery_path});
            continue;
        }

        defer {
            battery.battery_dev = null;
            _ = c.udev_device_unref(battery.battery_dev);
        }

        const charge = try get_battery_charge(battery);
        const is_charging = is_battery_charging(udev, battery) catch continue;

        if (is_charging) {
            battery.critical_shown = false;
            battery.low_shown = false;
            if (battery.notification != null) {
                _ = c.notify_notification_close(battery.notification, null);
            }
        } else {
            if (charge <= CRITICAL_THRESHOLD) {
                const force_show = !battery.critical_shown;
                const charge_percent = 100 * charge;
                const critical_message = try std.fmt.allocPrintZ(allocator, CRITICAL_MESSAGE_FORMAT, .{charge_percent});
                defer allocator.free(critical_message);
                notify(battery, critical_message, "", "battery-low", force_show);
                battery.critical_shown = true;
            } else if (charge <= LOW_THRESHOLD) {
                const force_show = !battery.low_shown;
                const charge_percent = 100 * charge;
                const low_message = try std.fmt.allocPrintZ(allocator, LOW_MESSAGE_FORMAT, .{charge_percent});
                defer allocator.free(low_message);
                notify(battery, low_message, "", "battery-low", force_show);
                battery.low_shown = true;
            }
        }
    }
}

fn monitor_battery(allocator: *std.mem.Allocator, udev: ?*c.udev, batteries: *std.ArrayList(Battery)) !void {
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
        .it_interval = std.os.timespec{ .tv_sec = POLL_INTERVAL, .tv_nsec = 0 },
        .it_value = std.os.timespec{ .tv_sec = POLL_INTERVAL, .tv_nsec = 0 },
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
        try update(allocator, udev, batteries);

        const result = std.os.poll(&pollfds, -1);

        if (c.udev_monitor_receive_device(mon) == null) {
            _ = try std.os.read(timer_fd, &timer_buffer);
        } else {
            // reset timeout on udev event
            _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
        }
    }
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

    if (c.notify_init(APPLICATION_NAME) != 1) {
        return error.NotifyInit;
    }

    const udev = c.udev_new();
    defer _ = c.udev_unref(udev);
    if (udev == null) {
        return error.UdevNew;
    }

    // in the future, support multiple batteries
    var batteries = std.ArrayList(Battery).init(&gpa.allocator);
    defer batteries.deinit();

    var config = BatteryConfig{
        // .power_supply_path = null,
        .power_supply_path = POWER_SUPPLY_PATH,
        .battery_path = BATTERY_PATH,
    };

    const g_main_loop = c.g_main_loop_new(null, 0);
    _ = try std.Thread.spawn(run_g_main_loop, g_main_loop);
    try batteries.append(Battery{
        .config = &config,
    });
    try monitor_battery(&gpa.allocator, udev, &batteries);
}

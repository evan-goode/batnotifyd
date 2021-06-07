const std = @import("std");
const c = @cImport({
    @cInclude("libnotify/notify.h");
    @cInclude("libudev.h");
});

const POLL_INTERVAL = 2;
const POWER_SUPPLY_SUBSYSTEM_DEVTYPE = "power_supply";
const POWER_SUPPLY_SUBSYSTEM_PATH = "/sys/class/" ++ POWER_SUPPLY_SUBSYSTEM_DEVTYPE;

const PROP_CHARGE_NOW = "POWER_SUPPLY_CHARGE_NOW";
const PROP_CHARGE_FULL = "POWER_SUPPLY_CHARGE_FULL";
const PROP_CAPACITY = "POWER_SUPPLY_CAPACITY";
const PROP_ONLINE = "POWER_SUPPLY_ONLINE";

const APPLICATION_NAME = "battnotifyd";

const LOW_THRESHOLD = 0.15;
const LOW_MESSAGE = "Low battery!";

const CRITICAL_THRESHOLD = 0.05;
const CRITICAL_MESSAGE = "Critically low battery!";

const POWER_SUPPLY_PATH = POWER_SUPPLY_SUBSYSTEM_PATH ++ "/ADP1";
const BATTERY_PATH = POWER_SUPPLY_SUBSYSTEM_PATH ++ "/BAT0";

const BatteryConfig = struct {
    power_supply_path: [*c]const u8,
    battery_path: [*c]const u8,
};

const Battery = struct {
    config: *BatteryConfig,
    notification: ?*c.NotifyNotification = null,
    low_shown: bool = false,
    critical_shown: bool = false,
};

fn notify(battery: *Battery, summary: [*c]const u8, body: [*c]const u8, icon: [*c]const u8) void {
    if (battery.notification == null) {
        battery.notification = c.notify_notification_new(summary, body, icon);
        // _ = g_signal_connect(battery.notification, "closed", @ptrCast(c.GCallback, on_closed), null);
        _ = c.notify_notification_set_timeout(battery.notification, c.NOTIFY_EXPIRES_NEVER);
        _ = c.notify_notification_show(battery.notification, null);
    } else {
        _ = c.notify_notification_update(battery.notification, summary, body, icon);
        _ = c.notify_notification_show(battery.notification, null);
    }
}

fn get_charge(dev: *c.udev_device) !f32 {
    const charge_now_str = c.udev_device_get_property_value(dev, PROP_CHARGE_NOW);
    const charge_full_str = c.udev_device_get_property_value(dev, PROP_CHARGE_FULL);

    if (charge_now_str != null and charge_full_str != null) {
        const charge_now = try std.fmt.parseInt(u32, std.mem.spanZ(charge_now_str), 10);
        const charge_full = try std.fmt.parseInt(u32, std.mem.spanZ(charge_full_str), 10);
        return @intToFloat(f32, charge_now) / @intToFloat(f32, charge_full);
    }

    const capacity_str = c.udev_device_get_property_value(dev, PROP_CAPACITY);
    const capacity = try std.fmt.parseInt(u32, std.mem.spanZ(capacity_str), 10);
    return @intToFloat(f32, capacity) / 100;
}

fn update(udev: ?*c.udev, batteries: std.ArrayList(Battery)) !void {
    var i: usize = 0;
    while (i < batteries.items.len) : (i += 1) {
        const battery = batteries.items[i];

        const battery_dev = c.udev_device_new_from_syspath(udev, battery.config.battery_path);
        defer _ = c.udev_device_unref(battery_dev);

        if (battery_dev == null) continue;

        const charge = try get_charge(battery_dev.?);

        const power_supply_dev = c.udev_device_new_from_syspath(udev, battery.config.power_supply_path);
        defer _ = c.udev_device_unref(power_supply_dev);
        const online_str = c.udev_device_get_property_value(power_supply_dev, PROP_ONLINE);
        const is_charging = std.mem.eql(u8, std.mem.spanZ(online_str), "1");

        if (is_charging) {
            batteries.items[i].critical_shown = false;
            batteries.items[i].low_shown = false;
            _ = c.notify_notification_close(battery.notification, null);
        } else {
            if (charge <= CRITICAL_THRESHOLD) {
                if (!battery.critical_shown) {
                    notify(&batteries.items[i], CRITICAL_MESSAGE, "", "battery-low");
                    batteries.items[i].critical_shown = true;
                }
            } else if (charge <= LOW_THRESHOLD and !battery.low_shown) {
                if (!battery.low_shown) {
                    notify(&batteries.items[i], LOW_MESSAGE, "", "battery-low");
                    batteries.items[i].low_shown = true;
                }
            }
        }
    }
}

fn monitor_battery(udev: ?*c.udev, batteries: std.ArrayList(Battery)) !void {
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
        try update(udev, batteries);

        const result = std.os.poll(&pollfds, -1);

        if (c.udev_monitor_receive_device(mon) == null) {
            _ = try std.os.read(timer_fd, &timer_buffer);
        } else {
            // reset timeout on udev event
            _ = std.os.linux.timerfd_settime(timer_fd, 0, &itimerspec, null);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.assert(!leaked);
    }

    if (c.notify_init(APPLICATION_NAME) != 1) {
        return error.NotifyInitFailed;
    }

    const udev = c.udev_new();
    defer _ = c.udev_unref(udev);
    if (udev == null) {
        return error.UdevFailed;
    }

    var batteries = std.ArrayList(Battery).init(&gpa.allocator);
    defer batteries.deinit();

    var config = BatteryConfig{
        .power_supply_path = POWER_SUPPLY_PATH,
        .battery_path = BATTERY_PATH,
    };
    try batteries.append(Battery{
        .config = &config,
    });
    try monitor_battery(udev, batteries);
}
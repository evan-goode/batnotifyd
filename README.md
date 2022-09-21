# batnotifyd

Lightweight daemon for low battery notifications on GNU/Linux. Requires libudev and libnotify. Written in [Zig](https://ziglang.org/).

## Build & Run

```
zig build
./zig-out/bin/batnotifyd
```

## Recommended usage

batnotifyd can run a command if the battery gets "dangerously low" (default is 2%, configure with `--danger_threshold`). It's highly recommended to set it to suspend, or hibernate if your system supports it:

```
./zig-out/bin/batnotifyd --danger_hook 'systemctl suspend'
```

## Install

A systemd `--user` unit file is included for convenience.

```
zig build
sudo install -m 755 ./zig-out/bin/batnotifyd /usr/local/bin/
install -m 644 batnotifyd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now batnotifyd
```

# systemd-oomd 与 PonWrt 编译

## 为什么会“编译自动退出”

2026-10-31 14:20:43 的 journal：

```
systemd-oomd[941]: Killed /user.slice/.../app-org.gnome.Terminal.slice/vte-spawn-....scope
due to memory pressure for /user.slice/user-1000.slice/user@1000.service
being 53.98% > 50.00% for > 20s with reclaim activity
```

Ubuntu 的 `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf`
把 `user@.service` 设成了 `ManagedOOMMemoryPressure=kill` +
`ManagedOOMMemoryPressureLimit=50%`。编译时内存压力超过 50% 并持续 20 秒，
systemd-oomd 就把整个 GNOME Terminal 的 scope（连同里面的 `make`）SIGKILL 掉。
这不是 `build.sh` 的行为。

## 方案 A（推荐，root，永久）：调高 user@.service 的阈值

```sh
sudo ./scripts/systemd/install-oomd-override.sh
```

它会安装：

```
/etc/systemd/system/user@.service.d/99-oomd-user-service.conf
```

内容是把 `ManagedOOMMemoryPressureLimit` 覆盖成 `100%`，然后
`systemctl daemon-reload` + `try-restart systemd-oomd`。查看：

```sh
systemctl show user@1000.service \
  -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit
```

撤销：

```sh
sudo rm /etc/systemd/system/user@.service.d/99-oomd-user-service.conf
sudo systemctl daemon-reload
sudo systemctl try-restart systemd-oomd
```

> 如果当前 shell 在带 `no_new_privs` 的沙箱里，`sudo` 会被拦截
> （“The 'no new privileges' flag is set”），请在普通终端执行上面这条 `sudo`。
> 配置文件和脚本已经随仓库放在 `scripts/systemd/`。

## 方案 B（无 root，只保护当前终端）

```sh
. /home/jzhou/work/ponwrt/scripts/systemd/protect-terminal-scope.sh
```

它把**当前 shell 所在 scope** 的 `ManagedOOMMemoryPressureLimit` 设成 `100%`，
效果只覆盖这个终端及其子进程。想每个新终端自动生效，把这行加进 `~/.bashrc`：

```sh
echo '. /home/jzhou/work/ponwrt/scripts/systemd/protect-terminal-scope.sh' >> ~/.bashrc
```

这个方案不能保护浏览器等其它 scope；要系统级永久生效请用方案 A。

## 编译时还可以做的

- `JOBS=8 ./build.sh`（或更低）降低峰值内存；
- 或者用独立 transient scope 跑构建，终端即使被杀，构建也还在：

  ```sh
  systemd-run --user --scope \
    -p ManagedOOMMemoryPressure=kill \
    -p ManagedOOMMemoryPressureLimit=100% \
    -- ./build.sh
  ```

## GitHub / CI 上的限制（为什么仓库不自动装）

- 这是**主机侧** systemd 配置，不是固件构建输入；`build.sh` 不会改 `/etc`、不会重启
  `systemd-oomd`，避免构建脚本去动开发机的系统服务。
- 本地 Ubuntu 需要 root 执行一次 `scripts/systemd/install-oomd-override.sh`；这是唯一
  的人工步骤，普通构建脚本无法代劳。
- CI 容器里通常没有 systemd-oomd，不需要这段；如果 CI 用 systemd 且允许 sudo，可以在
  job 里显式调用该脚本。
- 不能把 Ubuntu 24.04 的 50% 默认值当成 PonWrt 的 bug：它属于 `systemd-oomd` 包
  的桌面默认策略，对 `make -j16` 这种重编译太激进，覆盖即可。
- 无 root / 无 systemd 的环境改用独立 `systemd-run` scope，或者在终端里 source
  `protect-terminal-scope.sh`。


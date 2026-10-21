# adblock-fast 启动时 LuCI 全站卡死：rpcd 被 procd flock 堵住

> 机器：Nokia XG-040G-MD（`nokia,xg-040g-md-ubi`，AN7581）
> 镜像：PonWrt `r41558+68-a57faf93c6`，内核 `6.18.52`，squashfs 产物 2026-10-21 14:23
> 现象：SSH 正常，`192.168.32.254:8000` 的 LuCI **要么 30 秒后 403、要么一直转圈**，
> 登录页都出不来；`curl /`（静态首页）却是 0.001 秒。
> 修复：`feed-patches/packages/net/adblock-fast/0002-nonblocking-service-enabled.patch`

---

## 0. 结论速览

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | adblock-fast 启动/下载期间，**所有** LuCI 页面卡死 | `get_init_status` → `service_enabled()` 执行 `init.d/adblock-fast enabled`；`procd.sh` 在 **source 阶段** 就 `flock` 服务锁，而锁被正在跑的 `start` 占着 | 改成直接看 `/etc/rc.d/S??adblock-fast` 符号链接，不再执行 init 脚本 |
| 2 | 为什么 `start` 一跑就是十几分钟 | 这台机器上 anti-AD / OISD 的下载和 `heartbeat.mossdef.org` 探测都超时，`start` 直到全部失败才退出 | 本次**只修卡死**；列表源/心跳是网络侧问题，见 §4 |

**一句话**：rpcd 是单线程的。adblock-fast 的 `start` 要跑十几分钟，全程持有
`/var/lock/procd_adblock-fast.lock`；LuCI 的 adblock 页面每秒轮询一次
`luci.adblock-fast getInitStatus`，这个 RPC 里又去执行 `init.d/adblock-fast enabled`，
于是卡在 `flock` 上；rpcd 一卡，**整个 Web 界面**（登录、状态、菜单）全部排队等它，
直到 uhttpd 的 `-T 30` 网络超时，浏览器看到的就是 30 秒白屏/403。

---

## 一、现场证据

### 1.1 症状 `[实测]`

```
# 从编译机访问（同一时刻）
$ curl -m 60 -w 'code=%{http_code} start=%{time_starttransfer}\n' http://192.168.32.254:8000/
code=200 start=0.001            ← 静态首页正常
$ curl -m 60 -w 'code=%{http_code} start=%{time_starttransfer}\n' http://192.168.32.254:8000/cgi-bin/luci
code=403 start=30.123           ← 动态页面整整 30 秒才回

# 设备上
# time ubus call session list
（>30 秒不返回）
```

### 1.2 卡在哪：rpcd → sh enabled → flock

```
# ps w
1782 root  3460 S  /sbin/rpcd -s /var/run/ubus/ubus.sock -t 30

# /proc/1782/wchan
do_wait                          ← rpcd 在等子进程

# 1782 的子进程
10789 root 1764 S  {adblock-fast} /bin/sh /etc/rc.common /etc/init.d/adblock-fast enabled
10815 root 10789 S flock 1000    ← wchan = locks_lock_inode_wait

# 10789 的 fd
1000 -> /tmp/lock/procd_adblock-fast.lock
```

`/lib/functions/procd.sh` 末尾在 **source 时**就调用 `_procd_wrapper ...`，
`_procd_wrapper` 第一件事是 `procd_lock`：

```
procd_lock() {
    flock -n 1000 &> /dev/null
    if [ "$?" != "0" ]; then
        exec 1000>"$IPKG_INSTROOT/var/lock/procd_${service_name}.lock"
        flock 1000          ← 阻塞，直到 start 结束
    fi
}
```

所以只要 `adblock-fast start` 还在跑，任何 `init.d/adblock-fast enabled` 都会阻塞。

### 1.3 为什么 start 跑了十几分钟

```
14:41:21 adblock-fast: [ DL ] Blocked List: OISD - Small (adblockplus) [✓]
14:49:21 adblock-fast: [ DL ] Blocked List: anti-AD [✗]
14:50:07 adblock-fast: [DNSM] Probing heartbeat.mossdef.org for 10 seconds [✗]
14:50:11 adblock-fast: adblock-fast 1.2.4-r4 failed to start: Testing resolver on heartbeat.mossdef.org.
14:50:11 adblock-fast: [ERROR] Failed to download anti-AD!
```

用户 14:41:52 登录 LuCI（`dispatcher.uc: luci: accepted login ... from 192.168.32.135`），
正好落在这次 `start` 的窗口里 —— 所以"SSH 能用、Web 打不开"。

### 1.4 定量复现

在设备上人为占住 procd 锁，再调那个 RPC：

```
# flock -x /var/lock/procd_adblock-fast.lock -c "sleep 15" &
# time ubus call luci.adblock-fast getInitStatus '{"name":"adblock-fast"}'
real 0m 14.0s                    ← 锁一释放才返回
```

---

## 二、修复

`/lib/adblock-fast/adblock-fast.uc` 里的 `service_enabled()` 原来直接执行 init 脚本：

```ucode
function service_enabled(name) {
	return system(sprintf('/etc/init.d/%s enabled >/dev/null 2>&1', name)) == 0;
}
```

改为只读 `/etc/rc.d` 的启用符号链接（`enable` 做的事就是建这个链接，语义完全一致）：

```ucode
function service_enabled(name) {
	let entries = lsdir('/etc/rc.d') || [];
	for (let entry in entries) {
		let m = match(entry, /^S[0-9][0-9](.+)$/);
		if (m && m[1] == name)
			return true;
	}
	return false;
}
```

上游 adblock-fast 的 issue #9 已经处理过"`start`/`dl` 不能同步跑，否则冻住 rpcd"，
但漏了 `get_init_status` 这条读状态的路径；这个补丁补的就是它。

补丁以 feed 补丁形式固化（`feeds/` 不入库）：

```
feed-patches/packages/net/adblock-fast/0002-nonblocking-service-enabled.patch
```

`build.sh` / 顶层 `make` 会自动调用 `feed-patches/apply.sh` 套用，幂等。

---

## 三、验证 `[实测]`

修补后重启 rpcd（ucode 插件在 rpcd 启动时载入，改完文件必须重启）：

```
# /etc/init.d/rpcd restart
```

在占住 procd 锁的情况下：

```
getInitStatus[1] 0ms rc=0
getInitStatus[2] 0ms rc=0
session.list     0ms
```

LuCI 登录页从 30.1 秒降到 **0.11 秒**：

```
luci 0.120826s 403
luci 0.107608s 403
luci 0.109163s 403
```

（403 是 LuCI 未登录时的正常应答，带 `x-luci-login-required: yes`，就是登录页。）

---

## 四、未修的部分（网络侧）

这次只修"卡死"。adblock-fast 在这台机器上仍然启动失败，原因与 Web 无关：

```
# nslookup small.oisd.nl 127.0.0.1
;; connection timed out; no servers could be reached
# nslookup www.baidu.com 127.0.0.1
www.baidu.com canonical name = www.a.shifen.com      ← 国内域名正常
```

`anti-ad.net` / `small.oisd.nl` / `heartbeat.mossdef.org` 都是境外域名，当前
PassWall 的 DNS 链路解析不了（或极慢）。于是：

* 两个列表都下载失败、心跳探测失败 → `start` 判定失败，还会把 dnsmasq
  重置/重启两次（`[DNSM] Resetting dnsmasq`）；
* `start` 在失败前会一直占着 procd 锁（本次实测约 13 分钟）。

Web 已经不会被它拖死，但要让 **广告过滤真正生效**，得先修好 PassWall 的
DNS 链路，或者把 `heartbeat.mossdef.org` 换成国内可达的域名、把列表源换成
国内镜像。后者属于配置取舍，未在本次改动里替用户决定。

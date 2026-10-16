# 工作原理与边界

## 为什么不只过滤 AAAA

普通 DNS 返回 IPv6 的记录称为 AAAA。过滤它们能让部分客户端只得到 IPv4，但应用可能使用自己的 HTTPDNS、加密 DNS 或缓存地址，不一定重新查询路由器。单纯 DNS 过滤无法保证阻止已经拿到 IPv6 地址的实际连接。

本项目保留普通 DNS 答案，以 dnsmasq 原生 `nftset` 收集目标地址，再在路由转发层快速拒绝目标 IPv6 网页连接。同时以 TLS SNI / HTTP Host 补充学习绕过普通 DNS 的目标。

## 三个部分

### 1. dnsmasq

安装器在 `/etc/dnsmasq.conf` 添加唯一标记段：

```text
# BEGIN XHS-IPV4
nftset=/xiaohongshu.com/xhscdn.com/xhscdn.net/xhsrcdn.com/6#inet#xhs_ipv4#targets6
# END XHS-IPV4
```

`6#` 限定加入的是 IPv6 答案；`inet` 是表族，`xhs_ipv4` 是本项目表名，`targets6` 是集合。名字中的 IPv4 表示期望的回退方向，集合内保存的实际是 IPv6 地址。参数含义见 [dnsmasq 手册](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)。

默认上游和 DHCP 选项保持原样。安装、卸载时需重启 dnsmasq 重新读取配置。

### 2. 捕获与 Lua 学习

`xhs-ipv4-monitor` 创建 `/var/run/xhs-ipv4/live.pcap` FIFO。目录权限 700，FIFO 权限由 umask 077 限制。它连接两个进程：

```text
tcpdump → FIFO（内存管道）→ Lua 解析器 → nft add element
```

tcpdump 只监听指定 LAN 接口的入方向，过滤 IPv6 TCP 目标端口 80/443，每包最多复制 4096 字节到用户态。常规已加密的数据包也可能被捕获并很快丢弃；它不是仅在 SNI 出现时才工作。

Lua 支持 Ethernet、带 VLAN 标记的 Ethernet、Linux cooked v1/v2 的经典 pcap 输入，以及大小端文件头，支持常见连续 TCP 分段的有限拼接。它读取 TLS ClientHello 的 server_name 扩展或明文 HTTP Host，用精确域名/点分隔后缀匹配，避免把 `evilxhscdn.com` 当成 `xhscdn.com`。

只学习 `2000::/3` 范围内的具体 IPv6 目标地址。地址写入命令由原始地址字节生成，域名文本不进入 shell 命令。拼接数据限制为每条 16 KiB，暂存连接在后续流量到来时清理，清理后最多保留 1024 条；空闲期间不会为清理而持续唤醒。地址写入有短期去重。

它不做完整 TCP 流重组、IPv6 分片重组或 QUIC 解密。虽然解析器能跳过部分 IPv6 扩展头，前置 tcpdump 过滤仍可能无法捕获这些报文。不能把它当成完整 DPI、内容审计或安全访问控制系统；LAN 客户端可伪造 SNI/Host，学习结果不是经过认证的服务归属证明。

### 3. nftables

独立表 `inet xhs_ipv4` 包含：

- `targets6`：类型 `ipv6_addr`、默认过期 1h、GC 间隔 1m、最大 4096 个元素。
- `forward`：过滤链，优先级 `-10`，默认策略 accept。
- 两条拒绝规则：指定 LAN 入接口 + 集合内 IPv6 目标；TCP 80/443 返回 reset，UDP 443 返回 ICMPv6 port-unreachable。

默认策略 accept 只意味着本表不拒绝其他报文；其他防火墙链仍可继续处理和拒绝它们。本项目不会清空现有规则、全局放行流量或关闭全局 IPv6。

拒绝让客户端尽快知道该路径不可用，避免等到原始故障的长超时；是否以及多快尝试 IPv4，由应用自身决定。

## 生命周期

procd 维护捕获/学习与维护两个实例。服务启动时创建自有表；捕获接口尚未就绪时，实例退出并由 procd 重试。维护循环每 15 秒检查自有表是否存在，每 300 秒向本机 DNS 查询一次配置的已知主机名。

运行中的表被清空后会在维护周期中重建。集合中的动态地址不会持久化，也不会在每次学习后写闪存；重启后通过 DNS 和连接重新学习。因此冷启动与防火墙重载后存在重新收集地址的窗口。未在所有固件上验证完整整机启动顺序。

## 为什么仍可能影响其他域名

域名匹配发生在“收集地址”阶段，防火墙匹配发生在“地址和端口”阶段。规则不记住每条被拒绝连接的具体域名。若另一个站点恰好共享同一 IPv6 地址及目标端口，它也会被拒绝 IPv6。精确地址和一小时超时可以限制影响范围，但不能保证没有共享地址误伤。

若需要严格的逐域名、逐连接控制，需要另外设计并验证不同的流量处理机制，本项目不声称提供这种隔离。

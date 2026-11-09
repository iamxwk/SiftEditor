# SSH 测试平台 / SSH testbed

这是一组 Linux 主机，用于测试通过  SSH（ROADMAP 的 B5 / C7）打开文件的功能。
通过 Docker 启动五台测试主机，覆盖 macOS sshd 无法模拟的连接场景。

A set of throwaway Linux hosts for verifying SiftEditor's SSH support. Five containers,
covering the entry points that a Mac's own `sshd` cannot exercise.

## 为什么仅靠 Mac 还不够？

- **不同的工具**。macOS 属于 BSD 系列，具体来说是 `stat`/`tail`/`sed`，而实际的日志服务器属于 GNU 系列。
  shell out 由于输出是根据此进行解释的，因此除非用实际产品踩踏，否则发货后将会损坏。
- **需要一块垫脚石**。`ssh -J localhost localhost` 是自跳，路径并不存在。
  此处，`inner` 不暴露任何端口，只能通过 `jump` 访问。
- **需要一个会说话的服务器**。登录期间 MOTD 与 stdout 的混合仅在 Linux 的情况下发生。

## 版本

```sh
colima start          # 如果 Docker 尚未运行
sh run.sh up
sh run.sh config >> ~/.ssh/config
sh run.sh check
```

由  `run.sh keys` 创建的密钥进入 `keys/`，并且**不在 git 的管理范围内**（私钥未放置在公共存储库中）。
主机密钥也已修复，因此即使您重新构建它，您的 `known_hosts` 也不会变脏。

## 5个单元的作用

| 主机 | 踩到什么 |
|---|---|
| `mred-deb` | Debian / glibc / GNU coreutils。默认验证目标 |
| `mred-alma` | AlmaLinux。与 RHEL 系列的区别（coreutils 的版本，sshd 的默认设置）|
| `mred-pw` | **仅密码验证**。路由至 `SSH_ASKPASS` (`mred` / `mred`) |
| `mred-jump` | 脚凳。edge 和 inner 均带有脚 |
| `mred-inner` | **端口未公开**。仅可通过 `mred-jump` 访问 = ProxyJump 的现场测试 |

每个主机都有一个 200 行的样本（每 25 行一个 `ERROR`），位于 `/srv/logs/app.log`。

## 插入  10GB

```sh
sh run.sh up-big      # 将 testdata/test_10gb.log 只读挂载到 deb 的 /srv/logs/big.log
```

> ⚠️ **请勿公布使用此路由测得的速度。** 因为它涉及 colima 的虚拟文件系统，
> 这些不是实际的远程号码。偏移量计算 `dd skip=` `tail -c +N`
> 请仅用于验证**正确性**。

## 添加延迟

localhost 为 0ms 和 GB/s。**在低延迟环境下创建时，感知性能（进度显示、传输量估算等）至关重要。**
整个过程将在错误的放弃观念下完成。** 至少尝试一次 Network Link Conditioner 或
请插入并触摸 50-200ms，使用  `dnctl` / `pfctl`。

## 折叠

```sh
sh run.sh down        # 保留密钥，下次只需运行 up
```

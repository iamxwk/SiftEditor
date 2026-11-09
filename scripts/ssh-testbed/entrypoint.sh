#!/bin/sh
# 所有容器通用的启动过程。
#   - 主机密钥借用自 /keys/host（以防止 known_hosts 每次重建时都被弄脏）。
#   - 从 /keys/authorized_keys 借用公钥
#   - 仅当 AUTH=pw 时才进行密码验证（用于验证 SSH_ASKPASS）
#   - 发送 MOTD（在真实服务器上，此数据包将与 stdout 混合。此数据包是“故意”发送的，以确认它不会被混合在一起）。
set -eu

mkdir -p /etc/ssh /home/mred/.ssh

# 主机密钥：如果可用，请使用预生成的密钥；否则，请立即创建一个。
if [ -d /keys/host ] && [ -f /keys/host/ssh_host_ed25519_key ]; then
    cp /keys/host/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
    cp /keys/host/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
    chmod 600 /etc/ssh/ssh_host_ed25519_key
else
    ssh-keygen -A
fi

if [ -f /keys/authorized_keys ]; then
    cp /keys/authorized_keys /home/mred/.ssh/authorized_keys
    chmod 700 /home/mred/.ssh
    chmod 600 /home/mred/.ssh/authorized_keys
fi
chown -R mred:mred /home/mred/.ssh

# 認証方式
if [ "${AUTH:-key}" = "pw" ]; then
    # 仅限密码。密钥无效 = 必须通过 SSH_ASKPASS 验证。
    printf 'PasswordAuthentication yes\nPubkeyAuthentication no\n' > /etc/ssh/sshd_config.d/testbed.conf
else
    printf 'PasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/testbed.conf
fi
echo 'PermitRootLogin no' >> /etc/ssh/sshd_config.d/testbed.conf

# 登录时会说话的人（用于验证 stdout 是否被污染）。将 MOTD_NOISE 设置为 0 可使其静音。
if [ "${MOTD_NOISE:-1}" = "1" ]; then
    printf '=== testbed %s ===\nDo not trust this banner.\n' "${HOSTNAME:-unknown}" > /etc/motd
else
    : > /etc/motd
fi

# 留下一个包含内容的日志文件（否则，即使连接成功，也没有任何内容可以打开）。
mkdir -p /srv/logs
if [ ! -f /srv/logs/app.log ]; then
    i=1
    while [ "$i" -le 200 ]; do
        printf '2026-08-15T09:%02d:%02dZ %s app[%d]: request id=%d status=%d\n' \
            $((i % 60)) $(((i * 7) % 60)) \
            "$(if [ $((i % 25)) -eq 0 ]; then echo ERROR; else echo INFO; fi)" \
            "$$" "$i" "$(if [ $((i % 25)) -eq 0 ]; then echo 500; else echo 200; fi)"
        i=$((i + 1))
    done > /srv/logs/app.log
fi
chown -R mred:mred /srv/logs

exec /usr/sbin/sshd -D -e

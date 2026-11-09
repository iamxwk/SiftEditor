#!/bin/sh
# SSH：创建/销毁 Linux 主机集群以进行验证。
#
#   sh run.sh keys 创建密钥（仅限首次创建。keys/ 不受 git 管理）
#   sh run.sh up 版本
#   将  sh run.sh up-big testdata/test_10gb.log 插入 deb 并构建它。
#   要粘贴到  sh run.sh config ~/.ssh/config 的输出设置
#   sh run.sh check 5 检查是否能够实际连接到主机
#   sh run.sh down 折叠（钥匙保留）
set -eu

cd "$(dirname "$0")"
DIR=$(pwd)
KEY="$DIR/keys/id_ed25519"

compose() { docker compose "$@"; }

cmd_keys() {
    mkdir -p keys/host
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -C sifteditor-testbed -f "$KEY"
    [ -f keys/host/ssh_host_ed25519_key ] || \
        ssh-keygen -t ed25519 -N '' -C testbed-host -f keys/host/ssh_host_ed25519_key
    cp "$KEY.pub" keys/authorized_keys
    echo "密钥已保存到 $DIR/keys/（不纳入 Git 管理）"
}

cmd_config() {
    cat <<EOF
# --- SiftEditor ssh-testbed 从这里开始 ---
Host mred-deb mred-alma mred-pw mred-jump
    HostName 127.0.0.1
    User mred
    IdentityFile $KEY
    IdentitiesOnly yes
    # 即使每次重建时主机密钥都会更改，也能解放双手。
    UserKnownHostsFile $DIR/keys/known_hosts
    StrictHostKeyChecking accept-new

Host mred-deb
    Port 2201
Host mred-alma
    Port 2202
Host mred-pw
    Port 2203
    PubkeyAuthentication no
    PasswordAuthentication yes
Host mred-jump
    Port 2204

# 端口未公开。仅可通过跳转主机访问 = ProxyJump 现场测试目标
Host mred-inner
    HostName inner
    User mred
    IdentityFile $KEY
    IdentitiesOnly yes
    UserKnownHostsFile $DIR/keys/known_hosts
    StrictHostKeyChecking accept-new
    ProxyJump mred-jump
# --- 到此为止 ---
EOF
}

cmd_check() {
    for h in mred-deb mred-alma mred-jump mred-inner; do
        printf '%-11s ' "$h"
        ssh -F "${SSH_CONFIG:-$HOME/.ssh/config}" -o ConnectTimeout=5 -o BatchMode=yes \
            "$h" 'uname -s; head -1 /srv/logs/app.log' 2>&1 | tr '\n' ' '
        echo
    done
    echo 'mred-pw     （仅支持密码认证；交互输入 mred / mred 验证）'
}

case "${1:-}" in
    keys)   cmd_keys ;;
    up)     cmd_keys; compose up -d --build ;;
    up-big) cmd_keys; compose -f compose.yaml -f compose.bigfile.yaml up -d --build ;;
    config) cmd_config ;;
    check)  cmd_check ;;
    down)   compose down ;;
    ps)     compose ps ;;
    *)      sed -n '2,12p' "$0"; exit 1 ;;
esac

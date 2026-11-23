#!/bin/bash
# ===========================================================================
# 转发节点初始化
#
# 作用：把本机 443 端口收到的 TCP 连接原样转发到对象存储的内网地址。
#
# 为什么用内核转发而不是装一个反向代理：
#   本实践的子网没有任何公网出口，装不了软件包。内核的 netfilter 是操作系统
#   自带的，零外部依赖。而且四层转发不解 TLS，客户端携带的 SNI 与 Host 原样
#   送达对象存储，证书校验照常通过，转发节点上不需要放任何证书。
#
# 对象存储的内网地址会变，所以解析结果不能写死。这里用一个定时器周期性重解析，
# 变了就更新转发目标。
#
# 本脚本是静态文件，不含任何模板占位符。运行所需的域名由 Terraform 在
# user-data 前缀里写入 /etc/obs-relay.conf，本脚本只负责读取。
# ===========================================================================
set -euo pipefail

mkdir -p /var/lib/obs-relay

# ---------------------------------------------------------------------------
# 1. 打开内核转发
#    DNAT 把目的地址改成了非本机地址，报文必须走 forward 路径才出得去。
# ---------------------------------------------------------------------------
cat > /etc/sysctl.d/99-obs-relay.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
SYSCTL
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 2. 关闭本机防火墙服务
#    访问边界由安全组承担，本机再叠一层只会制造难查的静默丢包。
# ---------------------------------------------------------------------------
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. 转发规则维护脚本
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/obs-relay-sync <<'RELAY'
#!/bin/bash
set -uo pipefail

. /etc/obs-relay.conf
STATE_FILE=/var/lib/obs-relay/target

target=$(getent ahostsv4 "$OBS_DOMAIN" | awk '{print $1; exit}')
if [ -z "$target" ]; then
  logger -t obs-relay -- "resolve failed for $OBS_DOMAIN, keeping current rules"
  exit 1
fi

current=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$target" = "$current" ]; then
  exit 0
fi

# 规则挂在自建链上，重建时只清自己的，不动系统里其他人的规则
iptables -t nat -N OBS_RELAY 2>/dev/null || true
iptables -t nat -F OBS_RELAY
iptables -t nat -C PREROUTING -p tcp --dport 443 -j OBS_RELAY 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport 443 -j OBS_RELAY
iptables -t nat -A OBS_RELAY -p tcp --dport 443 -j DNAT --to-destination "$target:443"

iptables -t nat -N OBS_RELAY_SNAT 2>/dev/null || true
iptables -t nat -F OBS_RELAY_SNAT
iptables -t nat -C POSTROUTING -p tcp --dport 443 -j OBS_RELAY_SNAT 2>/dev/null \
  || iptables -t nat -A POSTROUTING -p tcp --dport 443 -j OBS_RELAY_SNAT
iptables -t nat -A OBS_RELAY_SNAT -p tcp -d "$target" --dport 443 -j MASQUERADE

iptables -P FORWARD ACCEPT

echo "$target" > "$STATE_FILE"
logger -t obs-relay -- "relay target updated to $target"
RELAY
chmod 0755 /usr/local/sbin/obs-relay-sync

# ---------------------------------------------------------------------------
# 4. 开机自启 + 周期刷新
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/obs-relay.service <<'UNIT'
[Unit]
Description=Sync L4 relay rules to the object storage internal address
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/obs-relay-sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/obs-relay.timer <<'TIMER'
[Unit]
Description=Periodically refresh the relay target address

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now obs-relay.service
systemctl enable --now obs-relay.timer

logger -t obs-relay -- "initialization finished"

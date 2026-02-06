#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
SCRIPT_PATH="/usr/local/bin/cn-vm-egress-guard.sh"

# ===== 资源 =====
CN_IPV4_URL="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
CN_IPV6_URL="https://ruleset.skk.moe/Clash/ip/china_ip_ipv6.txt"
P2P_TRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"

# ===== IPSET =====
CN4_SET="cn_block4"
CN6_SET="cn_block6"
P2P_SET="p2p_trackers"

# ===== CHAIN =====
CHAIN="VM_EGRESS_FILTER"

# ---------- 基础校验 ----------
if [[ "$ACTION" != "apply" && "$ACTION" != "update" ]]; then
  echo "Usage: $0 {apply|update}"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
tmpname() { echo "${1}_tmp_$$"; }

# ---------- 依赖 ----------
if ! need_cmd ipset || ! need_cmd curl; then
  apt-get update && apt-get install -y ipset curl
fi
if ! need_cmd iptables || ! need_cmd ip6tables; then
  apt-get update && apt-get install -y iptables
fi

# ---------- IPSET 初始化 ----------
ipset create -exist "$CN4_SET" hash:net family inet
ipset create -exist "$CN6_SET" hash:net family inet6
ipset create -exist "$P2P_SET" hash:ip  family inet

# ---------- 更新函数 ----------
update_set() {
  local url="$1" set="$2" type="$3" family="$4"
  local tmp="/tmp/${set}.txt"
  curl -fsSL "$url" -o "$tmp" || {
    echo "WARN: $set update failed, keep old data"
    return 0
  }

  local tset; tset=$(tmpname "$set")
  ipset create -exist "$tset" "hash:$type" family "$family"
  ipset flush "$tset"

  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ipset add "$tset" "$line" -exist 2>/dev/null || true
  done < "$tmp"

  ipset swap "$tset" "$set"
  ipset destroy "$tset" 2>/dev/null || true
}

do_update() {
  update_set "$CN_IPV4_URL" "$CN4_SET" net inet
  update_set "$CN_IPV6_URL" "$CN6_SET" net inet6
  update_set "$P2P_TRACKER_URL" "$P2P_SET" ip inet
  echo "OK: ipset 更新完成"
}

# ---------- 防火墙 ----------
apply_fw() {
  iptables  -N "$CHAIN" 2>/dev/null || true
  ip6tables -N "$CHAIN" 2>/dev/null || true
  iptables  -F "$CHAIN"
  ip6tables -F "$CHAIN"

  # 仅 VM 新建出站连接进入
  iptables -C FORWARD -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
    || iptables -I FORWARD 1 -m conntrack --ctstate NEW -j "$CHAIN"
  ip6tables -C FORWARD -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null \
    || ip6tables -I FORWARD 1 -m conntrack --ctstate NEW -j "$CHAIN"

  # 1. P2P Tracker 阻断（统计点）
  iptables -A "$CHAIN" -m set --match-set "$P2P_SET" dst -j DROP

  # 2. 中国 IP 出站阻断（统计点）
  iptables -A "$CHAIN" -m set --match-set "$CN4_SET" dst -j DROP
  ip6tables -A "$CHAIN" -m set --match-set "$CN6_SET" dst -j DROP

  # 3. 其他全部放行
  iptables  -A "$CHAIN" -j RETURN
  ip6tables -A "$CHAIN" -j RETURN

  echo "OK: 防火墙规则已应用"
}

install_self() {
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
  fi
  (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH update"; \
   echo "0 3 * * * $SCRIPT_PATH update > /dev/null 2>&1") | crontab -
}

# ---------- 主流程 ----------
if [[ "$ACTION" == "apply" ]]; then
  do_update
  apply_fw
  install_self
  echo "Done: 宿主机 VM 出站管控已启用（带统计）"
else
  do_update
fi

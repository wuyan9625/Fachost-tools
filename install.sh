#!/bin/bash
# ==========================================
# CN Block + TW Block + P2P Tracker Block + Bili Whitelist
# 特性：不封锁端口，仅封锁 P2P Tracker 服务器 IP
# 部署：curl -sSL <URL> | sudo bash -s apply all
# ==========================================

set -euo pipefail

# --- 基础配置 ---
ACTION="${1:-}"
MODE="${2:-all}"
SCRIPT_PATH="/usr/local/bin/cn-block.sh"
# 请替换为你的真实 GitHub Raw 链接
RAW_URL="https://raw.githubusercontent.com/你的用户名/仓库名/main/cn-block.sh"

if [[ "$ACTION" != "apply" && "$ACTION" != "update" ]]; then
  echo "Usage: $0 {apply|update} {in-only|all}"
  exit 1
fi

# --- 资源链接 ---
CN_IPV4_URL="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
CN_IPV6_URL="https://ruleset.skk.moe/Clash/ip/china_ip_ipv6.txt"
TW_IPV4_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/tw.netset"
# P2P Tracker IP 列表 (每日更新，包含主流 BT Tracker 服务器 IP)
P2P_TRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"
V2FLY_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
BILI_LISTS=("bilibili" "bilibili-cdn" "bilibili-game" "bilibili2")

# --- IPSET 集合名称 ---
CN4_SET="cn_block4"
CN6_SET="cn_block6"
BILI4_SET="bili_white4"
BILI6_SET="bili_white6"
TW_BLOCK_SET="tw_block4"
P2P_SET="p2p_trackers"  # 存储 Tracker IP

MAX_IPS_PER_DOMAIN=50

# ---------- 工具函数 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
tmpname() { echo "${1}_tmp_$$"; }

# ---------- 网络检查 ----------
for _ in {1..30}; do
  if ip route show default 2>/dev/null | grep -q '^default'; then break; fi
  sleep 2
done

# ---------- 依赖安装 ----------
if ! need_cmd ipset || ! need_cmd curl; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y ipset curl
fi

if [[ "$ACTION" == "apply" ]] && (! need_cmd iptables || ! need_cmd ip6tables); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y iptables
fi

# ---------- 创建 IPSET 集合 ----------
ipset create -exist "$CN4_SET"      hash:net family inet
ipset create -exist "$CN6_SET"      hash:net family inet6
ipset create -exist "$BILI4_SET"    hash:ip  family inet
ipset create -exist "$BILI6_SET"    hash:ip  family inet6
ipset create -exist "$TW_BLOCK_SET" hash:net family inet
ipset create -exist "$P2P_SET"      hash:ip  family inet # Tracker 主要是 IPv4

# ---------- 通用 IPSET 更新函数 ----------
update_set_from_url() {
    local url="$1"
    local set_name="$2"
    local type="$3" # net or ip
    local family="$4" # inet or inet6
    
    echo "正在更新 $set_name ..."
    local tmp_file="/tmp/${set_name}.txt"
    curl -fsSL "$url" -o "$tmp_file"

    local tmp_set; tmp_set=$(tmpname "$set_name")
    ipset create -exist "$tmp_set" "hash:$type" family "$family"
    ipset flush "$tmp_set"

    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^$ ]] && continue
        ipset add "$tmp_set" "$line" -exist 2>/dev/null || true
    done < "$tmp_file"

    ipset swap "$tmp_set" "$set_name"
    ipset destroy "$tmp_set" 2>/dev/null || true
}

# ---------- Bilibili 域名解析 ----------
update_bilibili_whitelist() {
    echo "处理 Bilibili 域名解析..."
    local domains="/tmp/bilibili_domains.txt"
    : > "$domains"
    
    # 提取域名函数
    extract_domains() {
        sed 's/\r$//' | awk '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^[ \t]*$/ || /^[ \t]*#/ { next }
        {
            line=trim($0)
            if (line ~ /^include:/ || line ~ /^(keyword|regexp):/) next
            if (index(line, ":") > 0) {
            split(line, a, ":"); t=a[1]; v=trim(substr(line, length(t)+2))
            if (t=="domain" || t=="full" || t=="suffix") print v
            next
            }
            print line
        }' | sed -e 's/^\.\+//' -e 's/\.$//' | sort -u
    }

    for f in "${BILI_LISTS[@]}"; do
        curl -fsSL "$V2FLY_BASE/$f" | extract_domains >> "$domains"
    done
    sort -u "$domains" -o "$domains"

    # 解析 IP
    resolve_ips4() {
        if need_cmd getent; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | head -n "$MAX_IPS_PER_DOMAIN"
        elif need_cmd dig; then dig +short A "$1" | head -n "$MAX_IPS_PER_DOMAIN"; fi
    }
    resolve_ips6() {
        if need_cmd getent; then getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | head -n "$MAX_IPS_PER_DOMAIN"
        elif need_cmd dig; then dig +short AAAA "$1" | head -n "$MAX_IPS_PER_DOMAIN"; fi
    }

    local tmp_b4; tmp_b4=$(tmpname "$BILI4_SET"); ipset create -exist "$tmp_b4" hash:ip family inet
    local tmp_b6; tmp_b6=$(tmpname "$BILI6_SET"); ipset create -exist "$tmp_b6" hash:ip family inet6

    while read -r d; do
        [[ -z "$d" ]] && continue
        resolve_ips4 "$d" | while read -r ip; do ipset add "$tmp_b4" "$ip" -exist 2>/dev/null || true; done
        resolve_ips6 "$d" | while read -r ip; do ipset add "$tmp_b6" "$ip" -exist 2>/dev/null || true; done
    done < "$domains"

    ipset swap "$tmp_b4" "$BILI4_SET"; ipset destroy "$tmp_b4" 2>/dev/null || true
    ipset swap "$tmp_b6" "$BILI6_SET"; ipset destroy "$tmp_b6" 2>/dev/null || true
}

# ---------- 总更新入口 ----------
do_update_ipsets() {
    # 1. 更新 CN (Block)
    update_set_from_url "$CN_IPV4_URL" "$CN4_SET" "net" "inet"
    update_set_from_url "$CN_IPV6_URL" "$CN6_SET" "net" "inet6"
    
    # 2. 更新 TW (Block - Finance)
    update_set_from_url "$TW_IPV4_URL" "$TW_BLOCK_SET" "net" "inet"

    # 3. 更新 P2P Trackers (Block - Websites/Servers)
    update_set_from_url "$P2P_TRACKER_URL" "$P2P_SET" "ip" "inet"

    # 4. 更新 Bilibili (Whitelist)
    update_bilibili_whitelist

    echo "OK: 所有 ipset 更新完成。"
}

# ---------- 防火墙规则 ----------
apply_firewall_rules_once() {
  local mode="$1"
  iptables -N CNFILTER 2>/dev/null || true
  ip6tables -N CNFILTER 2>/dev/null || true
  iptables -F CNFILTER && ip6tables -F CNFILTER

  iptables -C FORWARD -j CNFILTER 2>/dev/null || iptables -I FORWARD 1 -j CNFILTER
  ip6tables -C FORWARD -j CNFILTER 2>/dev/null || ip6tables -I FORWARD 1 -j CNFILTER

  # 1. 基础连接放行
  iptables -A CNFILTER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A CNFILTER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # 2. Bilibili 白名单 (优先级最高 - 即使在被封锁地区也放行)
  iptables -A CNFILTER -m set --match-set "$BILI4_SET" dst -j ACCEPT
  ip6tables -A CNFILTER -m set --match-set "$BILI6_SET" dst -j ACCEPT

  # 3. P2P Tracker 网站阻断 (不封端口，只封 IP)
  # 阻止连接到已知的 Tracker 服务器
  iptables -A CNFILTER -m set --match-set "$P2P_SET" dst -j DROP
  # 辅助：简单的应用层过滤 (announce 字符串)，防止漏网的 Tracker
  iptables -A CNFILTER -p tcp -m string --algo bm --string "announce" -j DROP
  iptables -A CNFILTER -p udp -m string --algo bm --string "announce" -j DROP

  # 4. 台湾 IP 阻断 (黑名单 - 金融风控)
  iptables -A CNFILTER -m set --match-set "$TW_BLOCK_SET" dst -j REJECT --reject-with icmp-host-prohibited
  
  # 5. 中国 IP 阻断 (出站)
  iptables -A CNFILTER -m set --match-set "$CN4_SET" dst -m limit --limit 5/min -j LOG --log-prefix "BLOCK_CN_OUT: "
  iptables -A CNFILTER -m set --match-set "$CN4_SET" dst -j DROP
  ip6tables -A CNFILTER -m set --match-set "$CN6_SET" dst -j DROP

  # 6. 中国 IP 阻断 (入站)
  if [[ "$mode" == "all" ]]; then
    iptables -A CNFILTER -m set --match-set "$CN4_SET" src -j DROP
    ip6tables -A CNFILTER -m set --match-set "$CN6_SET" src -j DROP
  fi

  iptables -A CNFILTER -j RETURN
  ip6tables -A CNFILTER -j RETURN
  echo "OK: 防火墙规则已安装。"
}

# ---------- 自动部署 ----------
install_script() {
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "安装脚本至 $SCRIPT_PATH ..."
    if [[ -f "$0" ]]; then cp "$0" "$SCRIPT_PATH"; else curl -sSL "$RAW_URL" -o "$SCRIPT_PATH"; fi
    chmod +x "$SCRIPT_PATH"
  fi
  
  CRON_JOB="0 3 * * * $SCRIPT_PATH update > /dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH update"; echo "$CRON_JOB") | crontab -
  echo "OK: 定时任务已设置 (每日 03:00)"
}

# ---------- 主逻辑 ----------
if [[ "$ACTION" == "apply" ]]; then
    do_update_ipsets
    apply_firewall_rules_once "$MODE"
    install_script
    echo "Done: 部署完成。"
else
    do_update_ipsets
fi

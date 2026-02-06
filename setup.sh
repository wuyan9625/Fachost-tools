#!/bin/bash
# =========================================================
# Block-FW | PVE 防火牆 
# =========================================================

# --- 設定區 ---
SCRIPT_NAME="block-fw"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
DATA_DIR="/var/lib/block-fw"
MY_GITHUB_URL="https://raw.githubusercontent.com/wuyan9625/block_tools/main/setup.sh"

# --- 外部清單來源 ---
URL_CN="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
# 使用更穩定的 GitHub Mirror
URL_MALWARE="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
URL_P2P="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/iblocklist_level1.netset"

# --- 本地暫存檔 ---
FILE_COMBINED="$DATA_DIR/blocked_combined.list"
IPSET_NAME="fachost_block"
RULE_COMMENT="block-fw"

# --- 顏色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 檢查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}錯誤：請使用 root 權限執行${PLAIN}"
   exit 1
fi

mkdir -p "$DATA_DIR"

# =======================
# 核心功能
# =======================

# 強制開啟網橋過濾 (這是最關鍵的一步)
enable_bridge_filter() {
    echo -e "${YELLOW}[*] 正在強制開啟網橋過濾 (br_netfilter)...${PLAIN}"
    modprobe br_netfilter
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
    
    # 寫入 sysctl.conf 確保重開機生效
    if ! grep -q "net.bridge.bridge-nf-call-iptables = 1" /etc/sysctl.conf; then
        echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
        echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
}

fetch_rules() {
    echo -e "${YELLOW}[*] 正在同步清單...${PLAIN}"
    > "${FILE_COMBINED}.tmp"

    echo -e " -> 下載 CN IP..."
    curl -fsSL "$URL_CN" >> "${FILE_COMBINED}.tmp"
    echo -e " -> 下載 P2P & 惡意 IP..."
    curl -fsSL "$URL_MALWARE" >> "${FILE_COMBINED}.tmp"
    curl -fsSL "$URL_P2P" >> "${FILE_COMBINED}.tmp"
    
    if [ -s "${FILE_COMBINED}.tmp" ]; then
        grep -vE "^#|^$|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\." "${FILE_COMBINED}.tmp" > "$FILE_COMBINED"
        rm "${FILE_COMBINED}.tmp"
        echo -e "${GREEN} -> 規則已更新${PLAIN}"
    else
        echo -e "${RED} [!] 下載失敗，使用舊檔${PLAIN}"
    fi
}

apply_rules() {
    local block_inbound="$1"

    if [ ! -f "$FILE_COMBINED" ]; then
        echo -e "${RED}錯誤：找不到清單檔案${PLAIN}"
        return
    fi

    # 1. 確保核心模組開啟
    enable_bridge_filter

    # 2. 載入 IPSET
    echo -e "${YELLOW}[*] 載入 IPSET...${PLAIN}"
    ipset create "$IPSET_NAME" hash:net -exist
    ipset flush "$IPSET_NAME"
    ipset restore -exist < <(sed "s/^/add $IPSET_NAME /" "$FILE_COMBINED")

    # 3. 設定防火牆 (使用 RAW 表 PREROUTING 鏈，這是最優先的攔截點)
    echo -e "${YELLOW}[*] 設定 iptables (使用 RAW 表 PREROUTING)...${PLAIN}"

    # 清除舊規則 (包含 filter 表和 raw 表)
    iptables -t filter -D FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    iptables -t filter -D FORWARD -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    iptables -t raw -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    iptables -t raw -D PREROUTING -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true

    # 【核彈規則】 RAW 表 PREROUTING - 封包剛到網卡就被殺掉，無法繞過
    # 攔截出站 (去往黑名單)
    iptables -t raw -I PREROUTING -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT"
    
    # 攔截入站 (來自黑名單)
    if [[ "$block_inbound" == "yes" ]]; then
        iptables -t raw -I PREROUTING -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT"
        echo -e "${GREEN} -> [雙向封鎖] RAW 表規則已生效${PLAIN}"
    else
        echo -e "${GREEN} -> [僅出站] RAW 表規則已生效${PLAIN}"
    fi
}

setup_cron() {
    local block_inbound="$1"
    local cron_cmd="0 4 * * * $INSTALL_PATH update $block_inbound > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$cron_cmd") | crontab -
}

install_self() {
    curl -fsSL "$MY_GITHUB_URL" -o "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
}

uninstall() {
    iptables -t raw -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    iptables -t raw -D PREROUTING -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    # 清理舊 filter 表殘留
    iptables -D FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    rm -rf "$DATA_DIR"
    rm -f "$INSTALL_PATH"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -
    echo -e "${GREEN}已移除${PLAIN}"
}

# =======================
# 主流程
# =======================

if [[ "$1" == "update" ]]; then
    block_inbound=${2:-no}
    fetch_rules
    apply_rules "$block_inbound"
    exit 0
fi

clear
echo -e "==========================================="
echo -e " Block-FW | PVE 防火牆 (v3 RAW 核彈版)"
echo -e "==========================================="
echo -e " 1. 部署防護 (強制開啟 Bridge Filter)"
echo -e " 2. 手動更新清單"
echo -e " 3. 移除防護"
echo -e " 0. 離開"
echo -e "==========================================="
read -p "選項: " opt

case "$opt" in
    1)
        install_self
        read -p "是否封鎖入站? [y/N]: " in_opt
        [[ "$in_opt" == "y" || "$in_opt" == "Y" ]] && block_inbound="yes" || block_inbound="no"
        fetch_rules
        apply_rules "$block_inbound"
        setup_cron "$block_inbound"
        ;;
    2)
        fetch_rules
        echo -e "${GREEN}請重新部署${PLAIN}"
        ;;
    3)
        uninstall
        ;;
    0)
        exit 0
        ;;
    *)
        echo "無效選項"
        ;;
esac

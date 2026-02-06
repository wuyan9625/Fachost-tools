#!/bin/bash
# =========================================================
# Block-FW | PVE 自動化出站防火牆
# =========================================================

# --- 設定區 ---
SCRIPT_NAME="block-fw"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
DATA_DIR="/var/lib/block-fw"

# --- 外部清單來源 ---
URL_CN="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
URL_MALWARE="https://iplists.firehol.org/files/firehol_level1.netset"
URL_P2P="https://iplists.firehol.org/files/iblocklist_level1.netset"

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

detect_vmbr() {
    ip link show | awk -F: '/vmbr[0-9]+/ {print $2}' | tr -d ' '
}

select_vmbr() {
    echo -e "${YELLOW}正在偵測可用網橋...${PLAIN}"
    mapfile -t VMBrs < <(detect_vmbr)
    
    if [ ${#VMBrs[@]} -eq 0 ]; then
        echo -e "${RED}未偵測到任何 vmbr 介面${PLAIN}"
        exit 1
    fi

    for i in "${!VMBrs[@]}"; do
        echo "[$i] ${VMBrs[$i]}"
    done
    echo
    read -p "請輸入網橋編號（Enter 預設全部防護）： " idx
    if [[ -z "$idx" ]]; then
        echo "ALL"
    else
        echo "${VMBrs[$idx]}"
    fi
}

# 下載並整合所有清單 (CN + Malware + P2P)
fetch_rules() {
    echo -e "${YELLOW}[*] 正在同步清單 (CN + P2P + Malware)...${PLAIN}"
    
    # 建立暫存檔
    > "${FILE_COMBINED}.tmp"

    # 1. 下載 CN IP (因為你說出站一定要封，所以直接下載合併)
    echo -e " -> 下載 CN IP..."
    curl -fsSL "$URL_CN" >> "${FILE_COMBINED}.tmp"

    # 2. 下載 P2P & Malware
    echo -e " -> 下載 P2P 與 惡意 IP..."
    curl -fsSL "$URL_MALWARE" >> "${FILE_COMBINED}.tmp"
    curl -fsSL "$URL_P2P" >> "${FILE_COMBINED}.tmp"
    
    if [ -s "${FILE_COMBINED}.tmp" ]; then
        # 過濾處理：移除註解、空行、私有 IP (避免誤殺內網)
        grep -vE "^#|^$|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\." "${FILE_COMBINED}.tmp" > "$FILE_COMBINED"
        rm "${FILE_COMBINED}.tmp"
        echo -e "${GREEN} -> 所有規則已合併完成 (包含 CN 強制封鎖)${PLAIN}"
    else
        echo -e "${RED} [!] 清單下載失敗，將使用舊檔 (如果存在)${PLAIN}"
    fi
}

apply_rules() {
    local vmbr="$1"
    local block_inbound="$2" # yes/no

    if [ ! -f "$FILE_COMBINED" ]; then
        echo -e "${RED}找不到規則檔案，請先執行更新${PLAIN}"
        return
    fi

    echo -e "${YELLOW}[*] 正在載入 IPSET (條目眾多請稍候)...${PLAIN}"
    ipset create "$IPSET_NAME" hash:net -exist
    ipset flush "$IPSET_NAME"
    ipset restore < <(sed "s/^/add $IPSET_NAME /" "$FILE_COMBINED")

    # 設定 iptables
    local interfaces
    if [[ "$vmbr" == "ALL" ]]; then
        interfaces=$(detect_vmbr)
    else
        interfaces="$vmbr"
    fi

    for b in $interfaces; do
        # 1. 清除舊規則
        iptables -D FORWARD -i "$b" -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
        iptables -D FORWARD -i "$b" -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true

        # 2. 【強制】封鎖出站 (VM -> 黑名單/CN)
        # dst = 封包的目的地是黑名單 IP
        iptables -I FORWARD -i "$b" -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT"
        
        # 3. 【可選】封鎖入站 (黑名單/CN -> VM)
        # src = 封包的來源是黑名單 IP
        if [[ "$block_inbound" == "yes" ]]; then
            iptables -I FORWARD -i "$b" -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT"
            echo -e "${GREEN} -> [出站+入站] 皆已封鎖: $b${PLAIN}"
        else
            echo -e "${GREEN} -> [僅出站] 已封鎖: $b (允許 CN 連入)${PLAIN}"
        fi
    done
}

setup_cron() {
    local block_inbound="$1"
    # 將選擇寫入 cron 指令中，這樣每天更新時會記得你的選擇
    local cron_cmd="0 4 * * * $INSTALL_PATH update $block_inbound > /dev/null 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$cron_cmd") | crontab -
    echo -e "${GREEN}[*] 已設定每日 04:00 自動更新 (入站封鎖: $block_inbound)${PLAIN}"
}

install_self() {
    cp "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
}

uninstall() {
    for b in $(detect_vmbr); do
        iptables -D FORWARD -i "$b" -m set --match-set "$IPSET_NAME" dst -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
        iptables -D FORWARD -i "$b" -m set --match-set "$IPSET_NAME" src -j DROP -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    done
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    rm -rf "$DATA_DIR"
    rm -f "$INSTALL_PATH"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -
    echo -e "${GREEN}防護已移除${PLAIN}"
}

stats() {
    echo "=== 攔截封包統計 ==="
    echo "DST match = 攔截 VM 訪問外部 (出站)"
    echo "SRC match = 攔截 外部 訪問 VM (入站)"
    iptables -L FORWARD -v -n | grep "$RULE_COMMENT"
    echo -e "\n=== IPSET 條目數 ==="
    ipset list "$IPSET_NAME" | grep "Number of entries"
}

# =======================
# 主流程
# =======================

# Cron 自動更新模式： ./block-fw update <yes/no>
if [[ "$1" == "update" ]]; then
    block_inbound=${2:-no} # 預設不封入站，除非 cron 指定
    fetch_rules
    apply_rules "ALL" "$block_inbound"
    exit 0
fi

clear
echo -e "==========================================="
echo -e " Block-FW | PVE 防火牆 (CN 出站強制封鎖版)"
echo -e "==========================================="
echo -e " 1. 部署防護 (選單)"
echo -e " 2. 查看統計"
echo -e " 3. 手動更新清單"
echo -e " 4. 移除防護"
echo -e " 0. 離開"
echo -e "==========================================="
read -p "選項: " opt

case "$opt" in
    1)
        install_self
        vmbr=$(select_vmbr)
        
        echo -e "\n${YELLOW}關於流量方向設定：${PLAIN}"
        echo -e "1. ${GREEN}出站 (Outbound)${PLAIN}: VM -> CN/P2P。 ${RED}[強制封鎖]${PLAIN}"
        echo -e "   (防止客戶濫用機器進行 P2P 下載或做回國跳板)\n"
        
        read -p "是否也要封鎖【入站 (Inbound)】流量? (防止 CN/惡意 IP 連接你的 VM) [y/N]: " in_opt
        if [[ "$in_opt" == "y" || "$in_opt" == "Y" ]]; then
            block_inbound="yes"
        else
            block_inbound="no"
        fi
        
        fetch_rules
        apply_rules "$vmbr" "$block_inbound"
        setup_cron "$block_inbound"
        ;;
    2)
        stats
        ;;
    3)
        fetch_rules
        echo -e "${GREEN}清單已下載，請重新部署以套用。${PLAIN}"
        ;;
    4)
        uninstall
        ;;
    0)
        exit 0
        ;;
    *)
        echo "無效選項"
        ;;
esac

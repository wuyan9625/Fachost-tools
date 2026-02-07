#!/bin/bash
set -e

# ================= 配置 =================
REPO_URL="https://raw.githubusercontent.com/wuyan9625/block_tools/main"
INSTALL_DIR="/usr/local/block-tools"
BIN_LINK="/usr/local/bin/block-fw"
SYSTEMD_DIR="/etc/systemd/system"

# ================= 檢查 =================
[[ $EUID -ne 0 ]] && { echo "Error: 請用 root 執行"; exit 1; }

echo "========================================"
echo "   Block-Tools Enterprise Installer     "
echo "========================================"

# 1. 安裝依賴 (新增 dnsutils 用於域名解析)
echo "[+] 安裝系統依賴..."
apt-get update -qq
apt-get install -y -qq iptables ipset curl ca-certificates xtables-addons-common dnsutils 2>/dev/null
modprobe xt_tls 2>/dev/null || true

# 2. 建立目錄結構
echo "[+] 建立目錄結構..."
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/conf"
mkdir -p "$INSTALL_DIR/data"

# 3. 下載檔案
echo "[+] 從 GitHub 下載核心檔案..."

# 下載主程式
curl -fsSL "$REPO_URL/bin/block-fw.sh" -o "$INSTALL_DIR/bin/block-fw"

# 下載設定檔 (如果不存才下載)
if [ ! -f "$INSTALL_DIR/conf/options.conf" ]; then
    curl -fsSL "$REPO_URL/conf/options.conf" -o "$INSTALL_DIR/conf/options.conf"
else
    echo "    設定檔已存在，跳過下載..."
fi

# 下載數據檔 (新增 allow_cn_domains.txt)
curl -fsSL "$REPO_URL/data/tw_bank_sni.txt" -o "$INSTALL_DIR/data/tw_bank_sni.txt"
curl -fsSL "$REPO_URL/data/bt_ports.txt" -o "$INSTALL_DIR/data/bt_ports.txt"
curl -fsSL "$REPO_URL/data/allow_cn_domains.txt" -o "$INSTALL_DIR/data/allow_cn_domains.txt"

# 下載 Systemd 服務
curl -fsSL "$REPO_URL/systemd/block-fw-update.service" -o "$SYSTEMD_DIR/block-fw-update.service"
curl -fsSL "$REPO_URL/systemd/block-fw-update.timer" -o "$SYSTEMD_DIR/block-fw-update.timer"

# 4. 設定權限
echo "[+] 設定權限..."
chmod +x "$INSTALL_DIR/bin/block-fw"
chmod 644 "$INSTALL_DIR/conf/options.conf"

# 5. 建立指令連結
echo "[+] 建立全域指令..."
ln -sf "$INSTALL_DIR/bin/block-fw" "$BIN_LINK"

# 6. 啟動服務
echo "[+] 啟動自動更新服務..."
systemctl daemon-reload
systemctl enable --now block-fw-update.timer

echo "========================================"
echo "✅ 安裝完成！"
echo "👉 請輸入 'block-fw' 進入設定選單"
echo "========================================"

#!/bin/bash
set -e

# 定義安裝路徑 (標準化結構)
INSTALL_DIR="/usr/local/block-tools"
BIN_LINK="/usr/local/bin/block-fw"
SYSTEMD_DIR="/etc/systemd/system"

echo "========================================"
echo "   Block-Tools Enterprise Installer     "
echo "========================================"

# 1. 檢查 Root
[[ $EUID -ne 0 ]] && { echo "Error: 請用 root 執行"; exit 1; }

# 2. 安裝依賴
echo "[+] 安裝系統依賴..."
apt-get update -qq
apt-get install -y -qq iptables ipset curl ca-certificates xtables-addons-common 2>/dev/null
modprobe xt_tls 2>/dev/null || true

# 3. 建立目錄結構
echo "[+] 建立目錄結構..."
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/conf"
mkdir -p "$INSTALL_DIR/data"

# 4. 複製檔案 (兼容 Git Clone 本地安裝 與 遠端下載模式)
# 這裡假設你將此腳本放在 repo 根目錄執行
echo "[+] 部署檔案..."
cp -f bin/block-fw.sh "$INSTALL_DIR/bin/block-fw" 2>/dev/null || echo "警告: 找不到 bin/block-fw.sh"
cp -rf conf/* "$INSTALL_DIR/conf/" 2>/dev/null || echo "警告: 找不到 conf/"
cp -rf data/* "$INSTALL_DIR/data/" 2>/dev/null || echo "警告: 找不到 data/"
cp -f systemd/* "$SYSTEMD_DIR/" 2>/dev/null || echo "警告: 找不到 systemd service"

# 5. 設定權限
chmod +x "$INSTALL_DIR/bin/block-fw"
chmod 644 "$INSTALL_DIR/conf/options.conf"

# 6. 建立指令連結 (解決 command not found)
echo "[+] 建立全域指令..."
ln -sf "$INSTALL_DIR/bin/block-fw" "$BIN_LINK"

# 7. 設定 Systemd
echo "[+] 啟動自動更新服務..."
systemctl daemon-reload
systemctl enable --now block-fw-update.timer

echo "========================================"
echo "安裝完成！"
echo "請輸入 'block-fw' 進入設定選單與啟動防火牆"
echo "========================================"

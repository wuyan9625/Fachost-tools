#!/bin/bash
set -e

[[ $EUID -ne 0 ]] && { echo "請用 root 執行"; exit 1; }

BASE_DIR="/etc/block-fw"
BIN_PATH="/usr/local/bin/block-fw"

echo "[*] 安裝必要套件..."
apt update
apt install -y \
  iptables ipset curl ca-certificates \
  xtables-addons-common

modprobe xt_tls 2>/dev/null || true

echo
echo "請選擇 VM 出站管控網橋模式："
echo "1) 套用到【全部網橋】"
echo "2) 指定網橋（可輸入多個）"
echo "3) 查詢目前系統所有網橋"
read -rp "請輸入選項 [1-3]: " BR_OPT

BRIDGE_MODE=""
VM_BRIDGES=""

case "$BR_OPT" in
  1)
    BRIDGE_MODE="all"
    ;;
  2)
    BRIDGE_MODE="specific"
    read -rp "請輸入網橋名稱（以空白分隔，例如: vmbr0 vmbr1）: " VM_BRIDGES
    ;;
  3)
    echo
    echo "系統目前的 bridge："
    ip -o link show type bridge | awk -F': ' '{print $2}'
    echo
    echo "請重新執行 install.sh 選擇 1 或 2"
    exit 0
    ;;
  *)
    echo "無效選項"
    exit 1
    ;;
esac

echo "[*] 安裝 block-fw..."

install -d "$BASE_DIR"
install -d "$BASE_DIR/data"
install -d "$BASE_DIR/conf"

cp -r data/* "$BASE_DIR/data/"
cp conf/options.conf "$BASE_DIR/conf/options.conf"
install -m 755 bin/block-fw.sh "$BIN_PATH"

sed -i "s|^BRIDGE_MODE=.*|BRIDGE_MODE=\"$BRIDGE_MODE\"|" "$BASE_DIR/conf/options.conf"

if [[ "$BRIDGE_MODE" == "specific" ]]; then
  sed -i "s|^VM_BRIDGES=.*|VM_BRIDGES=($VM_BRIDGES)|" "$BASE_DIR/conf/options.conf"
fi

echo "[*] 安裝 systemd timer..."
install -m 644 systemd/block-fw-update.service /etc/systemd/system/
install -m 644 systemd/block-fw-update.timer /etc/systemd/system/

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now block-fw-update.timer

echo "[*] 套用防火牆規則..."
"$BIN_PATH" apply

echo
echo "安裝完成 ✅"
echo "設定檔：$BASE_DIR/conf/options.conf"
echo "主指令：block-fw apply | update"

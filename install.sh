#!/bin/bash
# Fachost Guest Environment Fixer

echo "------------------------------------------------"
echo "   Fachost 虛擬機環境自動優化腳本 (2026版)"
echo "------------------------------------------------"

# 判斷系統類型並安裝
if [ -f /etc/debian_version ]; then
    apt-get update && apt-get install -y qemu-guest-agent cloud-init
elif [ -f /etc/redhat-release ]; then
    yum makecache && yum install -y qemu-guest-agent cloud-init
else
    echo "❌ 暫不支持您的系統類型。"
    exit 1
fi

# 配置 PVE 數據源
mkdir -p /etc/cloud/cloud.cfg.d/
echo "datasource_list: [ NoCloud, ConfigDrive ]" > /etc/cloud/cloud.cfg.d/99_pve.cfg

# 啟動服務
systemctl enable --now qemu-guest-agent
systemctl enable --now cloud-init

echo "------------------------------------------------"
echo "✅ 環境修復完成！請在面板點擊「重啟」以生效。"
echo "------------------------------------------------"

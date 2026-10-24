# 🚀 VPS Status & Telegram Management Bot

A powerful, secure, and lightweight Telegram bot designed for Ubuntu VPS administration. This script installs a persistent background service that allows you to monitor system health, track bandwidth usage, manage the `x-ui` VPN panel, and safely reboot your server—all from an interactive Telegram dashboard or a built-in SSH menu.

## ✨ Features

* **🖥️ Live System Monitoring:** Check CPU load, RAM usage, Swap, Disk space, and Uptime instantly.
* **📊 Persistent Bandwidth Tracking:** Utilizes `vnStat` to safely record network traffic (Download/Upload) across reboots.
* **🎯 Automatic Quota Alerts:** Set a monthly bandwidth limit (GB). The bot will automatically send a warning to admins when traffic hits **80%**, **90%**, and **100%** of the quota.
* **⚡ Real-Time Speed Test:** Measure live incoming and outgoing network throughput in Mbps/MBps.
* **🛡️ x-ui VPN Integration:** Check if `x-ui` is running, restart the service remotely, or securely download your `/etc/x-ui/x-ui.db` database backup straight to Telegram.
* **🔄 Secure Remote Reboot:** Reboot your VPS directly from Telegram with a built-in "Are you sure?" confirmation button to prevent accidental misclicks.
* **💻 Interactive SSH Menu:** Type `vps-bot` in your terminal anytime to change tokens, adjust quotas, view logs, or easily uninstall the tool.

## 📋 Prerequisites

* An **Ubuntu VPS** (20.04 or 22.04 recommended) with `root` access.
* A **Telegram Bot Token** (Create one by messaging [@BotFather](https://t.me/BotFather) on Telegram).
* Your **Numeric Telegram User ID** (Get this by messaging [@userinfobot](https://t.me/userinfobot)).

## ⚙️ One-Line Installation

Log into your VPS via SSH as the `root` user and paste the following command:


```bash
bash <(curl -Ls [https://raw.githubusercontent.com/SPW-SL/vps_Status_through_Telegram_BOT/main/install.sh](https://raw.githubusercontent.com/SPW-SL/vps_Status_through_Telegram_BOT/main/install.sh))

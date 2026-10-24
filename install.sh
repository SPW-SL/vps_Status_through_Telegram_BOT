#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}   VPS Telegram Manager & Bandwidth Monitor Installer ${NC}"
echo -e "${CYAN}======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root (use sudo su).${NC}"
    exit 1
fi

DEFAULT_IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
DEFAULT_IFACE=${DEFAULT_IFACE:-eth0}
SERVER_IP=$(curl -s4m 5 ifconfig.me || hostname -I | awk '{print $1}')

while [[ -z "$BOT_TOKEN" ]]; do
    read -r -p "Enter your Telegram Bot Token: " BOT_TOKEN < /dev/tty
done

while [[ -z "$ADMIN_ID_INPUT" ]]; do
    read -r -p "Enter Admin Telegram User ID(s) (comma-separated): " ADMIN_ID_INPUT < /dev/tty
done

read -r -p "Enter network interface to monitor [default: ${DEFAULT_IFACE}]: " IFACE_INPUT < /dev/tty
INTERFACE=${IFACE_INPUT:-$DEFAULT_IFACE}

read -r -p "Enter monthly bandwidth limit in GB (0 for unlimited) [default: 0]: " QUOTA_INPUT < /dev/tty
QUOTA_GB=$(echo "${QUOTA_INPUT:-0}" | sed 's/[^0-9.]//g')
QUOTA_GB=${QUOTA_GB:-0}

CLEAN_ADMIN_IDS=$(echo "$ADMIN_ID_INPUT" | tr -d '[:space:]' | sed 's/[^0-9,]//g')

echo -e "\n${YELLOW}[1/4] Installing system dependencies (python3-venv, vnstat)...${NC}"
apt-get update -y
apt-get install -y python3-venv vnstat curl

echo -e "${YELLOW}[2/4] Configuring vnStat for persistent 1-minute disk saves...${NC}"
sed -i 's/^;*SaveInterval.*/SaveInterval 1/' /etc/vnstat.conf
sed -i 's/^;*OfflineSaveInterval.*/OfflineSaveInterval 1/' /etc/vnstat.conf
systemctl enable --now vnstat
vnstat --add -i "$INTERFACE" 2>/dev/null || true
systemctl restart vnstat

echo -e "${YELLOW}[3/4] Setting up Python virtual environment & packages...${NC}"
mkdir -p /root/vps-bot
python3 -m venv /root/vps-bot/venv
/root/vps-bot/venv/bin/pip install --upgrade pip -q
/root/vps-bot/venv/bin/pip install python-telegram-bot psutil -q

cat << EOF > /root/vps-bot/config.json
{
    "bot_token": "${BOT_TOKEN}",
    "admin_ids": [${CLEAN_ADMIN_IDS}],
    "interface": "${INTERFACE}",
    "server_ip": "${SERVER_IP}",
    "monthly_quota_gb": ${QUOTA_GB},
    "alert_state": {
        "month": "",
        "80": false,
        "90": false,
        "100": false
    }
}
EOF
chmod 600 /root/vps-bot/config.json

cat << 'EOF' > /root/vps-bot/bot.py
import os
import json
import asyncio
import logging
import datetime
import subprocess
import psutil
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
)

CONFIG_PATH = "/root/vps-bot/config.json"

def load_config() -> dict:
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)

def save_config(cfg: dict):
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=4)

CONFIG = load_config()
BOT_TOKEN = CONFIG["bot_token"]
AUTHORIZED_ADMINS = set(CONFIG["admin_ids"])
INTERFACE = CONFIG["interface"]
SERVER_IP = CONFIG["server_ip"]

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO
)

def is_authorized(user_id: int) -> bool:
    return user_id in AUTHORIZED_ADMINS

def fmt_bytes(num_bytes: float) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if num_bytes < 1024.0:
            return f"{num_bytes:.2f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.2f} PB"

def make_progress_bar(pct: float, length: int = 10) -> str:
    filled = min(length, int(round((pct / 100.0) * length)))
    return "\u2588" * filled + "\u2591" * (length - filled)

def main_menu_keyboard() -> InlineKeyboardMarkup:
    keyboard = [
        [
            InlineKeyboardButton("\U0001f5a5 Server Status", callback_data="cmd_status"),
            InlineKeyboardButton("\U0001f4ca Bandwidth", callback_data="cmd_traffic"),
        ],
        [
            InlineKeyboardButton("\u26a1 Live Speed", callback_data="cmd_live"),
            InlineKeyboardButton("\U0001f51d Top Processes", callback_data="cmd_top"),
        ],
        [
            InlineKeyboardButton("\U0001f6e0 Restart x-ui", callback_data="cmd_xui_restart"),
            InlineKeyboardButton("\U0001f4be Backup x-ui DB", callback_data="cmd_backup"),
        ],
        [
            InlineKeyboardButton("\U0001f504 Reboot VPS", callback_data="cmd_reboot_ask"),
        ],
    ]
    return InlineKeyboardMarkup(keyboard)

def get_status_report() -> str:
    cpu_pct = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    disk = psutil.disk_usage("/")
    boot_dt = datetime.datetime.fromtimestamp(psutil.boot_time())
    uptime = str(datetime.datetime.now() - boot_dt).split(".")[0]

    xui_active = subprocess.run(
        ["systemctl", "is-active", "--quiet", "x-ui"]
    ).returncode == 0
    xui_str = "\U0001f7e2 Running" if xui_active else "\U0001f534 Not Running / Not Installed"

    return (
        f"\U0001f5a5 *VPS System Status ({SERVER_IP})*\n\n"
        f"*\u2699\ufe0f CPU Usage:* `{cpu_pct}%` ({psutil.cpu_count()} Cores)\n"
        f"*\U0001f9e0 RAM:* `{fmt_bytes(mem.used)} / {fmt_bytes(mem.total)} ({mem.percent}%)`\n"
        f"*\U0001f4be Swap:* `{fmt_bytes(swap.used)} / {fmt_bytes(swap.total)} ({swap.percent}%)`\n"
        f"*\U0001f4bf Disk (/):* `{fmt_bytes(disk.used)} / {fmt_bytes(disk.total)} ({disk.percent}%)`\n"
        f"*\u23f1 Uptime:* `{uptime}`\n"
        f"*\U0001f6e1 x-ui Service:* {xui_str}"
    )

def get_vnstat_data() -> dict:
    res = subprocess.run(
        ["vnstat", "-i", INTERFACE, "--json"],
        capture_output=True,
        text=True,
        check=True
    )
    return json.loads(res.stdout)["interfaces"][0]["traffic"]

def get_vnstat_report() -> str:
    cfg = load_config()
    quota_gb = float(cfg.get("monthly_quota_gb", 0))
    traffic = get_vnstat_data()

    day = traffic["day"][-1] if traffic.get("day") else {"rx": 0, "tx": 0}
    month = traffic["month"][-1] if traffic.get("month") else {"rx": 0, "tx": 0}
    total = traffic["total"]
    month_total_bytes = month["rx"] + month["tx"]

    quota_section = ""
    if quota_gb > 0:
        quota_bytes = quota_gb * (1024 ** 3)
        pct = (month_total_bytes / quota_bytes) * 100.0
        bar = make_progress_bar(pct)
        quota_section = (
            f"\n\U0001f3af *Monthly Quota:* `{fmt_bytes(month_total_bytes)} / {quota_gb:.1f} GB`\n"
            f"`[{bar}] {pct:.1f}%`\n"
        )
    else:
        quota_section = "\n\U0001f3af *Monthly Quota:* `Unlimited` (set with `/quota <GB>`)\n"

    return (
        f"\U0001f4ca *Persistent Bandwidth ({INTERFACE} - {SERVER_IP})*\n\n"
        f"*Today:*\n"
        f"  \u2b07 Download: `{fmt_bytes(day['rx'])}`\n"
        f"  \u2b06 Upload: `{fmt_bytes(day['tx'])}`\n"
        f"  \u2795 Total: `{fmt_bytes(day['rx'] + day['tx'])}`\n\n"
        f"*This Month:*\n"
        f"  \u2b07 Download: `{fmt_bytes(month['rx'])}`\n"
        f"  \u2b06 Upload: `{fmt_bytes(month['tx'])}`\n"
        f"  \u2795 Total: `{fmt_bytes(month_total_bytes)}`"
        f"{quota_section}\n"
        f"*All-Time (Across Reboots):*\n"
        f"  \u2795 Total: `{fmt_bytes(total['rx'] + total['tx'])}`"
    )

async def check_quota_and_alert(application):
    try:
        cfg = load_config()
        quota_gb = float(cfg.get("monthly_quota_gb", 0))
        if quota_gb <= 0:
            return

        traffic = get_vnstat_data()
        if not traffic.get("month"):
            return

        m_data = traffic["month"][-1]
        ym_key = f"{m_data['date']['year']}-{m_data['date']['month']:02d}"
        used_bytes = m_data["rx"] + m_data["tx"]
        quota_bytes = quota_gb * (1024 ** 3)
        pct = (used_bytes / quota_bytes) * 100.0

        state = cfg.get("alert_state", {})
        if state.get("month") != ym_key:
            state = {"month": ym_key, "80": False, "90": False, "100": False}

        triggered = None
        if pct >= 100.0 and not state.get("100"):
            triggered = ("100", "\U0001f6a8 *CRITICAL: 100% Bandwidth Quota Reached!*")
            state["80"] = state["90"] = state["100"] = True
        elif pct >= 90.0 and not state.get("90"):
            triggered = ("90", "\u26a0\ufe0f *WARNING: 90% Bandwidth Quota Reached!*")
            state["80"] = state["90"] = True
        elif pct >= 80.0 and not state.get("80"):
            triggered = ("80", "\U0001f514 *NOTICE: 80% Bandwidth Quota Reached!*")
            state["80"] = True

        cfg["alert_state"] = state
        save_config(cfg)

        if triggered:
            _, title = triggered
            bar = make_progress_bar(pct)
            msg = (
                f"{title}\n\n"
                f"\U0001f5a5 *Server:* `{SERVER_IP}` (`{INTERFACE}`)\n"
                f"\U0001f4ca *Used This Month:* `{fmt_bytes(used_bytes)} / {quota_gb:.1f} GB`\n"
                f"\U0001f4c8 *Progress:* `[{bar}] {pct:.1f}%`"
            )
            for admin_id in AUTHORIZED_ADMINS:
                await application.bot.send_message(
                    chat_id=admin_id,
                    text=msg,
                    parse_mode="Markdown",
                    reply_markup=main_menu_keyboard()
                )
    except Exception as e:
        logging.error(f"Quota monitor check error: {e}")

async def quota_monitor_loop(application):
    while True:
        await check_quota_and_alert(application)
        await asyncio.sleep(300)  # Check every 5 minutes

async def get_live_speed_report() -> str:
    net1 = psutil.net_io_counters(pernic=True).get(INTERFACE)
    if not net1:
        return f"\u26a0\ufe0f Interface `{INTERFACE}` not found."
    await asyncio.sleep(3)
    net2 = psutil.net_io_counters(pernic=True).get(INTERFACE)

    rx_per_sec = (net2.bytes_recv - net1.bytes_recv) / 3.0
    tx_per_sec = (net2.bytes_sent - net1.bytes_sent) / 3.0
    rx_mbps = (rx_per_sec * 8) / 1_000_000
    tx_mbps = (tx_per_sec * 8) / 1_000_000

    return (
        f"\u26a1 *Live Traffic Speed ({INTERFACE})*\n\n"
        f"\u2b07 *Download:* `{fmt_bytes(rx_per_sec)}/s` (`{rx_mbps:.2f} Mbps`)\n"
        f"\u2b06 *Upload:* `{fmt_bytes(tx_per_sec)}/s` (`{tx_mbps:.2f} Mbps`)"
    )

def get_top_processes() -> str:
    out = subprocess.run(
        ["ps", "-eo", "pid,comm,%cpu,%mem", "--sort=-%cpu"],
        capture_output=True,
        text=True
    ).stdout.strip().splitlines()
    lines = ["\U0001f51d *Top 5 Processes by CPU:*\n```"]
    lines.extend(out[:6])
    lines.append("```")
    return "\n".join(lines)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        await update.message.reply_text(f"\u26d4 Unauthorized. Your ID: {user_id}")
        return
    await update.message.reply_text(
        f"\u2705 *VPS Control Panel ({SERVER_IP})*\n"
        "Select an action below or use `/` commands:",
        parse_mode="Markdown",
        reply_markup=main_menu_keyboard()
    )

async def status_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    await update.message.reply_text(get_status_report(), parse_mode="Markdown", reply_markup=main_menu_keyboard())

async def traffic_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    try:
        await update.message.reply_text(get_vnstat_report(), parse_mode="Markdown", reply_markup=main_menu_keyboard())
    except Exception as e:
        await update.message.reply_text(f"\u26a0\ufe0f Error reading vnStat: {e}")

async def quota_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    cfg = load_config()
    if not context.args:
        q = cfg.get("monthly_quota_gb", 0)
        await update.message.reply_text(
            f"\U0001f3af *Current Monthly Quota:* `{q} GB`\n"
            "To change it, send: `/quota <GB>` (e.g. `/quota 1000` or `/quota 0` to disable).",
            parse_mode="Markdown"
        )
        return
    try:
        new_quota = float(context.args[0])
        cfg["monthly_quota_gb"] = new_quota
        cfg["alert_state"] = {"month": "", "80": False, "90": False, "100": False}
        save_config(cfg)
        await update.message.reply_text(
            f"\u2705 Monthly bandwidth quota set to *{new_quota} GB*.\n"
            "Automatic alerts are armed for *80%*, *90%*, and *100%*.",
            parse_mode="Markdown",
            reply_markup=main_menu_keyboard()
        )
        await check_quota_and_alert(context.application)
    except ValueError:
        await update.message.reply_text("\u26a0\ufe0f Please provide a valid number in GB (e.g., `/quota 1000`).", parse_mode="Markdown")

async def live_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    msg = await update.message.reply_text("\u23f3 Measuring live network speed (3s)...")
    report = await get_live_speed_report()
    await msg.edit_text(report, parse_mode="Markdown", reply_markup=main_menu_keyboard())

async def top_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    await update.message.reply_text(get_top_processes(), parse_mode="Markdown", reply_markup=main_menu_keyboard())

async def xui_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    res = subprocess.run(["systemctl", "restart", "x-ui"])
    if res.returncode == 0:
        await update.message.reply_text("\u2705 `x-ui` service restarted successfully!", parse_mode="Markdown")
    else:
        await update.message.reply_text("\u26a0\ufe0f Failed to restart `x-ui` (is it installed?).", parse_mode="Markdown")

async def backup_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    db_path = "/etc/x-ui/x-ui.db"
    if os.path.exists(db_path):
        with open(db_path, "rb") as f:
            await update.effective_message.reply_document(
                document=f,
                filename=f"x-ui-backup-{SERVER_IP}.db",
                caption=f"\U0001f4be x-ui Database Backup ({SERVER_IP})"
            )
    else:
        await update.effective_message.reply_text("\u26a0\ufe0f `/etc/x-ui/x-ui.db` not found on this server.", parse_mode="Markdown")

async def reboot_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id):
        return
    kb = InlineKeyboardMarkup([
        [
            InlineKeyboardButton("\u2705 Yes, Reboot Now", callback_data="confirm_reboot"),
            InlineKeyboardButton("\u274c Cancel", callback_data="cancel_reboot"),
        ]
    ])
    await update.message.reply_text(
        f"\u26a0\ufe0f *Are you sure you want to reboot VPS ({SERVER_IP})?*",
        parse_mode="Markdown",
        reply_markup=kb
    )

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    if not is_authorized(query.from_user.id):
        await query.answer("Unauthorized", show_alert=True)
        return
    await query.answer()
    data = query.data

    if data == "cmd_status":
        await query.edit_message_text(get_status_report(), parse_mode="Markdown", reply_markup=main_menu_keyboard())
    elif data == "cmd_traffic":
        await query.edit_message_text(get_vnstat_report(), parse_mode="Markdown", reply_markup=main_menu_keyboard())
    elif data == "cmd_live":
        await query.edit_message_text("\u23f3 Measuring live network speed (3s)...")
        report = await get_live_speed_report()
        await query.edit_message_text(report, parse_mode="Markdown", reply_markup=main_menu_keyboard())
    elif data == "cmd_top":
        await query.edit_message_text(get_top_processes(), parse_mode="Markdown", reply_markup=main_menu_keyboard())
    elif data == "cmd_xui_restart":
        res = subprocess.run(["systemctl", "restart", "x-ui"])
        msg = "\u2705 `x-ui` service restarted!" if res.returncode == 0 else "\u26a0\ufe0f `x-ui` service not found."
        await query.edit_message_text(msg, parse_mode="Markdown", reply_markup=main_menu_keyboard())
    elif data == "cmd_backup":
        await backup_cmd(update, context)
    elif data == "cmd_reboot_ask":
        kb = InlineKeyboardMarkup([
            [
                InlineKeyboardButton("\u2705 Yes, Reboot Now", callback_data="confirm_reboot"),
                InlineKeyboardButton("\u274c Cancel", callback_data="cancel_reboot"),
            ]
        ])
        await query.edit_message_text(
            f"\u26a0\ufe0f *Are you sure you want to reboot VPS ({SERVER_IP})?*",
            parse_mode="Markdown",
            reply_markup=kb
        )
    elif data == "cancel_reboot":
        await query.edit_message_text("\u2705 Reboot cancelled.", reply_markup=main_menu_keyboard())
    elif data == "confirm_reboot":
        subprocess.run(["vnstat", "--sync"], check=False)
        await query.edit_message_text("\U0001f504 Initiating VPS reboot now... Stand by for boot notification.")
        subprocess.run(["/usr/sbin/reboot"])

async def notify_on_boot(application):
    commands = [
        BotCommand("start", "Open interactive VPS control panel"),
        BotCommand("status", "Check CPU, RAM, Disk, Uptime & x-ui"),
        BotCommand("traffic", "Check persistent bandwidth & quota bar"),
        BotCommand("quota", "Set monthly bandwidth limit in GB"),
        BotCommand("live", "Measure real-time network speed"),
        BotCommand("top", "Show top 5 CPU-consuming processes"),
        BotCommand("xui", "Restart x-ui VPN panel service"),
        BotCommand("backup", "Download /etc/x-ui/x-ui.db backup"),
        BotCommand("reboot", "Reboot the VPS (with confirmation)"),
    ]
    await application.bot.set_my_commands(commands)

    for admin_id in AUTHORIZED_ADMINS:
        try:
            await application.bot.send_message(
                chat_id=admin_id,
                text=f"\U0001f7e2 *Ubuntu VPS ({SERVER_IP}) is back online!*\nAll services and bandwidth monitors have initialized.",
                parse_mode="Markdown",
                reply_markup=main_menu_keyboard()
            )
        except Exception as e:
            logging.error(f"Failed to send boot notification to {admin_id}: {e}")

    # Start the 5-minute background bandwidth quota watcher
    asyncio.create_task(quota_monitor_loop(application))

if __name__ == "__main__":
    app = (
        ApplicationBuilder()
        .token(BOT_TOKEN)
        .post_init(notify_on_boot)
        .build()
    )
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("status", status_cmd))
    app.add_handler(CommandHandler("traffic", traffic_cmd))
    app.add_handler(CommandHandler("quota", quota_cmd))
    app.add_handler(CommandHandler("live", live_cmd))
    app.add_handler(CommandHandler("top", top_cmd))
    app.add_handler(CommandHandler("xui", xui_cmd))
    app.add_handler(CommandHandler("backup", backup_cmd))
    app.add_handler(CommandHandler("reboot", reboot_cmd))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.run_polling(drop_pending_updates=True)
EOF

echo -e "${YELLOW}[4/4] Registering systemd service & interactive 'vps-bot' menu...${NC}"
cat << 'EOF' > /etc/systemd/system/telegram-vps-bot.service
[Unit]
Description=Telegram VPS Manager & Traffic Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/vps-bot
ExecStart=/root/vps-bot/venv/bin/python /root/vps-bot/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /usr/local/bin/vps-bot
#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
CONFIG_FILE="/root/vps-bot/config.json"

get_bot_status() {
    if systemctl is-active --quiet telegram-vps-bot.service; then
        echo -e "${GREEN}Running ●${NC}"
    else
        echo -e "${RED}Stopped ○${NC}"
    fi
}

get_vnstat_status() {
    if systemctl is-active --quiet vnstat; then
        echo -e "${GREEN}Running ●${NC}"
    else
        echo -e "${RED}Stopped ○${NC}"
    fi
}

change_credentials() {
    echo -e "\n${CYAN}--- Change Bot Token / Admin ID(s) ---${NC}"
    read -r -p "Enter new Bot Token (leave blank to keep current): " NEW_TOKEN < /dev/tty
    read -r -p "Enter new Admin ID(s) comma-separated (leave blank to keep current): " NEW_ADMINS < /dev/tty

    python3 - "$CONFIG_FILE" "$NEW_TOKEN" "$NEW_ADMINS" << 'PYEOF'
import sys, json, re

cfg_path, token, admins = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()
with open(cfg_path, "r") as f:
    data = json.load(f)

if token:
    data["bot_token"] = token
if admins:
    clean_ids = [int(x) for x in re.findall(r'\d+', admins)]
    if clean_ids:
        data["admin_ids"] = clean_ids

with open(cfg_path, "w") as f:
    json.dump(data, f, indent=4)
PYEOF

    systemctl restart telegram-vps-bot.service
    echo -e "${GREEN}✅ Configuration updated and bot restarted!${NC}"
}

change_quota() {
    echo -e "\n${CYAN}--- Set Monthly Bandwidth Quota ---${NC}"
    read -r -p "Enter monthly limit in GB (0 for unlimited): " NEW_QUOTA < /dev/tty
    python3 - "$CONFIG_FILE" "$NEW_QUOTA" << 'PYEOF'
import sys, json

cfg_path, q_str = sys.argv[1], sys.argv[2].strip()
try:
    q_val = float(q_str)
except ValueError:
    print("Invalid number.")
    sys.exit(1)

with open(cfg_path, "r") as f:
    data = json.load(f)

data["monthly_quota_gb"] = q_val
data["alert_state"] = {"month": "", "80": False, "90": False, "100": False}

with open(cfg_path, "w") as f:
    json.dump(data, f, indent=4)
PYEOF
    systemctl restart telegram-vps-bot.service
    echo -e "${GREEN}✅ Monthly bandwidth quota updated to ${NEW_QUOTA} GB!${NC}"
}

restart_bot() {
    echo -e "\n${YELLOW}Restarting Telegram VPS Bot...${NC}"
    systemctl restart telegram-vps-bot.service
    sleep 1
    echo -e "Current Status: $(get_bot_status)"
}

view_traffic() {
    IFACE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['interface'])" 2>/dev/null || echo "eth0")
    echo -e "\n${CYAN}--- Persistent Bandwidth Usage (${IFACE}) ---${NC}"
    vnstat -i "$IFACE"
}

uninstall_bot() {
    echo -e ""
    read -r -p "Are you sure you want to uninstall VPS Telegram Bot? [y/N]: " CONFIRM < /dev/tty
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop telegram-vps-bot.service 2>/dev/null || true
        systemctl disable telegram-vps-bot.service 2>/dev/null || true
        rm -f /etc/systemd/system/telegram-vps-bot.service
        rm -rf /root/vps-bot
        rm -f /usr/local/bin/vps-bot
        systemctl daemon-reload
        echo -e "${GREEN}✅ VPS Telegram Bot has been completely uninstalled.${NC}"
        exit 0
    else
        echo -e "${YELLOW}Uninstall cancelled.${NC}"
    fi
}

show_menu() {
    while true; do
        ADMIN_LIST=$(python3 -c "import json; print(', '.join(map(str, json.load(open('$CONFIG_FILE'))['admin_ids'])))" 2>/dev/null || echo "Unknown")
        IFACE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['interface'])" 2>/dev/null || echo "eth0")
        QUOTA=$(python3 -c "import json; q=json.load(open('$CONFIG_FILE')).get('monthly_quota_gb', 0); print(f'{q} GB' if q>0 else 'Unlimited')" 2>/dev/null || echo "Unlimited")

        echo -e "\n${CYAN}======================================================${NC}"
        echo -e "${GREEN}          VPS Telegram Bot Management Menu            ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "  Bot Status    : $(get_bot_status)"
        echo -e "  vnStat Status : $(get_vnstat_status)"
        echo -e "  Interface     : ${YELLOW}${IFACE}${NC}"
        echo -e "  Monthly Quota : ${YELLOW}${QUOTA}${NC}"
        echo -e "  Admin ID(s)   : ${YELLOW}${ADMIN_LIST}${NC}"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo -e "  ${GREEN}1.${NC} Change Token / Admin ID(s)"
        echo -e "  ${GREEN}2.${NC} Set Monthly Bandwidth Quota (GB)"
        echo -e "  ${GREEN}3.${NC} Restart Bot"
        echo -e "  ${GREEN}4.${NC} View Traffic (vnStat)"
        echo -e "  ${GREEN}5.${NC} Uninstall Bot"
        echo -e "  ${GREEN}6.${NC} View Bot Logs"
        echo -e "  ${GREEN}0.${NC} Exit"
        echo -e "${CYAN}======================================================${NC}"
        read -r -p "Please enter your selection [0-6]: " CHOICE < /dev/tty

        case "$CHOICE" in
            1) change_credentials ;;
            2) change_quota ;;
            3) restart_bot ;;
            4) view_traffic ;;
            5) uninstall_bot ;;
            6) journalctl -u telegram-vps-bot.service -n 25 --no-pager ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option, please choose [0-6].${NC}" ;;
        esac
    done
}

case "$1" in
    status) systemctl status telegram-vps-bot.service --no-pager ;;
    restart) restart_bot ;;
    traffic) view_traffic ;;
    logs) journalctl -u telegram-vps-bot.service -n 30 --no-pager ;;
    uninstall) uninstall_bot ;;
    *) show_menu ;;
esac
EOF
chmod +x /usr/local/bin/vps-bot

systemctl daemon-reload
systemctl enable --now telegram-vps-bot.service
systemctl restart telegram-vps-bot.service

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}✅ Installation Complete!${NC}"
echo -e "   • Type ${YELLOW}vps-bot${NC} anytime to open the terminal management menu."
echo -e "   • Send ${YELLOW}/start${NC} or ${YELLOW}/quota 1000${NC} to your bot on Telegram."
echo -e "${CYAN}======================================================${NC}"

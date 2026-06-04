#!/bin/bash
# 系统状态快照 → Git 版本化追踪
# 记录 Ubuntu + Mac Mini 双系统的完整运行状态
# Cron: 30 3 * * * (每天凌晨3:30)

SNAP_DIR="$HOME/clawd/docs/system-state"
MAC_HOST="neardws@192.168.31.112"
LOG_TAG="[system-snapshot]"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_TAG} $1"
}

mkdir -p "$SNAP_DIR"

log "Starting system snapshot..."

# ============================================================
# Ubuntu Server 状态
# ============================================================

log "Capturing Ubuntu state..."

# Cron jobs
crontab -l > "$SNAP_DIR/ubuntu-crontab.txt" 2>/dev/null

# Systemd services (自定义的)
systemctl list-units --type=service --state=running --plain --no-pager \
    | grep -vE '(systemd-|dbus|ssh\.service|udev|cron\.service|snap\.|polkit|rsyslog|unattended|multipathd|networkd|resolved|journal|user@|login|fstrim|irq|accounts|getty|mod)' \
    > "$SNAP_DIR/ubuntu-services.txt" 2>/dev/null

# Docker containers
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" \
    > "$SNAP_DIR/ubuntu-docker.txt" 2>/dev/null

# Listening ports
ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4, $6}' | sort \
    > "$SNAP_DIR/ubuntu-ports.txt"

# Cloudflared tunnels (sanitized)
sudo cat /etc/cloudflared/config.yml 2>/dev/null | \
    sed 's/credentials-file:.*/credentials-file: [REDACTED]/' \
    > "$SNAP_DIR/ubuntu-cloudflared.txt"

# Disk usage
df -h / /home 2>/dev/null | tail -2 > "$SNAP_DIR/ubuntu-disk.txt"

# Versions
{
    echo "Snapshot: $(date -Iseconds)"
    echo "Hostname: $(hostname)"
    echo "OS: $(lsb_release -ds 2>/dev/null)"
    echo "Kernel: $(uname -r)"
    echo "Node: $(node -v 2>/dev/null)"
    echo "pnpm: $(pnpm -v 2>/dev/null)"
    echo "Git: $(git --version 2>/dev/null)"
    echo "Docker: $(docker --version 2>/dev/null)"
    echo "OpenClaw: $(cd ~/clawdbot && git describe --tags --always 2>/dev/null)"
    echo "Python: $(python3 --version 2>/dev/null)"
    echo "Rust: $(rustc --version 2>/dev/null)"
    echo "Bun: $(bun --version 2>/dev/null)"
} > "$SNAP_DIR/ubuntu-versions.txt"

# npm/pnpm global packages
pnpm list -g --depth=0 2>/dev/null > "$SNAP_DIR/ubuntu-pnpm-global.txt" || true

log "Ubuntu state captured"

# ============================================================
# Mac Mini M4 状态 (via SSH)
# ============================================================

log "Capturing Mac Mini state..."

MAC_REACHABLE=0
if ssh -o ConnectTimeout=10 "$MAC_HOST" 'echo ok' 2>/dev/null | grep -q ok; then
    MAC_REACHABLE=1

    # Cron jobs
    ssh "$MAC_HOST" 'crontab -l 2>/dev/null' > "$SNAP_DIR/mac-crontab.txt" 2>/dev/null

    # Launchd services (非 Apple)
    ssh "$MAC_HOST" 'launchctl list 2>/dev/null | grep -vE "^-|com\.apple"' \
        > "$SNAP_DIR/mac-launchd.txt" 2>/dev/null

    # Homebrew packages
    ssh "$MAC_HOST" '/opt/homebrew/bin/brew list --formula 2>/dev/null' \
        > "$SNAP_DIR/mac-homebrew.txt" 2>/dev/null

    # Homebrew cask
    ssh "$MAC_HOST" '/opt/homebrew/bin/brew list --cask 2>/dev/null' \
        > "$SNAP_DIR/mac-homebrew-cask.txt" 2>/dev/null

    # Listening ports
    ssh "$MAC_HOST" 'lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | grep -vE "(rapportd|controlce|mDNS|AirPlay|WiFi|sharingd)" | awk "{print \$1, \$9}"' \
        > "$SNAP_DIR/mac-ports.txt" 2>/dev/null

    # Disk usage
    ssh "$MAC_HOST" 'df -h / 2>/dev/null | tail -1' > "$SNAP_DIR/mac-disk.txt" 2>/dev/null

    # Versions
    ssh "$MAC_HOST" 'echo "Hostname: $(hostname)"; echo "macOS: $(sw_vers -productVersion)"; echo "Chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo M4)"; echo "Memory: $(sysctl -n hw.memsize 2>/dev/null | awk "{print \$1/1024/1024/1024 \" GB\"}")"; echo "Node: $(node -v 2>/dev/null)"; echo "pnpm: $(/opt/homebrew/bin/pnpm -v 2>/dev/null)"' \
        > "$SNAP_DIR/mac-versions.txt" 2>/dev/null

    log "Mac Mini state captured"
else
    log "⚠ Mac Mini SSH unreachable, skipping"
    for file in mac-crontab.txt mac-launchd.txt mac-homebrew.txt mac-homebrew-cask.txt mac-ports.txt mac-disk.txt; do
        : > "$SNAP_DIR/$file"
    done
    echo "UNREACHABLE at $(date -Iseconds)" > "$SNAP_DIR/mac-versions.txt"
fi

# ============================================================
# 生成变更摘要
# ============================================================
{
    echo "# System State Snapshot"
    echo "Generated: $(date -Iseconds)"
    echo ""
    echo "## Ubuntu Server"
    echo "- Services: $(wc -l < "$SNAP_DIR/ubuntu-services.txt") running"
    echo "- Docker: $(docker ps -q 2>/dev/null | wc -l) containers"
    echo "- Cron: $(wc -l < "$SNAP_DIR/ubuntu-crontab.txt") jobs"
    echo "- Ports: $(wc -l < "$SNAP_DIR/ubuntu-ports.txt") listening"
    echo ""
    echo "## Mac Mini M4"
    if [ "$MAC_REACHABLE" -eq 1 ]; then
        echo "- Cron: $(wc -l < "$SNAP_DIR/mac-crontab.txt") jobs"
        echo "- Homebrew: $(wc -l < "$SNAP_DIR/mac-homebrew.txt") packages"
        echo "- Launchd: $(wc -l < "$SNAP_DIR/mac-launchd.txt") services"
    else
        echo "- Status: unreachable"
    fi
} > "$SNAP_DIR/README.md"

log "Snapshot complete"

# ============================================================
# Git commit + push
# ============================================================
cd "$HOME/clawd"
git add docs/system-state/
CHANGES=$(git diff --cached --stat 2>/dev/null | tail -1)
if [ -n "$CHANGES" ] && echo "$CHANGES" | grep -qE "[0-9]+ file"; then
    git commit -m "snapshot: system state $(date +%Y-%m-%d)" > /dev/null 2>&1
    git push origin main > /dev/null 2>&1
    log "Git committed and pushed"
else
    log "No changes to commit"
fi

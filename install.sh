#!/bin/bash
# =============================================================
# grub-btrfs + Timeshift fix for Linux Mint 22.3 / Ubuntu Noble
# Author: mimferpo
# Repo: https://github.com/mimferpo/grub-btrfs-timeshift-mint
# Buy me a coffee: https://buymeacoffee.com/mimferpo
# =============================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Helpers
ok()     { echo -e "  ${GREEN}✔${NC} $1"; }
info()   { echo -e "  ${CYAN}→${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()   { echo -e "  ${RED}✘${NC} $1"; echo ""; exit 1; }
header() { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; echo -e "  ${BLUE}$(printf '%.0s─' {1..45})${NC}"; }
check()  { echo -e "  ${GREEN}✔${NC} $1"; CHECKS_PASSED=$((CHECKS_PASSED+1)); }
checkfail() { echo -e "  ${RED}✘${NC} $1"; CHECKS_FAILED=$((CHECKS_FAILED+1)); }

CHECKS_PASSED=0
CHECKS_FAILED=0

# Banner
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   grub-btrfs + Timeshift — Complete Fix      ║${NC}"
echo -e "${BOLD}${CYAN}║   Linux Mint 22.3 / Ubuntu Noble             ║${NC}"
echo -e "${BOLD}${CYAN}║   github.com/mimferpo/grub-btrfs-timeshift   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ─── Pre-flight checks ────────────────────────────────────────
header "Pre-flight checks"

if [ "$EUID" -eq 0 ]; then
    fail "Do not run as root. Script uses sudo when needed."
fi
ok "Not running as root"

if ! grep -qiE "ubuntu|linuxmint|debian" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu/Mint/Debian."
    read -p "  Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
else
    DISTRO=$(grep "^PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    ok "Distro: $DISTRO"
fi

if ! df -T / | grep -q btrfs; then
    fail "Root filesystem is not btrfs. This script is not needed."
fi
ok "btrfs filesystem confirmed"

if ! command -v timeshift &>/dev/null; then
    warn "Timeshift not found. Install it first: sudo apt install timeshift"
    read -p "  Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
else
    ok "Timeshift found"
fi

# ─── Step 1: Install grub-btrfs ──────────────────────────────
header "Step 1 — Installing grub-btrfs from source"

info "Installing git..."
sudo apt install -y git

info "Cloning grub-btrfs..."
cd ~
[ -d "grub-btrfs" ] && { warn "Old folder found — removing"; rm -rf grub-btrfs; }
git clone https://github.com/Antynea/grub-btrfs.git

info "Running make install..."
cd ~/grub-btrfs
sudo make install

info "Cleaning up source folder..."
cd ~
rm -rf grub-btrfs
ok "grub-btrfs installed and source folder removed"

# ─── Step 2: Install dependencies ────────────────────────────
header "Step 2 — Installing required dependencies"

sudo apt install -y inotify-tools gawk
ok "inotify-tools installed — required for snapshot watching"
ok "gawk installed — fixes mawk regex bug (root cause of UUID error)"

# ─── Step 3: Fix the service ─────────────────────────────────
header "Step 3 — Fixing grub-btrfsd service"

info "Creating service override with --timeshift-auto..."
sudo systemctl edit grub-btrfsd.service --force <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto
EOF

info "Verifying override.conf..."
if sudo cat /etc/systemd/system/grub-btrfsd.service.d/override.conf | grep -q "timeshift-auto"; then
    ok "override.conf saved correctly:"
    sudo cat /etc/systemd/system/grub-btrfsd.service.d/override.conf | sed 's/^/     /'
else
    fail "override.conf not saved correctly — check manually"
fi

info "Applying service changes..."
sudo systemctl daemon-reload
sudo systemctl enable grub-btrfsd.service
sudo systemctl restart grub-btrfsd.service

sleep 2
if systemctl is-active --quiet grub-btrfsd.service; then
    ok "grub-btrfsd service is active (running)"
else
    echo ""
    warn "Service failed to start. Status:"
    sudo systemctl status grub-btrfsd.service --no-pager
    fail "Fix the service before continuing"
fi

# ─── Step 4: Fix config ───────────────────────────────────────
header "Step 4 — Fixing grub-btrfs config"

CONFIG="/etc/default/grub-btrfs/config"

info "Fixing GRUB_BTRFS_IGNORE_SPECIFIC_PATH..."
if grep -q 'GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("@")' "$CONFIG"; then
    sudo sed -i 's/GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("@")/GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("")/' "$CONFIG"
    ok "GRUB_BTRFS_IGNORE_SPECIFIC_PATH set to empty"
else
    warn "Already set or not found — skipping"
fi

info "Fixing GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE..."
if grep -q '#GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")' "$CONFIG"; then
    sudo sed -i 's/#GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")/GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")/' "$CONFIG"
    ok "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE uncommented"
else
    warn "Already set or not found — skipping"
fi

info "Fixing GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION..."
if grep -q '#GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"' "$CONFIG"; then
    sudo sed -i 's/#GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"/GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"/' "$CONFIG"
    ok "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION set to true"
else
    warn "Already set or not found — skipping"
fi

# ─── Step 5: Update GRUB ─────────────────────────────────────
header "Step 5 — Updating GRUB"
sudo update-grub

# ─── Step 6: Verify ──────────────────────────────────────────
header "Step 6 — Verifying"
if sudo grep -q "Linux Mint snapshots\|snapshots-btrfs" /boot/grub/grub.cfg; then
    ok "Snapshots submenu found in GRUB config!"
else
    warn "Snapshots not found in GRUB config."
    info "Make sure you have at least one Timeshift snapshot:"
    info "sudo timeshift --create --comments 'test'"
    info "Then run: sudo update-grub"
fi

# ─── Step 7: Clean leftover backups ──────────────────────────
header "Step 7 — Cleaning leftover backup scripts"
FOUND=0
for f in /etc/grub.d/41_snapshots-btrfs.bak \
          /etc/grub.d/41_snapshots-btrfs.backup \
          /etc/grub.d/41_snapshots-btrfs.bkp; do
    if [ -f "$f" ]; then
        warn "Found leftover: $f — removing to prevent duplicate GRUB entries"
        sudo rm "$f"
        ok "Removed $f"
        FOUND=1
    fi
done
[ "$FOUND" -eq 0 ] && ok "No leftover backup scripts found"

# ─── Final verification ───────────────────────────────────────
header "Final Verification — Checking everything"

# 1. grub-btrfs script exists
if [ -f /etc/grub.d/41_snapshots-btrfs ]; then
    check "grub-btrfs script installed (/etc/grub.d/41_snapshots-btrfs)"
else
    checkfail "grub-btrfs script NOT found"
fi

# 2. gawk installed
if command -v gawk &>/dev/null; then
    check "gawk installed ($(gawk --version | head -1))"
else
    checkfail "gawk NOT installed — UUID detection will fail"
fi

# 3. inotify-tools installed
if command -v inotifywait &>/dev/null; then
    check "inotify-tools installed"
else
    checkfail "inotify-tools NOT installed — service will fail"
fi

# 4. override.conf exists and correct
if sudo cat /etc/systemd/system/grub-btrfsd.service.d/override.conf 2>/dev/null | grep -q "timeshift-auto"; then
    check "Service override correct (--timeshift-auto)"
else
    checkfail "Service override missing or incorrect"
fi

# 5. Service is running
if systemctl is-active --quiet grub-btrfsd.service; then
    check "grub-btrfsd service is active (running)"
else
    checkfail "grub-btrfsd service is NOT running"
fi

# 6. Service is enabled
if systemctl is-enabled --quiet grub-btrfsd.service; then
    check "grub-btrfsd service is enabled (starts on boot)"
else
    checkfail "grub-btrfsd service is NOT enabled"
fi

# 7. Config IGNORE_SPECIFIC_PATH
if grep -q 'GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("")' /etc/default/grub-btrfs/config; then
    check "GRUB_BTRFS_IGNORE_SPECIFIC_PATH set correctly"
else
    checkfail "GRUB_BTRFS_IGNORE_SPECIFIC_PATH not set correctly"
fi

# 8. Config IGNORE_SNAPSHOT_TYPE
if grep -q '^GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")' /etc/default/grub-btrfs/config; then
    check "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE set correctly"
else
    checkfail "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE not set correctly"
fi

# 9. Config OVERRIDE_BOOT_PARTITION_DETECTION
if grep -q '^GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"' /etc/default/grub-btrfs/config; then
    check "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION set correctly"
else
    checkfail "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION not set correctly"
fi

# 10. No leftover backup scripts
LEFTOVERS=$(ls /etc/grub.d/41_snapshots-btrfs.* 2>/dev/null | grep -v "^/etc/grub.d/41_snapshots-btrfs$" || true)
if [ -z "$LEFTOVERS" ]; then
    check "No leftover backup scripts in /etc/grub.d/"
else
    checkfail "Leftover backup scripts found: $LEFTOVERS — delete them"
fi

# 11. Snapshots in GRUB config
if sudo grep -q "Linux Mint snapshots\|snapshots-btrfs" /boot/grub/grub.cfg; then
    check "Snapshots submenu present in /boot/grub/grub.cfg"
else
    checkfail "Snapshots submenu NOT in /boot/grub/grub.cfg"
fi

# 12. awk UUID test
UUID_TEST=$(sudo btrfs subvolume show / 2>/dev/null | grep -m1 "UUID:" | awk '{print $NF}')
if [ -n "$UUID_TEST" ]; then
    check "UUID detection working ($UUID_TEST)"
else
    checkfail "UUID detection failed — check awk installation"
fi

# ─── Verification summary ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}Results: ${GREEN}${CHECKS_PASSED} passed${NC} / ${RED}${CHECKS_FAILED} failed${NC}"
echo ""

if [ "$CHECKS_FAILED" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║   ✔  All checks passed!                      ║${NC}"
    echo -e "${BOLD}${GREEN}║   Reboot to see Timeshift snapshots          ║${NC}"
    echo -e "${BOLD}${GREEN}║   in your GRUB menu.                         ║${NC}"
    echo -e "${BOLD}${GREEN}║                                              ║${NC}"
    echo -e "${BOLD}${GREEN}║   No need to run update-grub manually —      ║${NC}"
    echo -e "${BOLD}${GREEN}║   gawk + service handles it automatically.   ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
else
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║   ✘  Some checks failed!                     ║${NC}"
    echo -e "${BOLD}${RED}║   Review the errors above and fix them       ║${NC}"
    echo -e "${BOLD}${RED}║   before rebooting.                          ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  Reboot now with: ${CYAN}sudo reboot${NC}"
echo ""
echo -e "  If this helped, consider buying me a coffee ☕"
echo -e "  ${CYAN}https://buymeacoffee.com/mimferpo${NC}"
echo ""
#!/bin/bash
# =============================================================
# grub-btrfs + Timeshift fix for Linux Mint 22.3 / Ubuntu Noble
# Author: mimferpo
# Repo: https://github.com/mimferpo/grub-btrfs-timeshift-fix
# Buy me a coffee: https://buymeacoffee.com/mimferpo
# =============================================================

set -euo pipefail

# ─── Dry-run mode ─────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# Wrapper for mutating commands
run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Helpers
ok()        { echo -e "  ${GREEN}✔${NC} $1"; }
info()      { echo -e "  ${CYAN}→${NC} $1"; }
warn()      { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()      { echo -e "  ${RED}✘${NC} $1"; echo ""; exit 1; }
header()    { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; echo -e "  ${BLUE}$(printf '%.0s─' {1..45})${NC}"; }
check()     { echo -e "  ${GREEN}✔${NC} $1"; CHECKS_PASSED=$((CHECKS_PASSED+1)); }
checkfail() { echo -e "  ${RED}✘${NC} $1"; CHECKS_FAILED=$((CHECKS_FAILED+1)); }

CHECKS_PASSED=0
CHECKS_FAILED=0

# Require interactive terminal
if [ ! -t 0 ]; then
    echo "This script requires an interactive terminal."
    exit 1
fi

# Temp directory with guaranteed auto cleanup
TMPCLONE=$(mktemp -d -t grub-btrfs-XXXXXX)
trap 'rm -rf "$TMPCLONE"' EXIT

# Safe clear
command -v clear >/dev/null 2>&1 && clear || true

# Banner
echo ""
if [ "$DRY_RUN" = true ]; then
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║   grub-btrfs + Timeshift — DRY RUN MODE     ║${NC}"
echo -e "${BOLD}${YELLOW}║   No changes will be made to your system     ║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${NC}"
else
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   grub-btrfs + Timeshift — Complete Fix      ║${NC}"
echo -e "${BOLD}${CYAN}║   Linux Mint 22.3 / Ubuntu Noble             ║${NC}"
echo -e "${BOLD}${CYAN}║   github.com/mimferpo/grub-btrfs-timeshift   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
fi
echo ""

# ─── Pre-flight checks ────────────────────────────────────────
header "Pre-flight checks"

# Must not run as root
if [ "$EUID" -eq 0 ]; then
    fail "Do not run as root. Script uses sudo when needed."
fi
ok "Not running as root"

# Dependency preflight
REQUIRED_CMDS=(sudo grep sed findmnt systemctl btrfs awk)
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    fail "Required commands missing: ${MISSING[*]}"
fi
ok "Required system commands found"

# Must be Ubuntu/Mint/Debian
if ! grep -qiE "ubuntu|linuxmint|debian" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu/Mint/Debian."
    read -rp "  Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
else
    DISTRO=$(grep "^PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    ok "Distro: $DISTRO"
fi

# Must be btrfs
if [ "$(findmnt -no FSTYPE /)" != "btrfs" ]; then
    fail "Root filesystem is not btrfs. This script is not needed."
fi
ok "btrfs filesystem confirmed"

# Check Timeshift
if ! command -v timeshift &>/dev/null; then
    warn "Timeshift not found. Install it first: sudo apt install timeshift"
    read -rp "  Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
else
    ok "Timeshift found"
fi

# Check network using actual git protocol
info "Checking network connectivity to github.com..."
if git ls-remote https://github.com/Antynea/grub-btrfs.git >/dev/null 2>&1; then
    ok "Network connectivity confirmed"
else
    fail "Cannot reach github.com — check your network connection"
fi

# ─── Step 1: Install grub-btrfs ──────────────────────────────
header "Step 1 — Installing grub-btrfs from source"

info "Updating apt package list..."
run sudo apt update -q

info "Installing git and make..."
run sudo apt install -y git make

info "Cloning grub-btrfs to temp directory ($TMPCLONE)..."
run git clone https://github.com/Antynea/grub-btrfs.git "$TMPCLONE/grub-btrfs"

info "Running make install..."
if [ "$DRY_RUN" = false ]; then
    cd "$TMPCLONE/grub-btrfs"
    sudo make install
    cd "$HOME"
fi
ok "grub-btrfs installed — temp folder auto-cleaned on exit"

# ─── Step 2: Install dependencies ────────────────────────────
header "Step 2 — Installing required dependencies"

run sudo apt install -y inotify-tools gawk
ok "inotify-tools — required for snapshot watching"
ok "gawk — fixes mawk regex bug (root cause of UUID error)"

# ─── Step 3: Fix the service ─────────────────────────────────
header "Step 3 — Fixing grub-btrfsd service"

# Dynamically find grub-btrfsd binary
GRUB_BTRFSD=$(command -v grub-btrfsd 2>/dev/null) || fail "grub-btrfsd binary not found — check grub-btrfs installation"
ok "grub-btrfsd found at: $GRUB_BTRFSD"

info "Creating service override directory..."
run sudo mkdir -p /etc/systemd/system/grub-btrfsd.service.d

info "Writing override.conf..."
if [ "$DRY_RUN" = false ]; then
    sudo tee /etc/systemd/system/grub-btrfsd.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=$GRUB_BTRFSD --syslog --timeshift-auto
EOF
else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would write override.conf with:"
    echo "     [Service]"
    echo "     ExecStart="
    echo "     ExecStart=$GRUB_BTRFSD --syslog --timeshift-auto"
fi

if [ "$DRY_RUN" = false ]; then
    if sudo grep -q "timeshift-auto" /etc/systemd/system/grub-btrfsd.service.d/override.conf; then
        ok "override.conf saved correctly:"
        sudo sed 's/^/     /' /etc/systemd/system/grub-btrfsd.service.d/override.conf
    else
        fail "override.conf not saved correctly — check manually"
    fi
fi

info "Applying service changes..."
run sudo systemctl daemon-reload
run sudo systemctl enable grub-btrfsd.service
run sudo systemctl restart grub-btrfsd.service

if [ "$DRY_RUN" = false ]; then
    sleep 2
    if systemctl is-active --quiet grub-btrfsd.service; then
        ok "grub-btrfsd service is active (running)"
    else
        echo ""
        warn "Service failed to start. Status:"
        sudo systemctl status grub-btrfsd.service --no-pager
        fail "Fix the service before continuing"
    fi
fi

# ─── Step 4: Fix config ───────────────────────────────────────
header "Step 4 — Fixing grub-btrfs config"

CONFIG="/etc/default/grub-btrfs/config"

[ -f "$CONFIG" ] || fail "Config file not found at $CONFIG — check grub-btrfs installation"
ok "Config file found"

info "Backing up config..."
run sudo cp "$CONFIG" "${CONFIG}.bak"
ok "Config backed up to ${CONFIG}.bak"

info "Fixing GRUB_BTRFS_IGNORE_SPECIFIC_PATH..."
if grep -Eq '^GRUB_BTRFS_IGNORE_SPECIFIC_PATH=\("@"\)' "$CONFIG"; then
    run sudo sed -Ei 's/^GRUB_BTRFS_IGNORE_SPECIFIC_PATH=\("@"\)/GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("")/' "$CONFIG"
    ok "GRUB_BTRFS_IGNORE_SPECIFIC_PATH set to empty"
elif grep -Eq '^GRUB_BTRFS_IGNORE_SPECIFIC_PATH=\(""\)' "$CONFIG"; then
    warn "Already set correctly — skipping"
else
    warn "Not found in expected format — skipping"
fi

info "Fixing GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE..."
if grep -Eq '^#?GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=' "$CONFIG"; then
    run sudo sed -Ei 's/^#?GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=.*/GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")/' "$CONFIG"
    ok "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE set correctly"
else
    warn "Not found — skipping"
fi

info "Fixing GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION..."
if grep -Eq '^#?GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=' "$CONFIG"; then
    run sudo sed -Ei 's/^#?GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=.*/GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"/' "$CONFIG"
    ok "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION set to true"
else
    warn "Not found — skipping"
fi

# ─── Step 5: Update GRUB ─────────────────────────────────────
header "Step 5 — Updating GRUB"

if command -v update-grub &>/dev/null; then
    run sudo update-grub
else
    warn "update-grub not found — using grub-mkconfig"
    run sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

# ─── Step 6: Verify snapshots ────────────────────────────────
header "Step 6 — Verifying snapshots in GRUB"

if [ "$DRY_RUN" = false ]; then
    if sudo grep -q "menuentry.*snapshot\|41_snapshots-btrfs" /boot/grub/grub.cfg; then
        ok "Snapshots submenu found in GRUB config!"
    else
        warn "Snapshots not found in GRUB config."
        info "Make sure you have at least one Timeshift snapshot:"
        info "sudo timeshift --create --comments 'test'"
        info "Then run: sudo update-grub"
    fi
else
    warn "[DRY-RUN] Skipping GRUB config check — no changes made"
fi

# ─── Step 7: Clean leftover backups ──────────────────────────
header "Step 7 — Cleaning leftover backup scripts"

shopt -s nullglob
leftovers=(/etc/grub.d/41_snapshots-btrfs.*)
shopt -u nullglob

FOUND=0
for f in "${leftovers[@]}"; do
    [ "$f" = "/etc/grub.d/41_snapshots-btrfs" ] && continue
    warn "Found leftover: $f — removing to prevent duplicate GRUB entries"
    run sudo rm "$f"
    ok "Removed $f"
    FOUND=1
done
[ "$FOUND" -eq 0 ] && ok "No leftover backup scripts found"

# ─── Final verification ───────────────────────────────────────
if [ "$DRY_RUN" = false ]; then

header "Final Verification — Checking everything"

# 1. grub-btrfs script
if [ -f /etc/grub.d/41_snapshots-btrfs ]; then
    check "grub-btrfs script installed"
else
    checkfail "grub-btrfs script NOT found"
fi

# 2. gawk
if command -v gawk &>/dev/null; then
    check "gawk installed ($(gawk --version | head -1))"
else
    checkfail "gawk NOT installed"
fi

# 3. inotify-tools
if command -v inotifywait &>/dev/null; then
    check "inotify-tools installed"
else
    checkfail "inotify-tools NOT installed"
fi

# 4. override.conf
if sudo grep -q "timeshift-auto" /etc/systemd/system/grub-btrfsd.service.d/override.conf 2>/dev/null; then
    check "Service override correct (--timeshift-auto)"
else
    checkfail "Service override missing or incorrect"
fi

# 5. Service running
if systemctl is-active --quiet grub-btrfsd.service; then
    check "grub-btrfsd service is active (running)"
else
    checkfail "grub-btrfsd service is NOT running"
fi

# 6. Service enabled
if systemctl is-enabled --quiet grub-btrfsd.service; then
    check "grub-btrfsd service is enabled (starts on boot)"
else
    checkfail "grub-btrfsd service is NOT enabled"
fi

# 7. Config IGNORE_SPECIFIC_PATH
if grep -Eq '^GRUB_BTRFS_IGNORE_SPECIFIC_PATH=\(""\)' "$CONFIG"; then
    check "GRUB_BTRFS_IGNORE_SPECIFIC_PATH set correctly"
else
    checkfail "GRUB_BTRFS_IGNORE_SPECIFIC_PATH not set correctly"
fi

# 8. Config IGNORE_SNAPSHOT_TYPE
if grep -Eq '^GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=\(""\)' "$CONFIG"; then
    check "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE set correctly"
else
    checkfail "GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE not set correctly"
fi

# 9. Config OVERRIDE_BOOT_PARTITION_DETECTION
if grep -Eq '^GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"' "$CONFIG"; then
    check "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION set correctly"
else
    checkfail "GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION not set correctly"
fi

# 10. No leftover backup scripts
shopt -s nullglob
remaining=(/etc/grub.d/41_snapshots-btrfs.*)
shopt -u nullglob
CLEAN=1
for f in "${remaining[@]}"; do
    [ "$f" = "/etc/grub.d/41_snapshots-btrfs" ] && continue
    checkfail "Leftover backup script found: $f"
    CLEAN=0
done
[ "$CLEAN" -eq 1 ] && check "No leftover backup scripts"

# 11. Snapshots in GRUB config
if sudo grep -q "menuentry.*snapshot\|41_snapshots-btrfs" /boot/grub/grub.cfg; then
    check "Snapshots submenu present in /boot/grub/grub.cfg"
else
    checkfail "Snapshots submenu NOT in /boot/grub/grub.cfg"
fi

# 12. UUID detection
UUID_TEST=$(sudo btrfs subvolume show / 2>/dev/null | grep -m1 "UUID:" | awk '{print $NF}' || true)
if [ -n "$UUID_TEST" ]; then
    check "UUID detection working ($UUID_TEST)"
else
    checkfail "UUID detection failed — check awk installation"
fi

# ─── Summary ──────────────────────────────────────────────────
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

else
    # Dry-run summary
    echo ""
    echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║   DRY-RUN complete — no changes were made    ║${NC}"
    echo -e "${BOLD}${YELLOW}║   Run without --dry-run to apply fixes       ║${NC}"
    echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  Reboot now with: ${CYAN}sudo reboot${NC}"
echo ""
echo -e "  If this helped, consider buying me a coffee ☕"
echo -e "  ${CYAN}https://buymeacoffee.com/mimferpo${NC}"
echo ""

# grub-btrfs-timeshift-fix

> Fix Timeshift btrfs snapshots not showing in GRUB boot menu on Linux Mint 

[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net)
[![Tested on](https://img.shields.io/badge/tested%20on-Linux%20Mint%2022.3-87CF3E)](https://linuxmint.com)

---

##### The Problem

After installing [grub-btrfs](https://github.com/Antynea/grub-btrfs) on Linux Mint 22.3 / Ubuntu Noble / Debian, running `sudo update-grub` fails with:

```
Detecting snapshots ...
UUID of the root subvolume is not available
```

Even though Timeshift snapshots exist and are valid.

---

##### Root Cause

The script `/etc/grub.d/41_snapshots-btrfs` uses an awk regex (`\s`) that is **not supported by mawk** — the default awk on Mint. This causes the UUID detection to silently return empty and the script to fail.

**Confirmed in:** [grub-btrfs issue #421](https://github.com/Antynea/grub-btrfs/issues/421) and [grub-btrfs issue #430](https://github.com/Antynea/grub-btrfs/issues/430)

**Fix:** Install `gawk` which replaces `mawk` and handles the regex correctly — and survives grub-btrfs updates unlike script patches.

---

##### My Env

- Linux Mint 22.3 / Ubuntu Noble / Debian (or similar)
- btrfs root filesystem
- [Timeshift](https://github.com/linuxmint/timeshift) installed in btrfs mode
- At least one Timeshift snapshot already created

---

## Quick Install (Automatic)

> ⚠️ Always review scripts before running them:

```bash
# Review first
curl -fsSL https://raw.githubusercontent.com/mimferpo2/grub-btrfs-timeshift-fix/refs/heads/main/install.sh?token=GHSAT0AAAAAAD6HAGHU65KS3YMS7STISYGS2QWYNZA | less
```

##### Then run
```bash
curl -fsSL https://raw.githubusercontent.com/mimferpo2/grub-btrfs-timeshift-fix/refs/heads/main/install.sh?token=GHSAT0AAAAAAD6HAGHU65KS3YMS7STISYGS2QWYNZA | bash
```

##### Or with wget:
```bash
wget -qO- https://raw.githubusercontent.com/mimferpo2/grub-btrfs-timeshift-fix/refs/heads/main/install.sh?token=GHSAT0AAAAAAD6HAGHU65KS3YMS7STISYGS2QWYNZA | bash
```

## Manual Installation(Recommanded)

If you prefer to do everything yourself step by step.

##### Step 1 — Install grub-btrfs from source

Not available via `apt` on Mint 22.3 — must install from source:

```bash
cd ~
git clone https://github.com/Antynea/grub-btrfs.git
cd grub-btrfs
sudo make install
cd ~
rm -rf grub-btrfs
```

Note: After `make install` the cloned folder is no longer needed. Safe to delete.

---

##### Step 2 — Install required dependencies

```bash
sudo apt install inotify-tools gawk
```

- `inotify-tools` — required for the service to watch for new snapshots. Without it the service fails with `inotifywait was not found`
- `gawk` — **the real fix** — replaces `mawk` which can't handle the `\s` regex in the script. Survives grub-btrfs updates

---

##### Step 3 — Fix the service

The service by default watches `/.snapshots` but Timeshift uses a different path.

```bash
sudo systemctl edit grub-btrfsd.service
```

This opens a nano editor. Type exactly these three lines **between** the two `###` comment blocks:

```
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto
```

At the end the final edit should look exactly like this:

```
### Anything between here and the comment below will become the contents of the drop-in file

[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto

### Edits below this comment will be discarded
```
Save: Ctrl+O → Enter → Ctrl+X

> ⚠️ The empty `ExecStart=` line is required — it clears the original command first.
> ⚠️ Type between the `###` blocks only — anything below the second block is discarded.

Apply the changes:

```bash
sudo systemctl daemon-reload
sudo systemctl restart grub-btrfsd.service
sudo systemctl status grub-btrfsd.service
```

Confirm it shows **`Active: active (running)`**

---

##### Step 4 — Fix grub-btrfs config

```bash
sudo nano /etc/default/grub-btrfs/config
```

Find and change these three lines:

```bash
# 1. Change from ("@") to ("") — default silently ignores Timeshift snapshots
GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("")

# 2. Uncomment and set to ("") — don't ignore any snapshot types
GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")

# 3. Uncomment and set to "true" — needed when /boot is not a separate partition
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"
```

Save: **Ctrl+O → Enter → Ctrl+X**

> ⚠️ `GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("@")` is the silent killer — `update-grub` says "Detecting snapshots" but finds nothing with no error explaining why. This default matches and ignores Timeshift's snapshot subvolume names which end in `/@`.

---

##### Step 5 — Update GRUB

```bash
sudo update-grub
```

You should now see:

```
Detecting snapshots ...
Found snapshot: 2026-05-26 22:06:19 | timeshift-btrfs/snapshots/... | ondemand | N/A |
Found snapshot: 2026-05-26 19:00:02 | timeshift-btrfs/snapshots/... | daily    | N/A |
Found 6 snapshot(s)
```

---

##### Step 6 — Verify

```bash
sudo grep -i snapshot /boot/grub/grub.cfg
```

Should return:

```
submenu 'Linux Mint snapshots' {
```

---

##### Step 7 — Clean leftover backup scripts

If you created any backup files during troubleshooting, check and remove them:

```bash
ls /etc/grub.d/
```

If you see anything like `41_snapshots-btrfs.backup` or `41_snapshots-btrfs.bak` delete them:

```bash
sudo rm /etc/grub.d/41_snapshots-btrfs.backup
sudo rm /etc/grub.d/41_snapshots-btrfs.bak
```

> ⚠️ GRUB runs **all executable files** in `/etc/grub.d/` — backup files cause the snapshots submenu to appear **twice** at boot.

---

##### Step 8 — Reboot

```bash
sudo reboot
```

At the GRUB menu you will now see **"Linux Mint snapshots"** submenu containing all your Timeshift snapshots.

---

##### How it works after setup

```
Timeshift creates snapshot → grub-btrfsd detects it → GRUB updates automatically
```

No need to run `sudo update-grub` manually after each snapshot.

---

##### Tested on

| Distro | Version | Status |
|--------|---------|--------|
| Linux Mint | 22.3 (Zena) |  Confirmed working |

---

##### Related Discussions

- [grub-btrfs - Github issue #430](https://github.com/Antynea/grub-btrfs/issues/430)
- [Linux Mint forum thread](https://forums.linuxmint.com/viewtopic.php?t=469557)
- [Reddit discussion (Linux Mint)](https://www.reddit.com/r/linuxmint/comments/1tok814/comment/oo3xouq/)

---

##### Contributing

Pull requests welcome. Please test on your distro and report results.


---

##### Support

If this helped you, consider buying me a coffee ☕

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-mimferpo-orange)](https://buymeacoffee.com/mimferpo)


##### What's included:

- Problem description 
- Root cause explanation 
- Quick install one-liner 
- Dry-run instructions 
- Full manual step-by-step guide 
- Tested distros table 
- Related GitHub issues 

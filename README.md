# Jetson AGX TC Kernel Module Deployment

This workspace provides scripts to enable and deploy these kernel options as modules on a Jetson AGX:

- `CONFIG_NET_SCH_HTB=m`
- `CONFIG_NET_SCH_TBF=m`
- `CONFIG_NET_ACT_POLICE=m`
- `CONFIG_NET_CLS_U32=m`
- `CONFIG_NET_CLS_MATCHALL=m`

## Files

- `scripts/run_remote_tc_modules.sh`: host-side launcher (macOS/Linux) that SSHes to Jetson and runs deployment.
- `scripts/on_device_tc_modules.sh`: on-device build/install logic.
- `scripts/selftest.sh`: local shell syntax test harness.
- `auth.env.example`: template for SSH credentials.

## 1) Prepare credentials

Create `auth.env` in the repo root:

```bash
cp auth.env.example auth.env
# edit auth.env with real host/user/pass
```

## 2) Optional host dependency for non-interactive SSH

If your host has `sshpass`, the launcher will run non-interactively. Without it, SSH/SCP may prompt for password.

```bash
brew install hudochenkov/sshpass/sshpass
```

## 3) Run local script checks

```bash
bash scripts/selftest.sh
```

## 4) Deploy to Jetson (module-only first)

```bash
bash scripts/run_remote_tc_modules.sh auth.env
```

This keeps `/boot/Image` unchanged by default and only builds/installs `net/sched` modules.

## 5) Allow full Image fallback if module vermagic mismatches

```bash
bash scripts/run_remote_tc_modules.sh auth.env --allow-image-fallback
```

When fallback is used, the previous image is saved as `/boot/Image.pre-tcmods-<timestamp>`.

## 6) Quick rollback on Jetson

Each run creates a rollback bundle under:

- `/var/backups/jetson-tc-modules-<timestamp>/quick_rollback.sh`

Run on Jetson:

```bash
sudo /var/backups/jetson-tc-modules-<timestamp>/quick_rollback.sh
```

## Notes

- Source tree detection is automatic; if missing, script exits with expected paths.
- Build is done in-place on the Jetson and uses `/proc/config.gz` when available.
- Unsigned first pass: no secure boot signing steps are included.

# Hibernation on Fedora Cosmic Atomic (Framework 13)

Goal: lid close → suspend → after 5 min hibernate to the 96 GB LUKS swap
partition; resume asks for the LUKS passphrase and restores the session.

## What has to be true

| Requirement | Where it is set |
| --- | --- |
| Swap partition ≥ RAM (60 GB RAM → 96 GB) inside LUKS | Partition layout (docs/migration-guide.md Phase 1) |
| `rd.luks.uuid=<swap LUKS uuid>` on the kernel cmdline so the initramfs can unlock it before resume | `install-atomic.sh` (`--karg`) — or Anaconda |
| `resume=UUID=<swap fs uuid>` on the kernel cmdline | `install-atomic.sh` (`--karg`) — or `enable-hibernation.sh` |
| `/etc/crypttab` + `/etc/fstab` entries so swap is active after boot | `install-atomic.sh` — or Anaconda |
| `HibernateDelaySec=300` | image: `/etc/systemd/sleep.conf.d/10-hibernate.conf` |
| `HandleLidSwitch=suspend-then-hibernate` (docked too) | image: `/etc/systemd/logind.conf.d/10-lid.conf` |
| SELinux module `systemd_hibernate` | image: compiled by `configure-hibernation.sh`, source and `.pp` in `/usr/share/selinux/packages/fedora-cosmic-atomic/` |
| **Secure Boot OFF** — kernel lockdown blocks hibernation | Firmware (F2 → Security) |

Static parts live in the image (`recipes/recipe-framework.yml`); the UUID-bound
parts are per disk and are written at install time. Nothing hibernation-related
lives in `/usr/local` any more (it would be lost on upgrade).

## Verify

```bash
sudo enable-hibernation.sh --check      # every line ✓
cat /proc/cmdline | tr ' ' '\n' | grep -E 'resume|rd.luks'
swapon --show                           # 96G partition, not zram only, not a file
systemctl hibernate                     # machine powers off; power on → passphrase → session is back
systemctl suspend-then-hibernate        # then wait 5 min
```

`sudo enable-hibernation.sh` (without `--check`) repairs what it can: adds the
missing karg(s) with `rpm-ostree kargs`, installs the SELinux module. Reboot
after a karg change. It deliberately refuses to create a swapfile: if no swap
partition is active the install went wrong and should be fixed at the source.

## Troubleshooting

```bash
journalctl -b -1 -u systemd-hibernate -u systemd-suspend-then-hibernate -u systemd-logind
cat /sys/power/disk           # must not say [disabled]
cat /sys/kernel/security/lockdown   # [none] — anything else means Secure Boot is on
sudo ausearch -m avc -ts recent     # SELinux denials → sudo audit2allow -a
```

Kernel 6.11+ has a known Bluetooth black-screen-on-resume bug on the Framework;
Framework's workaround (a systemd unit that toggles Bluetooth around sleep) is at
<https://github.com/FrameworkComputer/linux-docs/tree/main/hibernation>. Add it
to `files/etc/systemd/system/` if you hit it.

## Desktop

The desktop image shares the drop-ins but has no swap partition and no lid; it
will simply never hibernate. Harmless.

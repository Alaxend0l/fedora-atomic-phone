<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 0003: Minimal, layered images; device specifics only in devices/

Status: accepted (2026-11-20, user)

## Decision
Images are as close to the basics as possible, built in layers:
1. **base** (every device): Fedora bootc core, systemd, NetworkManager,
   PipeWire, SSH, firmware loading. No desktop, nothing device-specific.
2. **desktop** (one per UI, e.g. `desktops/plasma-mobile`): Wayland compositor,
   the shell, and only the apps the shell needs or ships as its core set.
   Explicit package lists, `install_weak_deps=False`; no package groups that
   pull in desktop extras (desktop System Settings, ...). **Discover stays**
   (user's choice: the app store/updates UI), but not its background notifier
   autostart on low-RAM devices.
3. **device** (`devices/<id>/`): kernel/DT/modules, boot method, firmware
   extraction, quirks. Nothing generic goes here; anything two devices need
   moves down a layer.
4. **quality-of-life** (opt-in, later): Waydroid, extra apps, dev tools — never
   in the default image.

Primary target today is the OnePlus 12 (waffle), but nothing generic may assume
it: every device must build from the same base/desktop layers.

## Consequences
- The N100 installroot (`boot/android-bootimg/installroot/`) currently installs
  `@kde-mobile-environment` with weak deps and has Waydroid merged in: to be
  trimmed to an explicit list and Waydroid moved to an opt-in layer.
- Hiding unwanted apps (desktop System Settings) is a symptom of
  over-installing; prefer not installing them. Discover is kept on purpose.
- New packages need a reason (which layer, why); the update bot's
  watched-packages list follows the same layers.

## Implementation (branch `minimal-layers`, 2026-11-20)
- Layer folders carry `packages` lists (one reason per package, no weak
  deps; `packages.image`/`packages.devroot` for one target); bootc images
  start from base-atomic for every desktop (docs/architecture.md).
- The installroot is `make-devroot.sh --installroot oneplus-billie2
  plasma-mobile waydroid`: 763 packages on fedora:45 instead of 1168.
- Not avoidable without breaking hard deps: plasma-desktop and the desktop
  System Settings (plasma-workspace requires plasma-desktop; hidden with
  NoDisplay), QtWebEngine (Discover → qt6-qtwebview, ~250 MB).
- Plasma Mobile 6.8 uses plasma-keyboard, not Maliit.

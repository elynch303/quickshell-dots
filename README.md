<h1 align="center"> Quickshell Rise </h1>

<h4 align="center"> My Quickshell bar for Omarchy — my new Rise journey into Quickshell starts here. Enjoy! </h4>
<div align="center">

[![Stars](https://img.shields.io/github/stars/HANCORE-linux/quickshell-dots?style=for-the-badge&labelColor=000000&color=209edb&logo=github&logoColor=209edb&cacheSeconds=21600)](https://github.com/HANCORE-linux/quickshell-dots)
[![Forks](https://img.shields.io/github/forks/HANCORE-linux/quickshell-dots?style=for-the-badge&labelColor=000000&color=209edb&logo=github&logoColor=209edb&cacheSeconds=21600)](https://github.com/HANCORE-linux/quickshell-dots/network)
[![Issues](https://img.shields.io/github/issues/HANCORE-linux/quickshell-dots?style=for-the-badge&labelColor=000000&color=209edb&logo=github&logoColor=209edb&cacheSeconds=21600)](https://github.com/HANCORE-linux/quickshell-dots/issues)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-SUPPORT-000000?style=for-the-badge&labelColor=000000&color=209edb&logo=buymeacoffee&logoColor=209edb)](https://buymeacoffee.com/hancore)

</div>

<table>
  <tr>
    <td align="center"><b>Theme Picker</b></td>
    <td align="center"><b>Bar functions &amp; animations</b></td>
    <td align="center"><b>Unlockbar + Widget drag/drop</b></td>
  </tr>
  <tr>
    <td><video src="https://github.com/user-attachments/assets/160ca54f-defb-40de-a0e4-6d2e4139294d" controls="controls" style="max-width: 100%;"></video></td>
    <td><video src="https://github.com/user-attachments/assets/5e91501e-e12c-4125-be10-caa26678098d" controls="controls" style="max-width: 100%;"></video></td>
    <td><video src="https://github.com/user-attachments/assets/1971385a-6d8b-43ee-ab1d-763e2e40dbf7" controls="controls" style="max-width: 100%;"></video></td>
  </tr>
</table>

## Features

| Module | Function |
|---|---|
| Unlock &amp; reorder ✨ | unlock the bar → drag whole widget-groups to swap positions · persistent |
| Image pickers ✨ | theme · wallpaper · screenshots · videos — 3 selectable styles: Tanzaku · Hearthstone · Carousel (cached thumbnails + instant reopen) |
| Self-update ✨ | in-bar badge when a new version ships → one-click update &amp; restart |
| Package updates ✨ | system + AUR counter with a pre-install security check against the known-infected AUR list (auto-refreshed weekly) |
| Workspaces | switch · overview · persist 10 / 5 / active-only ✨ · dots / numbers / magic styles ✨ |
| Weather | current conditions · °C / °F (imperial/metric) toggle ✨ |
| Clock | time · calendar · 24h / 12h toggle ✨ |
| Mpris | media controls |
| System monitors | CPU · RAM · battery (health · cycles · size · draw ✨) · net · bt |
| Control center | quick toggles · power · Bar Functions fly-out ✨ (widget · workspace · style) |
| Bar style ✨ | border &amp; box-shadow toggles (independent) · pill radius 12 / 6 · bar on top or bottom · theme-aware border tone |
| Split groups ✨ | positional pill splits + gap animations (Stream · Surge · Bolt · Bolt 2) |
| Keybind IPC ✨ | `qs -c bar ipc call picker theme\|wallpaper\|screenshots\|videos` |
| Per-widget panels | click widget → popup |

> ✨ = new in v2.x

## Requirements

Built for **Omarchy / Hyprland** — not for plain setups without Omarchy. The bar
integrates the `omarchy-*` helpers (wifi/bluetooth/audio launchers, update,
screen recorder, voxtype) and follows the active Omarchy theme.

> **Omarchy version:** built for classic Omarchy (Waybar-based, ~3.8.x), where
> the menu keybinds call `omarchy-menu`. On Omarchy 4.0.0 (the Quickshell-based
> *omarchy-shell*) you'd disable the built-in shell bar to avoid running two
> bars, and the theme/wallpaper/menu/launcher are invoked differently — adjust
> the keybinds you pull from here accordingly.

Comes with Omarchy: Hyprland, the `omarchy-*` helpers, fonts (JetBrainsMono
Nerd Font + Material Symbols Rounded), mako. Extra:

```bash
sudo pacman -S quickshell git jq curl ttf-jetbrains-mono-nerd ttf-material-symbols-variable
```

Optional per widget: `pamixer`, `brightnessctl`, `power-profiles-daemon`,
`bluez`, `iwd` + `impala`, `hypridle`, `gpu-screen-recorder`, `voxtype`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/HANCORE-linux/quickshell-dots/main/install.sh | bash -s V1
```

The bar launches immediately so you can try it. Your previous config is backed
up to `~/.config/quickshell/bar.bak.<timestamp>` automatically (older backups
are kept).

> **Keep it across reboots:** the install starts the bar for the current
> session only — after a reboot Omarchy brings back its stock Waybar. Add the
> post-boot hook from [Autostart](#autostart) once and the bar (with all your
> settings — they persist in `~/.cache/quickshell_*`) is back at every login.

## Usage

### Click bindings
<details>

Default: left-click opens the widget panel. Exceptions:

| Widget | Left | Mid | Right | Scroll |
|---|---|---|---|---|
| Audio | panel | — | mute toggle | ±volume |
| Brightness | panel | — | — | ±brightness |
| Clock | toggle 24h / 12h | — | timezone picker | — |
| Power Profile | panel | — | cycle profile | — |
| Network / Bluetooth | panel | — | open system manager | — |
| Weather | panel (Refresh ⁄ °C↔°F) | — | force refresh | — |
| Voxtype | cycle model | — | config | — |
| Workspace | click dot: switch | — | overview | — |
| Mpris | ‹ play › buttons inline | — | toggle panel | — |
| Tray (bar) | toggle tray panel | — | — | — |
| Tray icon | activate | context menu | hide icon | — |

**Double-click** an empty bar area → unlock &amp; drag widget-groups to reorder
(`Esc` / click the dimmed backdrop to lock).

</details>

### Keybindings — theme / wallpaper picker on the Omarchy hotkeys (optional)
<details>

Omarchy binds its theme/wallpaper menus (shown via walker) to:

| Action | Key | Omarchy default |
|---|---|---|
| Theme | `Super`+`Shift`+`Ctrl`+`Space` | `omarchy-menu theme` |
| Wallpaper | `Super`+`Ctrl`+`Space` | `omarchy-menu background` |

To make those keys open the bar's own pickers instead (and unbind walker for
them), add this to **your own** `~/.config/hypr/bindings.conf` — Omarchy
sources it *after* its defaults, so it survives `omarchy update`:

```conf
# quickshell-dots: route the theme/wallpaper hotkeys to the bar's pickers
unbind = SUPER SHIFT CTRL, SPACE
unbind = SUPER CTRL, SPACE
bindd  = SUPER SHIFT CTRL, SPACE, Theme picker,     exec, qs -c bar ipc call picker theme
bindd  = SUPER CTRL, SPACE,       Wallpaper picker, exec, qs -c bar ipc call picker wallpaper
```

Then `hyprctl reload`. The `unbind` lines stop walker's menu from *also* firing
on those keys; delete the block to restore the Omarchy default. Walker stays
your launcher everywhere else — only these two keys change.

> Different Omarchy version? Check
> `~/.local/share/omarchy/default/hypr/bindings/utilities.conf` for the
> `omarchy-menu theme` / `omarchy-menu background` lines and match whatever
> keys are bound there.

(Also available: `qs -c bar ipc call picker screenshots` and `… videos`.)

</details>

### Autostart
<details>
<summary>Post-boot hook (recommended — brings the bar back at every login)</summary>

```bash
mkdir -p ~/.config/omarchy/hooks/post-boot.d
curl -fsSL -o ~/.config/omarchy/hooks/post-boot.d/quickshell-rise \
  https://raw.githubusercontent.com/HANCORE-linux/quickshell-dots/main/contrib/post-boot.d/quickshell-rise
chmod +x ~/.config/omarchy/hooks/post-boot.d/quickshell-rise
```

Remove: `rm -f ~/.config/omarchy/hooks/post-boot.d/quickshell-rise`

</details>

## Updating

The bar keeps itself current: an update badge appears in the bar when a new
version is released — click it to review the changes and apply with one click.

Package updates run through the ArchUpdater panel with a per-package verdict
(OK · review · blocked) checked against the known-infected AUR list, which a
weekly timer keeps up to date. Blocked packages are excluded from the update
command automatically.

## Uninstall

One command (works for any installed version) — stops the bar, removes the
theme hook, post-boot hook and timers, and brings back your previous config
from the backup:

```bash
curl -fsSL https://raw.githubusercontent.com/HANCORE-linux/quickshell-dots/main/uninstall.sh | bash
```

## Repo structure
<details>

Each folder under `versions/` is a complete, self-contained bar.

```
versions/V1/
├── shell.qml        # entry point
├── Bar.qml          # layout + dynamic split pills
├── Theme.qml        # colors, state, flags
├── Palette.js       # reads Omarchy colors.toml
├── IconMap.js       # icon name → codepoint
├── assets/          # logo
├── modules/         # bar widgets  (*Widget.qml)
└── panels/          # popups       (*Panel.qml, TooltipOverlay)
```

</details>

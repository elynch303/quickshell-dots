//@ pragma UseQApplication
import Quickshell
import QtQuick
import "panels"

ShellRoot {
    id: root

    Theme { id: theme }

    // Bar { root: theme }              // ← original (revert: uncomment, comment BarSlot)
    BarSlot { root: theme }             // ← WIP slot-based port (left region)
    TooltipOverlay { root: theme }
    CalendarPopup { root: theme }
    ArchUpdaterPanel { root: theme }
    PowerProfilePanel { root: theme }
    MemoryPanel { root: theme }
    CpuPanel { root: theme }
    VolumePanel { root: theme }
    TrayPanel { root: theme }
    NotificationPanel { root: theme }
    NetworkPanel { root: theme }
    BluetoothPanel { root: theme }
    BatteryPanel { root: theme }
    BrightnessPanel { root: theme }
    MprisPanel { root: theme }
    WeatherPanel { root: theme }
    WorkspacePanel { root: theme }
    ControlPanel { root: theme }
    TrayMenu { root: theme }
    // Picker variants: only the selected pickerStyle is instantiated — the other
    // four full-screen PanelWindows never exist until the style is switched.
    // (each panel already early-returns when its style isn't active; LazyLoader
    //  removes the dormant window + bindings entirely.)
    LazyLoader { active: theme.pickerStyle === "tanzaku" || theme.pickerStyle === "";  ImageCarouselPanel       { root: theme } }
    LazyLoader { active: theme.pickerStyle === "hearthstone";                           ImageCarouselHearthstone { root: theme } }
    LazyLoader { active: theme.pickerStyle === "carousel";                              ImageCarouselCarousel    { root: theme } }
    LazyLoader { active: theme.pickerStyle === "tanzaku" || theme.pickerStyle === "";  MediaBrowserPanel        { root: theme } }
    LazyLoader { active: theme.pickerStyle === "hearthstone";                           MediaBrowserHearthstone  { root: theme } }
    LazyLoader { active: theme.pickerStyle === "carousel";                              MediaBrowserCarousel     { root: theme } }
}

# XMB Menu for Omarchy

A full-screen, PS3-inspired cross-media-bar interface for Omarchy's main menu.
It preserves the existing menu structure, application launcher, providers,
actions, search, and `SUPER + SPACE` shortcut while replacing the presentation
with an animated horizontal-and-vertical XMB layout.

![XMB Menu preview](preview.png)

## Features

- Fixed-position horizontal category carousel
- Inline vertical item carousel
- Global search across menu entries and applications
- Animated translucent background ribbons
- Keyboard, mouse-wheel, touchpad, and click navigation
- Focused-monitor presentation
- Existing Omarchy top bar remains unchanged
- Reversible replacement for the packaged `omarchy.menu`

## Requirements

- Omarchy 4 / Quattro with the Quickshell plugin system
- No third-party packages or services

The plugin reads Omarchy's existing menu definitions and uses the commands and
application data already provided by the system. If Omarchy does not inject an
app library into a third-party menu, XMB loads the host's `qs.services.AppLibrary`
as a fallback. This preserves Omarchy's app filtering, icon lookup, and launch
feedback, but depends on that internal host module remaining available.

## Install

```bash
omarchy plugin add https://github.com/surfacedP/omarchy-xmb-menu.git --enable
```

Enabling the plugin routes the existing Omarchy menu shortcut to the XMB
interface. The packaged menu is not modified.

## Controls

- Left / Right: choose a root category
- Up / Down: choose an item
- Mouse wheel / two-finger touchpad: scroll using the system sensitivity
- Click: open an item or choose a category
- Enter / Right: open or run
- Left / Backspace: go back inside nested menus
- Escape or `SUPER + SPACE`: close
- Type: search all menu entries and applications
- Delete: uninstall a selected application, with confirmation

## Update

```bash
omarchy plugin update io.github.surfacedp.xmb-menu
```

## Disable or remove

Disable the XMB interface while keeping it installed:

```bash
omarchy plugin disable io.github.surfacedp.xmb-menu
```

Remove it completely:

```bash
omarchy plugin remove io.github.surfacedp.xmb-menu
```

Disabling or removing the plugin restores the packaged `omarchy.menu`. Your
Omarchy menu configuration and top bar are not deleted or overwritten.

## Configuration

The plugin deliberately uses the standard Omarchy menu configuration, including
user additions in `~/.config/omarchy/extensions/omarchy-menu.jsonc`. It does not
introduce a separate menu database.

## Attribution and trademarks

Thanks to [gbflores](https://github.com/gbflores) for diagnosing and proposing
an empty Apps menu fix in [PR #3](https://github.com/surfacedP/omarchy-xmb-menu/pull/3),
and to [LeonardoM011](https://github.com/LeonardoM011) for identifying the Qt
manifest-sequence issue and proposing reuse of the host's app library in the
[PR discussion](https://github.com/surfacedP/omarchy-xmb-menu/pull/3#issuecomment-5759495158).

This project is derived from the MIT-licensed Omarchy menu implementation by
David Heinemeier Hansson and contributors. The XMB-inspired visual presentation
and plugin modifications are maintained by Patrick Brook.

"PlayStation" and "PS3" are trademarks of Sony Interactive Entertainment.
This unofficial community project is not affiliated with or endorsed by Sony.
No Sony artwork, firmware, or other proprietary assets are included.

## License

[MIT](LICENSE)

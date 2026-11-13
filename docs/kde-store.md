# KDE Store listing

Paste the fields below into the KDE Store submission form. The description is plain text with dash
bullets, because the store renders it without a Markdown parser.

## Fields

| Field | Value |
|---|---|
| Name | LocalSend |
| Summary | Send and receive files on your local network from the Plasma panel |
| Category | Plasma 6 Applets |
| License | MIT |
| Version | 0.3.0 |
| Homepage | https://github.com/motangpuar/kde-applet-localsend |
| Source code | https://github.com/motangpuar/kde-applet-localsend |
| Changelog | https://github.com/motangpuar/kde-applet-localsend/blob/main/CHANGELOG.md |
| Release asset | https://github.com/motangpuar/kde-applet-localsend/releases/latest |
| Download file | io.github.localsend.plasmoid-0.3.0.plasmoid |
| Preview | docs/icon-preview.png, plus two popup screenshots |

## Description

LocalSend for Plasma. The applet speaks the LocalSend v2.2 protocol itself, so files move between this
machine and any official LocalSend app on the same network without running the Flutter application.

What it does

- Lists the LocalSend devices that announce themselves on the local network, with alias, address and
  operating system.
- Sends files to a device from the panel popup. The other side confirms in its own app, or accepts
  automatically once you mark it as a trusted device.
- Receives transfers over HTTPS with the same certificate and PIN rules as the reference
  implementation. Incoming files land in ~/Downloads/LocalSend, or the directory you configure.
- Keeps a transfer history with direction, peer, size, duration and average rate, grouped by day.
  Click a file to open it, right click for Open File or Open File Location with the file selected in
  Dolphin.
- Shows the device count in the panel, and reports new prompts through a desktop notification and a
  tray badge. Accept or decline straight from the notification.
- Queues outgoing transfers, so a second send waits for the first instead of competing for the link.
  Retry a failed transfer with one click and only the files that failed are sent again.
- Picks up devices over mDNS as well as the LocalSend announcement, which keeps the list working on
  networks that drop multicast announcements.
- Uses the packaged icon, any icon installed on the system through the icon picker, or an SVG or PNG
  of your own.

How it works

- Backend: one Python 3 process, localsendd, that owns multicast and mDNS discovery and TCP port
  53317. It is the only part that speaks the protocol.
- Control plane: newline delimited JSON over a Unix socket in XDG_RUNTIME_DIR. No D-Bus, no systemd
  unit, no root.
- Lifecycle: the widget starts the backend when it is needed and stops it when the widget is removed or
  the master switch is off. Runtime files stay under ~/.local/share/localsend-applet and
  ~/.config/localsendd, so uninstalling the plasmoid removes the whole install.
- Scripts: localsendctl answers with JSON for state, peers, send, respond, cancel, history, scan and
  favorites if you would rather drive transfers from a shell.
- Requirements: Plasma 6, python3, and free UDP multicast plus TCP port 53317 on the local network.

Privacy

Discovery is multicast and mDNS inside the local network and transfers go directly between devices.
There is no account, no cloud relay and no telemetry. The TLS certificate and key are generated locally on first
start.

Limitations

- Text and clipboard messages from protocol v2.1 are not implemented, file transfers only.
- Dropping files onto the popup is not implemented. Use the folder button or the per device Send action.
- One backend per host. Two LocalSend daemons on the same machine cannot discover each other, because
  the kernel load balances multicast between them.

Source, issues and the full changelog: https://github.com/motangpuar/kde-applet-localsend

#!/usr/bin/env python3
"""nsscreen.py PNG STATE... - exit 0 when the screenshot shows one of the
NeXTSTEP installation's screens (scripts/board/nextstep-install.sh), and
print which. The screenshot is an OBS grab (scripts/board/osd.sh shot) of
the MiSTer's HDMI output: 1280x720, the core's 1024x768 picture scaled into
x 298-982, y 104-616.

States:
  netpanel   "Configuring Network" ("No response from network configuration
             server"): a white panel with a black title bar in the middle
  configure  Configure.app's "Summary of Devices" (title bar at the top)
  install    BuildDisk's "Install NEXTSTEP" panel (title bar, the packages
             list's teal header)
  nodisks    BuildDisk's "No Disks" alert (BuildDisk in its normal mode)
  done       "NEXTSTEP has been installed successfully ... click Restart",
             an alert over the Install panel
  welcome    loginwindow's Welcome panel (language and keyboard)
  confirm    its "Are you sure" alert over it
  workspace  the Workspace (its main menu at the top left)
  logout     the Workspace's "Do you really want to log out?" (Cancel,
             Power Off, Log Out)
  nspanel    the NEXTSTEP panel on the grey background (starting up, or
             "System shutdown. It's safe to turn off the computer")
"""
import sys
from PIL import Image


def black_run(px, y, x0, x1):
    return sum(1 for x in range(x0, x1, 2) if max(px[x, y]) < 40) / ((x1 - x0) / 2)


def states(px):
    out = []
    workspace = black_run(px, 106, 300, 358) > 0.8
    if black_run(px, 302, 540, 740) > 0.5 and px[640, 400] == (255, 255, 255):
        out.append("netpanel")
    if black_run(px, 112, 470, 720) > 0.5 and min(px[600, 360]) > 190 and not workspace:
        out.append("configure")
    t = px[640, 280]
    if black_run(px, 202, 525, 755) > 0.5 and t[1] > t[0] + 10:
        out.append("install")
    panel_behind = abs(px[640, 365][2] - px[640, 365][0]) > 15 and px[640, 365][1] > 180
    # "No disks that you can build ..." starts at the alert's left edge;
    # "Do you really want to log out?" is centred
    left_text = any(max(px[x, y]) < 120 for x in range(526, 570) for y in range(283, 292))
    if black_run(px, 220, 525, 755) > 0.5 and black_run(px, 202, 525, 755) < 0.2 \
            and (left_text or not workspace):
        out.append("done" if panel_behind and black_run(px, 211, 525, 755) > 0.5 else "nodisks")
    grey = px[400, 200] == (106, 106, 106)
    panel = [px[470, 300], px[800, 300], px[460, 182]]
    if all(c == (217, 217, 217) for c in panel):
        out.append("confirm" if black_run(px, 229, 520, 735) > 0.5 else "welcome")
    if workspace:
        if black_run(px, 220, 525, 755) > 0.5:
            if not left_text:
                out.append("logout")
        else:
            out.append("workspace")
    if grey and px[640, 302] == (237, 237, 237) and px[640, 360] == (165, 165, 165):
        out.append("nspanel")
    return out


def main():
    px = Image.open(sys.argv[1]).convert("RGB").load()
    found = states(px)
    print(" ".join(found) if found else "unknown")
    sys.exit(0 if set(found) & set(sys.argv[2:]) else 1)


if __name__ == "__main__":
    main()

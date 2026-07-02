# dmgbuild settings — the drag-to-Applications installer window.
# Usage: dmgbuild -s dmg-settings.py -D app=build/Context.app "Context" out.dmg
import os.path

app = defines.get("app", "build/Context.app")  # noqa: F821 (defines injected by dmgbuild)
appname = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}

badge_icon = "AppIcon.icns"
background = "dmg-background.tiff"
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    appname: (165, 215),
    "Applications": (495, 215),
}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

format = "UDZO"

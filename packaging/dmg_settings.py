# dmgbuild settings for a drag-to-Applications installer window.
# Values come in through -D: app=<path to .app>, background=<path to .tiff/.png>
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

icon = os.path.join(application, "Contents/Resources/AppIcon.icns")
background = defines["background"]  # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
icon_size = 112
text_size = 13
arrange_by = None
label_pos = "bottom"

icon_locations = {
    appname: (170, 190),
    "Applications": (470, 190),
}

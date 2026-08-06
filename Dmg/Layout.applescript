-- Arranges the mounted DMG's Finder window: background picture, window size,
-- icon size and the two icon slots (app + Applications drop target).
--
-- Invoked by the Makefile `dmg` target:
--   osascript Dmg/Layout.applescript <volName> <winW> <winH> <iconSize> \
--             <appX> <appY> <dropX> <dropY> <appBundleName>
--
-- Positions are in Finder coordinates: origin at the window content's top-left,
-- y growing downward — the same convention Dmg/CreateBackground.swift draws in.

on run argv
	set volName to item 1 of argv
	set winW to (item 2 of argv) as integer
	set winH to (item 3 of argv) as integer
	set iconSize to (item 4 of argv) as integer
	set appX to (item 5 of argv) as integer
	set appY to (item 6 of argv) as integer
	set dropX to (item 7 of argv) as integer
	set dropY to (item 8 of argv) as integer
	set appName to item 9 of argv

	tell application "Finder"
		tell disk volName
			open

			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			-- Finder's window bounds include the title bar, so the content area
			-- (where the background picture is drawn) needs it added back on
			set titleBarHeight to 28
			set the bounds of container window to {200, 140, 200 + winW, 140 + winH + titleBarHeight}

			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to iconSize
			set text size of viewOptions to 13
			set label position of viewOptions to bottom
			set shows item info of viewOptions to false
			set background picture of viewOptions to file ".background:background.tiff"

			set position of item appName of container window to {appX, appY}
			set position of item "Applications" of container window to {dropX, dropY}

			-- Close/reopen forces Finder to commit the layout to .DS_Store
			close
			open
			update without registering applications
			delay 1
		end tell
	end tell
end run

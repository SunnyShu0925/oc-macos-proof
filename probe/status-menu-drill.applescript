-- Open the shipped status menu and drill to a session's Thinking/Verbose
-- submenu, then dump every item's accessibility mark so the proof records
-- which level (if any) the app checked.
--
-- argv 1: "Thinking" or "Verbose"
-- argv 2: "1" to click the "Off" item after dumping (applies the override)
--
-- Returns the dump text. The menu is left open (unless Off was clicked) so the
-- shell can capture the popup window that is on screen.

on run argv
	set targetTitle to item 1 of argv
	set clickOff to false
	try
		set clickOff to (item 2 of argv is "1")
	end try

	set out to ""
	tell application "System Events"
		set procs to every process whose name is "OpenClaw"
		if (count of procs) = 0 then return "NO_OPENCLAW_PROCESS"
		set p to item 1 of procs
		tell p
			set frontmost to true
			delay 0.8
			-- Close any menu left open by an earlier stage.
			try
				key code 53
			end try
			delay 0.8
			if (count of menu bars) < 2 then return "NO_MENUBAR2"
			set si to menu bar item 1 of menu bar 2
			click si
			delay 2
			set m to menu 1 of si
			set out to out & "ROOT_ITEMS=" & ((name of every menu item of m) as string) & linefeed

			-- A session row is the item whose submenu owns the Thinking item.
			set sessionIndex to 0
			repeat with i from 1 to (count of menu items of m)
				try
					set candidate to menu 1 of (menu item i of m)
					set candidateNames to (name of every menu item of candidate) as string
					if candidateNames contains targetTitle then
						set sessionIndex to i
						exit repeat
					end if
				end try
			end repeat
			if sessionIndex = 0 then return out & "NO_SESSION_ITEM" & linefeed

			set sessionItem to menu item sessionIndex of m
			set out to out & "SESSION_ROW=" & sessionIndex & " name=" & (name of sessionItem as string) & linefeed
			click sessionItem
			delay 1.5
			set sessionMenu to menu 1 of sessionItem
			set out to out & "SESSION_ITEMS=" & ((name of every menu item of sessionMenu) as string) & linefeed

			set targetIndex to 0
			repeat with j from 1 to (count of menu items of sessionMenu)
				if (name of menu item j of sessionMenu as string) is targetTitle then set targetIndex to j
			end repeat
			if targetIndex = 0 then return out & "NO_TARGET_ITEM" & linefeed

			click (menu item targetIndex of sessionMenu)
			delay 1.5
			set targetMenu to menu 1 of (menu item targetIndex of sessionMenu)
			set out to out & "OPEN_MENU=" & targetTitle & linefeed
			repeat with k from 1 to (count of menu items of targetMenu)
				set mi to menu item k of targetMenu
				set itemName to ""
				try
					set itemName to (name of mi as string)
				end try
				set markChar to "<none>"
				try
					set v to value of attribute "AXMenuItemMarkChar" of mi
					if v is missing value then
						set markChar to "<missing>"
					else
						set markChar to v as string
					end if
				end try
				set markOn to "<none>"
				try
					set markOn to (value of attribute "AXMenuItemMark" of mi) as string
				end try
				set sel to "<none>"
				try
					set sel to (selected of mi) as string
				end try
				set out to out & "ITEM[" & k & "] name=" & itemName & " markChar=" & markChar & " mark=" & markOn & " selected=" & sel & linefeed
				if clickOff and itemName is "Off" then
					click mi
					set out to out & "CLICKED_OFF" & linefeed
					set clickOff to false
				end if
			end repeat
		end tell
	end tell
	return out
end run

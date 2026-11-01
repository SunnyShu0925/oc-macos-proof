-- Drill into a session row's Thinking/Verbose submenu inside the status menu
-- that the packaged app opened with --debug-open-menu, then dump every item's
-- accessibility mark so the proof records which level the app checked.
--
-- argv 1: "Thinking" or "Verbose"
-- argv 2: "1" to click the "Off" item after dumping (applies the override)
--
-- The menu must already be on screen. Left-clicking the status item opens the
-- dashboard, so this script never clicks the status item itself.

on menuItemCount(si)
	set n to 0
	try
		set m to menu 1 of si
		set n to (count of menu items of m)
	end try
	return n
end menuItemCount

on run argv
	set targetTitle to item 1 of argv
	set clickOff to false
	try
		set clickOff to (item 2 of argv is "1")
	end try

	set appPid to 0
	try
		set appPid to (system attribute "APP_PID") as integer
	end try

	set out to ""
	tell application "System Events"
		set matches to {}
		if appPid > 0 then set matches to (every process whose unix id is appPid)
		if (count of matches) = 0 then set matches to (every process whose name contains "OpenClaw")
		if (count of matches) = 0 then return "NO_OPENCLAW_PROCESS"
		set p to item 1 of matches
		tell p
			try
				set frontmost to true
			end try
			delay 1
			set out to out & "MENUBARS=" & (count of menu bars as string) & linefeed
			if (count of menu bars) < 2 then return out & "NO_MENUBAR2"
			set si to menu bar item 1 of menu bar 2
			set count0 to my menuItemCount(si)
			set out to out & "STATUS_ITEM_POS=" & (position of si as string) & linefeed
			if count0 = 0 then return out & "MENU_NOT_OPEN" & linefeed
			set out to out & "MENU_OPEN items=" & (count0 as string) & linefeed

			set m to menu 1 of si
			set out to out & "ROOT_ITEMS=" & ((name of every menu item of m) as string) & linefeed

			-- A session row is the item whose submenu owns the Thinking item.
			set sessionIndex to 0
			set sessionNames to ""
			repeat with attempt from 1 to 8
				set m to menu 1 of si
				repeat with i from 1 to (count of menu items of m)
					try
						set candidate to menu 1 of (menu item i of m)
						set candidateNames to (name of every menu item of candidate) as string
						if candidateNames contains targetTitle then
							set sessionIndex to i
							set sessionNames to candidateNames
							exit repeat
						end if
					end try
				end repeat
				if sessionIndex > 0 then exit repeat
				delay 2
			end repeat
			if sessionIndex = 0 then return out & "NO_SESSION_ITEM items=" & (count of menu items of m as string) & linefeed

			set sessionItem to menu item sessionIndex of m
			set out to out & "SESSION_ROW=" & sessionIndex & " items=" & sessionNames & linefeed
			click sessionItem
			delay 1.5
			set sessionMenu to menu 1 of sessionItem
			if ((name of every menu item of sessionMenu) as string) is "" then
				try
					perform action "AXShowMenu" of sessionItem
				end try
				delay 1.5
				set sessionMenu to menu 1 of sessionItem
			end if
			set out to out & "SESSION_ITEMS=" & ((name of every menu item of sessionMenu) as string) & linefeed

			set targetIndex to 0
			repeat with j from 1 to (count of menu items of sessionMenu)
				if (name of menu item j of sessionMenu as string) is targetTitle then set targetIndex to j
			end repeat
			if targetIndex = 0 then return out & "NO_TARGET_ITEM" & linefeed

			click (menu item targetIndex of sessionMenu)
			delay 1.5
			set targetMenu to menu 1 of (menu item targetIndex of sessionMenu)
			if ((name of every menu item of targetMenu) as string) is "" then
				try
					perform action "AXShowMenu" of (menu item targetIndex of sessionMenu)
				end try
				delay 1.5
				set targetMenu to menu 1 of (menu item targetIndex of sessionMenu)
			end if
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

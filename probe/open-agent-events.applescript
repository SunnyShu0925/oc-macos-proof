-- Open the shipped app's Debug -> Open Agent Events window through the
-- status menu, using only public accessibility APIs. Prints a step log and
-- ends with CLICKED_OPEN_AGENT_EVENTS when the menu item was activated.
on run argv
	set appPid to 0
	try
		set appPid to (system attribute "APP_PID") as integer
	on error
		set appPid to 0
	end try
	set out to ""
	tell application "System Events"
		set matches to {}
		if appPid > 0 then set matches to (every process whose unix id is appPid)
		if (count of matches) = 0 then set matches to (every process whose name contains "OpenClaw")
		if (count of matches) = 0 then return "NO_PROCESS_FOUND"
		set p to item 1 of matches
		tell p
			set out to out & "PROC_NAME=" & (name as string) & linefeed
			set out to out & "PID=" & (unix id as string) & linefeed
			set out to out & "MENUBARS=" & (count of menu bars as string) & linefeed
			set out to out & "WINDOWS=" & (count of windows as string) & linefeed
			repeat with w in windows
				try
					set out to out & "WIN name=" & (name of w as string) & linefeed
				end try
			end repeat
			if (count of menu bars) < 2 then return out & "NO_MENUBAR2"

			set statusItem to menu bar item 1 of menu bar 2
			-- The status menu can already be open (the app opens it for
			-- screenshots when launched with --debug-open-menu).
			set menuOpen to false
			try
				set probeMenu to menu 1 of statusItem
				set probeNames to (name of every menu item of probeMenu) as string
				set menuOpen to true
				set out to out & "MENU_ALREADY_OPEN=" & probeNames & linefeed
			end try
			if not menuOpen then
				try
					click statusItem
					delay 2
					set out to out & "CLICKED_STATUS_ITEM" & linefeed
				on error errMsg number errNum
					set out to out & "STATUS_CLICK_ERR=" & errMsg & " (" & errNum & ")" & linefeed
				end try
			end if

			set clicked to false
			repeat with attempt from 1 to 12
				if not clicked then
					try
						set m to menu 1 of statusItem
						set names to (name of every menu item of m) as string
						set out to out & "MENU[" & attempt & "]=" & names & linefeed
						set dbgIndex to 0
						repeat with i from 1 to (count of menu items of m)
							if (name of menu item i of m as string) is "Debug" then set dbgIndex to i
						end repeat
						if dbgIndex = 0 then
							set out to out & "NO_DEBUG_ITEM" & linefeed
						else
							click (menu item dbgIndex of m)
							delay 1
							set sub to menu 1 of (menu item dbgIndex of m)
							set subNames to (name of every menu item of sub) as string
							set out to out & "SUB=" & subNames & linefeed
							set targetIndex to 0
							repeat with j from 1 to (count of menu items of sub)
								if (name of menu item j of sub as string) starts with "Open Agent Events" then set targetIndex to j
							end repeat
							if targetIndex = 0 then
								set out to out & "NO_EVENTS_ITEM" & linefeed
							else
								click (menu item targetIndex of sub)
								set clicked to true
								set out to out & "CLICKED_OPEN_AGENT_EVENTS" & linefeed
							end if
						end if
					on error errMsg number errNum
						set out to out & "ERR[" & attempt & "]=" & errMsg & " (" & errNum & ")" & linefeed
					end try
				end if
				if clicked then exit repeat
				delay 2
			end repeat

			delay 2
			set out to out & "WINDOWS_AFTER=" & (count of windows as string) & linefeed
			repeat with w in windows
				try
					set out to out & "WIN_AFTER name=" & (name of w as string) & linefeed
				end try
			end repeat
		end tell
	end tell
	return out
end run

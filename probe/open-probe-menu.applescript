-- Click the status bar item of the probe app so its NSMenu opens and stays
-- open while the shell captures pixels.
on run argv
	set appPid to 0
	try
		set appPid to (item 1 of argv) as integer
	on error
		set appPid to 0
	end try
	set out to ""
	tell application "System Events"
		set matches to {}
		if appPid > 0 then set matches to (every process whose unix id is appPid)
		if (count of matches) = 0 then set matches to (every process whose name contains "MenuProbe")
		if (count of matches) = 0 then return "NO_PROCESS_FOUND"
		set p to item 1 of matches
		tell p
			set out to out & "PROC=" & (name as string) & " PID=" & (unix id as string) & linefeed
			set out to out & "MENUBARS=" & (count of menu bars as string) & linefeed
			if (count of menu bars) < 2 then return out & "NO_MENUBAR2"
			set si to menu bar item 1 of menu bar 2
			try
				set m to menu 1 of si
				set out to out & "ALREADY_OPEN=" & ((name of every menu item of m) as string) & linefeed
				return out
			end try
			try
				click si
			on error errMsg number errNum
				set out to out & "CLICK_ERR=" & errMsg & " (" & errNum & ")" & linefeed
			end try
			delay 1.5
			try
				set m to menu 1 of si
				set out to out & "OPEN_ITEMS=" & ((name of every menu item of m) as string) & linefeed
			on error errMsg number errNum
				set out to out & "READ_ERR=" & errMsg & " (" & errNum & ")" & linefeed
			end try
		end tell
	end tell
	return out
end run

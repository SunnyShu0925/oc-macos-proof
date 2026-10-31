-- Dump the accessibility text of the Agent Events window.
on run argv
	set appPid to 0
	try
		set appPid to (system attribute "APP_PID") as integer
	on error
		set appPid to 0
	end try
	tell application "System Events"
		set matches to {}
		if appPid > 0 then set matches to (every process whose unix id is appPid)
		if (count of matches) = 0 then set matches to (every process whose name contains "OpenClaw")
		if (count of matches) = 0 then return "NO_PROCESS_FOUND"
		set p to item 1 of matches
		tell p
			set targetWindow to missing value
			repeat with w in windows
				try
					if (name of w as string) is "Agent Events" then set targetWindow to w
				end try
			end repeat
			if targetWindow is missing value then return "NO_WINDOW"
			set out to ""
			repeat with e in (entire contents of targetWindow)
				try
					if (role of e is "AXStaticText") then
						set v to value of e
						if v is not missing value then set out to out & (v as text) & linefeed
					end if
				end try
			end repeat
			return out
		end tell
	end tell
end run

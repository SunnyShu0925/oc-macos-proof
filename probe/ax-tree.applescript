-- Dump the accessibility tree of the Agent Events window with roles and values
-- so the proof can show what the shipped window exposes.
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
			set out to "WINDOW=Agent Events" & linefeed
			set elems to (entire contents of targetWindow)
			set out to out & "ELEMENTS=" & ((count of elems) as string) & linefeed
			repeat with e in elems
				try
					set r to (role of e as string)
					set v to ""
					try
						set v to (value of e as string)
					end try
					if v is "" then
						try
							set v to (description of e as string)
						end try
					end if
					if v is "" then
						try
							set v to (title of e as string)
						end try
					end if
					set out to out & r & " :: " & v & linefeed
				on error
					-- Elements that reject attribute reads are not evidence either way.
				end try
			end repeat
			return out
		end tell
	end tell
end run

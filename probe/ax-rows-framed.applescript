-- Dump the shipped Agent Events window's run-label rows with their frames.
-- SwiftUI keeps clipped rows in the AX tree, so a row only counts as rendered
-- when its label frame sits inside the AXScrollArea viewport.
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
			set wp to position of targetWindow
			set ws to size of targetWindow
			set out to out & "WIN " & (item 1 of wp as text) & " " & (item 2 of wp as text) & " " & (item 1 of ws as text) & " " & (item 2 of ws as text) & linefeed
			repeat with e in (entire contents of targetWindow)
				try
					if (role of e is "AXScrollArea") then
						set sp to position of e
						set ss to size of e
						set out to out & "SCROLL " & (item 1 of sp as text) & " " & (item 2 of sp as text) & " " & (item 1 of ss as text) & " " & (item 2 of ss as text) & linefeed
					end if
				end try
				try
					if (role of e is "AXStaticText") then
						set v to value of e
						if v is not missing value then
							if (v as text) starts with "run " then
								set ep to position of e
								set es to size of e
								set out to out & "ROW " & (item 1 of ep as text) & " " & (item 2 of ep as text) & " " & (item 1 of es as text) & " " & (item 2 of es as text) & " " & (v as text) & linefeed
							end if
						end if
					end if
				end try
			end repeat
			return out
		end tell
	end tell
end run

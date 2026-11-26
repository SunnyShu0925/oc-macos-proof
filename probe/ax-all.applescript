-- Dump every window of the OpenClaw app with roles and values.
-- The onboarding window has no fixed title, so this walks all windows instead of
-- matching one name; the caller greps the text it expects.
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
		set out to ""
		tell p
			set out to out & "WINDOW_COUNT=" & ((count of windows) as string) & linefeed
			repeat with w in windows
				try
					set wname to ""
					try
						set wname to (name of w as string)
					end try
					set out to out & "=== WINDOW: " & wname & " ===" & linefeed
					set elems to (entire contents of w)
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
							if v is "" then
								try
									set v to (name of e as string)
								end try
							end if
							if v is not "" then set out to out & r & " :: " & v & linefeed
						end try
					end repeat
				end try
			end repeat
		end tell
		return out
	end tell
end run

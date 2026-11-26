-- Click the onboarding "Next" button so the run reaches the connection page,
-- which is the only page that calls refreshLocalGatewayProbe().
-- SwiftUI buttons surface their label on different attributes depending on
-- version, so all of title/description/value are tried.
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
		set seen to {}
		tell p
			repeat with w in windows
				try
					set elems to (entire contents of w)
					repeat with e in elems
						try
							set r to (role of e as string)
							if r is "AXButton" then
								set label to ""
								try
									set label to (title of e as string)
								end try
								if label is "" then
									try
										set label to (description of e as string)
									end try
								end if
								if label is "" then
									try
										set label to (value of e as string)
									end try
								end if
								if label is not "" then set end of seen to label
								if label is "Next" or label is "Continue" then
									click e
									return "CLICKED:" & label
								end if
							end if
						end try
					end repeat
				end try
			end repeat
		end tell
		return "NO_NEXT_BUTTON;BUTTONS=" & (seen as string)
	end tell
end run

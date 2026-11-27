-- Click the shipped app's status menu -> Debug -> Restart Gateway using only
-- public accessibility APIs. This mirrors probe/open-agent-events.applescript
-- but targets the real shipped Debug entrypoint (DebugActions.restartGateway,
-- which calls GatewayProcessManager.shared.setActive(true) after a stop).
--
-- Prints a step log and ends with CLICKED_RESTART_GATEWAY when the item was
-- activated. APP_PID (env) selects the exact app process. The status menu may
-- already be expanded when the app was launched with --debug-open-menu.
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
			try
				set out to out & "STATUS_ITEM=" & (name of statusItem as string) & linefeed
			end try

			-- --debug-open-menu can leave the menu already open on launch.
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
								if (name of menu item j of sub as string) starts with "Restart Gateway" then set targetIndex to j
							end repeat
							if targetIndex = 0 then
								set out to out & "NO_RESTART_ITEM" & linefeed
							else
								click (menu item targetIndex of sub)
								set clicked to true
								set out to out & "CLICKED_RESTART_GATEWAY" & linefeed
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

			-- Re-open the status menu, dump its full AX contents (the header
			-- renders a failed-probe diagnostic), then open Connection... so the
			-- Debug pane shows the gateway status label and stdout/stderr log.
			set menuOpenAfter to false
			try
				set mAfter to menu 1 of statusItem
				set menuOpenAfter to true
			end try
			if not menuOpenAfter then
				try
					click statusItem
					delay 2
					set menuOpenAfter to true
				on error errMsg number errNum
					set out to out & "REOPEN_ERR=" & errMsg & " (" & errNum & ")" & linefeed
				end try
			end if

			if menuOpenAfter then
				set out to out & "MENU_AX_BEGIN" & linefeed
				try
					set elems to entire contents of (menu 1 of statusItem)
					repeat with e in elems
						try
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
							if v is not "" then set out to out & "AXMENU :: " & v & linefeed
						end try
					end repeat
				end try
				set out to out & "MENU_AX_END" & linefeed

				try
					set mAfter to menu 1 of statusItem
					set connIndex to 0
					repeat with i from 1 to (count of menu items of mAfter)
						if (name of menu item i of mAfter as string) starts with "Connection" then set connIndex to i
					end repeat
					if connIndex > 0 then
						click (menu item connIndex of mAfter)
						set out to out & "CLICKED_CONNECTION" & linefeed
					else
						set out to out & "NO_CONNECTION_ITEM" & linefeed
					end if
				on error errMsg number errNum
					set out to out & "CONNECTION_ERR=" & errMsg & " (" & errNum & ")" & linefeed
				end try
			end if

			-- The Connection window has a Debug tab holding the gateway status
			-- ("Using existing gateway ...") and the stdout/stderr log. Select it
			-- best effort so the caller's AX dump can read both.
			delay 3
			try
				if (count of windows) > 0 then
					set wList to windows
					set w to item 1 of wList
					set els to entire contents of w
					repeat with e in els
						try
							if (name of e as string) is "Debug" then
								click e
								set out to out & "CLICKED_DEBUG_TAB" & linefeed
								exit repeat
							end if
						end try
					end repeat
				end if
			end try

			delay 4
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

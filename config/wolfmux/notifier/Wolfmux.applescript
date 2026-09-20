-- Wolfmux.app — the owner of notifications for a team nobody is attached to.
--
-- macOS opens the application that posted a notification when you click it. For a
-- notification sent with `osascript` that application is Script Editor. This tiny
-- application posts the notification instead, so a click comes back HERE, and here a
-- click means: bring the team to the screen.
--
-- It is launched twice in a notification's life and tells the two apart by whether
-- teamctl is holding a message for it:
--   a message is waiting  -> post it (teamctl launched us)
--   nothing is waiting    -> you clicked: open a terminal attached to the team
-- Built by install.sh with osacompile; never runs on its own, keeps nothing open.

on run
	set teamctl to quoted form of ((POSIX path of (path to home folder)) & "bin/teamctl")
	set waiting to ""
	try
		set waiting to do shell script teamctl & " _notify-pending"
	end try
	if waiting is "" then
		try
			do shell script teamctl & " _open-team"
		end try
	else
		set body to paragraph 1 of waiting
		set detail to ""
		if (count of paragraphs of waiting) > 1 then set detail to paragraph 2 of waiting
		display notification body with title "Wolfmux" subtitle detail
		delay 1 -- the notification centre needs a moment before this process ends
	end if
end run

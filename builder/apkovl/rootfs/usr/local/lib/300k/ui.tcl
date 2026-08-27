package require Tk
source /usr/local/lib/300k/content.tcl

wm title . "300K Linux"
wm attributes . -fullscreen 1
wm minsize . 800 600
option add *Font {Terminus 14}

set ::turn_index 0
set ::bg #212121
set ::panel #171717
set ::card #2f2f2f
set ::text #ececec
set ::muted #b4b4b4
set ::accent #10a37f

proc append_message {speaker message} {
    .main.transcript configure -state normal
    .main.transcript insert end "$speaker\n" speaker
    .main.transcript insert end "$message\n\n" body
    .main.transcript configure -state disabled
    .main.transcript see end
}

proc show_help {} {
    tk_messageBox -title "300K Help" -message "Type ordinary text for local scripted comedy. Terminal opens a real BusyBox ash shell. Ctrl+Alt+T does the same. Nothing is sent anywhere."
}

proc show_about {} {
    tk_messageBox -title "About 300K Linux" -message "300K Linux is an unofficial offline parody built from original project artwork. It is not affiliated with or operated by OpenAI."
}

proc show_system_info {} {
    if {[catch {exec /usr/local/bin/300k-runtime system-info} details]} {
        set details "System information is temporarily unavailable."
    }
    tk_messageBox -title "Local System Info" -message $details
}

proc request_power {operation} {
    set label [expr {$operation eq "reboot" ? "Reboot" : "Shut down"}]
    set answer [tk_messageBox -type yesno -icon question -title "$label 300K Linux" -message "$label this disposable live session?"]
    if {$answer eq "yes"} {
        exec doas /usr/local/sbin/300k-power $operation &
    }
}

proc submit_prompt {} {
    set prompt [.main.composer.entry get]
    if {[string trim $prompt] eq ""} { return }
    .main.composer.entry delete 0 end
    append_message "You" $prompt
    set record [reply_for $prompt $::turn_index]
    incr ::turn_index
    append_message "300K" [dict get $record text]
    set effect [dict get $record effect]
    if {$effect eq "toast"} { .status configure -text "Local absurdity delivered. No packets were harmed." }
    if {$effect eq "fake_progress"} { .status configure -text "Pretending to think locally... done." }
    if {$effect eq "open_about"} { after 50 show_about }
}

frame .sidebar -background $::panel -width 235
pack .sidebar -side left -fill y
canvas .sidebar.badge -width 110 -height 110 -background $::panel -highlightthickness 0
.sidebar.badge create oval 12 12 98 98 -fill $::accent -outline #7fffd4 -width 3
.sidebar.badge create text 55 55 -text "300K" -fill white -font {Terminus 20 bold}
pack .sidebar.badge -pady {30 12}
label .sidebar.title -text "300K Linux" -background $::panel -foreground $::text -font {Terminus 18 bold}
pack .sidebar.title -pady {0 24}

button .sidebar.terminal -text "Terminal" -command {exec /usr/local/bin/300k-runtime terminal &}
button .sidebar.help -text "Help" -command show_help
button .sidebar.about -text "About" -command show_about
button .sidebar.system -text "System Info" -command show_system_info
button .sidebar.reboot -text "Reboot" -command {request_power reboot}
button .sidebar.shutdown -text "Shutdown" -command {request_power poweroff}
foreach control {.sidebar.terminal .sidebar.help .sidebar.about .sidebar.system .sidebar.reboot .sidebar.shutdown} {
    $control configure -background $::card -foreground $::text -activebackground $::accent -activeforeground white -relief flat -padx 14 -pady 9
    pack $control -fill x -padx 18 -pady 5
}

frame .main -background $::bg
pack .main -side left -fill both -expand 1
label .main.identity -text "UNOFFICIAL PARODY / OFFLINE / LOCAL SCRIPT / NO OPENAI SERVICE" -background #6b4f00 -foreground #fff2b2 -font {Terminus 13 bold} -padx 12 -pady 9
pack .main.identity -side top -fill x

text .main.transcript -background $::bg -foreground $::text -insertbackground white -wrap word -state disabled -relief flat -padx 50 -pady 28 -spacing2 5
.main.transcript tag configure speaker -foreground #8fffe2 -font {Terminus 14 bold}
.main.transcript tag configure body -foreground $::text
pack .main.transcript -side top -fill both -expand 1 -padx 40

frame .main.composer -background $::card -padx 10 -pady 10
entry .main.composer.entry -background $::card -foreground $::text -insertbackground white -relief flat
button .main.composer.send -text "Send locally" -command submit_prompt -background $::accent -foreground white -relief flat
pack .main.composer.entry -side left -fill x -expand 1 -padx {8 12} -ipady 7
pack .main.composer.send -side right -ipadx 10 -ipady 5
pack .main.composer -side bottom -fill x -padx 70 -pady {8 12}
bind .main.composer.entry <Return> {submit_prompt; break}

label .status -text "LOCAL ONLY - scripted replies; real terminal available separately" -background $::bg -foreground $::muted -anchor w -padx 72 -pady 4
pack .status -side bottom -fill x

append_message "300K" "Hello. I am a local Tcl script with excellent boundaries and no idea what the internet is doing."
focus .main.composer.entry
update idletasks
if {![winfo ismapped .]} { error "300K top-level did not map" }
exec /usr/local/bin/300k-runtime serial-stage UI_READY
after 1200 {catch {exec /usr/local/bin/300k-runtime terminal-proof &}}

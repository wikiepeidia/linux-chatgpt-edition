set ::threehundredk_catalog {}
set ::threehundredk_rng_state 300000
set ::threehundredk_initialized 0

    lappend ::threehundredk_catalog [dict create id debug_duck triggers {debug bug crash} effect toast actions {terminal} text {I asked the rubber duck. It opened a consulting firm and invoiced the kernel.}]
    lappend ::threehundredk_catalog [dict create id sudo_sandwich triggers {sudo root admin} effect none actions {terminal} text {Permission denied politely. This sandwich requires two slices of least privilege.}]
    lappend ::threehundredk_catalog [dict create id wifi_ghost triggers {wifi internet network} effect fake_progress actions {system_info} text {Networking is off. I found three bars anyway; they belong to a tiny prison window.}]
    lappend ::threehundredk_catalog [dict create id update_ritual triggers {update upgrade install} effect fake_progress actions {terminal} text {Update complete: absolutely nothing contacted the cloud, exactly as promised.}]
    lappend ::threehundredk_catalog [dict create id memory_snack triggers {memory ram forget} effect none actions {system_info} text {This live system remembers everything until poweroff, then achieves enlightenment.}]
    lappend ::threehundredk_catalog [dict create id coffee_kernel triggers {coffee tired sleep} effect toast actions {} text {The kernel drinks decaf so interrupts remain emotionally available.}]
    lappend ::threehundredk_catalog [dict create id deadline_clock triggers {deadline hurry fast} effect fake_progress actions {} text {Estimated completion: before the progress bar learns object permanence.}]
    lappend ::threehundredk_catalog [dict create id ai_denial triggers {ai model chatgpt openai} effect open_about actions {about} text {No model lives here. It is Tcl wearing a very confident cardigan.}]
    lappend ::threehundredk_catalog [dict create id file_goblin triggers {file folder directory} effect none actions {terminal} text {Your file is local. A goblin indexed it alphabetically, then requested dental.}]
    lappend ::threehundredk_catalog [dict create id reboot_prophecy triggers {reboot restart again} effect toast actions {reboot} text {Rebooting cures state, doubt, and most temporary personality defects.}]
    lappend ::threehundredk_catalog [dict create id shutdown_poem triggers {shutdown poweroff bye} effect none actions {shutdown} text {Goodnight, tiny computer. May your capacitors dream in hexadecimal.}]
    lappend ::threehundredk_catalog [dict create id terminal_truth triggers {terminal shell command} effect none actions {terminal} text {The Terminal button opens a real local ash shell. I remain decorative and legally distinct.}]
    lappend ::threehundredk_catalog [dict create id linux_penguin triggers {linux alpine penguin} effect toast actions {system_info} text {Alpine arrived without a penguin. Customs confiscated the fish.}]
    lappend ::threehundredk_catalog [dict create id meaning_300k triggers {300k credit dollar money} effect fake_progress actions {about} text {Three hundred thousand imaginary credits were compressed into one extremely real boot menu.}]
    lappend ::threehundredk_catalog [dict create id help_oracle triggers {help what can you do} effect none actions {help terminal} text {I can tell jokes, show facts, open a real terminal, and avoid pretending to be online.}]
    lappend ::threehundredk_catalog [dict create id fallback triggers {} effect none actions {help terminal} text {I searched the entire local universe. It was one list, and your prompt was not on it.}]

set ::threehundredk_effect_allowlist {none toast fake_progress open_about}
set ::threehundredk_action_allowlist {terminal help about system_info reboot shutdown}

proc threehundredk_normalize {value} {
    set lowered [string tolower [string trim $value]]
    regsub -all {[^a-z0-9]+} $lowered { } lowered
    return [string trim $lowered]
}

proc threehundredk_initialize_rng {} {
    global threehundredk_initialized threehundredk_rng_state
    if {$threehundredk_initialized} { return }
    if {[info exists ::env(300K_SEED)] && [string is integer -strict $::env(300K_SEED)]} {
        set threehundredk_rng_state [expr {wide($::env(300K_SEED)) & 0x7fffffff}]
    } else {
        set threehundredk_rng_state [expr {[clock seconds] & 0x7fffffff}]
    }
    set threehundredk_initialized 1
}

proc threehundredk_next_index {count turn} {
    global threehundredk_rng_state
    threehundredk_initialize_rng
    set threehundredk_rng_state [expr {(1103515245 * ($threehundredk_rng_state + $turn) + 12345) & 0x7fffffff}]
    return [expr {$threehundredk_rng_state % $count}]
}

proc threehundredk_validate_catalog {} {
    global threehundredk_catalog threehundredk_effect_allowlist threehundredk_action_allowlist
    set seen {}
    set fallback_count 0
    foreach record $threehundredk_catalog {
        set id [dict get $record id]
        if {[dict exists $seen $id]} { error "duplicate content id" }
        dict set seen $id 1
        if {$id eq "fallback"} { incr fallback_count }
        if {[lsearch -exact $threehundredk_effect_allowlist [dict get $record effect]] < 0} { error "invalid content effect" }
        foreach action [dict get $record actions] {
            if {[lsearch -exact $threehundredk_action_allowlist $action] < 0} { error "invalid content action" }
        }
    }
    if {$fallback_count != 1} { error "fallback content is not closed" }
}

proc reply_for {prompt {turn 0}} {
    global threehundredk_catalog
    set normalized [threehundredk_normalize $prompt]
    set eligible {}
    set fallback {}
    foreach record $threehundredk_catalog {
        if {[dict get $record id] eq "fallback"} {
            set fallback $record
            continue
        }
        foreach trigger [dict get $record triggers] {
            if {[string first $trigger $normalized] >= 0} {
                lappend eligible $record
                break
            }
        }
    }
    if {[llength $eligible] == 0} { return $fallback }
    return [lindex $eligible [threehundredk_next_index [llength $eligible] $turn]]
}

threehundredk_validate_catalog

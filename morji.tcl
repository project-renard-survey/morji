#!/usr/bin/env tclsh8.6
# Copyright (c) 2017 Yon <anaseto@bardinflor.perso.aquilenet.fr>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

package require sqlite3
package require term::ansi::send
package require term::ansi::code::ctrl
package require textutil
package require cmdline

######################### namespace state ################

namespace eval morji {
    ::term::ansi::send::import
    proc variables {args} {
        foreach arg $args {
            uplevel [list variable $arg]
        }
    }

    variables START_TIME FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN TEST TEXT_WIDTH NO_CLEAR_SCREEN
    set TEXT_WIDTH 56
    set NO_CLEAR_SCREEN 0
    namespace eval markup {
        # index of current card's cloze
        variable CLOZE 0
    }

    namespace eval config {}
}

# morji::init_state initializes the morji database and the startup time
# variable.
proc morji::init_state {{dbfile :memory:}} {
    variables START_TIME
    sqlite3 db $dbfile

    db eval {
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS cards(
            uid INTEGER PRIMARY KEY,
            -- last repetition time (null for new cards)
            last_rep INTEGER,
            -- next repetition time (null for new cards)
            next_rep INTEGER CHECK(next_rep ISNULL OR last_rep < next_rep),
            easiness REAL NOT NULL DEFAULT 2.5 CHECK(easiness > 1.29),
            -- number of repetitions (0 for new and forgotten cards)
            reps INTEGER NOT NULL,
            fact_uid INTEGER NOT NULL REFERENCES facts ON DELETE CASCADE,
            -- additional data whose meaning depends on facts.type
            fact_data TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cards_idx1 ON cards(next_rep);
        CREATE INDEX IF NOT EXISTS cards_idx2 ON cards(fact_uid);
        CREATE TABLE IF NOT EXISTS tags(
            uid INTEGER PRIMARY KEY,
            name TEXT UNIQUE NOT NULL,
            active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS tags_idx1 ON tags(name);
        CREATE INDEX IF NOT EXISTS tags_idx2 ON tags(active);
        CREATE TABLE IF NOT EXISTS fact_tags(
            fact_uid INTEGER NOT NULL REFERENCES facts ON DELETE CASCADE,
            tag_uid INTEGER NOT NULL REFERENCES tags ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS fact_tags_idx1 ON fact_tags(tag_uid);
        CREATE UNIQUE INDEX IF NOT EXISTS fact_tags_idx2 ON fact_tags(fact_uid, tag_uid);
        CREATE TABLE IF NOT EXISTS facts(
            uid INTEGER PRIMARY KEY,
            question TEXT NOT NULL,
            answer TEXT NOT NULL,
            notes TEXT NOT NULL,
            -- oneside/twoside(recognition/production)/cloze...
            type TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS misc_info(
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT
        )
    }

    set START_TIME [clock seconds]
}

######################### managing facts ################

# morji::add_fact adds a new fact to the database. It generates needed cards.
proc morji::add_fact {question answer notes type {tags {}}} {
    db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, $type)}
    set fact_uid [db last_insert_rowid]
    switch $type {
        oneside {
            add_card $fact_uid
        }
        twoside {
            foreach fact_data {R P} {
                add_card $fact_uid $fact_data
            }
        }
        cloze {
            set i 0
            foreach elt [get_clozes $question] {
                set cmd [string range $elt 1 end-1]
                check_cloze_cmd $cmd
                set fact_data [list $i {*}[lrange $cmd 1 end]]
                add_card $fact_uid $fact_data
                incr i
            }
        }
        default {
            error "invalid type: $type"
        }
    }
    lappend tags all
    set tag_uids [lmap tag $tags {
        db eval {INSERT OR IGNORE INTO tags(name) VALUES($tag)}
        db eval {SELECT uid FROM tags WHERE name=$tag}
    }]
    foreach uid [lsort -unique $tag_uids] {
        db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
    }
    return $fact_uid
}

proc morji::add_card {fact_uid {fact_data {}}} {
    db eval {
        INSERT INTO cards(reps, fact_uid, fact_data)
        VALUES(0, $fact_uid, $fact_data)
    }
}

# morji::update_fact updates a fact with new data and tags.
proc morji::update_fact {fact_uid question answer notes type tags} {
    set otype [db eval {SELECT type FROM facts WHERE uid=$fact_uid}]
    if {$otype ni {oneside twoside cloze}} {
        error "internal error: invalid otype: $otype"
    }
    db eval {UPDATE facts SET question=$question, answer=$answer, notes=$notes WHERE uid=$fact_uid}
    if {($otype eq "oneside") && ($type eq "twoside")} {
        db eval {UPDATE cards SET fact_data = 'R' WHERE fact_uid = $fact_uid}
        db eval {UPDATE facts SET type=$type WHERE uid=$fact_uid}
        add_card $fact_uid "P"
    } elseif {($otype eq "twoside") && ($type eq "oneside")} {
        db eval {DELETE FROM cards WHERE fact_uid=$fact_uid AND fact_data = 'P'}
        db eval {UPDATE facts SET type=$type WHERE uid=$fact_uid}
        db eval {UPDATE cards SET fact_data = '' WHERE fact_uid=$fact_uid}
    } elseif {($type ne $otype)} {
        warn "card of type $otype cannot become of type $type"
    }
    if {($otype eq "cloze")} {
        update_cloze_fact $fact_uid $question
    }
    if {$type ni {oneside twoside cloze}} {
        warn "invalid type: $type"
    }
    update_tags_for_fact $fact_uid $tags
}

# morji::update_cloze_fact updates a fact of type cloze. It tries to be smart
# and reuse card history in some common editing cases (e.g. delete or add
# clozes and leave others as-is, modify clozes but preserve their order and
# number, or permute clozes without changing them).
proc morji::update_cloze_fact {fact_uid question} {
    set ocards [db eval {SELECT uid, fact_data FROM cards WHERE cards.fact_uid=$fact_uid}]
    set nclozes {}
    set i 0
    foreach elt [get_clozes $question] {
        set cmd [string range $elt 1 end-1]
        check_cloze_cmd $cmd
        lappend nclozes [list $i {*}[lrange $cmd 1 end]]
        incr i
    }
    set nclozes_first [lmap cloze $nclozes {lindex $cloze 1}]
    set oclozes_first [lmap {uid cloze} $ocards {lindex $cloze 1}]
    if {[llength $oclozes_first] ==  [llength $nclozes_first] && [lsort $nclozes_first] != [lsort $oclozes_first] } {
        foreach {uid ocloze} $ocards {
            set ncloze [lindex $nclozes [lindex $ocloze 0]]
            db eval {UPDATE cards SET fact_data=$ncloze WHERE uid=$uid}
        }
        return
    }
    foreach {uid ocloze} $ocards {
        set found [lsearch -exact $nclozes_first [lindex $ocloze 1]]
        if {$found > -1} {
            set ncloze [lindex $nclozes $found]
            db eval {UPDATE cards SET fact_data=$ncloze WHERE uid=$uid}
        } else {
            db eval {DELETE FROM cards WHERE uid=$uid}
        }
    }
    foreach ncloze $nclozes {
        set found [lsearch -exact $oclozes_first [lindex $ncloze 1]]
        if {$found == -1} {
            add_card $fact_uid $ncloze
        }
    }
}

proc morji::get_clozes {question} {
    return [regexp -inline -all {\[cloze [^\]]*\]} $question]
}

proc morji::check_cloze_cmd {cmd} {
    if {[llength $cmd] > 3} {
        warn "More than two arguments in cloze command: \[$cmd\]"
    }
    if {[llength $cmd] < 2} {
        warn "At least one argument required in cloze command: \[$cmd\]"
    }
}

proc morji::add_tag_for_fact {fact_uid tag} {
    set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
    if {$uid eq ""} {
        db eval {INSERT INTO tags(name) VALUES($tag)}
        set uid [db last_insert_rowid]
    }
    db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
}

proc morji::update_tags_for_fact {fact_uid tags} {
    set otags [db eval {
        SELECT name FROM tags
        WHERE EXISTS(SELECT 1 FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid = tags.uid)
    }]
    # new tags
    foreach tag [lsort -unique $tags] {
        if {$tag eq "all"} {
            continue
        }
        if {!($tag in $otags)} {
            add_tag_for_fact $fact_uid $tag
        }
    }
    # removed tags
    foreach tag $otags {
        if {$tag eq "all"} {
            continue
        }
        if {!($tag in $tags)} {
            set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
            if {$uid eq ""} {
                error "internal error: update_tags_for_fact: tag without uid"
            }
            db eval {DELETE FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid=$uid}
        }
    }
    remove_orphaned_tags
}

proc morji::remove_orphaned_tags {} {
    db eval {
        DELETE FROM tags
        WHERE NOT EXISTS(SELECT 1 FROM fact_tags WHERE fact_tags.tag_uid = tags.uid)
    }
}

proc morji::delete_fact {fact_uid} {
    db eval {DELETE FROM facts WHERE uid=$fact_uid}
    remove_orphaned_tags
}

######################### getting cards and fact data ################

# morji::start_of_day returns the date corresponding the start of a day for
# morji, which is at 2AM.
proc morji::start_of_day {} {
    variable START_TIME
    set fmt %d/%m/%Y
    return [clock add [clock scan [clock format [clock add $START_TIME -2 hours] -format $fmt] -format $fmt] 2 hours]
}

proc morji::substcmd {text} {
    return [subst -nobackslashes -novariables $text]
}

proc morji::get_cards_where_tag_clause {} {
    return {
        EXISTS(SELECT 1 FROM tags, fact_tags, facts
            WHERE cards.fact_uid = facts.uid
            AND tags.uid = fact_tags.tag_uid
            AND facts.uid = fact_tags.fact_uid
            AND tags.active = 1)
    }
}

# morji::get_today_cards returns cards scheduled for revision before tomorrow.
proc morji::get_today_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [substcmd {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps > 0 AND
        [get_cards_where_tag_clause]
        ORDER BY next_rep - last_rep
    }]]
}

# morji::get_forgotten_cards returns cards previously memorized that have been
# forgotten. It returns at most 25 cards.
proc morji::get_forgotten_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [substcmd {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps = 0 AND
        [get_cards_where_tag_clause]
        ORDER BY next_rep - last_rep
        LIMIT 25
    }]]
}

# morji::get_new_cards returns 5 new cards yet to be memorized.
proc morji::get_new_cards {} {
    return [db eval [substcmd {
        SELECT min(cards.uid) FROM cards
        WHERE cards.next_rep ISNULL AND
        [get_cards_where_tag_clause]
        GROUP BY fact_uid
        LIMIT 5
    }]]
}

proc morji::get_card_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type, cards.fact_data
        FROM cards, facts
        WHERE cards.uid=$uid AND facts.uid = cards.fact_uid
    }]
}

proc morji::get_fact_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type
        FROM facts
        WHERE facts.uid=$uid
    }]
}

proc morji::get_fact_tags {uid} {
    return [db eval {
        SELECT name FROM tags
        WHERE EXISTS(
            SELECT 1 FROM fact_tags
            WHERE fact_tags.fact_uid=$uid
            AND tag_uid = tags.uid)
    }]
}

proc morji::get_card_tags {uid} {
    return [get_fact_tags [get_card_fact_uid $uid]]
}

proc morji::get_card_fact_uid {uid} {
    return [db onecolumn {SELECT fact_uid FROM cards WHERE uid=$uid}]
}

######################### tag functions ################

proc morji::get_tags {} {
    return [db eval {SELECT name FROM tags ORDER BY name}]
}

proc morji::get_active_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 1 ORDER BY name}]
}

proc morji::get_inactive_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 0 ORDER BY name}]
}

proc morji::select_tags {pattern} {
    db eval {UPDATE tags SET active = 1 WHERE name GLOB $pattern}
}

proc morji::deselect_tags {pattern} {
    db eval {UPDATE tags SET active = 0 WHERE name GLOB $pattern}
}

proc morji::rename_tag {old_name new_name} {
    db eval {UPDATE tags SET name=$new_name WHERE name=$old_name}
}

######################### scheduling ################

# morji::schedule_card schedules a card using a given grade. It returns
# "scheduled" on successful operation. It uses a modified version of the SM2
# algorithm.
proc morji::schedule_card {uid grade} {
    variable START_TIME
    db eval {SELECT last_rep, next_rep, easiness, reps, fact_uid FROM cards WHERE uid=$uid} break
    if {![info exists reps]} {
        error "internal error: schedule_card: card does not exist: $uid"
    }
    # grades are the same as in anki: again, hard, good, easy
    if {(($reps == 0) && ($grade eq "again"))} {
        # card was new or already forgotten, so no change
        return scheduled
    }
    if {$next_rep eq "" && $grade eq "hard"} {
        # NOTE: for unseen card grade "hard" is the same as "good"
        set grade good
    }
    switch $grade {
        hard { set easiness [expr {$easiness - 0.15}] }
        easy { set easiness [expr {$easiness + 0.1}] }
        good - again { }
        default { error "invalid grade: $grade" }
    }
    if {$easiness < 1.3} {
        set easiness 1.3
    }
    if {$grade ne "again"} {
        set new_last_rep $START_TIME
        set new_next_rep $new_last_rep
        incr reps
    } else {
        # forgotten card
        set new_last_rep $last_rep
        set new_next_rep $next_rep
        set reps 0
    }
    switch $reps {
        0 {}
        1 {
            set new_next_rep [clock add $new_next_rep 1 day]
            if {$grade eq "easy"} {
                if {$next_rep ne ""} {
                    set new_next_rep [clock add $new_next_rep 2 days]
                } else {
                    # unseen card was easy, so probably not really new: skip
                    # first repetition.
                    set new_next_rep [clock add $new_next_rep 5 days]
                    incr reps
                }
            }
        }
        2 {
            set new_next_rep [clock add $new_next_rep 6 day]
            # some little adjustments for first repetition
            switch $grade {
                hard { set new_next_rep [clock add $new_next_rep -2 days] }
                easy { set new_next_rep [clock add $new_next_rep 1 day] }
            }
        }
        default {
            set late [expr {$new_last_rep - $next_rep}]
            if {$grade eq "hard" && $late > 2*86400} {
                # reviewing late and card was hard, so use conservatively the
                # same interval again
                set interval [expr {$new_last_rep-$last_rep}]
            } else {
                set interval [expr {int(($new_last_rep-$last_rep)*$easiness)}]
            }
            set new_next_rep [clock add $new_next_rep $interval seconds]
        }
    }
    if {$reps > 0} {
        if {![info exists interval]} {
            set interval [expr {$last_rep eq "" ? 0 : $new_next_rep-$new_last_rep}]
        }
        # randomize a little the interval
        set new_next_rep [
            clock add $new_next_rep [interval_noise $interval] days
        ]
    }
    while {[db exists {
                SELECT 1 FROM cards
                WHERE fact_uid=$fact_uid AND uid!=$uid
                AND date(next_rep-7200,'unixepoch') = date($new_next_rep-7200, 'unixepoch')}]
        } {
        # avoid putting sister cards on the same day
        set new_next_rep [clock add $new_next_rep 1 day]
    }
    db eval {
        UPDATE cards
        SET last_rep=$new_last_rep, next_rep=$new_next_rep, easiness=$easiness, reps=$reps
        WHERE uid=$uid
    }
    return scheduled
}

proc morji::interval_noise {interval} {
    set noise 0
    set day 86400
    # use noise calculation similar to mnemosyne's
    if {$interval <= 10 * $day} {
        set noise [expr {$day * rand() * 2}]
    } elseif {$interval <= 20 * $day} {
        set noise [expr {$day * (rand() * 5 - 2)}]
    } elseif {$interval <= 60 * $day} {
        set noise [expr {$day * (rand() * 7 - 3)}]
    } else {
        set noise [expr {$interval * (-0.05 + 0.1 * rand())}]
    }
    return [expr {int($noise / $day)}]
}

######################### prompts ################

proc morji::ask_for_initial_grade {fact_uid} {
    set uids [db eval {SELECT uid FROM cards WHERE fact_uid=$fact_uid}]
    set key [get_key "initial grade (type ? for help)>>"]
    switch $key {
        a { return scheduled }
        g {
            foreach card_uid $uids {schedule_card $card_uid good}
            return scheduled
        }
        e {
            foreach card_uid $uids {schedule_card $card_uid easy}
            return scheduled
        }
        E { return edit }
        C { return cancel }
        ? {
            put_initial_schedule_prompt_help
            return ""
        }
        Q { quit }
    }
    with_color red {
        puts "Error: invalid key: $key (type ? for help)"
    }
}

proc morji::prompt_delete_card {uid} {
    if {[prompt_confirmation {Delete fact (will delete current card and any sister-cards)}]} {
        delete_fact [get_card_fact_uid $uid]
        return restart
    }
}

proc morji::prompt_confirmation {prompt} {
    while {1} {
        set key [get_key "$prompt? \[y/N\] >>"]
        switch $key {
            Y - y { return 1 }
            default { return 0 }
        }
    }
}

proc morji::card_prompt {card_uid} {
    variables FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN
    lassign [get_card_user_info $card_uid] question answer notes type fact_data
    if {$FIRST_ACTION_FOR_CARD} {
        draw_line
        put_tags $type [get_card_tags $card_uid]
        put_question $question $answer $type $fact_data
    }
    set key [get_key ">>"]
    switch $key {
        q {
            put_tags $type [get_card_tags $card_uid]
            put_question $question $answer $type $fact_data;
            return
        }
        " " {
            put_answer $question $answer $notes $type $fact_data
            set ANSWER_ALREADY_SEEN 1
            return
        }
        E { edit_existent_card $card_uid; return }
        ? { put_keys_help; return }
        D { return [prompt_delete_card $card_uid] }
        a - h - g - e {
            if {!$ANSWER_ALREADY_SEEN} {
                error "you must see the answer before grading the card"
            }
        }
    }

    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    if {$ANSWER_ALREADY_SEEN} {
        switch $key {
            a { return [schedule_card $card_uid again] }
            h { return [schedule_card $card_uid hard] }
            g { return [schedule_card $card_uid good] }
            e { return [schedule_card $card_uid easy] }
        }
    }
    error "invalid key: $key (type ? for help)"
}

proc morji::no_card_prompt {} {
    set key [get_key ">>"]
    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    error "invalid key: $key (type ? for help)"
}

proc morji::handle_base_key {key} {
    variable TEST
    switch $key {
        t {
            put_header {Inactive Tags}
            puts [get_inactive_tags]
            set line [get_line "+tag>>"]
            if {$line ne ""} {
                select_tags $line
                return restart
            } else {
                return 1
            }
        }
        T {
            put_header {Active Tags}
            puts [get_active_tags]
            set line [get_line "-tag>>"]
            if {$line ne ""} {
                deselect_tags $line
                return restart
            } else {
                return 1
            }
        }
        + { if {$TEST} { return next_day } }
        N { edit_new_card; return restart }
        r { rename_tag_prompt; return 1 }
        s { show_cards_scheduled_prompt; return 1 }
        S { show_statistics; return 1 }
        f { find_fact_to_edit; return restart }
        I { import_tsv_facts_prompt; return restart }
        Q { puts ""; return quit }
        ? { put_context_independent_keys_help; return 1 }
    }
}

proc morji::rename_tag_prompt {} {
    set tags [get_tags]
    put_header Tags
    puts $tags
    set old_tag [get_line "tag to rename>>"]
    if {$old_tag eq ""} {
        return
    }
    if {$old_tag ni $tags} {
        error "tag does not exist: $old_tag"
    }
    set new_tag [get_line "new tag name>>"]
    if {$new_tag in $tags} {
        error "tag name already exists: $new_tag"
    }
    if {$new_tag eq ""} {
        error "empty tag name not allowed"
    }
    rename_tag $old_tag $new_tag
}

proc morji::show_cards_scheduled_prompt {} {
    set key [get_key "cards scheduled \[w/m/y\] (? for help)>>"]
    switch $key {
        w { set days 7 }
        m { set days 30 }
        y { set days 365 }
        \u001b - \n - \r {
            return
        }
        ? {
            puts "Keys: w (7 days), m (30 days) and y (365 days)"
            tailcall show_cards_scheduled_prompt
        }
        default {
            with_color red {
                puts "Error: invalid key: $key (type ? for help)."
            }
            tailcall show_cards_scheduled_prompt
        }
    }
    show_cards_scheduled_next_days $days
}

proc morji::get_line {prompt} {
    with_color blue {
        puts -nonewline "$prompt "
        flush stdout
    }

    with_raw_mode {
        set line [read_line]
    }
    return $line
}

proc morji::get_key {prompt} {
    with_color blue {
        puts -nonewline "$prompt "
        flush stdout
    }
    with_raw_mode {
        set key [read stdin 1]
    }
    puts $key
    return $key
}

######################### read line utility ################

# morji::read_line is a minimal read line function. It interprets only newline,
# backspace and escape.
proc morji::read_line {} {
    set chars {}
    while {1} {
        set key [read stdin 1]
        switch $key {
            \u0008 - \u007f { ;# backspace
                if {[llength $chars] > 0} {
                    set chars [lrange $chars 0 end-1]
                    send::cb
                    send::eeol
                    flush stdout
                }
            }
            \u001b { ;# escape
                puts ""
                return ""
            }
            \n - \r { ;# newline
                puts ""
                return [join $chars ""]
            }
            default {
                lappend chars $key
                puts -nonewline $key
                flush stdout
            }
        }
    }
}

######################### fact parsing ################

# morji::parse_cards parses card data and returns a list with data. The order
# is: question, answer, notes, type, tags.
proc morji::parse_card {text} {
    set fields [textutil::splitx $text {(@(?:Question|Answer|Notes|Type|Tags):)}]
    set field_contents [dict create]
    set current_field ""
    foreach f {@Question: @Answer: @Notes: @Type: @Tags:} { dict set field_contents $f "" }
    foreach field $fields {
        switch $field {
            @Question: - @Answer: - @Notes: - @Type: - @Tags: {
                check_field $field_contents $field
                set current_field $field
            }
            default {
                if {$current_field ne ""} {
                    dict set field_contents $current_field [string trim $field]
                } elseif {[regexp {\S} $field]} {
                    warn "wandering text outside field: “$field”"
                }
            }
        }
    }
    return [dict values $field_contents]
}

proc morji::check_field {field_contents field} {
    if {[dict get $field_contents $field] ne ""} {
        warn "double use of $field"
    }
}

# morji::import_tsv_facts imports new facts from a file of tab separated values. Each
# line should have the following 5 fields: question, answer, notes, type and tags.
proc morji::import_tsv_facts {file} {
    set fh [open $file]
    set content [read $fh]
    close $fh
    set lines [split $content \n]
    set lnum 0
    set nfacts 0
    foreach line $lines {
        incr lnum
        if {$line eq ""} {
            continue
        }
        set fields [split $line \t]
        if {[llength $fields] != 5} {
            error "$file:$lnum: incorrect number of fields: [llength $fields] (should be 5)"
        }
        lassign $fields question answer notes type tags
        if {$type ni {oneside twoside cloze}} {
            error "$file:$lnum: invalid type: $type"
        }
        if {$question eq ""} {
            warn "$file:$lnum: empty question"
        }
        if {$tags eq ""} {
            warn "$file:$lnum: no tags specified"
        }
        try {
            add_fact $question $answer $notes $type $tags
            incr nfacts
        } on error {msg} {
            error "$file:$lnum: $msg"
        }
    }
    puts "Added $nfacts new facts."
}

######################### output stuff ################

proc morji::with_color {color script} {
    send::sda_fg$color
    try {
        uplevel $script
    } finally {
        send::sda_fgdefault
    }
}

proc morji::with_style {style script} {
    send::sda_$style
    try {
        uplevel $script
    } finally {
        send::sda_no$style
    }
}

proc morji::colored {color text} {
    return "[::term::ansi::code::ctrl::sda_fg$color]$text[::term::ansi::code::ctrl::sda_fgdefault]"
}

proc morji::styled {style text} {
    return "[::term::ansi::code::ctrl::sda_$style]$text[::term::ansi::code::ctrl::sda_no$style]"
}

proc morji::warn {msg} {
    with_color red {
        puts "Warning: $msg"
    }
}

proc morji::put_info {msg} {
    with_color cyan {
        puts "Info: $msg"
    }
}

proc morji::put_header {title {color yellow}} {
    with_color $color {
        puts -nonewline "$title: "
        flush stdout
    }
}

proc morji::draw_line {} {
    variable TEXT_WIDTH
    # NOTE: this is suboptimal
    puts [string repeat ─ $TEXT_WIDTH]
}

proc morji::with_raw_mode {script} {
    set stty [auto_execok stty]
    set fh [open [string cat "|" [concat $stty "-g"]]]
    set saved_state [read -nonewline $fh]
    close $fh
    exec $stty raw -echo <@stdin
    try {
        uplevel $script
    } finally {
        exec $stty $saved_state
    }
}

######################### help ################

proc morji::put_keys_help {} {
    put_header {Keys (on current card)} cyan
    puts {
  q      show current card question again
  space  show current card answer
  a      grade card as not memorized (again)
  h      grade card recall as hard
  g      grade card recall as good
  e      grade card recall as easy
  E      edit current card
  D      delete current card's fact}
    put_context_independent_keys_help
}

proc morji::put_initial_schedule_prompt_help {} {
    put_header Keys cyan
    puts {
  a      grade card as not memorized (again)
  g      grade card memorization as good
  e      grade card memorization as easy
  C      cancel operation
  E      edit new card
  Q      quit program}
}

proc morji::put_context_independent_keys_help {} {
    put_header Keys cyan
    puts {
  ?      show this help
  N      new card
  t      select tags with glob pattern
  T      deselect tags with glob pattern
  f      find a fact to edit with glob pattern
  r      rename a tag
  s      show cards scheduled in next days
  S      show statistics
  I      import file of facts with tab separated fields
  Q      quit program}
}

######################### text rendering ################

# morji::put_text renders a text paragraph with markup tags.
proc morji::put_text {text} {
    set elts [textutil::splitx $text {(\[[^\]]*\])}]
    set buf {}
    foreach elt $elts {
        if {[regexp {^\[.*\]$} $elt]} {
            try {
                set cmd [string range $elt 1 end-1]
                set cmdname [lindex $cmd 0]
                set args [lrange $cmd 1 end]
                if {[namespace which -command morji::markup::$cmdname] ne ""} {
                    lappend buf [morji::markup::$cmdname {*}$args]
                } else {
                    warn "unknown markup tag: $cmdname"
                    lappend buf [colored red "\[$cmdname $args\]"]
                }
            } on error {msg} {
                lappend buf [colored red "@@$elt ==> Error: $msg@@"]
            }
        } else {
            lappend buf $elt
        }
    }
    puts [fmt [join $buf ""] 10]
}

# morji::fmt formats a paragraph $text with first line indentation $indent.
proc morji::fmt {text {indent 0}} {
    variable TEXT_WIDTH
    set chars [split $text ""]
    set col 0
    set wantspace 0
    set escape 0
    set wordbuf {}
    set wlen 0
    set pbuf {}
    set first_line 1
    foreach c $chars {
        if {$escape} {
            if {$c eq "m"} {
                set escape 0
            }
            if {!([string is digit $c] || $c eq ";" || $c eq "\[" || $c eq "m")} {
                warn "invalid character in escape sequence: “$c”"
                set escape 0
            }
            lappend wordbuf $c
            continue
        }
        if {$c eq "\033"} {
            set escape 1
            lappend wordbuf $c
            continue
        }
        if {[string is space $c] && $c ne "\xa0"} {
            if {$wlen > 0} {
                if {$col+$wlen > ($first_line ? $TEXT_WIDTH - $indent : $TEXT_WIDTH)} {
                    if {$wantspace} {
                        lappend pbuf "\n"
                        set first_line 0
                        set col 0
                    }
                } else {
                    if {$wantspace} {
                        lappend pbuf " "
                        incr col
                    }
                }
                lappend pbuf {*}$wordbuf
                incr col $wlen
                set wordbuf {}
                set wlen 0
                set wantspace 1
            }
            continue
        }
        lappend wordbuf $c
        incr wlen
    }
    if {[llength $wordbuf] > 0} {
        if {$wantspace} {
            if {$wlen+$col > $TEXT_WIDTH} {
                lappend pbuf "\n"
            } else {
                lappend pbuf " "
            }
        }
        lappend pbuf {*}$wordbuf
    }
    return [join $pbuf ""]
}

proc morji::markup::cloze {cloze {hint {…}}} {
    if {$morji::markup::CLOZE == 0} {
        set ret [morji::styled bold "\[$hint\]"]
    } elseif {$morji::markup::CLOZE <= -42} {
        set ret "\[cloze $cloze [morji::styled bold $hint]\]"
    } else {
        set ret $cloze
    }
    incr morji::markup::CLOZE -1
    return $ret
}

proc morji::config::markup {name type arg} {
    if {$type ni {styled colored}} {
        error "markup $name: bad type: $type (should be \"styled\" or \"colored\")"
    }
    set styles {bold dim italic underline blink revers hidden strike}
    if {$type eq "styled" && $arg ni $styles} {
        error "markup $name: bad style: $arg (should be one of $styles)"
    }
    set colors {black red green yellow blue magenta cyan white default}
    if {$type eq "colored" && $arg ni $colors} {
        error "markup $name: bad color: $arg (should be one of $colors)"
    }
    proc ::morji::markup::$name {args} [
        string cat "return \[morji::$type $arg " {[join $args]} "\]"
    ]
}

# [em ...] emphasis predefined tag.
morji::config::markup em styled bold

# [lbracket] and [rbracket] markup tags
foreach {n s} {lbracket \[ rbracket \]} {
    proc morji::markup::$n {} [list return $s]
}

proc morji::put_question {question answer type fact_data} {
    put_header Question
    switch $type {
        oneside { put_text $question }
        twoside {
            if {$fact_data eq "R"} {
                put_text $question
            } else {
                put_text $answer
            }
        }
        cloze {
            lassign $fact_data i
            set morji::markup::CLOZE $i
            put_text $question
        }
    }
}

proc morji::put_tags {type tags} {
    put_header Tags yellow
    set tags [lsearch -inline -all -not -exact $tags all]
    puts $tags
}

proc morji::put_answer {question answer notes type fact_data} {
    put_header Answer
    switch $type {
        oneside { put_text $answer }
        twoside {
            if {$fact_data eq "R"} {
                put_text $answer
            } else {
                put_text $question
            }
        }
        cloze {
            set cloze [lindex $fact_data 1]
            puts $cloze
        }
    }
    if {[regexp {\S} $notes]} {
        put_header Notes
        put_text $notes
    }
}

######################### cards editing ################

proc morji::put_card_fields {ch {question {}} {answer {}} {notes {}} {type {}} {tags {}}} {
    puts $ch "@Question: $question"
    puts $ch "@Answer: $answer"
    puts $ch "@Notes: $notes"
    puts $ch "@Type: $type"
    puts $ch "@Tags: $tags"
}

proc morji::with_tempfile {tmp tmpfile script} {
    upvar $tmp t $tmpfile tf
    set t [file tempfile tf]
    try {
        uplevel $script
    } finally {
        close $t
        file delete $tf
    }
}

proc morji::edit_new_card {} {
    with_tempfile tmp tmpfile {
        set type [db onecolumn {SELECT value FROM misc_info WHERE key='last_added_fact_type'}]
        set tags [db onecolumn {SELECT value FROM misc_info WHERE key='last_added_fact_tags'}]
        if {$type eq ""} {
            set type oneside
        }
        put_card_fields $tmp {} {} {} $type $tags
        flush $tmp
        edit_card $tmp $tmpfile
    }
}

proc morji::edit_existent_card {card_uid} {
    set fact_uid [get_card_fact_uid $card_uid]
    edit_existent_fact $fact_uid
}

proc morji::edit_existent_fact {fact_uid} {
    with_tempfile tmp tmpfile {
        db eval {SELECT question, answer, notes, type FROM facts WHERE uid=$fact_uid} break
        set tags [get_fact_tags $fact_uid]
        set tags [lsearch -inline -all -not -exact $tags all]
        put_card_fields $tmp $question $answer $notes $type $tags
        flush $tmp
        edit_card $tmp $tmpfile $fact_uid
    }
}

proc morji::edit_card {tmp tmpfile {fact_uid {}}} {
    if {[info exists config::EDITOR]} {
        set editor $config::EDITOR
    } elseif {[info exists ::env(EDITOR)]} {
        set editor $::env(EDITOR)
    }
    if {$editor eq ""} {
        warn "No external editor configured. Trying vim…"
        set editor vim
    }
    seek $tmp 0
    set content_before [read $tmp]
    with_raw_mode {
        exec -ignorestderr {*}$editor [file normalize $tmpfile] <@stdin >@stdout 2>@stderr
    }
    seek $tmp 0
    set content_after [read $tmp]
    if {$content_before eq $content_after} {
        throw CANCEL {}
    }
    lassign [parse_card $content_after] question answer notes type tags
    if {$question eq ""} {
        warn "Question field is empty"
    }
    if {$answer eq "" && $type ne "cloze"} {
        warn "Answer field is empty"
    }
    if {$answer ne "" && $type eq "cloze"} {
        warn "Answer field not used for card of type “cloze”"
    }
    set tags [lsearch -inline -all -not -exact $tags all]
    set tags [lsort -unique $tags]
    if {$fact_uid ne ""} {
        update_fact $fact_uid $question $answer $notes $type $tags
        show_fact $fact_uid $tags
        if {![prompt_confirmation {Ok}]} {
            throw CANCEL {}
        }
    } else {
        set fact_uid [add_fact $question $answer $notes $type $tags]
        show_fact $fact_uid $tags
        set ret ""
        while {$ret ne "scheduled"} {
            set ret [ask_for_initial_grade $fact_uid]
            if {$ret eq "edit"} {
                seek $tmp 0
                delete_fact $fact_uid
                tailcall edit_card $tmp $tmpfile
            } elseif {$ret eq "cancel"} {
                delete_fact $fact_uid
                throw CANCEL {}
            }
        }
        db eval {INSERT OR REPLACE INTO misc_info VALUES('last_added_fact_type', $type)}
        db eval {INSERT OR REPLACE INTO misc_info VALUES('last_added_fact_tags', $tags)}
    }
}

proc morji::show_fact {fact_uid tags} {
    lassign [get_fact_user_info $fact_uid] question answer notes type
    foreach {f t} [list $question Question $answer Answer $notes Notes $type Type $tags Tags] {
        if {$type eq "cloze" && $t eq "Answer"} {
            continue
        }
        if {$type eq "cloze" && $t eq "Question"} {
            set morji::markup::CLOZE -42
        }
        put_header "$t"
        switch $t {
            Question - Answer - Notes { put_text $f }
            default { puts $f }
        }
    }
}

proc morji::find_fact_to_edit {} {
    set pattern [get_line "(glob pattern) >>"]
    if {$pattern eq ""} {
        throw CANCEL {}
    }
    set pattern "*$pattern*"
    set facts [db eval {
        SELECT uid, question, answer, notes FROM facts
        WHERE question GLOB $pattern OR answer GLOB $pattern OR notes GLOB $pattern
    }]
    if {[llength $facts] == 0} {
        puts "Found no facts corresponding to pattern"
        throw CANCEL {}
    }
    if {[info exists config::FUZZY_FINDER]} {
        set fuzzy $config::FUZZY_FINDER
    } else {
        set fuzzy {}
    }

    set fact_uid {}
    if {$fuzzy ne ""} {
        with_tempfile tmp tmpfile {
            put_fact_rows $facts $tmp
            with_tempfile tmp_result tmpfile_result {
                try {
                    with_raw_mode {
                        exec -ignorestderr {*}$config::FUZZY_FINDER <$tmpfile 2>@stderr >>$tmpfile_result
                    }
                } on error {msg} {
                    # It is not possible in general to determine if it is
                    # really an error, or just a canceled operation.
                    throw CANCEL {}
                }
                set row [read -nonewline $tmp_result]
            }
            lassign [split $row |] fact_uid
        }
    }
    if {$fact_uid eq ""} {
        put_fact_rows $facts
        set fact_uid [get_line "(choose fact number) >>"]
        if {$fact_uid eq ""} {
            throw CANCEL {}
        }
    }
    if {[db exists {SELECT 1 FROM facts WHERE uid=$fact_uid}]} {
        edit_existent_fact $fact_uid
    } else {
        error "invalid fact number: $fact_uid"
    }
}

proc morji::put_fact_rows {facts {out ""}} {
    foreach {uid question answer notes} $facts {
        foreach field {question answer notes} {
            regsub -all {\s} [set $field] { } $field
        }
        if {$out eq ""} {
            puts "$uid|$question|$answer|$notes"
        } else {
            puts $out "$uid|$question|$answer|$notes"
        }
    }
    if {$out ne ""} {
        flush $out
    }
}

######################### stats ################

proc morji::put_stats {key value} {
    put_header $key cyan
    puts $value
}

proc morji::show_cards_scheduled_next_days {days} {
    set counts {}
    set after [clock add [start_of_day] 1 day]
    for {set i 0} {$i < $days} {incr i} {
        set before $after
        set after [clock add $after 1 day]
        set scheduled [db eval [substcmd {
            SELECT count(*) FROM cards
            WHERE next_rep < $after
            AND $before <= next_rep
            AND reps > 0
            AND [get_cards_where_tag_clause]
        }]]
        lappend counts $scheduled
    }
    put_stats "Cards scheduled for next $days days" $counts
}

proc morji::show_statistics {} {
    set not_memorized [db eval [substcmd {
        SELECT count(*) FROM cards WHERE reps = 0 AND [get_cards_where_tag_clause]
    }]]
    put_stats "Cards not memorized" $not_memorized
    set memorized [db eval [substcmd {
        SELECT count(*) FROM cards WHERE reps > 0 AND [get_cards_where_tag_clause]
    }]]
    put_stats "Memorized cards" $memorized
    set today [start_of_day]
    set tomorrow [clock add [start_of_day] 1 day]
    set learned [db eval [substcmd {
        SELECT count(*) FROM cards
        WHERE next_rep >= $tomorrow AND last_rep < $tomorrow AND last_rep > $today
        AND reps = 1 AND [get_cards_where_tag_clause]
    }]]
    put_stats "Cards memorized today" $learned
}

######################### import new facts ################

proc morji::import_tsv_facts_prompt {} {
    set line [get_line "filename >>"]
    if {$line eq ""} {
        throw CANCEL {}
    }
    if {![file exists $line]} {
        error "no such file: $line"
    }
    import_tsv_facts $line
    if {![prompt_confirmation "Ok"]} {
        put_info "Any changes rolled back."
        throw CANCEL {}
    }
}

######################### database checks ################

# morji::check_database does some sanity checks on the database and returns a
# true value if the checks are successful.
proc morji::check_database {} {
    if {![check_all_tag]} {
        puts stderr "tag 'all' not found for all cards"
        return 0
    }
    if {![check_oneside]} {
        puts stderr "check oneside failed"
        return 0
    }
    if {![check_twoside]} {
        puts stderr "check twoside failed"
        return 0
    }
    if {![check_cloze]} {
        puts stderr "check cloze failed"
        return 0
    }
    return 1
}

proc morji::check_all_tag {} {
    set all_uid [db onecolumn {SELECT uid FROM tags WHERE name='all'}]
    set uids [db eval {
        SELECT 1 FROM facts
        WHERE NOT EXISTS(SELECT 1 FROM fact_tags WHERE fact_uid = facts.uid AND fact_tags.tag_uid=$all_uid)
    }]
    if {$uids ne ""} {
        puts stderr "fact $uid: tag 'all' not found"
        return 0
    }
    return 1
}

proc morji::check_oneside {} {
    db eval {SELECT uid FROM facts WHERE type = 'oneside'} {
        set count [db eval {SELECT count(*) FROM cards WHERE fact_uid=$uid}]
        if {$count != 1} {
            puts stderr "fact $uid: bad card count"
            return 0
        }
    }
    return 1
}

proc morji::check_twoside {} {
    db eval {SELECT uid FROM facts WHERE type = 'twoside'} {
        set count [db eval {SELECT count(*) FROM cards WHERE fact_uid=$uid}]
        if {$count != 2} {
            puts stderr "fact $uid: bad card count"
            return 0
        }
        set data R
        db eval {SELECT fact_data FROM cards WHERE fact_uid=$uid} {
            if {$data ne $fact_data} {
                puts stderr "fact $uid: bad fact_data"
                return 0
            }
            set data P
        }
    }
    return 1
}

proc morji::check_cloze {} {
    db eval {SELECT uid, question FROM facts WHERE type = 'cloze'} {
        set clozes [get_clozes $question]
        set count [db eval {SELECT count(*) FROM cards WHERE fact_uid=$uid}]
        if {$count != [llength $clozes]} {
            puts stderr "fact $uid: bad card count: $count (expected [llength $clozes])"
            return 0
        }
        set cloze_args {}
        set i 0
        foreach cloze $clozes {
            set cmd [string range $cloze 1 end-1]
            check_cloze_cmd $cmd
            lappend cloze_args [list $i {*}[lrange $cmd 1 end]]
            incr i
        }
        set fact_datas {}
        db eval {SELECT fact_data FROM cards WHERE fact_uid=$uid} {
            lappend fact_datas $fact_data
        }
        if {[lsort $cloze_args] ne [lsort $fact_datas]} {
            puts stderr "fact $uid: card's fact_data and new clozes do not match: [lsort $cloze_args] vs [lsort $fact_datas]"
            return 0
        }
    }
    return 1
}

######################### main loop stuff ################

proc morji::put_phase_info {phase n} {
    switch $phase {
        get_today_cards { put_info "Review $n memorized cards." }
        get_forgotten_cards { put_info "Review $n forgotten cards." }
        get_new_cards { put_info "Memorize $n new cards." }
    }
}

proc morji::put_screen_start {} {
    variable NO_CLEAR_SCREEN
    if {!$NO_CLEAR_SCREEN} {
        send::clear
    }
    puts "Type ? for help."
}

proc morji::within_transaction {script} {
    set ret ""
    try {
        set ret [db transaction {uplevel $script}]
    } trap {CANCEL} {msg} {
        if {$msg ne ""} {
            put_info $msg
        }
    } on error {msg} {
        with_color red {
            puts "Error: $msg"
        }
    } finally {
        return $ret
    }
}

proc morji::run {} {
    variables FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN TEST
    set found_cards 0
    foreach f {get_today_cards get_forgotten_cards get_new_cards} {
        set cards [db transaction {$f}]
        if {[llength $cards] > 0} {
            set found_cards 1
            set n [llength $cards]
        }
        foreach card $cards {
            put_screen_start
            put_phase_info $f $n
            incr n -1
            set ret ""
            set FIRST_ACTION_FOR_CARD 1
            set ANSWER_ALREADY_SEEN 0
            while {$ret ne "scheduled"} {
                set ret [within_transaction {card_prompt $card}]
                set FIRST_ACTION_FOR_CARD 0
                switch $ret {
                    quit { quit }
                    restart { tailcall run }
                    next_day { tailcall test_go_to_next_day }
                }
            }
        }
    }
    if {$found_cards} {
        tailcall run
    }
    if {$TEST} {
        tailcall test_go_to_next_day
    } else {
        put_screen_start
        put_info "No cards to review nor new cards"
        set ret ""
        while {1} {
            set ret [within_transaction {no_card_prompt}]
            switch $ret {
                quit { quit }
                restart { tailcall run }
            }
        }
    }
}

proc morji::start {} {
    set ret 0
    try {
        run
    } on error {result} {
        puts stderr "morji: fatal error: $result"
        set ret 1
    } finally {
        db close
    }
    exit $ret
}

proc morji::quit {} {
    db close
    exit
}

proc morji::test_go_to_next_day {} {
    # This function is for testing purposes. It advances time to next day.
    variable START_TIME
    draw_line
    put_info "... Next Day (testing)"
    draw_line
    puts -nonewline "from [clock format $START_TIME] "
    set START_TIME [clock add $START_TIME 1 day]
    puts "to [clock format $START_TIME]"
    set key [get_key "(press any key or Q to quit) >>"]
    if {$key eq "Q"} {
        quit
    }
    tailcall run
}

proc morji::get_config_location {} {
    if {[info exists ::env(XDG_CONFIG_HOME)]} {
        set config_dir $::env(XDG_CONFIG_HOME)/morji
    } else {
        set config_dir $::env(HOME)/.config/morji
    }
    if {![file exists $config_dir] || ![file exists $config_dir/init.tcl]} {
        file mkdir $config_dir
        set fh [open $config_dir/init.tcl w]
        puts $fh {# morji configuration file
#markup em styled bold
}
        close $fh
    }
    return $config_dir/init.tcl
}

proc morji::process_config {{file {}}} {
    try {
        if {$file eq ""} {
            set file [get_config_location]
        }
        namespace eval config source $file
    } on error {msg more} {
        puts stderr "morji: error reading configuration file: $msg.\nDetails:"
        puts stderr [dict get $more -errorinfo]
        exit 1
    }
}

proc morji::do_backup {data_dir} {
    if {![file exists $data_dir/backups]} {
        file mkdir $data_dir/backups
    }
    set dbfile $data_dir/morji.db
    set backup_file $data_dir/backups/backup.db
    if {[file exists $dbfile] && [file exists $backup_file]} {
        if {[file mtime $dbfile] - [file mtime $backup_file] >= 86400} {
            sqlite3 db $dbfile
            try {
                file rename -force $backup_file $backup_file.old
                db backup $backup_file
            } finally {
                db close
            }
        }
    } else {
        sqlite3 db $dbfile
        try { db backup $backup_file } finally { db close }
    }
}

proc morji::get_db_location {} {
    if {[info exists ::env(XDG_DATA_HOME)]} {
        set data_dir $::env(XDG_DATA_HOME)/morji
    } else {
        set data_dir $::env(HOME)/.local/share/morji
    }
    if {![file exists $data_dir]} {
        file mkdir $data_dir
    }
    do_backup $data_dir
    return $data_dir/morji.db
}

proc morji::init {{dbfile :memory:}} {
    try {
        init_state $dbfile
    } on error {msg} {
        puts stderr "morji: error initializing database: $msg"
        if {[namespace which -command db] ne ""} {
            db close
        }
        exit 1
    }
}

proc morji::main {} {
    variables TEXT_WIDTH NO_CLEAR_SCREEN
    set options {
        {c.arg "" "custom config file location"}
        {f.arg "" "custom database file location"}
        {n "" "no screen clear"}
        {v "" "show version"}
        {w.arg "" "text width"}
        {x.arg "" "name of script to execute"}
    }
    set usage ": morji \[-n\] \[v\] \[-c config-file\] \[-f db-file\] \[-w width\] \[-x script-file\]\nOptions:"
    try {
        array set params [::cmdline::getoptions ::argv $options $usage]
    } trap {CMDLINE USAGE} {msg} {
        puts stderr $msg
        exit 1
    }
    if {$params(v)} {
        puts "v0.3"
        exit 0
    }
    if {$params(c) ne ""} {
        if {[file exists $params(c)]} {
            process_config $params(c)
        } else {
            puts stderr "morji: error: no such file: $params(c)"
            exit 1
        }
    } else {
        process_config
    }
    if {$params(f) ne ""} {
        init $params(f)
    } else {
        try {
            set dbfile [get_db_location]
        } on error {msg} {
            puts stderr "Getting db file location: $msg"
            exit 1
        }
        init $dbfile
    }
    if {($params(w) ne "") && [string is integer $params(w)]} {
        set TEXT_WIDTH $params(w)
        if {$TEXT_WIDTH < 30} {
            set TEXT_WIDTH 30
        }
    }
    if {$params(n)} {
        set NO_CLEAR_SCREEN 1
    }
    if {$params(x) ne ""} {
        db transaction {
            source $params(x)
            if {![check_database] || ![prompt_confirmation "Ok"]} {
                puts "Any changes rolled back."
            }
        }
        exit 0
    }
    start
}

if {!([info exists morji::TEST] && $morji::TEST)} {
    set morji::TEST 0
    morji::main
}

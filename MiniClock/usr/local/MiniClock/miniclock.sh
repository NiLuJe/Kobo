#!/bin/sh

export LD_LIBRARY_PATH="/usr/local/MiniClock:${LD_LIBRARY_PATH}"
PATH="/usr/local/MiniClock:${PATH}"
BASE="/mnt/onboard/.addons/miniclock"
CONFIGFILE="${BASE}/miniclock.cfg"
# Use a custom FBInk pipe
export FBINK_NAMED_PIPE="/tmp/MiniClock/fbink-fifo"

# Kill all the things on exit
trap die 0 1 2 3 15
die() {
    kill_fbink
    pkill -TERM devinputeventdump
    #rm -rf /tmp/MiniClock
    exit 0
}

# udev kills slow scripts
udev_workarounds() {
    if [ "$SETSID" != "1" ]
    then
        renice 0 -p $$
        SETSID=1 setsid "$0" "$@" &
        exit
    fi

    # udev might call twice
    mkdir /tmp/MiniClock || exit
    # /tmp is mounted relatime, so we need to check a child file, and not our own folder,
    # otherwise, writing to a child file (like, say, the FBInk FIFO) updates the parent folder's atime.
    touch /tmp/MiniClock/config.ts
}

# nickel stuff
wait_for_nickel() {
    while ! pidof nickel >/dev/null 2>&1 || ! grep -q /mnt/onboard /proc/mounts
    do
        sleep 5
    done
}

# config parser
config() {
    local key value
    key=$(grep -E "^$1\s*=" "$CONFIGFILE")
    _ret=$?
    if [ ${_ret} -eq 0 ]
    then
        value=$(printf "%s" "$key" | tail -n 1 | sed -r -e 's@^[^=]*=\s*@@' -e 's@\s+(#.*|)$@@')
        echo "$value"
    else
        shift
        echo "$@"
    fi
}

uninstall_check() {
    if [ "$(config uninstall 0)" = "1" ]
    then
        mv "$CONFIGFILE" "$BASE"/uninstalled-$(date +%Y%m%d-%H%M).cfg
        rm -f /etc/udev/rules.d/MiniClock.rules
        rm -rf /usr/local/MiniClock /tmp/MiniClock
        exit
    fi
}

# Refresh our local fb state data, in order to have up-to-date info for accurate pixel watching...
refresh_fb_data() {
    # We'll need the up to date fb state for the pixel watching...
    eval $(fbink -e)
    # Let's try with a pixel in the middle (+/- viewport quirks) of the screen, to account for edge-cases where edge rows/columns may not be painted to...
    # This should never actually make it to a refresh, so we don't particularly care about its position.
    # And even if it did, you'd be hard-pressed to spot a single pixel on a 300dpi screen, especially one that's almost white...
    pixel_bytes="$((BPP>>3))"
    # NOTE: Handle quirky rotated fb for older FW versions...
    if [ "${isNTX16bLandscape}" -eq 1 ]
    then
        # c.f., initialize_fbink(), in this state, (screen|view)Height == xres & (screen|view)Width == yres
        pixel_address="$((((screenHeight >> 1) * pixel_bytes) + ((screenWidth >> 1) * lineLength)))"
    else
        pixel_address="$((((screenWidth >> 1) * pixel_bytes) + ((screenHeight >> 1) * lineLength)))"
    fi
    # Handle various bitdepths, to be extra safe...
    case "$pixel_bytes" in
        4)
            # BGRA
            pixel_value=$'\xde\xad\xbe\xef'
        ;;
        3)
            # BGR
            pixel_value=$'\xd0\x0d\xad'
        ;;
        2)
            # Stupid RGB565
            pixel_value=$'\xde\xad'
        ;;
        1)
            # Gray8
            pixel_value=$'\x42'
        ;;
        *)
            # Alien abduction
            pixel_value=$'\xde\xad\xbe\xef'
        ;;
    esac
}

## Check if arg is an int
is_integer()
{
    # Cheap trick ;)
    [ "${1}" -eq "${1}" ] 2>/dev/null
    return $?
}

# loads a config file but only if it was never loaded or changed since last load
load_config() {
    [ -z "${config_loaded:-}" ] || grep -q /mnt/onboard /proc/mounts || return 1 # not mounted
    [ -z "${config_loaded:-}" ] || [ "$CONFIGFILE" -nt /tmp/MiniClock/config.ts ] || [ "$CONFIGFILE" -ot /tmp/MiniClock/config.ts ] || return 1 # not changed
    config_loaded=1
    touch -r "$CONFIGFILE" /tmp/MiniClock/config.ts # remember timestamp

    uninstall_check
    cfg_debug=$(config debug '0')

    cfg_input_devices=$(printf "/dev/input/event%s " $(config input_devices '1'))

    cfg_whitelist=$(config whitelist 'ABS:MT_POSITION_X ABS:MT_POSITION_Y KEY:F23 KEY:F24 KEY:POWER ABS:X ABS:Y')
    cfg_graylist=$(config graylist 'MSC:RAW')
    cfg_cooldown=$(config cooldown '5 30')

    cfg_format=$(config format '%a %b %d %H:%M')
    cfg_column=$(config column '0')
    cfg_row=$(config row '0')
    cfg_offset_x=$(config offset_x '0')
    cfg_offset_y=$(config offset_y '0')
    cfg_font=$(config font 'IBM')
    cfg_size=$(config size '0')
    cfg_fg_color=$(config fg_color 'BLACK')
    cfg_bg_color=$(config bg_color 'WHITE')
    cfg_backgroundless=$(config backgroundless '0')
    cfg_overlay=$(config overlay '0')
    cfg_delay=$(config delay '1 1 1')
    cfg_aggressive_timing=$(config aggressive_timing '0')

    cfg_truetype=$(config truetype '')
    cfg_truetype_size=$(config truetype_size '16.0')
    cfg_truetype_px=$(config truetype_px '0')
    cfg_truetype_x=$(config truetype_x "$cfg_offset_x")
    cfg_truetype_y=$(config truetype_y "$cfg_offset_y")
    cfg_truetype_fg=$(config truetype_fg "$cfg_fg_color")
    cfg_truetype_bg=$(config truetype_bg "$cfg_bg_color")
    cfg_truetype_format=$(config truetype_format "$cfg_format")
    cfg_truetype_bold=$(config truetype_bold '')
    cfg_truetype_italic=$(config truetype_italic '')
    cfg_truetype_bolditalic=$(config truetype_bolditalic '')
    cfg_truetype_padding=$(config truetype_padding '0')

    cfg_nightmode_check=$(config check_nightmode '1')
    cfg_nightmode_file=$(config nightmode_file '/mnt/onboard/.kobo/Kobo/Kobo eReader.conf')
    cfg_nightmode_key=$(config nightmode_key 'InvertScreen')
    cfg_nightmode_value=$(config nightmode_value 'true')

    cfg_battery_min=$(config battery_min '0')
    cfg_battery_max=$(config battery_max '50')
    cfg_battery_source=$(config battery_source '/sys/devices/platform/pmic_battery.1/power_supply/mc13892_bat/capacity')

    cfg_days=$(config days '')
    cfg_months=$(config months '')

    # backward support for deprecated settings:

    # delay=1 repeat=3 -> delay=1 1 1
    cfg_repeat=$(config repeat '')
    if [ "$cfg_repeat" != "" ]
    then
        set -- $cfg_delay
        if [ $# -eq 1 ] && [ "$cfg_repeat" -gt 1 ]
        then
            cfg_delay=""
            for i in $(seq 1 "$cfg_repeat")
            do
                cfg_delay="$cfg_delay $1"
            done
        fi
    fi

    # calculated settings:
    if [ "$cfg_backgroundless" != "0" ]
    then
        backgroundless="--bgless"
    else
        backgroundless=""
    fi

    if [ "$cfg_overlay" != "0" ]
    then
        overlay="--overlay"
    else
        overlay=""
    fi

    # delta for sharp idle update
    set -- $cfg_delay
    #cfg_delta=$(awk "BEGIN {print ${i} + 1}")
    #cfg_delta=${cfg_delta:-0}

    # padding is spaces for now
    if [ "$cfg_truetype_padding" != "0" ]
    then
        cfg_truetype_format=" $cfg_truetype_format "
    fi

    # localization shenaniganizer
    my_date() {
        date "$@"
    }

    my_tt_date() {
        date "$@"
    }

    case "$cfg_format" in
        *{*)
        my_date() {
            shenaniganize_date "$@"
        }
        ;;
    esac

    case "$cfg_truetype_format" in
        *{*)
        my_tt_date() {
            shenaniganize_date "$@"
        }
        ;;
    esac

    # Auto-detect whether we need to bother with visual debug, or reading the frontlight level
    cfg_causality=0
    cfg_frontlight_check=0
    case "$cfg_format $cfg_truetype_format" in
        *{debug}*)      cfg_causality=1 ;;
        *{frontlight}*) cfg_frontlight_check=1 ;;
    esac

    do_debug_log() {
        echo "$@" >> "${BASE}/debuglog.txt"
    }

    if [ "$cfg_debug" = "1" ]
    then
        debug_log() {
            return 0 # yes
        }
    else
        debug_log() {
            return 1 # no
        }
    fi

    debug_log && do_debug_log "-- config file read $(date) --"
    debug_log && do_debug_log "-- cfg_debug = '$cfg_debug', format {debug} = '$cfg_causality' --"

    # whitelist filtering (string to number)
    debug_log && do_debug_log "-- cfg_whitelist = '$cfg_whitelist' --"
    set -- $cfg_whitelist
    cfg_whitelist=""
    for item in $@
    do
        set -- ${item//:/ }
        [ $# != 2 ] && continue
        set -- $(input_event_str2int $1 $2)
        [ $# != 2 ] && continue
        cfg_whitelist="$cfg_whitelist $1:$2"
    done
    debug_log && do_debug_log "-- cfg_whitelist (str2int) = '$cfg_whitelist' --"

    # graylist filtering (string to number)
    debug_log && do_debug_log "-- cfg_graylist = '$cfg_graylist' --"
    set -- $cfg_graylist
    cfg_graylist=""
    for item in $@
    do
        set -- ${item//:/ }
        [ $# != 2 ] && continue
        set -- $(input_event_str2int $1 $2)
        [ $# != 2 ] && continue
        cfg_graylist="$cfg_graylist $1:$2"
    done
    debug_log && do_debug_log "-- cfg_graylist (str2int) = '$cfg_graylist' --"

    # NOTE: Ideally, this ought to be the only time we need to refresh this,
    #       but Kobo bitdepth & rotation shenanigans make this more annoying than it ought to,
    #       c.f., the matching note in fbink_reinit() (both here and in FBInk)...
    refresh_fb_data
    debug_log && do_debug_log "-- current fb state -- rota ${currentRota} @ ${BPP}bpp (quirky: ${isNTX16bLandscape})"
    # Now that we've got it (from the eval in refresh_fb_data), print the FBInk version, too.
    debug_log && do_debug_log "-- using FBInk ${FBINK_VERSION} --"

    # Check the FW version, to see if we can enforce nightmode support in FBInk if we detect a recent enough version...
    NICKEL_BUILD="$(awk 'BEGIN {FS=","}; {split($3, FW, "."); print FW[3]};' "/mnt/onboard/.kobo/version")"
    debug_log && do_debug_log "-- running on Nickel build number ${NICKEL_BUILD} --"

    # If it's sane, and newer than 4.2.8432, enforce HW inversion support
    # This is only useful for the Aura, which used to be crashy on earlier kernels...
    # NOTE: Final Aura kernel is r7860_#2049 built 01/09/17 05:33:13;
    #       FW 4.2.8432 was released February 2017;
    #       the previous FW release was 3.19.5761 in December 2015 (!).
    if is_integer "${NICKEL_BUILD}" && [ "${NICKEL_BUILD}" -ge "8432" ]
    then
        export FBINK_ALLOW_HW_INVERT=1
        debug_log && do_debug_log "-- enforcing HW inversion support --"
    else
        unset FBINK_ALLOW_HW_INVERT
        debug_log && do_debug_log "-- FW version too old to enforce HW inversion support --"
    fi

    # Make sure font paths are absolute, because the FBInk daemon has a different PWD than us.
    [ "${cfg_truetype:0:1}" != "/" ] && cfg_truetype="${BASE}/${cfg_truetype}"
    [ "${cfg_truetype_bold:0:1}" != "/" ] && cfg_truetype_bold="${BASE}/${cfg_truetype_bold}"
    [ "${cfg_truetype_italic:0:1}" != "/" ] && cfg_truetype_italic="${BASE}/${cfg_truetype_italic}"
    [ "${cfg_truetype_bolditalic:0:1}" != "/" ] && cfg_truetype_bolditalic="${BASE}/${cfg_truetype_bolditalic}"

    # Ensure we'll restart the FBInk daemon on config (re-)load
    fbink_with_truetype=-1
}

# string replace str a b
str_replace() {
    local pre post
    pre=${1%%"$2"*}
    post=${1#*"$2"}
    echo "$pre$3$post"
}

# shenaniganize date (runs in a subshell)
shenaniganize_date() {
    local datestr=$(date "$@")
    local pre post

    # shenaniganize all the stuff
    for i in $(seq 100) # terminate on invalid strings
    do
        case "$datestr" in
            *{frontlight}*)
                datestr=$(str_replace "$datestr" "{frontlight}" "$frontlight")
            ;;
            *{battery}*)
                IFS= read -r battery < "$cfg_battery_source"
                if is_integer "$battery" && [ "$battery" -ge "$cfg_battery_min" ] && [ "$battery" -le "$cfg_battery_max" ]
                then
                    battery="${battery}%"
                else
                    battery=""
                fi
                datestr=$(str_replace "$datestr" "{battery}" "$battery")
            ;;
            *{day}*)
                set -- "" $cfg_days
                day=$(date +%u)
                shift $day
                datestr=$(str_replace "$datestr" "{day}" "$1")
            ;;
            *{month}*)
                set -- "" $cfg_months
                month=$(date +%m)
                shift $month
                datestr=$(str_replace "$datestr" "{month}" "$1")
            ;;
            *{debug}*)
                read -r uptime runtime < /proc/uptime
                datestr=$(str_replace "$datestr" "{debug}" "[${causality} @ ${uptime}]")
            ;;
            *)
                echo "$datestr"
                return
            ;;
        esac
    done
}

# nightmode check
nightmode_check() {
    if [ "$cfg_nightmode_check" -ne "1" ]
    then
        return
    fi

    [ ! -e /tmp/MiniClock/nightmode ] && touch /tmp/MiniClock/nightmode

    if [ "$cfg_nightmode_file" -nt /tmp/MiniClock/nightmode ] || [ "$cfg_nightmode_file" -ot /tmp/MiniClock/nightmode ]
    then
        # nightmode state might have changed
        nightmode=$(CONFIGFILE="$cfg_nightmode_file" config "$cfg_nightmode_key" "not $cfg_nightmode_value")

        if [ "$nightmode" = "$cfg_nightmode_value" ]
        then
            # We need hardware nightmode in overlay or bgless mode...
            if [ "$cfg_overlay" != "0" ] || [ "$cfg_backgroundless" != "0" ]
            then
                nightmode="--nightmode"
            else
                nightmode="--invert"
            fi
        else
            nightmode=""
        fi

        # remember timestamp so we don't have to do this every time
        touch -r "$cfg_nightmode_file" /tmp/MiniClock/nightmode

        # If nightmode state actually changed, we'll need to restart the FBInk daemon
        if [ "$nightmode" != "$prev_nightmode" ]
        then
            debug_log && do_debug_log "-- nightmode state switch -- ${prev_nightmode} -> ${nightmode}"
            fbink_with_truetype=-1
        fi
        prev_nightmode="$nightmode"
    fi
}

# frontlight check
frontlight_check() {
    if [ "$cfg_frontlight_check" -ne "1" ]
    then
        return
    fi

    [ ! -e /tmp/MiniClock/frontlight ] && touch /tmp/MiniClock/frontlight

    if [ "/mnt/onboard/.kobo/Kobo/Kobo eReader.conf" -nt /tmp/MiniClock/frontlight ] || [ "/mnt/onboard/.kobo/Kobo/Kobo eReader.conf" -ot /tmp/MiniClock/frontlight ]
    then
        # frontlight state might have changed
        frontlight=$(CONFIGFILE="/mnt/onboard/.kobo/Kobo/Kobo eReader.conf" config "FrontLightLevel" "??")

        # remember timestamp so we don't have to do this every time
        touch -r "/mnt/onboard/.kobo/Kobo/Kobo eReader.conf" /tmp/MiniClock/frontlight
    fi
}

# Check if the FBInk daemon is up
fbink_is_up() {
    if [ "${fbink_pid}" = '' ]
    then
        # Empty
        return 1
    fi

    if ! is_integer "${fbink_pid}"
    then
        # Not a PID?!
        return 1
    fi

    if [ -d "/proc/${fbink_pid}" ]
    then
        # It's alive
        if grep -q '%MINICLOCK%' /proc/${fbink_pid}/cmdline
        then
            # It's ours
            return 0
        fi
    fi

    # Meep!
    return 1
}

# Kill the current FBInk daemon
kill_fbink() {
    if fbink_is_up
    then
        kill -TERM $fbink_pid
        debug_log && do_debug_log "-- killed FBInk daemon -- ${fbink_pid} ${1}"
    fi
}

# Attempt to recover in case something awry happens, and we're left with no daemon but a FIFO,
# which would prevent a new daemon from respawning...
really_kill_fbink() {
    if ! fbink_is_up
    then
        # If there's a stray MiniClock FBInk daemon, kill it.
        fbink_pid="$(pgrep -f 'fbink --daemon 1 %MINICLOCK%')"
        kill_fbink "(stray)"

        # If the FIFO is somehow still there, remove it.
        if [ -p "${FBINK_NAMED_PIPE}" ]
        then
            rm -f "${FBINK_NAMED_PIPE}"
            debug_log && do_debug_log "-- removed broken FBInk pipe --"
        fi
    fi
}

# (re-)start the FBInk daemon (but only if we need to swap between OT/bitmap fonts)
fbink_check() {
    # NOTE: Technically, we only need to be able to read the fonts at daemon startup.
    #       With a bit of trickery, we could probably manage to keep a previous truetype daemon up during USBMS sessions...
    if [ -f "$cfg_truetype" ]
    then
        if [ "$fbink_with_truetype" -eq "1" ]
        then
            # Double-check that nothing awful happened to the FBInk daemon...
            if fbink_is_up
            then
                debug_log && do_debug_log "-- truetype FBInk daemon is already up --"
                return
            fi
        fi

        kill_fbink

        # variants available?
        truetype="regular=$cfg_truetype"
        [ -f "$cfg_truetype_bold" ] && truetype="$truetype,bold=$cfg_truetype_bold"
        [ -f "$cfg_truetype_italic" ] && truetype="$truetype,italic=$cfg_truetype_italic"
        [ -f "$cfg_truetype_bolditalic" ] && truetype="$truetype,bolditalic=$cfg_truetype_bolditalic"

        fbink_pid="$(fbink --daemon 1 %MINICLOCK% \
                    --truetype "$truetype",size="$cfg_truetype_size",px="$cfg_truetype_px",top="$cfg_truetype_y",bottom=0,left="$cfg_truetype_x",right=0,format \
                    -C "$cfg_truetype_fg" -B "$cfg_truetype_bg" $backgroundless $overlay \
                    $nightmode)"
        _ret=$?
        if [ ${_ret} -eq 0 ] && fbink_is_up
        then
            fbink_with_truetype=1
            debug_log && do_debug_log "-- launched truetype FBInk daemon -- ${fbink_pid}"
        else
            fbink_pid=''
            fbink_with_truetype=-1
            debug_log && do_debug_log "-- failed to launch truetype FBInk daemon --"
            # Attempt to recover...
            really_kill_fbink
        fi
    else
        if [ "$fbink_with_truetype" -eq "0" ]
        then
            # Double-check that nothing awful happened to the FBInk daemon...
            if fbink_is_up
            then
                debug_log && do_debug_log "-- bitmap FBInk daemon is already up --"
                return
            fi
        fi

        kill_fbink

        fbink_pid="$(fbink --daemon 1 %MINICLOCK% \
                    -x "$cfg_column" -X "$cfg_offset_x" -y "$cfg_row" -Y "$cfg_offset_y" \
                    -F "$cfg_font" -S "$cfg_size" \
                    -C "$cfg_fg_color" -B "$cfg_bg_color" $backgroundless $overlay \
                    $nightmode)"
        _ret=$?
        if [ ${_ret} -eq 0 ] && fbink_is_up
        then
            fbink_with_truetype=0
            debug_log && do_debug_log "-- launched bitmap FBInk daemon -- ${fbink_pid}"
        else
            fbink_pid=''
            fbink_with_truetype=-1
            debug_log && do_debug_log "-- failed to launch bitmap FBInk daemon --"
            # Attempt to recover...
            really_kill_fbink
        fi
    fi
}

# Refresh our own fb state if need be, much like FBInk's fbink_reinit
fbink_reinit() {
    # NOTE: In order to make the pixel/dd shenanigans accurate,
    #       we need to ensure the address and size of said pixel are up to date,
    #       given Kobo's propension for bitdepth & rotation changes...
    #       In order to avoid an useless fork if we were to simply always run refresh_fb_data,
    #       we'll mimic FBInk's fbink_reinit logic with clunky shell builtins.
    #       Busybox being what it is, this is probably barely any faster than just always running refresh_fb_data...
    #       Oh, well...
    local new_bpp new_rota
    IFS= read -r new_bpp < "/sys/class/graphics/fb0/bits_per_pixel"
    IFS= read -r new_rota < "/sys/class/graphics/fb0/rotate"
    if [ "${BPP}" != "${new_bpp}" ]
    then
        debug_log && do_debug_log "-- detected a change in framebuffer bitdepth, refreshing -- ${BPP} -> ${new_bpp}"
        refresh_fb_data
        debug_log && do_debug_log "-- new fb state -- rota ${currentRota} @ ${BPP}bpp (quirky: ${isNTX16bLandscape})"
    elif [ "${currentRota}" != "${new_rota}" ]
    then
        debug_log && do_debug_log "-- detected a change in framebuffer rotation, refreshing -- ${currentRota} -> ${new_rota}"
        refresh_fb_data
        debug_log && do_debug_log "-- new fb state -- rota ${currentRota} @ ${BPP}bpp (quirky: ${isNTX16bLandscape})"
    fi
}

update() {
    sleep 0.1

    debug_log && do_debug_log "-- clock update $(date) --"

    ( # subshell

    cd "$BASE" # blocks USB lazy-umount and cd / doesn't work

    # NOTE: We're technically using the config's *previous* state here, which means that, when swapping between bitmap/truetype,
    #       the first bitmap update will be sent a truetype string, and vice-versa.
    #       This is only potentially problematic if padding is enabled, as the extra width needed *may* affect the final layout...
    if [ -f "$cfg_truetype" ]
    then
        echo -n "$(my_tt_date +"$cfg_truetype_format")" > "$FBINK_NAMED_PIPE"
    else
        echo -n "$(my_date +"$cfg_format")" > "$FBINK_NAMED_PIPE"
    fi

    ) # subshell end / unblock
}

# --- Input Event Helpers: ---

EV="SYN KEY REL ABS MSC SW 0x6 0x7 0x8 0x9 0xa 0xb 0xc 0xd 0xe 0xf 0x10 LED SND 0x13 REP FF PWR FF_STATUS 0x18 0x19 0x1a 0x1b 0x1c 0x1d 0x1e MAX"
EV_SYN="REPORT CONFIG MT_REPORT DROPPED 0x4 0x5 0x6 0x7 0x8 0x9 0xa 0xb 0xc 0xd 0xe MAX"
EV_KEY="RESERVED ESC 1 2 3 4 5 6 7 8 9 0 MINUS EQUAL BACKSPACE TAB Q W E R T Y U I O P LEFTBRACE RIGHTBRACE ENTER LEFTCTRL A S D F G H J K L SEMICOLON APOSTROPHE GRAVE LEFTSHIFT BACKSLASH Z X C V B N M COMMA DOT SLASH RIGHTSHIFT KPASTERISK LEFTALT SPACE CAPSLOCK F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 NUMLOCK SCROLLLOCK KP7 KP8 KP9 KPMINUS KP4 KP5 KP6 KPPLUS KP1 KP2 KP3 KP0 KPDOT 0x54 ZENKAKUHANKAKU 102ND F11 F12 RO KATAKANA HIRAGANA HENKAN KATAKANAHIRAGANA MUHENKAN KPJPCOMMA KPENTER RIGHTCTRL KPSLASH SYSRQ RIGHTALT LINEFEED HOME UP PAGEUP LEFT RIGHT END DOWN PAGEDOWN INSERT DELETE MACRO MUTE VOLUMEDOWN VOLUMEUP POWER KPEQUAL KPPLUSMINUS PAUSE SCALE KPCOMMA HANGEUL HANJA YEN LEFTMETA RIGHTMETA COMPOSE STOP AGAIN PROPS UNDO FRONT COPY OPEN PASTE FIND CUT HELP MENU CALC SETUP SLEEP WAKEUP FILE SENDFILE DELETEFILE XFER PROG1 PROG2 WWW MSDOS COFFEE ROTATE_DISPLAY CYCLEWINDOWS MAIL BOOKMARKS COMPUTER BACK FORWARD CLOSECD EJECTCD EJECTCLOSECD NEXTSONG PLAYPAUSE PREVIOUSSONG STOPCD RECORD REWIND PHONE ISO CONFIG HOMEPAGE REFRESH EXIT MOVE EDIT SCROLLUP SCROLLDOWN KPLEFTPAREN KPRIGHTPAREN NEW REDO F13 F14 F15 F16 F17 F18 F19 F20 F21 F22 F23 F24 0xc3 0xc4 0xc5 0xc6 0xc7 PLAYCD PAUSECD PROG3 PROG4 DASHBOARD SUSPEND CLOSE PLAY FASTFORWARD BASSBOOST PRINT HP CAMERA SOUND QUESTION EMAIL CHAT SEARCH CONNECT FINANCE SPORT SHOP ALTERASE CANCEL BRIGHTNESSDOWN BRIGHTNESSUP MEDIA SWITCHVIDEOMODE KBDILLUMTOGGLE KBDILLUMDOWN KBDILLUMUP SEND REPLY FORWARDMAIL SAVE DOCUMENTS BATTERY BLUETOOTH WLAN UWB UNKNOWN VIDEO_NEXT VIDEO_PREV BRIGHTNESS_CYCLE BRIGHTNESS_AUTO DISPLAY_OFF WWAN RFKILL MICMUTE 0xf9 0xfa 0xfb 0xfc 0xfd 0xfe 0xff BTN_0 BTN_1 BTN_2 BTN_3 BTN_4 BTN_5 BTN_6 BTN_7 BTN_8 BTN_9 0x10a 0x10b 0x10c 0x10d 0x10e 0x10f BTN_LEFT BTN_RIGHT BTN_MIDDLE BTN_SIDE BTN_EXTRA BTN_FORWARD BTN_BACK BTN_TASK 0x118 0x119 0x11a 0x11b 0x11c 0x11d 0x11e 0x11f BTN_TRIGGER BTN_THUMB BTN_THUMB2 BTN_TOP BTN_TOP2 BTN_PINKIE BTN_BASE BTN_BASE2 BTN_BASE3 BTN_BASE4 BTN_BASE5 BTN_BASE6 0x12c 0x12d 0x12e BTN_DEAD BTN_SOUTH BTN_EAST BTN_C BTN_NORTH BTN_WEST BTN_Z BTN_TL BTN_TR BTN_TL2 BTN_TR2 BTN_SELECT BTN_START BTN_MODE BTN_THUMBL BTN_THUMBR 0x13f BTN_TOOL_PEN BTN_TOOL_RUBBER BTN_TOOL_BRUSH BTN_TOOL_PENCIL BTN_TOOL_AIRBRUSH BTN_TOOL_FINGER BTN_TOOL_MOUSE BTN_TOOL_LENS BTN_TOOL_QUINTTAP BTN_STYLUS3 BTN_TOUCH BTN_STYLUS BTN_STYLUS2 BTN_TOOL_DOUBLETAP BTN_TOOL_TRIPLETAP BTN_TOOL_QUADTAP BTN_GEAR_DOWN BTN_GEAR_UP 0x152 0x153 0x154 0x155 0x156 0x157 0x158 0x159 0x15a 0x15b 0x15c 0x15d 0x15e 0x15f OK SELECT GOTO CLEAR POWER2 OPTION INFO TIME VENDOR ARCHIVE PROGRAM CHANNEL FAVORITES EPG PVR MHP LANGUAGE TITLE SUBTITLE ANGLE FULL_SCREEN MODE KEYBOARD ASPECT_RATIO PC TV TV2 VCR VCR2 SAT SAT2 CD TAPE RADIO TUNER PLAYER TEXT DVD AUX MP3 AUDIO VIDEO DIRECTORY LIST MEMO CALENDAR RED GREEN YELLOW BLUE CHANNELUP CHANNELDOWN FIRST LAST AB NEXT RESTART SLOW SHUFFLE BREAK PREVIOUS DIGITS TEEN TWEN VIDEOPHONE GAMES ZOOMIN ZOOMOUT ZOOMRESET WORDPROCESSOR EDITOR SPREADSHEET GRAPHICSEDITOR PRESENTATION DATABASE NEWS VOICEMAIL ADDRESSBOOK MESSENGER DISPLAYTOGGLE SPELLCHECK LOGOFF DOLLAR EURO FRAMEBACK FRAMEFORWARD CONTEXT_MENU MEDIA_REPEAT 10CHANNELSUP 10CHANNELSDOWN IMAGES 0x1bb 0x1bc 0x1bd 0x1be 0x1bf DEL_EOL DEL_EOS INS_LINE DEL_LINE 0x1c4 0x1c5 0x1c6 0x1c7 0x1c8 0x1c9 0x1ca 0x1cb 0x1cc 0x1cd 0x1ce 0x1cf FN FN_ESC FN_F1 FN_F2 FN_F3 FN_F4 FN_F5 FN_F6 FN_F7 FN_F8 FN_F9 FN_F10 FN_F11 FN_F12 FN_1 FN_2 FN_D FN_E FN_F FN_S FN_B 0x1e5 0x1e6 0x1e7 0x1e8 0x1e9 0x1ea 0x1eb 0x1ec 0x1ed 0x1ee 0x1ef 0x1f0 BRL_DOT1 BRL_DOT2 BRL_DOT3 BRL_DOT4 BRL_DOT5 BRL_DOT6 BRL_DOT7 BRL_DOT8 BRL_DOT9 BRL_DOT10 0x1fb 0x1fc 0x1fd 0x1fe 0x1ff NUMERIC_0 NUMERIC_1 NUMERIC_2 NUMERIC_3 NUMERIC_4 NUMERIC_5 NUMERIC_6 NUMERIC_7 NUMERIC_8 NUMERIC_9 NUMERIC_STAR NUMERIC_POUND NUMERIC_A NUMERIC_B NUMERIC_C NUMERIC_D CAMERA_FOCUS WPS_BUTTON TOUCHPAD_TOGGLE TOUCHPAD_ON TOUCHPAD_OFF CAMERA_ZOOMIN CAMERA_ZOOMOUT CAMERA_UP CAMERA_DOWN CAMERA_LEFT CAMERA_RIGHT ATTENDANT_ON ATTENDANT_OFF ATTENDANT_TOGGLE LIGHTS_TOGGLE 0x21f BTN_DPAD_UP BTN_DPAD_DOWN BTN_DPAD_LEFT BTN_DPAD_RIGHT 0x224 0x225 0x226 0x227 0x228 0x229 0x22a 0x22b 0x22c 0x22d 0x22e 0x22f ALS_TOGGLE ROTATE_LOCK_TOGGLE 0x232 0x233 0x234 0x235 0x236 0x237 0x238 0x239 0x23a 0x23b 0x23c 0x23d 0x23e 0x23f BUTTONCONFIG TASKMANAGER JOURNAL CONTROLPANEL APPSELECT SCREENSAVER VOICECOMMAND ASSISTANT 0x248 0x249 0x24a 0x24b 0x24c 0x24d 0x24e 0x24f BRIGHTNESS_MIN BRIGHTNESS_MAX 0x252 0x253 0x254 0x255 0x256 0x257 0x258 0x259 0x25a 0x25b 0x25c 0x25d 0x25e 0x25f KBDINPUTASSIST_PREV KBDINPUTASSIST_NEXT KBDINPUTASSIST_PREVGROUP KBDINPUTASSIST_NEXTGROUP KBDINPUTASSIST_ACCEPT KBDINPUTASSIST_CANCEL RIGHT_UP RIGHT_DOWN LEFT_UP LEFT_DOWN ROOT_MENU MEDIA_TOP_MENU NUMERIC_11 NUMERIC_12 AUDIO_DESC 3D_MODE NEXT_FAVORITE STOP_RECORD PAUSE_RECORD VOD UNMUTE FASTREVERSE SLOWREVERSE DATA ONSCREEN_KEYBOARD 0x279 0x27a 0x27b 0x27c 0x27d 0x27e 0x27f 0x280 0x281 0x282 0x283 0x284 0x285 0x286 0x287 0x288 0x289 0x28a 0x28b 0x28c 0x28d 0x28e 0x28f 0x290 0x291 0x292 0x293 0x294 0x295 0x296 0x297 0x298 0x299 0x29a 0x29b 0x29c 0x29d 0x29e 0x29f 0x2a0 0x2a1 0x2a2 0x2a3 0x2a4 0x2a5 0x2a6 0x2a7 0x2a8 0x2a9 0x2aa 0x2ab 0x2ac 0x2ad 0x2ae 0x2af 0x2b0 0x2b1 0x2b2 0x2b3 0x2b4 0x2b5 0x2b6 0x2b7 0x2b8 0x2b9 0x2ba 0x2bb 0x2bc 0x2bd 0x2be 0x2bf BTN_TRIGGER_HAPPY1 BTN_TRIGGER_HAPPY2 BTN_TRIGGER_HAPPY3 BTN_TRIGGER_HAPPY4 BTN_TRIGGER_HAPPY5 BTN_TRIGGER_HAPPY6 BTN_TRIGGER_HAPPY7 BTN_TRIGGER_HAPPY8 BTN_TRIGGER_HAPPY9 BTN_TRIGGER_HAPPY10 BTN_TRIGGER_HAPPY11 BTN_TRIGGER_HAPPY12 BTN_TRIGGER_HAPPY13 BTN_TRIGGER_HAPPY14 BTN_TRIGGER_HAPPY15 BTN_TRIGGER_HAPPY16 BTN_TRIGGER_HAPPY17 BTN_TRIGGER_HAPPY18 BTN_TRIGGER_HAPPY19 BTN_TRIGGER_HAPPY20 BTN_TRIGGER_HAPPY21 BTN_TRIGGER_HAPPY22 BTN_TRIGGER_HAPPY23 BTN_TRIGGER_HAPPY24 BTN_TRIGGER_HAPPY25 BTN_TRIGGER_HAPPY26 BTN_TRIGGER_HAPPY27 BTN_TRIGGER_HAPPY28 BTN_TRIGGER_HAPPY29 BTN_TRIGGER_HAPPY30 BTN_TRIGGER_HAPPY31 BTN_TRIGGER_HAPPY32 BTN_TRIGGER_HAPPY33 BTN_TRIGGER_HAPPY34 BTN_TRIGGER_HAPPY35 BTN_TRIGGER_HAPPY36 BTN_TRIGGER_HAPPY37 BTN_TRIGGER_HAPPY38 BTN_TRIGGER_HAPPY39 BTN_TRIGGER_HAPPY40 0x2e8 0x2e9 0x2ea 0x2eb 0x2ec 0x2ed 0x2ee 0x2ef 0x2f0 0x2f1 0x2f2 0x2f3 0x2f4 0x2f5 0x2f6 0x2f7 0x2f8 0x2f9 0x2fa 0x2fb 0x2fc 0x2fd 0x2fe MAX"
EV_REL="X Y Z RX RY RZ HWHEEL DIAL WHEEL MISC RESERVED WHEEL_HI_RES HWHEEL_HI_RES 0xd 0xe MAX"
EV_ABS="X Y Z RX RY RZ THROTTLE RUDDER WHEEL GAS BRAKE 0xb 0xc 0xd 0xe 0xf HAT0X HAT0Y HAT1X HAT1Y HAT2X HAT2Y HAT3X HAT3Y PRESSURE DISTANCE TILT_X TILT_Y TOOL_WIDTH 0x1d 0x1e 0x1f VOLUME 0x21 0x22 0x23 0x24 0x25 0x26 0x27 MISC 0x29 0x2a 0x2b 0x2c 0x2d RESERVED MT_SLOT MT_TOUCH_MAJOR MT_TOUCH_MINOR MT_WIDTH_MAJOR MT_WIDTH_MINOR MT_ORIENTATION MT_POSITION_X MT_POSITION_Y MT_TOOL_TYPE MT_BLOB_ID MT_TRACKING_ID MT_PRESSURE MT_DISTANCE MT_TOOL_X MT_TOOL_Y 0x3e MAX"
EV_MSC="SERIAL PULSELED GESTURE RAW SCAN TIMESTAMP 0x6 MAX"
EV_SW="LID TABLET_MODE HEADPHONE_INSERT RFKILL_ALL MICROPHONE_INSERT DOCK LINEOUT_INSERT JACK_PHYSICAL_INSERT VIDEOOUT_INSERT CAMERA_LENS_COVER KEYPAD_SLIDE FRONT_PROXIMITY ROTATE_LOCK LINEIN_INSERT MUTE_DEVICE PEN_INSERTED"
EV_LED="NUML CAPSL SCROLLL COMPOSE KANA SLEEP SUSPEND MUTE MISC MAIL CHARGING 0xb 0xc 0xd 0xe MAX"
EV_SND="CLICK BELL TONE 0x3 0x4 0x5 0x6 MAX"
EV_REP="DELAY PERIOD"

# convert event string to number
input_event_str2int() {
    local type="$1"
    local code="$2"

    case $type in
        SYN) set -- $EV_SYN ;;
        KEY) set -- $EV_KEY ;;
        REL) set -- $EV_REL ;;
        ABS) set -- $EV_ABS ;;
        MSC) set -- $EV_MSC ;;
        SW)  set -- $EV_SW  ;;
        LED) set -- $EV_LED ;;
        SND) set -- $EV_SND ;;
        REP) set -- $EV_REP ;;
        *)   set --         ;;
    esac

    code=$(printf " %s \n" $@  | grep -n -F " $code ")
    _ret=$?
    [ ${_ret} -eq 0 ] && code=$((${code%%:*}-1))
    type=$(printf " %s \n" $EV | grep -n -F " $type ")
    _ret=$?
    [ ${_ret} -eq 0 ] && type=$((${type%%:*}-1))

    echo $type $code
}

# convert event number to string
input_event_int2str() {
    local type="$1"
    local code="$2"

    set -- $EV
    [ $# -gt $type ] && shift $type || set --
    type=${1:-$type}

    case $type in
        SYN) set -- $EV_SYN ;;
        KEY) set -- $EV_KEY ;;
        REL) set -- $EV_REL ;;
        ABS) set -- $EV_ABS ;;
        MSC) set -- $EV_MSC ;;
        SW)  set -- $EV_SW  ;;
        LED) set -- $EV_LED ;;
        SND) set -- $EV_SND ;;
        REP) set -- $EV_REP ;;
        *)   set --         ;;
    esac

    [ $# -gt $code ] && shift $code || set --
    code=${1:-$code}

    echo $type $code
}

check_event() {
    [ "$cfg_debug" = 1 ] && debug_event "$@"

    while [ $# -ge 5 ]
    do
        for item in $cfg_whitelist
        do
            if [ "$item" = "$3:$4" ]
            then
                # successful
                [ "$cfg_causality" = 1 ] && causality="$(input_event_int2str $3 $4 | tr ' ' ':') $5" &&
                    debug_log && do_debug_log "-- whitelist match -- $causality" ||
                    debug_log && do_debug_log "-- whitelist match -- $(input_event_int2str $3 $4 | tr ' ' ':')"
                whitelisted=1
                return 0
            fi
        done
        # If the graylist is empty, don't even bother
        if [ "$cfg_graylist" != "" ]
        then
            for item in $cfg_graylist
            do
                if [ "$item" = "$3:$4" ]
                then
                    # successful
                    [ "$cfg_causality" = 1 ] && causality="$(input_event_int2str $3 $4 | tr ' ' ':') $5" &&
                        debug_log && do_debug_log "-- graylist match -- $causality" ||
                        debug_log && do_debug_log "-- graylist match -- $(input_event_int2str $3 $4 | tr ' ' ':')"
                    whitelisted=0
                    return 0
                fi
            done
        fi
        shift 5
    done

    # unsuccessful
    return 1
}

debug_event() {
    eventstr="MiniClock debug event: [ input_devices = $cfg_input_devices ]"

    while [ $# -ge 5 ]
    do
        eventstr="$eventstr"$'\n'"[$1 $(input_event_int2str $3 $4 | tr ' ' ':') $5]"
        shift 5
    done

    debug_log && do_debug_log "$eventstr"
}

# --- Main: ---

main() {
    local negative=0

    udev_workarounds
    wait_for_nickel
    # NOTE: Another shaky workaround to the outdated fb state issue would be to wait for a 32bpp fb here...
    #       That'd give the shaft to older, 16bpp FW, though :/.
    #       And wouldn't help with rotation updates (to which, granted, we don't lose too much accuracy if ignored).

    while : # main loop
    do
        while # update loop
            sleep 0.2 # ratelimit
            load_config
            nightmode_check
            frontlight_check
            fbink_check
            fbink_reinit
            check_event $(devinputeventdump $cfg_input_devices 2>/dev/null)
        do
            # whitelisted/graylisted event
            negative=0
            # abort early if it was simply a graylist match
            if [ "$whitelisted" -ne "1" ]
            then
                continue
            fi

            # kill previous update if unfinished
            pkill -P $$ && debug_log && do_debug_log "-- killed previous update task --"
            debug_log && do_debug_log "-- cfg_delay = '$cfg_delay' --"
            (
                # The whole subshell runs in the background so the next event can be listened to already
                for i in $cfg_delay
                do
                    # See the lengthy notes below for why we sleep first by default...
                    # TL;DR: Because we can't have nice things :(.
                    if [ "${cfg_aggressive_timing}" -eq "0" ]
                    then
                        debug_log && do_debug_log "-- early delay -- $i"
                        sleep $i
                    fi
                    # If the pixel changed color, we're good to go!
                    pixel="$(dd if=/dev/fb0 skip=${pixel_address} count=${pixel_bytes} bs=1 2>/dev/null)"
                    # NOTE: Only sleeping in the "delay" branch allows us better reactivity,
                    #       at the expense of potentially being overriden by a button highlight.
                    #       f.g., if you print to the bottom right corner, that's smack inside the Library's next page button,
                    #       so we risk printing *before* the highlight disappears,
                    #       and the highlight disappearing will in practice "erase" us,
                    #       and since it's no longer tied to an input event, we won't reprint.
                    # NOTE: Unfortunately, that's not the only potential issue: the crappy performance of the ePub reader
                    #       also means that we'd almost always print before the pageturn.
                    #       And my guess is there's a double-blit involved, because we get erased by the page-turn :/.
                    # NOTE: You can now flip between those two behaviors via the aggressive_timing config switch :).
                    if [ "${pixel}" = "${pixel_value}" ]
                    then
                        debug_log && do_debug_log "-- sentinel pixel hasn't been updated yet --"
                        if [ "${cfg_aggressive_timing}" -ne "0" ]
                        then
                            debug_log && do_debug_log "-- late delay -- $i"
                            sleep $i
                        fi
                        continue
                    else
                        update
                        # End by painting our sentinel pixel a specific color (neither black nor white)
                        echo -n ${pixel_value} | dd of=/dev/fb0 seek=${pixel_address} count=${pixel_bytes} bs=1 2>/dev/null
                        break
                    fi
                done
            ) &
        done # end update loop

        # unknown event, cold treatment
        negative=$(($negative+1))
        debug_log && do_debug_log "-- whitelist not matched - negative $negative --"

        # getting cold events in a row? sleep a while.
        if [ "$negative" -ge "${cfg_cooldown% *}" ]
        then
            negative=0

            if [ "$cfg_causality" = 1 ]
            then
                # update only to display cooldown {debug}
                # No fancy pixel watching when debugging ;).
                causality="cooldown $cfg_cooldown"
                (
                    for i in $cfg_delay
                    do
                        sleep $i
                        update
                    done
                ) &
            fi

            debug_log && do_debug_log "-- cooldown start, $(date) --"
            sleep "${cfg_cooldown#* }"
            debug_log && do_debug_log "-- cooldown end,   $(date) --"
        fi
    done
}

main

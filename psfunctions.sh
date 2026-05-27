#!/bin/sh
# PS4-specific initramfs functions
# GRUB-like boot menu, HDD unlock, partition scanning

PS4_KEY_FILE="/key/eap_hdd_key.bin"
PS4_HOME="/ps4hdd"

# ─── HDD init ─────────────────────────────────────────────────────────────────

ps4_init_hdd() {
    if use ps4_hdd_mock; then
        einfo "Test mode: creating mock PS4 HDD"
        mkdir -p /ps4hdd/home /ps4hdd/linux/boot /ps4hdd/system/boot
        return 0
    fi

    local _hdd_dev=""
    for _pattern in /dev/sd*27 /dev/hd*27; do
        for _dev in $_pattern; do
            [ -b "$_dev" ] && _hdd_dev="$_dev" && break 2
        done
    done
    [ -z "$_hdd_dev" ] && { ewarn "PS4 data partition (sd*27) not found."; return 1; }
    [ ! -f "$PS4_KEY_FILE" ] && { ewarn "EAP HDD key not found at $PS4_KEY_FILE"; return 1; }

    einfo "Unlocking PS4 HDD: $_hdd_dev ..."
    if ! cryptsetup -d "$PS4_KEY_FILE" --cipher aes-xts-plain64 -s 256 \
        --offset 0 create ps4hdd "$_hdd_dev"; then
        ewarn "Failed to decrypt $_hdd_dev"
        return 1
    fi
    mkdir -p /ps4hdd
    if ! mount -t ufs -o ufstype=ufs2 /dev/mapper/ps4hdd /ps4hdd; then
        ewarn "Failed to mount /dev/mapper/ps4hdd (not UFS?)"
        cryptsetup close ps4hdd 2>/dev/null
        return 1
    fi
    einfo "PS4 HDD unlocked and mounted at /ps4hdd"
}

# ─── Partition scanner ─────────────────────────────────────────────────────────
# Scans for bootable targets and stores them in _BOOT_TARGETS.
# Format per entry: "type|dev|fstype|label|os"
#   type = "internal" (UFS + linux.img) or "external" (direct partition)

_ps4_scan_boot_targets() {
    _BOOT_TARGETS=""
    _NL="
"

    # ── Internal: /ps4hdd/home/linux.img (loopback) ──
    if mountpoint -q /ps4hdd && [ -f /ps4hdd/home/linux.img ]; then
        _os="PS4 Linux (Internal)"
        # Mount it read-only to peek at /etc/os-release inside
        mkdir -p /tmp/_psboot
        if losetup /dev/loop6 /ps4hdd/home/linux.img 2>/dev/null \
            && mount -o ro /dev/loop6 /tmp/_psboot 2>/dev/null; then
            _osr="/tmp/_psboot/etc/os-release"
            [ -f "$_osr" ] && _os=$(grep '^PRETTY_NAME=' "$_osr" \
                2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
            [ -z "$_os" ] && _os="PS4 Linux (Internal)"
            umount /tmp/_psboot 2>/dev/null
            losetup -d /dev/loop6 2>/dev/null
        fi
        rmdir /tmp/_psboot 2>/dev/null
        _BOOT_TARGETS="${_BOOT_TARGETS}${_BOOT_TARGETS:+$_NL}internal|loop|ext2|linux.img|${_os}"
    fi

    # ── External: scan /dev/sd* partitions ──
    for _dev in /dev/sd*; do
        [ -b "$_dev" ] || continue
        # Skip whole disks (no trailing digit)
        case "${_dev##*/}" in *[!0-9]) continue ;; esac
        # Skip partition 27 (handled by ps4_init_hdd)
        [ "${_dev##*[!0-9]}" = "27" ] && continue
        # Skip loop/ram
        case "$_dev" in */dev/loop*|*/dev/ram*) continue ;; esac

        mkdir -p /tmp/_psboot
        if mount -o ro "$_dev" /tmp/_psboot 2>/dev/null; then
            _root_ok=0
            _os=""
            _osr="/tmp/_psboot/etc/os-release"
            [ -f "$_osr" ] && _os=$(grep '^PRETTY_NAME=' "$_osr" \
                2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
            [ -x /tmp/_psboot/sbin/init ] && _root_ok=1

            if [ $_root_ok -eq 1 ] || [ -n "$_os" ]; then
                [ -z "$_os" ] && _os="$(basename "$_dev")"
                _BOOT_TARGETS="${_BOOT_TARGETS}${_BOOT_TARGETS:+$_NL}external|${_dev}|||${_os}"
            fi
            umount /tmp/_psboot 2>/dev/null
        fi
        rmdir /tmp/_psboot 2>/dev/null
    done
}

# ─── Boot target mounting ───────────────────────────────────────────────────────

_ps4_boot_selection() {
    local _entry="$1"
    local _type _dev _fstype _label _os

    IFS="|" read _type _dev _fstype _label _os <<EOF
$_entry
EOF

    einfo "Booting: $_os"

    case "$_type" in
        internal)
            einfo "Mounting loop: /ps4hdd/home/linux.img ..."
            losetup /dev/loop5 /ps4hdd/home/linux.img
            mount /dev/loop5 /newroot
            ;;
        external)
            einfo "Mounting $_dev ..."
            mount "$_dev" /newroot
            ;;
    esac

    if ! mountpoint -q /newroot; then
        ewarn "Failed to mount $_os at /newroot"
        rescueshell
        return 1
    fi

    # Run fast fsck automatically and log it.
    einfo "Running fast filesystem check on $_os ..."
    local _fsck_dev
    if [ "$_type" = "internal" ]; then
        _fsck_dev=/dev/loop5
    else
        _fsck_dev="$_dev"
    fi
    fsck "$_fsck_dev" -p; _fsck_rc=$?
    einfo "fsck exited with code $_fsck_rc"

    if [ $_fsck_rc -ne 0 ]; then
        ewarn "Filesystem check failed on $_os."
        while true; do
            echo ""
            einfo "Boot options for $_os:"
            printf "  [B]oot anyway        [F]ull fsck        [R]escue shell  [b/f/r]: "
            read -t 10 -n 1 _ans; echo ""
            case "${_ans}" in
                [Bb]|"")
                    einfo "Booting anyway ..."
                    break
                    ;;
                [Ff])
                    einfo "Running full fsck ..."
                    fsck "$_fsck_dev" -f -y
                    echo ""
                    ;;
                [Rr]) rescueshell ;;
                *) ewarn "Unknown option." ;;
            esac
        done
    else
        einfo "Filesystem check passed."
    fi
}

# ─── Menu helpers ──────────────────────────────────────────────────────────────

_ps4_menu_header() {
    clear
    echo ""
    einfo "+----------------------------------------------------+"
    einfo "|            PS4 Linux Boot Menu                      |"
    einfo "+----------------------------------------------------+"
    echo ""
}

_ps4_menu_footer() {
    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  S  Scan / rescan for bootable partitions   │"
    echo "  │  E  Edit kernel boot parameters             │"
    echo "  │  R  Rescue shell                            │"
    echo "  │  P  Power options (reboot / shutdown)       │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
}

# ─── Sub-menus ─────────────────────────────────────────────────────────────────

_ps4_menu_power() {
    while true; do
        clear
        echo ""
        einfo "+----------------------------------------------------+"
        einfo "|              Power Options                          |"
        einfo "+----------------------------------------------------+"
        echo ""
        echo "  [R] Reboot"
        echo "  [S] Shutdown"
        echo "  [C] Cancel"
        echo ""
        printf "  Selection: "
        read -n 1 _key; echo ""
        case "${_key}" in
            [Rr]) einfo "Rebooting ..."; sleep 1; reboot ;;
            [Ss]) einfo "Shutting down ..."; sleep 1; poweroff ;;
            [Cc]) return ;;
            *) ewarn "Invalid option."; sleep 1 ;;
        esac
    done
}

_ps4_menu_edit_params() {
    local _files=""
    for _f in /ps4hdd/linux/boot/bootargs.txt \
              /ps4hdd/system/boot/bootargs.txt; do
        [ -f "$_f" ] && _files="$_files $_f"
    done

    clear
    echo ""
    einfo "Edit kernel boot parameters (for next boot)"
    echo ""
    if [ -n "$_files" ]; then
        for _f in $_files; do echo "    $_f"; done
    else
        echo "    No bootargs.txt found."
        echo "    Will create /ps4hdd/linux/boot/bootargs.txt"
        _files="/ps4hdd/linux/boot/bootargs.txt"
    fi
    echo ""
    echo "  Changes affect the NEXT boot only (kernel is already loaded)."
    echo ""
    printf "  Press Enter to edit (vi), or C to cancel: "
    read -n 1 _key; echo ""
    case "${_key}" in [Cc]) return ;; esac

    local _target=""
    for _f in /ps4hdd/linux/boot/bootargs.txt \
              /ps4hdd/system/boot/bootargs.txt; do
        [ -f "$_f" ] && { _target="$_f"; break; }
    done
    [ -z "$_target" ] && _target="/ps4hdd/linux/boot/bootargs.txt"

    einfo "Opening $_target with vi ..."
    sleep 1
    vi "$_target"
    einfo "Saved."
    sleep 1
}

# ─── Main menu ─────────────────────────────────────────────────────────────────

ps4_main_menu() {
    local _key _count _countdown _num_entries

    _ps4_scan_boot_targets

    _num_entries=0
    [ -n "$_BOOT_TARGETS" ] && _num_entries=$(echo "$_BOOT_TARGETS" | wc -l)

    if [ $_num_entries -eq 0 ]; then
        while true; do
            _ps4_menu_header
            echo "  No bootable Linux installations found."
            echo ""
            echo "  Connect a drive with a Linux root filesystem or"
            echo "  install from the rescue shell."
            echo ""
            _ps4_menu_footer
            printf "  Selection: "
            read -n 1 _key; echo ""
            case "${_key}" in
                [Ss]) _ps4_scan_boot_targets
                      _num_entries=$(echo "$_BOOT_TARGETS" | wc -l)
                      [ $_num_entries -gt 0 ] && break
                      ewarn "Still nothing found."
                      sleep 1
                      ;;
                [Ee]) _ps4_menu_edit_params ;;
                [Rr]) rescueshell ;;
                [Pp]) _ps4_menu_power ;;
                *) ewarn "Unknown option."; sleep 1 ;;
            esac
        done
    fi

    # ── Phase 1: countdown auto-boot ──
    _BOOT_DEFAULT=$(echo "$_BOOT_TARGETS" | head -1)

    _countdown=10
    while true; do
        _ps4_menu_header

        printf "  %-12s %-8s %s\n" "#" "Type" "OS"
        printf "  %-12s %-8s %s\n" "─" "────" "──"
        _count=1
        IFS="
"
        for _entry in $_BOOT_TARGETS; do
            IFS="|" read _t _d _fs _l _o <<EOF
$_entry
EOF
            if [ "$_entry" = "$_BOOT_DEFAULT" ]; then
                printf "  [%d] %-10s %-8s %-25s  << default\n" "$_count" "$_t" "$_o" ""
            else
                printf "  [%d] %-10s %-8s %s\n" "$_count" "$_t" "$_o" ""
            fi
            _count=$((_count + 1))
        done
        IFS="$(printf ' \t\n')"
        _count=$((_count - 1))

        _ps4_menu_footer

        if [ $_countdown -ge 0 ]; then
            _os=$(echo "$_BOOT_DEFAULT" | cut -d'|' -f5)
            printf "\r  Auto-booting [%s] in %2ds ... Press any key. " "$_os" "$_countdown"
            read -t 1 -n 1 _key
            if [ $? -ne 0 ]; then
                _countdown=$((_countdown - 1))
                [ $_countdown -lt 0 ] && { echo ""; _ps4_boot_selection "$_BOOT_DEFAULT"; return; }
                continue
            fi
            echo ""
            _countdown=-1
        else
            printf "  Selection: "
            read -n 1 _key
            echo ""
        fi

        [ -z "$_key" ] && { _ps4_boot_selection "$_BOOT_DEFAULT"; return; }

        case "${_key}" in
            [1-9])
                _entry=$(echo "$_BOOT_TARGETS" | sed -n "${_key}p")
                if [ -n "$_entry" ]; then
                    _ps4_boot_selection "$_entry"
                    return
                fi
                ewarn "Invalid number."; sleep 1; _countdown=-1
                ;;
            [Ss])
                _ps4_scan_boot_targets
                _num_entries=$(echo "$_BOOT_TARGETS" | wc -l)
                [ $_num_entries -eq 0 ] && { ewarn "No targets found."; sleep 1; }
                _BOOT_DEFAULT=$(echo "$_BOOT_TARGETS" | head -1)
                _countdown=-1
                ;;
            [Ee]) _ps4_menu_edit_params; _countdown=-1 ;;
            [Rr]) rescueshell; _countdown=-1 ;;
            [Pp]) _ps4_menu_power; _countdown=-1 ;;
            *) ewarn "Unknown option: ${_key}"; sleep 1; _countdown=-1 ;;
        esac
    done
}

# ─── Post-menu helpers ─────────────────────────────────────────────────────────

ps4_copy_key() {
    if mountpoint -q /newroot; then
        if [ -f "$PS4_KEY_FILE" ] && [ ! -f /newroot/home/eap_hdd_key.bin ]; then
            cp "$PS4_KEY_FILE" /newroot/home/eap_hdd_key.bin
        fi
    fi
}

ps4_mount_ps4hdd() {
    mkdir -p /newroot/ps4hdd
    mount /ps4hdd /newroot/ps4hdd
}

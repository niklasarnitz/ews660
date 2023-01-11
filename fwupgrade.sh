#!/bin/sh

. /lib/upgrade/common.sh

firmware="/tmp/firmware.img"
tmpdir="/tmp/_upgrade"
output="/dev/ttyS0"
fw_env_config="/etc/fw_env.config"
str_16m_displayname="is16m_displayname"
str_32m_displayname="is32m_displayname"
sectorsize="$([ -f "${fw_env_config}" ] && grep "/dev/mtd1 " "${fw_env_config}" | sed -e "s/^\([^ \t]*[ \t]*\)\{4\}.*/\1/g")"
if [ -f "/etc/modelname" ]; then
        modelname="$(cat /etc/modelname)"
else
        modelname="$(cat /proc/sys/kernel/hostname | tr [A-Z] [a-z])"
fi
before_local="/etc/before-upgradelocal.sh"
after_local="/etc/after-upgradelocal.sh"
before="before-upgrade.sh"
after="after-upgrade.sh"
flag_disable_umount="/tmp/flag_disable_umount"

create_mtdaddr() {
        addr="0"
        cat "/proc/mtd" | grep "mtd[0-9]*: " | grep -v "\"rootfs_data\"" | cut -d " " -f 2,4 | \
        while read line; do
                printf "0xbf%06x $(echo "${line}" | cut -d " " -f 2)\n" "${addr}"
                addr="$((${addr} + 0x$(echo "${line}" | cut -d " " -f 1)))"
        done
}

doupgrade() {
        local append=""
        local CONF_TAR="/tmp/_sys/sysupgrade.tgz"
        [ -f "$CONF_TAR" ] && append="-j $CONF_TAR"

        mtdaddr="$(create_mtdaddr)"

        get_start_addr() {
                echo -e "${mtdaddr}" | grep "\"$1\"" | cut -d " " -f 1
        }

        get_size() {
                if [ "$1" = "kernel" ]; then
                        echo "0x$(printf "%08x" "$(ls -al "${kernel}" | sed -e "s/^\([^ ]* *\)\{4\}\([0-9]\+\).*$/\2/g")")"
                elif [ "$1" = "rootfs" ]; then
                        if [ "$(get_magic_word "${rootfs}")" = "6873" ]; then
                                len=""
                                for var in $(hexdump "${rootfs}" -s 40 -n 4 -e '/1 "%02x "' -v); do
                                        len="${var}${len}"
                                done
                                len="$((0x${len}))"
                        else
                                len="$(hexdump "${rootfs}" -s 67 -n 4 -e '"%d"')"
                        fi
                        printf "0x%08x\n" "$((((${len} - 1) / ${sectorsize} + 1) * ${sectorsize}))"
                fi
        }

        get_checksum() {
                if [ "$1" = "kernel" ]; then
                        md5sum "${kernel}"
                elif [ "$1" = "rootfs" ]; then
                        dd if="${rootfs}" bs="${sectorsize}" count="$(($(get_size "rootfs") / ${sectorsize}))" 2>/dev/null | md5sum -
                fi | cut -d " " -f 1
        }

        # check rootfs_size exist or not in u-boot-env mtdblock
        check_rootfs_size() {
                have_rootfs_size="$(fw_printenv | grep ^rootfs_size= | cut -d = -f 2)"

                [ -z "${have_rootfs_size}" ] && {
                        fw_setenv rootfs_size "$(get_size "rootfs")"
                }
        }

        check_rootfs_size

        [ -f "${before_local}" ] && chmod a+x "${before_local}" && . "${before_local}"
        [ -f "${before}" ] && chmod a+x "${before}" && . "${before}"

        [ ! -f "${flag_disable_umount}" ] && {
                rootfs_mtd="$(cat /proc/mtd | grep \"rootfs\" | cut -d : -f 1)"
                rootfs_size="$(($( ( fw_printenv | grep ^rootfs_size= | cut -d = -f 2 ) 2>&- )))"
                if [ ! -f "/rom/note" -a -n "${rootfs_mtd}" -a ${rootfs_size} -gt 0 ]; then
                        . /lib/functions/boot.sh && 
                        umount -l /jffs && 
                        pivot /rom /mnt && 
                        umount -l /mnt && 
                        {
                                dd if=/dev/${rootfs_mtd} of=/tmp/root.squashfs bs=${rootfs_size} count=1 && 
                                mount /tmp/root.squashfs /mnt && 
                                pivot /mnt /rom && 
                                umount -l /rom
                        } 2>&- || true && 
                        ramoverlay
                fi
        }

        # check kernel and upgrade kernel
        [ -n "${kernel}" -a -f "${kernel}" ] && [ "${magic_word_kernel}" = "2705" ] && {
                echo "Writing kernel($kernel)..." >"${output}"
                fw_setenv vmlinux_start_addr "$(get_start_addr "kernel")"
                fw_setenv vmlinux_size       "$(get_size "kernel")"
                fw_setenv vmlinux_checksum   "$(get_checksum "kernel")"
                mtd write "${kernel}" "kernel"
        }

        # check rootfs and upgrade rootfs
        [ -n "${rootfs}" -a -f "${rootfs}" ] && [ "${magic_word_rootfs}" = "7371" -o "${magic_word_rootfs}" = "6873" ] && {
                echo "Writing rootfs($rootfs)..." >"${output}"
                fw_setenv rootfs_start_addr     "$(get_start_addr "rootfs")"
                fw_setenv rootfs_size           "$(get_size "rootfs")"
                fw_setenv rootfs_checksum       "$(get_checksum "rootfs")"

                # Note:
                #       If append null, DUT will be set default after fw upgrade, otherwise, apply DUT now setting.
                mtd $append write "${rootfs}" "rootfs"
        }

        [ -f "${after_local}" ] && chmod a+x "${after_local}" && . "${after_local}"
        [ -f "${after}" ] && chmod a+x "${after}" && . "${after}"

        ask_bool 1 "Reboot" && {
                echo "Upgrade completed, rebooting system..." >"${output}"
                reboot -f
                sleep 5
                echo b 2>/dev/null >/proc/sysrq-trigger
        }
}

# main
if [ -f "${firmware}" ]; then
        if [ -n "${sectorsize}" ]; then
                sectorsize="$((${sectorsize}))"
        else
                echo "sectorsize Not defined." >"${output}"
                return 3
        fi

        # untar firmware
        [ -e "${tmpdir}" ] && rm -rf "${tmpdir}"
        mkdir -p "${tmpdir}" && cd "${tmpdir}" && tar zxf "${firmware}" && {
                errcode="1"

                # check rootfs/kernel filename
                kernel="$(ls -1 | grep "^openwrt\-.*\-${modelname}\-uImage\-lzma\.bin$")"
                rootfs="$(ls -1 | grep "^openwrt\-.*\-${modelname}\-root\.squashfs$")"
                [ -z "${kernel}" -a -z "${rootfs}" ] || [ -f "/etc/${str_16m_displayname}" -o -f "/etc/${str_32m_displayname}" ] && {
                        [ -f "/etc/${str_16m_displayname}" -a -f "./${str_16m_displayname}" ] && {
                                displayname="$(cat ./${str_16m_displayname})"
                                kernel="$(ls -1 | grep "^openwrt\-.*\-${displayname}\-uImage\-lzma\.bin$")"
                                rootfs="$(ls -1 | grep "^openwrt\-.*\-${displayname}\-root\.squashfs$")"
                        }
                        [ -f "/etc/${str_32m_displayname}" -a -f "./${str_32m_displayname}" ] && {
                                displayname="$(cat ./${str_32m_displayname})"
                                kernel="$(ls -1 | grep "^openwrt\-.*\-${displayname}\-uImage\-lzma\.bin$")"
                                rootfs="$(ls -1 | grep "^openwrt\-.*\-${displayname}\-root\.squashfs$")"
                        }
                }
                
                # check magic words in kernel/rootfs files (2bytes)
                [ -n "${kernel}" -a -f "${kernel}" -a -n "${rootfs}" -a -f "${rootfs}" ] && {
                        magic_word_kernel="$(get_magic_word "${kernel}")"
                        magic_word_rootfs="$(get_magic_word "${rootfs}")"
                        [ "${magic_word_kernel}" = "2705" ] && 
                                [ "${magic_word_rootfs}" = "7371" -o "${magic_word_rootfs}" = "6873" ] && 
                                errcode="0"
                }
                
                # check kernel/rootfs md5sums (2bytes)
                [ -f "md5sums" ] && {
                        [ "$(cat md5sums | grep "uImage" | cut -d ":" -f2)" = "$(md5sum "${kernel}" | cut -d " " -f1)" ] || errcode="1"
                        [ "$(cat md5sums | grep "root" | cut -d ":" -f2)" = "$(md5sum "${rootfs}" | cut -d " " -f1)" ] || errcode="1"
                }
                
                # check FWINFO filename
                [ -z $(ls FWINFO* | grep -i ${modelname}) ] && errcode="1"
                
                # Not support downgrade
                [ $(ls FWINFO* | grep -i ${modelname}) ] && [ $(ls FWINFO* | grep -i ${modelname} | cut -d "-" -f4 | cut -c 2) -lt 3 ] && errcode="1"
                
                #pass check when upload with full image file
                [ "${errcode}" -eq "1" ] && [ -f failsafe.bin ] && errcode="0"
                
                if [ "${errcode}" -eq "0" ] && [ -f "${before}" -o -f "${after}" ]; then
                        [ "$1" = "test" ] || {
                                echo doupgrade.... >"${output}"
                                rm -rf "${firmware}"
                                doupgrade
                        }
                else
                        echo "=== Firmware invalid format. ===" >"${output}"
                        return 1
                fi
                return
        } || {
                echo "==== Firmware invalid format. ====" >"${output}"
                return 1
        }
fi

echo "$firmware Not existed." >"${output}"
return 2

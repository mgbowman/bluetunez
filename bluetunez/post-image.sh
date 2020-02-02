#!/bin/bash

set -e

trap 'rm -rf "${OVERLAYS_TMP}"' EXIT
OVERLAYS_TMP="$(mktemp -d)"

# disable_splash in config.txt
if ! grep -qE '^disable_splash=' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
	cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# disable splash screen
disable_splash=1
__EOF__
fi

CMDLINE=$(cat ${BINARIES_DIR}/rpi-firmware/cmdline.txt)
if [[ "${CMDLINE}" != *"logo.nologo"* ]]; then
	CMDLINE="${CMDLINE} logo.nologo"
fi
if [[ "${CMDLINE}" != *"vt.global_cursor_default=0"* ]]; then
	CMDLINE="${CMDLINE} vt.global_cursor_default=0"
fi
echo $CMDLINE > ${BINARIES_DIR}/rpi-firmware/cmdline.txt

for arg in "$@"
do
	case "${arg}" in

		--quiet)
		CMDLINE=$(cat ${BINARIES_DIR}/rpi-firmware/cmdline.txt)
		if [[ "${CMDLINE}" != *"quiet"* ]]; then
			CMDLINE="${CMDLINE} quiet"
		fi
		echo $CMDLINE > ${BINARIES_DIR}/rpi-firmware/cmdline.txt
		;;
		
		--overlay=*)
		overlay_arg=${arg:10}
		if ! grep -qE "'^dtoverlay=${overlay_arg}'" "${BINARIES_DIR}/rpi-firmware/config.txt"; then
			mv ${BINARIES_DIR}/rpi-firmware/overlays/${overlay_arg}.dtbo ${OVERLAYS_TMP}/${overlay_arg}.dtbo
			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# add ${overlay_arg} support
dtoverlay=${overlay_arg}
__EOF__
		fi
		;;

		--without-hdmi)
		if ! grep -qE '^hdmi_blanking=' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# HDMI Output will be disabled on boot
# can be enabled via /usr/bin/tvservice
hdmi_blanking=2
__EOF__
		fi
		;;

	esac

done

rm -rf ${BINARIES_DIR}/rpi-firmware/overlays/
mv ${OVERLAYS_TMP} ${BINARIES_DIR}/rpi-firmware/overlays/

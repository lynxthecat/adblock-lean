#!/bin/sh
# shellcheck disable=SC3045

[ "${ACTION}" = remove ] || exit 0

ABL_PERSIST_VOL_FILE=/var/run/adblock-lean/hotplug-device

simple_log()
{
	logger -t abl-hotplug "${@}" &
}

ignore_event() { simple_log -p debug "DEVNAME is '${DEVNAME}'. ${1}${1:+ }We don't care about this event."; exit 0; }

case "${DEVNAME}" in /dev/root|tmpfs|/dev/loop*|overlayfs|'')
	ignore_event
esac

{
	read -r -n256 PERSIST_VOL _ < "${ABL_PERSIST_VOL_FILE}" 2>/dev/null &&
	[ "${PERSIST_VOL}" = "${DEVNAME}" ] || ignore_event "Read '${PERSIST_VOL}' from file."

	simple_log -p warn "Volume '${DEVNAME}' storing the persistent blocklist was disconnected. adblock-lean will restart and create a new blocklist on the ramdisk."
	rm -f "${ABL_PERSIST_VOL_FILE}"
	/etc/init.d/adblock-lean restart 1>/tmp/abl-restart-log 2>&1 &
}

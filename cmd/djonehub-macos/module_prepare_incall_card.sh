#!/bin/sh

base=/usrdata/djonehub/voice-test
module="$base/qdc507_incall_card.ko"
aprv3_module="$base/qdc507_aprv3.ko"
voice_module="$base/qdc507_voice.ko"
sound_device=/sys/bus/platform/devices/soc:sound
stock_driver=/sys/bus/platform/drivers/qdc507-voice-card
incall_driver=/sys/bus/platform/drivers/qdc507-incall-card

incall_ready() {
	test -c /dev/snd/controlC0 &&
		test -c /dev/snd/pcmC0D4p &&
		test -c /dev/snd/pcmC0D4c &&
		test -c /dev/snd/pcmC0D5p &&
		test -c /dev/snd/pcmC0D6c &&
		readlink /sys/class/sound/card0/device/driver 2>/dev/null |
		grep -Fq '/qdc507-incall-card' &&
		grep -Fq '(Sec AUX PCM Playback)' /proc/asound/pcm 2>/dev/null &&
		grep -Fq '(Sec AUX PCM Capture)' /proc/asound/pcm 2>/dev/null &&
		grep -Fq '(Voice Downlink Capture)' /proc/asound/pcm 2>/dev/null &&
		grep -Fq '(Voice Farend Playback)' /proc/asound/pcm 2>/dev/null
}

restore_stock_card() {
	if grep -q '^qdc507_incall_card ' /proc/modules 2>/dev/null; then
		rmmod qdc507_incall_card 2>/dev/null || true
	fi
	if test -e "$sound_device/driver_override"; then
		printf '\n' >"$sound_device/driver_override"
	fi
	if test -e "$stock_driver/bind" &&
	   test ! -e "$stock_driver/soc:sound"; then
		printf '%s\n' soc:sound >"$stock_driver/bind" 2>/dev/null || true
	fi
}

if test "${1:-}" = --restore-stock; then
	restore_stock_card
	exit 0
fi

incall_ready && exit 0
test -r "$module" || {
	printf '%s\n' "missing in-call card module: $module"
	exit 1
}

# The boot hook can run before the vendor runtime has registered its DAIs.
# Load the pinned vendor modules first, then replace only the machine-card
# binding. Any failure restores the stock card before returning an error.
grep -q '^qdc507_aprv3 ' /proc/modules 2>/dev/null ||
	insmod "$aprv3_module" || exit 1
grep -q '^qdc507_voice ' /proc/modules 2>/dev/null ||
	insmod "$voice_module" || exit 1

attempt=0
while test "$attempt" -lt 100; do
	test -c /dev/snd/controlC0 &&
		readlink /sys/class/sound/card0/device/driver 2>/dev/null |
		grep -Fq '/qdc507-voice-card' && break
	attempt=$((attempt + 1))
	sleep 0.1
done
if ! test -c /dev/snd/controlC0; then
	printf '%s\n' 'vendor voice ALSA card did not become ready'
	exit 1
fi

if grep -q '^qdc507_incall_card ' /proc/modules 2>/dev/null; then
	rmmod qdc507_incall_card || {
		printf '%s\n' 'could not remove stale in-call card module'
		exit 1
	}
fi

printf '%s\n' qdc507-incall-card >"$sound_device/driver_override" || exit 1
if test -e "$stock_driver/soc:sound"; then
	printf '%s\n' soc:sound >"$stock_driver/unbind" || {
		restore_stock_card
		exit 1
	}
fi

if ! insmod "$module"; then
	printf '%s\n' 'could not load in-call card module'
	restore_stock_card
	exit 1
fi

attempt=0
while test "$attempt" -lt 50; do
	incall_ready && {
		printf '%s\n' 'qdc507 in-call card ready: SEC_AUX and in-call PCM backends present'
		exit 0
	}
	attempt=$((attempt + 1))
	sleep 0.1
done

printf '%s\n' 'in-call card registered without the required PCM backends'
restore_stock_card
exit 1

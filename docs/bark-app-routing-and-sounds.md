# Bark notification routes and sounds

Bark payloads now set `url` to `djonehub://calls`, `djonehub://messages`, or
`djonehub://module` for tests. Opening a link selects a page and resumes the
existing connection lifecycle. It never answers, dials, or sends a message.
Numbers and message contents are not included in the link. Unknown routes,
credentials, query strings, fragments and ports are rejected.

The notification configuration accepts `bark_call_ringtone` and
`bark_sms_ringtone`. Empty strings use Bark's default; omitted fields preserve
existing values for older clients. Existing `bark_call_sound` continues to
control the 30-second looping call alert. Sound names are limited to 128 bytes
and cannot contain path separators or control characters. The sender sends
only the selected name; it does not upload audio to Bark.

In the module sheet, open reminders → Bark to enter the names or select a
common call sound. Custom files must first be imported in Bark itself. See
[Bark source](https://github.com/Finb/Bark/blob/master/Controller/SoundsViewModel.swift)
and [Bark parameters](https://github.com/Finb/Bark#readme).

Module settings → App 来电铃声 accepts one audio file (up to 30 seconds and
20 MB), validates it with AVAudioPlayer, copies it into the app's Library/Sounds,
and offers preview and reset. It is used for foreground incoming calls only.
The foreground player respects silent mode, stops before answering or ending,
and releases its audio session before call media. A bundled silent ringtone
avoids mixing the system tone with the imported foreground tone. Background
entry restores the system provider ringtone; imported audio is not used as a
background CallKit resource. Apple's documented `ringtoneSound` API requires a
[bundled resource](https://developer.apple.com/documentation/callkit/cxproviderconfiguration/ringtonesound).

Validation: modulepush tests cover event routes, selected sounds, default sound
omission, looping scope, persistence, old-client updates, invalid values, and
reset. iOS device build and static ARM sender audit pass. Actual notification
tapping and foreground/background call audio require device interaction and a
real incoming call; no live Bark test is sent during deployment.

Deployment verified on 2026-09-21: the module's installed sender matches SHA-256
`86bb11542d345622383e0991dffcf904e14659e70baad2cf985b8eae40d19cb9`.
After restarting and closing the deployment connection, an independently
established authenticated status request confirms both ringtone fields are
available and Bark remains configured. Configuration bytes were unchanged.
The replaced sender remains on the module as `djonehub-notify.armv7.before-bark`;
the older backup was copied to `/tmp/djonehub-bark-build` on the Mac before being
removed to make room. The iPhone app was installed and launched successfully.

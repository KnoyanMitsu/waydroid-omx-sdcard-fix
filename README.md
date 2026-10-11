# A first full Vibe Code (Hope you understand this)

# waydroid-omx-sdcard-fix

Fixes an **empty `/sdcard`** (and apps crashing on storage access) in Waydroid
Android 13 images whose vendor image declares the `media.omx` HAL without
shipping its service.

## Symptoms

- `/sdcard` (`/storage/emulated/0`) is empty or inaccessible; `mount | grep emulated`
  shows nothing after boot (the FUSE mount appears briefly, then vanishes).
- logcat, around 20 s after boot:
  - `StorageManagerService: Failed to mount volume VolumeInfo{emulated;0}` ...
    `Failed to start session ... TimeoutException`
  - `ANR in com.android.providers.media.module` (reason: executing service
    `...fuse.ExternalStorageServiceImpl`)
  - hundreds of `Waited one second for android.hardware.media.omx@1.0::IOmxStore/default`
- The ANR trace shows the MediaProvider main thread blocked in
  `MediaProvider.onCreate -> TranscodeHelperImpl.hasHDRPlugin -> MediaCodec.createDecoderByType
  -> MediaCodecList.getInstance -> BpMediaPlayerService.getCodecList`.

Seen with: `waydroid/lineage_waydroid_arm64_only ... 13/TQ3A.230901.001/eng.aleast.20260927.082710`,
vendor type MAINLINE, host postmarketOS (aarch64). Other builds/hosts: untested.

## Cause

`/vendor/etc/vintf/manifest.xml` declares `android.hardware.media.omx`
(`IOmx`, `IOmxStore`) but `/vendor/bin/hw` has no OMX service and no init rc starts one.
`mediaserver` blocks waiting for `IOmxStore`, MediaProvider never finishes `onCreate`,
the FUSE session start times out and vold unmounts `/storage/emulated`.

(`debug.stagefright.ccodec=0` in `waydroid.prop` looks suspicious but is **not** the cause;
removing it changes nothing.)

## Fix

A vendor overlay with a copy of the manifest minus the `media.omx` `<hal>` block.
The lookup then fails fast and Codec2 (`media.swcodec`) is used.

```sh
sudo ./waydroid-omx-sdcard-fix.sh status
sudo ./waydroid-omx-sdcard-fix.sh apply --restart   # container must be running once so rootfs is mounted
waydroid session start                              # as your normal user
sudo ./waydroid-omx-sdcard-fix.sh verify
```

Revert: `sudo ./waydroid-omx-sdcard-fix.sh revert --restart`.

The script refuses to run if the manifest has no `media.omx` entry, or if an OMX HAL
binary actually exists in the image. The original manifest is saved to
`/var/lib/waydroid/vendor-manifest.orig.xml`.

## Caveats

- Workaround, not a real fix: the overlay replaces the *whole* vendor manifest, so after a
  Waydroid image upgrade, diff against the saved original or `revert` to check whether it is
  still needed.
- Media decoding goes through Codec2 software codecs only.
- Tested end-to-end by hand on the setup above; the script's manifest editing was tested
  on a synthetic manifest, not yet run on other devices.
- `WD_DIR` (default `/var/lib/waydroid`) and `MANIFEST_SRC` can be overridden by env var.

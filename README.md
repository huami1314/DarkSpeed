# DarkSpeed

[简体中文](README_ZH.md) · [Original TrollSpeed](README_TrollSpeed.md) · [Repository](https://github.com/huami1314/DarkSpeed)

DarkSpeed is an IPA-only network-speed HUD for SpringBoard. It retains TrollSpeed's familiar display and settings while providing its own signed-app runtime and SpringBoard renderer.

The HUD supports live upload and download speeds, left/center/right placement, configurable size and units, lock-screen display, rotation, FPS text, and optional screenshot hiding. Presentation settings update while the HUD is running.

> [!WARNING]
> DarkSpeed uses experimental low-level techniques. Compatibility depends on the exact device and iOS build. Back up important data before testing. DarkSpeed never restarts the device automatically.

DarkSpeed must be signed with a valid certificate and provisioning profile before installation. After enabling the HUD, you can return to the Home Screen and use other apps; DarkSpeed remains alive in the background. Do not force-quit or swipe DarkSpeed away while the HUD is enabled.

## Support

| iOS Version | Support Status |
|---|---|
| iOS 16.x | Possible ¹ |
| iOS 16.7.2 | Tested, needs more testing |
| iOS 17.0 – iOS 18.7.1 | Supported |
| iOS 18.7.2+ | Not Supported |
| iOS 26.0 – iOS 26.0.1 | Supported |
| iOS 26.1+ | Not Supported |

¹ iOS 16.x may work, but not every device/build combination has been verified.

Compatibility issues may still occur on iOS 18.7 and 18.7.1. “Supported” means the required path is implemented; it does not guarantee that every device/build combination has been tested.

## First launch

- On CH/A devices, allow network access when prompted.
- After the DarkSpeed HUD starts successfully, do not close or force-quit the app.

## Build

The repository builds an IPA only; it does not contain a jailbreak tweak or PreferenceBundle target.

To build a signed IPA with the signing settings configured in Xcode:

```sh
./build-darkspeed.sh
```

For an unsigned IPA that will be signed later:

```sh
DARKSPEED_UNSIGNED=1 ./build-darkspeed.sh
```

The output is `packages/DarkSpeed_1.0-1.ipa`. Version `1.0-1` maps to marketing version `1.0` and build `1`.

## Credits

- [Lara](https://github.com/rooootdev/lara) for the kernel exploit implementation and RemoteCall reference.
- [i_82 / Lessica](https://github.com/Lessica) for the original [TrollSpeed](https://github.com/Lessica/TrollSpeed).
- opa334 for the kernel exploit PoC.
- ChOma and XPF.
- AppInstaller iOS for help with offsets.
- AlfieCG for libgrabkernel2.
- [Everyone who contributed to Lara](https://github.com/rooootdev/lara/graphs/contributors).

The original repository history is retained so prior authorship and contributions remain visible.

## License

See [LICENSE](LICENSE). Vendored components remain subject to their own licenses and notices.

# DarkSpeed

[English](README.md) · [原版 TrollSpeed](README_TrollSpeed.md) · [项目仓库](https://github.com/huami1314/DarkSpeed)

DarkSpeed 是一个仅通过 IPA 安装、直接显示在 SpringBoard 上的网速悬浮窗。它保留 TrollSpeed 熟悉的显示和设置，同时提供独立的签名应用运行时与 SpringBoard 渲染器。

悬浮窗支持实时上传/下载速度、左中右位置、尺寸与单位调整、锁屏显示、横竖屏适配、FPS 文本以及可选的截图隐藏。影响显示的设置会在悬浮窗运行时实时更新。

> [!WARNING]
> DarkSpeed 使用实验性的底层技术，兼容性取决于具体设备和 iOS 构建版本。测试前请备份重要数据。DarkSpeed 不会自动重启设备。

DarkSpeed 必须使用有效证书和描述文件签名后安装。悬浮窗启用成功后，可以回到桌面并正常使用其他应用，DarkSpeed 会在后台保持存活。悬浮窗启用期间，请勿从多任务界面上划或强制关闭 DarkSpeed。

## 支持范围

| iOS 版本 | 支持状态 |
|---|---|
| iOS 16.x | 可能支持 ¹ |
| iOS 16.7.2 | 已测试，仍需更多测试 |
| iOS 17.0 – iOS 18.7.1 | 支持 |
| iOS 18.7.2+ | 不支持 |
| iOS 26.0 – iOS 26.0.1 | 支持 |
| iOS 26.1+ | 不支持 |

¹ iOS 16.x 在原理上可能可用，但尚未覆盖所有设备与构建组合。

iOS 18.7 与 18.7.1 仍可能出现兼容性问题。“支持”表示对应路径已经实现，不代表每一种设备与构建组合都完成了实机验证。

## 首次启动

- CH/A 设备弹出提示时，需要允许网络权限。
- DarkSpeed HUD 启动成功后，请勿关闭或强制结束应用。

## 构建

本仓库只构建 IPA，不包含越狱插件或 PreferenceBundle 构建目标。

在 Xcode 中配置好签名后构建已签名 IPA：

```sh
./build-darkspeed.sh
```

生成待后续签名的未签名 IPA：

```sh
DARKSPEED_UNSIGNED=1 ./build-darkspeed.sh
```

安装包输出为 `packages/DarkSpeed_1.0-1.ipa`。版本 `1.0-1` 对应版本号 `1.0`、构建号 `1`。

## 致谢

- [Lara](https://github.com/rooootdev/lara)：提供底层实现与 RemoteCall 参考。
- [i_82 / Lessica](https://github.com/Lessica)：原始 [TrollSpeed](https://github.com/Lessica/TrollSpeed) 项目。
- opa334：kernel exploit PoC。
- ChOma 与 XPF。
- AppInstaller iOS：协助处理 offsets。
- AlfieCG：libgrabkernel2。
- [Lara 的所有贡献者](https://github.com/rooootdev/lara/graphs/contributors)。

项目保留原仓库历史，以继续保留原作者与贡献者记录。

## 许可

参见 [LICENSE](LICENSE)。仓库内第三方组件仍分别适用其自身的许可与声明。

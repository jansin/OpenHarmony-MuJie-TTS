# OpenHarmony MuJie TTS

基于 **sherpa-onnx** 的 OpenHarmony **离线**中英文文字转语音（TTS）示例应用。

| 项目 | 值 |
| --- | --- |
| Bundle Name | `com.jansin.tts` |
| 版本 | `1.0.0`（versionCode `1000000`） |
| 开发语言 | ArkTS / ArkUI（Stage 模型），TTS 推理由 C++ NAPI 库完成 |
| 目标平台 | OpenHarmony，API 12（compile / compatible / target SDK 均为 12） |
| 开源协议 | [Apache License 2.0](http://www.apache.org/licenses/LICENSE-2.0) |

---

## 1. 项目简介

**离线中英文 TTS 演示应用**：输入文本后于设备端完成声学推理，边合成边播放，可保存为 WAV。它解决「以纯本地方式获得中英文语音合成能力」的问题，涵盖模型随包分发与落盘、推理与播放衔接、进度与取消控制。

**实现方式**：合成能力来自项目内置的 `sherpa_onnx.har`（[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 的 HarmonyOS 封装，版本 `1.10.41`），模型为 VITS 架构的 **MeloTTS 中英文模型** `vits-melo-tts-zh_en`。**项目自身 `entry/src/main/cpp` 与 `entry/libs` 目录并不存在**——所有原生能力与预编译 `.so` 均由该 HAR 提供。

> ⚠️ 本项目**不是**系统 `@ohos.ai.textToSpeech` 接口的实现，也**未接入**任何在线合成 API；实际使用的是 **sherpa-onnx 离线引擎**。

---

## 2. 功能特性与技术栈

- **离线中英文合成**——加载内置 VITS MeloTTS 模型推理。
- **边合成边播放**——音频分片经 worker 回传主线程，写入环形缓冲区后送入 `AudioRenderer`；点「停止」发取消消息，推理回调返回 `0` 终止并停播。
- **参数可控**——语速默认 `1.0`，非正数被拦截；说话人 ID 仅当 `numSpeakers > 1` 时出现，须为 `0 ~ numSpeakers-1`。
- **进度与性能**——`Progress` + 百分比展示 `progress`（0~1）；完成后按 `systemTime.getRealTime()` 算时长、耗时与 **RTF**、线程数。
- **保存为 WAV**——经 `AudioViewPicker` 写 16-bit 单声道 PCM，带 44 字节 WAV 头（`savePcmToWav`）。
- **初始化与备份**——初始化回传采样率、说话人数、线程数后解锁「开始朗读」；`EntryBackupAbility` 配合 `backup_config.json` 的 `allowToBackupRestore = true`。

**技术栈**：ArkTS + ArkUI（`@Entry` / `@Component` / `@State`）；Stage 模型；Worker 多线程（`ThreadWorker`）；NAPI / C++ 预编译库；引擎 **sherpa-onnx 1.10.41** 与 **VITS / MeloTTS** ONNX 模型；`AudioRenderer`、`@ohos.file.fs`、`@ohos.file.picker`、`@ohos.systemTime`；CppJieba 分词；测试 `@ohos/hypium` / `@ohos/hamock`。

---

## 3. 目录结构与引擎资产

关键路径与体积（完整树见仓库）：

| 路径 | 说明 |
| --- | --- |
| `entry/src/sherpa_onnx.har` | 12.1 MB TTS 引擎 HAR（含预编译 .so） |
| `entry/src/main/ets/` | `Index.ets`（唯一页面）、`NonStreamingTtsWorker.ets` |
| `rawfile/tts-models.txt` | 21 B，模型目录名清单 |
| `rawfile/vits-melo-tts-zh_en/` | 180.25 MB：`model.onnx` 162.53 MB（Git LFS）、`lexicon.txt` 6.71 MB、`tokens.txt` 767 B、`date/number/phone.fst`、`dict/` 约 10.8 MB CppJieba 词典（含 `pos_dict/`） |

工程根目录另有 `AppScope/`（应用配置与图标）、`hvigor/hvigor-config.json5`（modelVersion 5.0.5）、`build-profile.json5`、`oh-package.json5`、`hvigorfile.ts`、`code-linter.json5`。

`sherpa_onnx.har` 内部：`Index.ets` 导出 `OfflineTts` / `TtsInput` / `TtsOutput` / `CircularBuffer` 等；`libs/arm64-v8a/` 含 `libonnxruntime.so` 12.9 MB、`libsherpa-onnx-c-api.so` 3.6 MB、`libsherpa_onnx.so`（NAPI 绑定）0.4 MB、`libc++_shared.so` 1.3 MB，`libs/armeabi-v7a/` 为 32 位版本。只声明 `arm64-v8a` 与 `armeabi-v7a`（`x86_64` 被注释掉），**不支持 x86_64 模拟器**。

---

## 4. 环境要求

| 项目 | 要求 |
| --- | --- |
| DevEco Studio | **5.0.5 Release 或更高**（工程 `modelVersion` 为 `5.0.5`） |
| SDK / 运行时 | **API 12**（compile / compatible / target 均为 12），`runtimeOS: "OpenHarmony"` |
| 设备 / ABI | ARM 设备或 ARM 模拟器（`arm64-v8a` / `armeabi-v7a`）；**不支持 x86_64** |
| Node / ohpm | 使用 DevEco Studio 自带的即可 |
| Git LFS | **必需**：`model.onnx` 由 Git LFS 托管 |
| 磁盘空间 | 工程约 386 MB；设备端另需约 180 MB |

本应用**不需要任何运行时权限**，播放由自身 `AudioRenderer` 完成。

---

## 5. 构建与运行

### 5.1 获取代码（⚠️ Git LFS 是硬性前提）

`.gitattributes` 将 `model.onnx` 交由 **Git LFS** 托管。**未安装 Git LFS 时只能拿到约 130 字节的指针文件，模型将无法初始化。**

```bash
git lfs install                    # 安装并启用 Git LFS（仅需一次）
git clone https://github.com/jansin/OpenHarmony-MuJie-TTS.git
# 或：git clone git@github.com:jansin/OpenHarmony-MuJie-TTS.git
cd TTSOpenHarmony && git lfs pull  # 若克隆时未拉取 LFS 对象，补拉
```

校验 `.../vits-melo-tts-zh_en/model.onnx`：应为 **170,429,550 字节**（而非约 130 字节）。

### 5.2 打开工程与签名配置

**File → Open** 打开含 `build-profile.json5` 的工程根目录，等待同步（未自动执行则运行 `ohpm install`）；再到 **File → Project Structure → Signing Configs** 勾选 **Automatically generate signature** 并登录华为账号。

> ⚠️ **签名配置必须替换**：`build-profile.json5` 的 `signingConfigs.default` 指向原始开发机上的本地证书路径，在你的机器上**不存在且不可用**。请重新指定自己的证书、Profile 与密钥库，并按自己的口令填写 `storePassword` / `keyPassword`（**请勿提交明文口令**），否则构建会失败。

### 5.3 构建

**方式 A（推荐）——DevEco Studio 界面**：**Build → Build Hap(s)/APP(s) → Build Hap(s)**，产物 `entry/build/default/outputs/default/entry-default-signed.hap`。

**方式 B——命令行**：本仓库**只有 `hvigorfile.ts`，不存在 `hvigorw` / `hvigorw.bat`**，无法执行 `./hvigorw assembleHap`，请改用 DevEco Studio 内置的 hvigor：

```powershell
$DevEco = "C:\Program Files\Huawei\DevEco Studio"   # 按本机实际安装路径调整
& "$DevEco\tools\ohpm\bin\ohpm.bat" install --all
& "$DevEco\tools\node\node.exe" "$DevEco\tools\hvigor\bin\hvigorw.js" `
    --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

也可在 IDE 同步一次后，从 `tools/hvigor/bin/` 复制 `hvigorw` 包装脚本到工程根目录，即可使用常规的 `hvigorw assembleHap`。

### 5.4 安装到设备

```bash
hdc list targets
hdc install entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.jansin.tts
```

也可直接在 DevEco Studio 点击 **Run**。

### 5.5 模型文件的准备与放置

模型随源码分发，**默认无需额外下载**。`.../rawfile/vits-melo-tts-zh_en/` 下共 17 个文件、合计 **180.25 MB**：`model.onnx`（162.53 MB，Git LFS）、`lexicon.txt`（6.71 MB 发音词典）、`tokens.txt`（767 B 音素表）、`date/number/phone.fst`（≈ 0.2 MB 规则）、`dict/*`（≈ 10.8 MB CppJieba 词典）。

`rawfile/tts-models.txt` 仅记录模型目录名（`vits-melo-tts-zh_en`），**未被代码读取**。**首次运行**时 Worker 会把模型与 `dict` 从 `rawfile` 拷到沙箱 `filesDir` 再由引擎加载，因此首次启动明显更慢，请等待提示「模型初始化完成！」。

---

## 6. 使用说明

应用只有页面 `pages/Index`，启动后直接进入：

1. **等待初始化**——提示「正在初始化 TTS 模型，请稍候...」，完成后提示「模型初始化完成！」并解锁「开始朗读」。
2. **输入文本**——在底部多行输入框输入文字（中英文均可）。
3. **调整参数（可选）**——语速须为正数，否则提示「请输入有效的语速（正数）」；说话人 ID 非法值提示「请输入有效的说话人 ID」。
4. **开始朗读**——音频边合成边播放，显示百分比进度。
5. **查看结果 / 停止**——信息区显示时长、耗时、**RTF**（越小越快）与线程数（当前 2 线程）；朗读中点「停止」立即中断。
6. **保存**——合成完成后「保存」可用，经系统音频选择器选定位置，写出 **16-bit 单声道 PCM WAV**（采样率取自模型的 `sampleRate`）并显示路径。

---

## 7. 配置说明

- **权限**：`module.json5` 中**没有 `requestPermissions` 字段，即未声明任何权限**；输入、推理、播放与保存（经系统选择器授权）均无需额外申请。
- **音频输出**：`initAudioRenderer()` 固定单声道 `CHANNEL_1`、`SAMPLE_FORMAT_S16LE`、`ENCODING_TYPE_RAW`、`STREAM_USAGE_MUSIC`；**采样率不作假定**，直接用模型回传的 `tts.sampleRate`。改声道或采样格式需同步修改 `audioPlayCallback` 的 PCM 转换逻辑。
- **应用信息**：`app_name` = `离线 TTS Demo`，`EntryAbility_label` = `离线 TTS`，`module_desc` = `基于 sherpa_onnx 的离线文字转语音 Demo`。
- **引擎参数**（硬编码于 `NonStreamingTtsWorker.ets` 的 `initTts()`，改后需重编译）：`modelDir = vits-melo-tts-zh_en`；`config.model.vits`：`model`/`lexicon`/`tokens` 依次为 `<modelDir>` 下的 `model.onnx`/`lexicon.txt`/`tokens.txt`，`dataDir = ""`，`dictDir` = 沙箱 `<modelDir>/dict`；`ruleFsts = date.fst,phone.fst,number.fst`、`ruleFars = ""`；`numThreads = 2`；`debug = true`。

---

## 8. 第三方依赖与开源许可

**ohpm 依赖**：`sherpa_onnx` `1.10.41`（`file:./src/sherpa_onnx.har`，离线合成引擎，含全部原生库）——**Apache-2.0**；`@ohos/hypium` `1.0.13`、`@ohos/hamock` `1.0.0`（devDependency）——**待核实**。

`sherpa_onnx` HAR 元信息：`author: The next-gen Kaldi team`、`license: Apache-2.0`、`homepage: https://github.com/k2-fsa/sherpa-onnx`、`repository: .../harmony-os/SherpaOnnxHar`。

**随包分发的第三方组件与模型**：

| 组件 | 形式 / 位置 | 许可证 |
| --- | --- | --- |
| **sherpa-onnx** | `entry/src/sherpa_onnx.har`（含 `libsherpa_onnx.so`、`libsherpa-onnx-c-api.so`） | **Apache-2.0** |
| **Microsoft onnxruntime** | `libonnxruntime.so`（arm64-v8a 12.9 MB / armeabi-v7a 8.9 MB，HAR 内置） | **待核实**（[onnxruntime](https://github.com/microsoft/onnxruntime)） |
| **libc++ (LLVM)** | `libc++_shared.so`（HAR 内置） | **待核实** |
| **VITS / MeloTTS 中英文模型** | `rawfile/vits-melo-tts-zh_en/model.onnx`（162.53 MB） | **待核实**（引擎二进制含 `MeloTTS` 标识及 "Please download the latest MeloTTS model" 提示，可确认属 MeloTTS 系列；以 [MeloTTS](https://github.com/myshell-ai/MeloTTS) 与 sherpa-onnx 模型页声明为准） |
| **CppJieba 词典** | `rawfile/vits-melo-tts-zh_en/dict/`（`jieba.dict.utf8`、`hmm_model.utf8`、`idf.utf8`、`stop_words.utf8`、`pos_dict/`） | **待核实**（[CppJieba](https://github.com/yanyiwu/cppjieba)） |

> 「待核实」= **许可证待核实**：上述 onnxruntime、libc++、VITS/MeloTTS 模型与 CppJieba 词典均未能从本仓库或随包二进制读到许可证原文（`dict/README.md` 说明该词典为 CppJieba 字典）。商用前请自行向上游确认；分发时保留各组件的版权与许可声明。

---

## 9. 开源协议

本项目自身代码以 **Apache License 2.0** 发布，全文见仓库根目录 [LICENSE](LICENSE)，亦可访问 <http://www.apache.org/licenses/LICENSE-2.0> 获取。

在遵守条件的前提下，你可 **商用**、**修改** 源码并二次分发、以源码或二进制形式 **再分发**；同时必须 **保留版权与许可声明**（保留原始版权、专利、商标与免责声明并附许可副本）、**标明修改**（对修改过的文件作显著变更说明），并遵守 **专利授权**（贡献者授予你专利许可，但若你发起专利诉讼则授权终止）。本许可**不提供任何担保**，按「原样」提供。

> ⚠️ **重要**：Apache-2.0 **仅覆盖本项目自身源代码**，**不覆盖**上文第 8 节所列第三方组件与模型；这些组件**仍遵循各自的原始许可证**，使用时请分别遵守。

---

## 10. 贡献指南与联系方式

欢迎提交 Issue 与 Pull Request：**一个 PR 只做一件事**并说明动机、改动与验证方式；遵循既有 ArkTS 严格模式风格（可用 Code Linter，规则见 `code-linter.json5`）；**不要提交构建产物与个人配置**（`build/`、`oh_modules/`、`.hvigor/`、签名证书等已在 `.gitignore` 排除）；新增模型或二进制请走 Git LFS；贡献按 Apache-2.0 授权，勿引入不兼容的代码或模型。

- **作者 / 项目主页**：<https://github.com/jansin>；**反馈**：仓库 Issue 区
- **致谢**：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 与 The next-gen Kaldi team、[MeloTTS](https://github.com/myshell-ai/MeloTTS)、[onnxruntime](https://github.com/microsoft/onnxruntime)、CppJieba 及 OpenHarmony 开源社区。

# monitor-speakers

<p align="center">
  <img src="pics/banner.jpg" alt="monitor-speakers — 三台显示器扬声器合成一个宽立体声声场" width="100%">
</p>

<p align="center"><a href="README.md">English</a> | <b>中文</b></p>

Rogue Amoeba Loopback 的免费替代品，只专注一件事：把系统音频路由到三台显示器扬声器，
合成一个宽立体声声场。

```
system output → BlackHole 2ch ──┐
                                 │   聚合设备 "LG TriSpeakers" (8 声道)
                                 │   ch 0-1  BlackHole  (环回输入，输出静音)
                 router IOProc ──┤   ch 2-3  显示器 A  ← 左
                                 │   ch 4-5  显示器 B  ← 左/右立体声（或单声道混音）
                                 │   ch 6-7  显示器 C  ← 右
```

BlackHole 和三台显示器处于**同一个**聚合设备内，因此 CoreAudio HAL 会自动处理它们之间的
时钟漂移补偿。router 是单个 IOProc，通过固定的混音矩阵把 BlackHole 环回输入拷贝到显示器
输出声道。延迟为一个 IO 缓冲（256 帧 ≈ 48 kHz 下约 5 ms）。

## 依赖

- [BlackHole 2ch](https://existential.audio/blackhole/)（免费虚拟音频驱动）
- 带扬声器的显示器，接好后每台会作为一个 CoreAudio 输出设备出现

## 构建

```sh
make            # 生成 bin/monitor-speakers
```

## 设置

```sh
bin/monitor-speakers setup            # 创建聚合设备
bin/monitor-speakers test             # 逐个声道对播放测试音（2、4、6）
bin/monitor-speakers map 2 4 6        # 默认映射不对时，把声道对分配到左/中/右
bin/monitor-speakers default "BlackHole 2ch"   # 把系统音频接入管线
bin/monitor-speakers run              # 开始路由（前台运行，Ctrl-C 停止）
```

可选：

```sh
bin/monitor-speakers gain 0.8         # 软件主增益（0.0-2.0）
bin/monitor-speakers center mono      # 中间显示器：单声道 (L+R)/2，而非自身立体声
bin/monitor-speakers autoswitch off   # 关闭默认输出自动切换
bin/monitor-speakers install          # launchd agent：登录时自启
bin/monitor-speakers uninstall        # 移除 agent
bin/monitor-speakers status           # 查看配置与设备可用性
bin/monitor-speakers teardown         # 销毁聚合设备
```

`install` 会把二进制拷到 `~/Library/Application Support/monitor-speakers/`
（launchd 不能依赖 iCloud 同步路径），日志写到 `/tmp/monitor-speakers.log`。

## 说明

- **麦克风权限**：读取 BlackHole 环回属于音频**输入**，所以 macOS 首次运行时会请求麦克风
  权限，点「允许」即可。（不是在听你的真实麦克风，读的是 BlackHole 虚拟环回。）
- **音量键**：BlackHole 作为默认输出时，键盘音量键控制的是 BlackHole 的虚拟音量，会等比
  缩放下游全部声音。想额外微调用 `gain`。
- **辨认显示器**：三个子设备保持 `setup` 打印的顺序（每对显示 transport）。用一次
  `test` + `map` 即可，映射存在 `~/.config/monitor-speakers/config.json`。
- **自动切换**（默认开启）：`run` 守护进程监听设备列表。所有显示器出现（插上扩展坞）时把
  默认输出设为 BlackHole；全部消失时回退到内建扬声器。边沿触发 + 2 秒防抖，所以你手动选了
  别的设备（AirPods 等）会被尊重，直到下次插拔事件。
- **切回**：`bin/monitor-speakers default "<你的扬声器>"` 把系统切回任意其他输出设备，
  router 可以继续挂着空跑。

## 许可

[MIT](LICENSE)

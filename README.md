# DediProg on macOS

DediProg SF100/SF600 命令行工具的 macOS 适配。基于 [DediProgSW/SF100Linux](https://github.com/DediProgSW/SF100Linux)，上游基线 `91c840db841b9b83341703cd6d67c0b4587b05b4`。保留上游历史与 GPL-2.0 许可证（见 LICENSE）。这是社区适配，**不是 Windows GUI 的 macOS 版本，也不是官方 macOS 发布包**。

## 验证范围（2026-10-16）

- Apple Silicon macOS：原生 arm64 编译成功，USB 访问不需要 sudo。
- SF100 固件 6.5.03：编程器识别成功；GD25LR512MF 的 JEDEC ID 为 `C8 60 1A`，容量 64 MiB，供电设定 1.8 V。
- 12 MHz：两次完整读取均返回 Read OK，但有 **1,444,016 字节不一致**，未通过备份一致性校验。
- 1.5 MHz：`0xB60000` 起 64 KiB 和 `0x3F60000` 起 128 KiB，两处各读两次，内容分别一致。**低速全片双读尚未验证。**
- 擦除、编程、EC 局部更新尚未在此 macOS 版本上实测；SF600、Intel Mac 也未实测。
- Read OK 仅表示工具完成流程，不能代替文件大小、双读比较和回读校验。不能仅凭全 00/FF 判定芯片损坏或唯一故障原因。

## 构建

先安装 Xcode Command Line Tools 和 Homebrew。没有命令行工具时运行 `xcode-select --install`，完成安装后继续：

```bash
brew install pkg-config libusb libxml2
git clone https://github.com/Buyuliang/dediprog-macos.git
cd dediprog-macos
bash scripts/build-macos.sh
```

脚本通过 `brew --prefix` 选择依赖路径，生成当前架构的 `dpcmd`；不执行任何 Flash 写入。必须保留可执行文件旁的 `ChipInfoDb.dedicfg`。暂不使用上游 `make install`，它包含 Linux udev 安装路径。

手工构建等价命令：

```bash
export PKG_CONFIG_PATH="$(brew --prefix libxml2)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
make clean
make -j4 CPPFLAGS="-I$(brew --prefix)/include"
./dpcmd --list > /tmp/dediprog-chip-list.txt
```

## 连接与识别

共享 BIOS Flash 操作前拔掉目标主板适配器，确保主板断电并检查夹具方向、接触及地线。本例芯片是 1.8 V 器件，不能改用 3.3/3.5 V。

```bash
./dpcmd --check
./dpcmd --detect --vcc 2 --spi-clk 5
./dpcmd --type 'GD25LR512MF ' --vcc 2 --spi-clk 5 \
  --raw-instruction '9F' --raw-require-return 3
```

预期 ID 为 `C8 60 1A`。该 ID 被多款器件共用，完整型号需结合芯片丝印或已有识别结果；手工 `--type` 输出不是识别证据。**当前数据库中的 `GD25LR512MF ` 末尾有空格，需保留引号内的空格。** `--vcc 2` 是 SF100 的 1.8 V 档位；`--spi-clk 5` 是 1.5 MHz，不是 5 MHz。电压参数不等于实测芯片 VCC。

## 只读备份与验证

在源码目录的 Bash 终端运行。每次新建目录，避免混用旧文件。64 MiB 低速读取可能需要数分钟。

```bash
set -euo pipefail
WORK=$(mktemp -d /tmp/dediprog-read.XXXXXX)
for n in 1 2; do
  ./dpcmd --type 'GD25LR512MF ' --vcc 2 --spi-clk 5 \
    --read "$WORK/read-$n.bin" > "$WORK/read-$n.log" 2>&1
done
python3 - "$WORK" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
a, b = [(p / f"read-{n}.bin").read_bytes() for n in (1, 2)]
assert len(a) == len(b) == 0x4000000, "Expected two 64 MiB files"
assert len(set(a)) > 1, "Uniform data: inspect connection/content before proceeding"
assert a == b, "Reads differ: do not treat these as verified backups"
print("Two full reads match:", p)
PYTHON
shasum -a 256 "$WORK/read-1.bin" "$WORK/read-2.bin"
```

通过比较后，将目录复制到持久存储。读取不一致时先检查接触、主板是否带电、线长与 SPI 时钟。不要用存在疑问的备份回滚，更不能以写入测试代替通信排障。

## 仅更新共享 BIOS 中的 EC：板级限定示例

以下布局仅来自 HyperBox V100 / AMD BirmanPlus / MEC1701 项目说明，**不适用于任意主板**：EC 区为 `0x81000..0xC0FFF`，长度 `0x40000`。512 KiB 构建产物的载荷是 `ec.bin[0x1000:0x41000]`，头部为 `PHCM`。本仓库不附带任何 EC/BIOS 固件。

提取载荷（在 ec.bin 所在目录执行）：

```bash
python3 - <<'PYTHON'
from pathlib import Path
ec = Path('ec.bin').read_bytes()
assert len(ec) == 0x80000
payload = ec[0x1000:0x41000]
assert len(payload) == 0x40000 and payload[:4] == b'PHCM'
Path('ec-bios.bin').write_bytes(payload)
PYTHON
```

**下列命令会修改 Flash，macOS 版尚未验证写入成功路径。** 执行前需完成正确芯片 ID 检查、低速备份双读比较，并确认目标 `0x81000` 的原始头部为 PHCM。PHCM 只是基本检查，不能证明整个布局或固件兼容性。核心命令（替换绝对路径）：

```bash
./dpcmd --type 'GD25LR512MF ' --vcc 2 --spi-clk 5 \
  -u /absolute/path/ec-bios.bin -a0x81000 -v
```

`-u` 按输入文件长度执行差异更新；不要替换成全片擦除或将完整 512 KiB ec.bin 直接传入。使用前须确认本版工具的局部擦写行为满足板级要求。更新后用新路径回读 `-a0x81000 -l0x40000`，与载荷做 `cmp`；保留原始 EC 区备份。稳定性未确认前建议继续只读排障。

## 适配变更

- macOS 用 `_NSGetExecutablePath` 查找芯片数据库，并兼容 dirname 的返回值语义。
- 数据库 XML 声明改为 UTF-16，与实际编码一致。
- 补充读取指令、地址宽度等芯片字段解析。
- `--list` 不再要求连接编程器；检测路径补齐目标、SPI 与电压档位初始化。
- 读取失败时不再继续保存；扩大单设备输出路径缓冲区。
- USB bulk 读取使用实际传输长度，短读不再伪装为完整块。
- `DEDIPROG_TRACE_ID=1` 可输出检测过程 ID，便于诊断。

这些修改不构成对上游所有错误处理、多设备或写入路径的完整审计。构建仍可能出现上游警告，不能据此声称软件已达到生产烧录工具的可靠性。

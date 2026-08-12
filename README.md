# XAUUSD M5 多空转换提醒

这是一个 MetaTrader 5 自定义指标。它固定监控黄金品种的 M5 实时行情，在盘中判断由多转空或由空转多；新方向连续获得有效报价支持满 10 秒后，播放一次提示音并弹出提醒。

指标只做监控和提醒，不会自动下单、平仓或修改订单。默认参数不是对所有市场环境都有效的“最优策略”，也不构成投资建议或盈利保证。

## 信号规则

每次目标品种出现新报价时，指标读取尚未收盘的 M5 K线，并计算三项投票：

- EMA 9 高于 EMA 21 投多票，低于则投空票。
- Supertrend 使用 ATR 10、倍数 3.0；价格在趋势线上方投多票，下方投空票。
- RSI 14 高于 50 投多票，低于 50 投空票。

至少两项同向才形成候选方向。候选方向与当前已确认方向相反、且在活跃报价中连续保持 10 秒后，才确认转换。首次加载只建立基准，不报警；同方向不会重复报警。

如果一段时间没有新报价，静默时间不计入 10 秒。报价中断超过默认 60 秒后恢复时，指标会静默重建基准，不补发断线期间的旧信号。

## 安装

1. 在 MT5 中选择“文件 → 打开数据文件夹”。
2. 进入 `MQL5\Indicators`。
3. 将 `MQL5\Indicators\XAUUSD_M5_Reversal_Alert.mq5` 复制到该目录。
4. 用 MetaEditor 打开该文件，按 `F7` 编译。安装验收要求为 `0 errors, 0 warnings`。
5. 回到 MT5，在“导航器 → 指标”上右键刷新。
6. 将 `XAUUSD M5 Reversal Alert` 加载到任意图表。它始终监控目标黄金品种的 M5 数据，不受当前图表周期影响。
7. 确保黄金品种已显示在“市场报价”中，并允许终端播放声音。

本指标不使用交易函数，因此不需要开启“算法交易”来发送订单。

项目同时提供已编译的 `XAUUSD_M5_Reversal_Alert.ex5`，可直接复制到
`MQL5\Indicators`。本次构建使用 MetaEditor 5.0.0.6104，结果为
`0 errors, 0 warnings`；源码和 EX5 的 SHA-256 记录在
`verification\build-provenance.txt`。

## 品种名称

默认目标为 `XAUUSD`。如果经纪商使用 `XAUUSDm`、`XAUUSD.a` 等前后缀，指标会先尝试精确名称，再自动搜索名称中包含 `XAUUSD` 的品种。状态面板会显示最终实际监控的名称。

如果账户中有多个名称包含 `XAUUSD` 的品种，建议在参数中直接填写准确名称，以免匹配到不同合约。

## 默认参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| 目标品种 | `XAUUSD` | 支持经纪商前后缀自动匹配 |
| 快速 / 慢速 EMA | 9 / 21 | 短线方向 |
| ATR 周期 / Supertrend 倍数 | 10 / 3.0 | 波动趋势 |
| RSI 周期 / 中轴 | 14 / 50 | 动能方向 |
| 转换保持时间 | 10 秒 | 活跃报价累计确认时间 |
| 最大活跃报价间隔 | 1000 毫秒 | 更长间隔不计入确认时间 |
| 重连重置时间 | 60 秒 | 超过后静默重建基准 |
| 定时器间隔 | 100 毫秒 | 轮询目标品种新报价 |
| 多头声音 | `alert.wav` | 位于 MT5 `Sounds` 目录 |
| 空头声音 | `timeout.wav` | 位于 MT5 `Sounds` 目录 |

EMA、ATR 和 RSI 周期的允许范围为 1–500；Supertrend 历史递推最多使用
5000 根 M5 K线，避免异常参数造成内存或计算压力。

声音与弹窗可以分别关闭，声音文件名也可在参数中修改。自定义声音文件必须放在终端数据目录的 `Sounds` 文件夹中。

## 状态面板

图表左上角显示：

- 实际监控品种与固定周期 M5；
- 当前已确认方向；
- EMA、Supertrend、RSI 的各自投票；
- 反向候选方向、已保持时间和剩余时间；
- 数据等待、报价恢复、参数错误或声音失败等状态。

## 验证建议

先在模拟账户或策略可控的环境中运行：

1. 确认面板显示正确的实际黄金品种和 `M5`。
2. 核对三项投票与候选方向。
3. 候选反向不足 10 秒时，确认不会报警。
4. 连续满 10 秒后，确认只播放一次对应声音并弹出服务器时间。
5. 确认同方向持续时不会重复提示。
6. 分别测试 `alert.wav` 与 `timeout.wav`；如无声音，检查 MT5 的声音设置和 `Sounds` 目录。

## 文件

- `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`：指标源码。
- `tests/test_signal_logic.py`：多数投票和防抖状态机的可重复参考测试。
- `tests/test_mql_contract.py`：关键 MQL5 运行契约的静态防回归检查。
- `verification/build-provenance.txt`：编译结果和源码/EX5 哈希。
- `docs/superpowers/specs/2026-08-12-xauusd-m5-reversal-alert-design.md`：已批准设计。
- `docs/superpowers/plans/2026-08-12-xauusd-m5-reversal-alert.md`：实施计划。

## PushPlus App 提醒 EA

`XAUUSD_M5_Reversal_Alert_EA` 是仅提醒、不交易的 EA。它沿用指标的
XAUUSD M5 三因子和 10 秒确认规则，只在已确认的多转空或空转多发生时
同步发送声音、MT5 弹窗和 PushPlus App 有声通知，不发送微信公众号消息。

### 安装

1. 将 `MQL5\Experts\XAUUSD_M5_Reversal_Alert_EA.ex5` 复制到 MT5 数据目录的
   `MQL5\Experts`。
2. 在 MT5 中选择“工具 → 选项 → 智能交易系统”。
3. 勾选“允许所列 URL 的 WebRequest”，加入：
   `https://www.pushplus.plus`
4. 回到导航器，在“智能交易系统”上右键刷新，并把 EA 加载到任意图表。
5. 在输入参数 `InpPushPlusToken` 中填写自己的 PushPlus Token。
6. 保持 `InpEnablePushPlus=true`，渠道默认为 `app`。
7. 开启 MT5 的“算法交易”，使 EA 定时器和网络请求能够运行。
8. 在手机安装 PushPlus App，登录 Token 所属的同一账号，并在手机系统中
   允许 PushPlus 通知和通知声音。

EA 没有导入交易库，也不含下单、平仓或改单代码。开启算法交易只允许 EA
运行，不会让本 EA 自动交易。

### PushPlus 参数与测试

- `InpPushPlusToken`：默认空，只在 MT5 运行参数中填写，不写入源码或 Git。
- `InpPushPlusUrl`：默认 `https://www.pushplus.plus/send`。
- `InpPushPlusChannel`：默认 `app`，只通知 PushPlus App，不发送微信公众号。
- `InpPushPlusTemplate`：默认 `txt`。
- `InpPushPlusTimeoutMs`：默认 5000 毫秒。
- `InpSendStartupTest`：默认关闭。临时开启后，每次加载 EA 最多发送一次连接测试；
  它不会伪造多空方向，也不改变信号状态。

开发和编译过程没有使用用户 Token，也没有执行真实外部推送。

### 故障排查

- 显示 `Token 未配置`：在 EA 输入参数中填写 Token 后重新加载。
- 显示请求失败或 MT5 错误 4014：确认程序是
  `MQL5\Experts` 中的 EA，并把 `https://www.pushplus.plus` 加入 WebRequest
  白名单。
- 显示 HTTP 状态：检查网络、防火墙、代理和 PushPlus 服务状态。
- 显示业务码：请求已到达 PushPlus，但接口拒绝；检查 Token 和账号绑定。
- 显示“服务端已接收”：PushPlus 已接收异步请求，不代表 App 最终一定送达；
  还需检查 PushPlus App 是否登录同一账号，以及系统通知和声音权限。
- 修改 Token、URL 或白名单后，卸载并重新加载 EA。

面板和 Experts 日志不会输出 Token、完整请求体或含 Token 的 URL。PushPlus
失败不会阻断行情监控，也不会为同一次已确认转换自动重试，避免重复消息。

PushPlus App 一个账号只能同时登录一台 App 设备；在第二台设备登录会使原设备
退出。只有 `channel=app` 会直接触发 App 通知。请不要在 EA 中把渠道改回
`wechat`，否则消息会发送到微信公众号而非直接通知 App。

### 大号反转通知框

确认多空转换后，EA 会在图表中央显示完整通知：

- 空转多使用绿色标题和边框。
- 多转空使用红色标题和边框。
- 显示品种、M5、服务器时间、EMA、Supertrend、RSI 和 PushPlus 发送状态。
- 默认显示 15 秒，底部显示自动关闭倒计时。
- 点击右上角 `×` 可以提前关闭。
- 调整图表窗口大小时，通知框会自动重新居中。

相关参数：

- `InpEnableLargeNotification=true`：启用图表中央大号通知框。
- `InpLargeNotificationSeconds=15`：自动关闭秒数，必须大于 0。
- `InpEnablePopup=false`：默认关闭尺寸不可调整的 MT5 原生小弹窗；如有需要可
  手动开启。

大号通知框、电脑提示音和 PushPlus App 推送互相独立。通知框绘制失败不会
阻断声音或手机推送。

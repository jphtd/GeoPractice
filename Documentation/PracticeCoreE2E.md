# Practice Core — End-to-End 测试版本

交付日期：2026-09-28。状态：最基本计划练习主流程已接通，并完成 iPhone 模拟器真实点击验证；等待用户产品验收。此交付不等于所有目标页面获得 FROZEN UI / QA Accepted 状态。

本次授权扩大到可实际操作的测试路径：添加曲目 → 创建练习划分 → 设置 Goal → 开始计划练习 → GeoBeat 记录 → 结束并确认保存 → Result / Stable BPM / Goal Gap / Analyze。继续使用 Rovia Product v1.1、Navigation v1.1 + Amendment 01、Animation v1.1 及三页 UI 的 FROZEN 基线，没有修改 SSOT。

## 从 Xcode 开始

1. 打开本 repo 的 `GeoPractice.xcodeproj`，不要打开 Downloads 里的旧 GeoPractice-main。
2. Xcode 顶部 Scheme 选择 **GeoPractice E2E**，设备选择 **iPhone 18 Pro**（或你的 iPhone）。
3. Product → Scheme → Edit Scheme… → Run → Info：Build Configuration 为 **Debug**。
4. Run → Arguments → Arguments Passed On Launch：E2E Scheme 默认没有场景参数。不要勾选 `-practice-core-fixture` 或 `normal` / `no-division` 等场景名称。
5. 点击运行三角形或 ⌘R。这个 Scheme 使用真实本机存储，重开 App 后保留数据。

原 GeoPractice Scheme 的示例场景参数也已改为默认不勾选。手工启用 fixture 时仍使用隔离内存数据，顶部会明确提示不持久保存，不能用于真实数据验收。

## 建议按这组数值完成第一次验收

1. Practice 首页点 **添加曲目**；如果已存在曲目，点右上角 **＋**。
2. 名称填“我的 E2E 测试曲”；划分方式选“按小节”；总数填 **32**；点表单中的 **保存**。
3. 曲目详情点 **创建练习划分**。起始 **1**、结束 **8**、适用手型选 **仅左手**；点 **保存**。
4. 应进入新划分详情，显示“还没有设置 Goal”。点 **设置 Goal**，目标次数填 **3**、目标速度填 **100**、目标音符单位保留 **四分音符**。日期可不填；点 **保存**。
5. 点 **开始计划练习**。App 现在创建真实 Active Session，并显示曲目、划分、状态、次数和计时。
6. 在“输入 BPM（20–240）”中填 **80**，点 **应用**；实际音符保留“四分音符”。这里改变的是实际速度，Goal 仍然是 100。
7. 点 **进入 GeoBeat 练习**，再点 **播放 / 继续练习**。每完整练习一遍，点一次 **完成一次 · 左手**；总共记录 **3 次**。
8. 向下滚动，点 **结束练习**。核对 3 条原始记录、时长和所属周期，然后点 **确认保存**。只有这一步会更新派生分析。
9. 在已保存结果里查看 Stable BPM、速度完成度、次数和 Mastery。打开 **测试预览 Pro Goal Gap** 可验收详细差距；这是 Debug 局部预览，不购买订阅、不改 StoreKit 权限。
10. 向下点 **返回练习划分**，再点 **查看分析**。也可以从底部 **Analyze** 进入总体页面。
11. Analyze 内点 **查看最近一次 Session 结果** 可以重看原始记录；退出、重开 App 后仍可查看。

在同一个当地日期完成以上新建测试，预期：

| 指标 | 预期 |
|---|---:|
| 原始完成记录 | 3 条，每条左手、四分音符、80 BPM |
| Current Stable BPM | 80（四分音符等值） |
| 本周期次数 | 3 / 3 |
| 速度完成度 | 80% |
| 左手 / 划分 Mastery | 85% = 75% × 80% + 25% × 100% |
| 次数 Gap | 0 次 |
| 速度 Gap | 20 BPM（四分音符） |

再以 100 BPM 完成并保存一轮，Current Stable BPM 应改为 100，结果页显示保存前后数值。当天次数会累计，不会因为新 Session 或编辑 Goal 清零。

## 已完成的行为

- 三个原有 FROZEN Screen 保持原有结构、层级与入口；表单保存后落在对应曲目 / 新划分 / 原划分。
- 曲目模式与可选总数明确保存。划分继承模式，校验正数、范围、总数上界与不重叠；不会自动创建 Goal。
- 每个适用手型单独设置次数和/或目标音符单位 + BPM；每个适用手型必须有效才能开始计划练习。目标单位不继承 GeoBeat。
- 同时只有一个新版本 Active Session。标签切换保留其归属；GeoBeat 的手动完成动作写入同一个 Session，并保存当时手型、速度、单位、时间和 UUID。
- 暂停不计时；App 进入后台会暂停。有效草稿重开后出现 Recovery，点击继续沿用相同 Session 身份和记录。恢复不累计关闭期间的时长；前台运行时每 15 秒检查点保存计时，记录动作立即保存草稿。
- 结束进入 Result 复核，尚未确认时不改变 Stable / Mastery。保存复用原有原子、幂等提交；重复提交不会重复加次数。保存失败保留草稿。空 Session 不保存。
- 只有带显式 planned 来源的 Confirmed Session 参与当前能力和 Goal 计算。各手型按全部标准化速度取中位数，偶数取中间两项均值，不剔除高低值。未练到的手型沿用最近有效值。
- 每日周期按当地 00:00 切换。跨午夜 Session 整体归开始时周期；Result 显示周期日期和该周期累计，Analyze 显示当前周期进度。无新数据时保留有效 Mastery，避免新一天次数归零被误读为能力归零。
- Goal 编辑保留已保存次数，并按新目标重新解释能力。默认 Mastery 权重 75% 速度 + 25% 次数；速度单维为 100%；没有速度参照时说明无法计算熟练度。三手型划分在数据齐备前不伪造整体熟练度。
- 实际速度 20–240 BPM；实际与目标音符均支持八种单位。GeoBeat 复用现有声音引擎和轮廓绘制，没有重写动画。
- 独立 GeoBeat 当前提供纯节拍工具使用，不会偷偷写入计划练习数据。

## 实际验收证据

2026-09-27～28，在 iPhone 18 Pro / iOS 27 模拟器内通过 UI 创建了 **E2E 验收练习曲 → 第 1–8 小节 → 仅左手 → 3 次 / 四分音符 100 BPM**。

- 第一轮在 GeoBeat 写入 80 BPM 记录，练习中切 Analyze 仍显示暂无已保存能力。
- 退出后恢复同一未完成 Session，跨日期完成并确认保存。最终 3 条 80 BPM 记录：Stable 80，Mastery 85%。全次归 9 月 27 日周期；9 月 28 日当前周期为 0/3。长时间退出没有计入练习时长。
- 关闭重开后，正常首页能打开真实曲目；Analyze 保留 Stable 80；“查看最近一次 Session 结果”能显示全部记录、日期和所属周期。
- 第二轮于 9 月 28 日以 100 BPM 记录 3 次并保存。结果页实际显示 **保存前 80 → 保存后 100、3/3、Mastery 100%、次数 Gap 0、速度 Gap 0、已保存 Session 2**。
- 从结果点击“返回练习划分”，实际回到同一曲目和第 1–8 小节；再点“查看分析”，上下文与结果一致。

截图在 `PracticeCoreE2EQA/`：`01-before-confirm.png`、`02-reopened-saved-session.png`、`03-saved-result-improvement.png`。这些是从真实操作创建的数据，不是预设 Debug 场景。验收用曲目与两次 Session 保留在该模拟器中，用户可另加一首曲目自行测试。

## Build / Test

- Debug：**BUILD SUCCEEDED**（GeoPractice E2E Scheme）。
- 完整自动测试：**280 passed, 0 failed**。其中 PracticeCoreTests 9 项、PracticeCoreE2ETests 8 项。
- 覆盖：持久库重开、曲目/划分/Session 关联、确认前无派生值、每手中位数与八种单位、暂停与恢复、唯一 Active、空 Session、提交失败回滚、重复保存、跨午夜、每日次数、目标编辑保留进度、缺数据手型、草稿损坏保留、备份恢复后来源与周期仍在。
- 最后新增的只读“最近一次 Session 结果”入口已完成实际点击验证，并重新通过 Debug 与 Release 编译。
- Release：**BUILD SUCCEEDED**（generic iOS Simulator，arm64 / x86_64）；Debug Pro 预览开关不出现在 Release。
- 既有警告仍在：旧 RootView.swift 未直接 import SwiftData 的 ModelContext 警告，以及无 AppIntents 依赖的元数据提示；未影响构建和测试。
- 实测范围是模拟器。未宣称完成真机音频延迟、所有动态字体/iPad布局、旧版本混合 iCloud 同步或全部 Pro 功能验收。

## SG / EG 与临时页面状态

| 项目 | 本轮状态 |
|---|---|
| SG-01 / SG-02 | Create Division、Goal Editor 已有用户授权的临时可操作表单；不再阻断主路径。内部视觉仍 Not FROZEN / Not UI QA Accepted。 |
| SG-03 | Add Piece、All Pieces、Piece Settings、Active Session、GeoBeat、Result、Analyze 已有本轮所需的临时集成；并非完整目标页面验收。 |
| SG-04 | 旧曲目/划分缺少模式、范围或适用手型时仍不推断、不重写。此版本测试请创建新曲目。 |
| SG-05 | 旧版草稿的计划来源、周期和新结构信息无法可靠确定，仍保留并登记兼容问题；不擅自迁移为新 planned Session。新版本创建的 Session 已支持恢复。 |
| EG-01 | 本轮所需每日 Goal、Stable、基础 Mastery/Weakness 与 Goal Gap 已接入。2/7 天周期、Ladder、Score Tempo Reference、自定义权重、完整高级分析未实现。 |
| EG-02 | 新版本 Session 的开始、暂停、恢复、保存闭环已完成；未沿用旧版无 Goal 启动、丢弃后切换或独立练习冒充计划数据的行为。 |
| EG-03 | 新字段保持可选、备份保留显式来源；持久重开和备份回环已测试。完整历史迁移、时区变更期间的周期迁移政策、混合版本 iCloud 行为仍未验收；本入口未启动旧自动同步。 |

独立 GeoBeat 的记录保存、主动脱离/重连、历史纠错/删除、归档和结构重划、完整 Piece Mastery、高级 Pro 仍在本轮路径之外。它们没有被伪装成已完成能力，也不阻断新建计划练习主流程。

## 本轮实际文件

新增：
- `GeoPractice/Views/PracticeCore/PracticeCoreSession.swift` — 新计划 Session 上下文、草稿恢复、提交和分析。
- `GeoPractice/Views/PracticeCore/PracticeCoreFlowViews.swift` — 临时创建/编辑、Active、GeoBeat、Result、Analyze、最近结果 UI。
- `GeoPractice.xcodeproj/xcshareddata/xcschemes/GeoPractice E2E.xcscheme` — 无 fixture 参数的可持久保存测试入口。
- 本文、`PracticeCoreE2EQA/` 截图。

修改：
- `PracticeCoreDomain.swift` — 保存曲目、Goal 的共用验证与提交；Goal 修改时间。
- `PracticeCoreViews.swift` — 三页与临时目标之间的真实连接、恢复、生命周期和结果返回。
- `PracticeCoreComponents.swift` — 底部标签正确选择及切换。
- `PracticeCoreIntegration.swift` — 移除已过时的统一未接入提示，保留旧资料兼容边界。
- `Models/PracticeAttempt.swift`、`Models/PracticeEvent.swift`、`Models/PracticeSong.swift` — 新 Session 的明确归属/来源/周期元数据，原子提交与备份保留。
- `Models/MetronomePreset.swift` — 20 BPM 下限及全音符；保留已有节拍数量变更。
- `Views/ProductPrototype/PrototypeRootMetronomeViews.swift` — 仅把现有 PrototypePulseStage 的 private 移除以复用；原有大量未提交 GeoBeat 改动不是本轮重写。
- `GeoPracticeTests/PracticeCoreTests.swift` — 增加 8 项 E2E 数据测试；`MetronomePresetTests.swift` 更新 BPM 下限断言。
- `GeoPractice.xcodeproj/project.pbxproj`、原 `GeoPractice.xcscheme` — 注册源文件、默认关闭隔离场景。
- `PracticeCoreVerticalSlice.md` — 标记历史交付状态已被本次集成补充。

此前的 App 入口、SwiftData 本地配置修复、Info.plist、MetronomeEngine 等既有工作树改动保持原样；未把它们计成本轮新功能。未提交 git commit，未发布或上传。

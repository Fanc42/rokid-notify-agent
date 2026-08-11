# rokid-notify-agent — 通知中心随身通道（Rokid Glasses AIUI Agent）

> AIUI 开发技能：`.agents/skills/aiui-dev/`（官方，含 API/组件/设计规范）
> 官方文档：https://js.rokid.com/AIUI（打包/分发/API）
> 官方仓库：https://github.com/jsar-project/AIUI

## 身份与能力

- **名称**：通知中心（Rokid Glasses 通知 Agent）
- **版本**：1.0.0
- **描述**：订阅 hermes-studio 通知中心 SSE 流，在眼镜显示通知卡片（审批/任务/提醒）
- **权限**：network（SSE 订阅）
- **运行**：AIUI 智能体（.aix），灵珠平台「应用管理 → 创建应用 → AIUI 智能体」发布

## 架构

```
hermes-studio 通知中心
    │ SSE GET /api/hermes/notifications/stream?deviceId=glasses-rokid-01&token=<设备token>
    ▼
Rokid AI App（手机，蓝牙网络中继——AIUI 网络经手机转发省电）
    ▼
本 Agent（app.js 订阅 → localStorage → pages/index 渲染卡片）
```

## AIUI 开发要点（来自 aiui-dev skill）

### 项目结构
```
AGENTS.md       # agent manifest（身份/权限）
app.json        # 全局配置（pages 路由/window）——pages 必填，第一个为首页
app.js          # 应用生命周期（onLaunch/onShow/onHide）+ 全局逻辑
pages/index/index.ink  # 页面（SFC：<script def> 配置 + <script setup> 逻辑 + <page> 模板 + <style>）
```

### 页面 SFC（.ink）
- `<script type="application/json" def>`：页面 JSON 配置（导航栏标题等）
- `<script setup>`：`export default { data, 生命周期, methods }`
- `<page>`：模板根；**条件渲染用 `ink:if` / `ink:elif` / `ink:else`**（不是 wx:if！）
- `<style>`：WXSS 风格；参考 design-system-green.md（monochrome 单色绿）

### 关键 API（详见 .agents/skills/aiui-dev/apis-*.md）
| API | 用途 | 本 agent 用法 |
|:---|:---|:---|
| `EventSource` | SSE 服务端推送 | 订阅通知流（apis-web.md / network 章节） |
| `localStorage` | 本地存储（Web Storage 标准） | app.js 写入 `ntf_current`，页面轮询读取 |
| `fetch()` | HTTPS 请求 | 备用 |
| `onKeyUp(event)` | 硬件键释放（拦截点） | GlobalHook/Enter/Backspace 关闭通知 |
| `setData()` | 更新页面数据 | refresh() 轮询更新 |

### 生命周期
- `app.js onLaunch`：启动 SSE 订阅（重连逻辑放这里）
- 页面 `onShow/onHide`：启动/停止轮询

### 硬件键（真机实测经验）
- 镜腿**单击 = Enter/GlobalHook**、**双击 = Backspace**
- 默认行为拦截点在 `onKeyUp`（不是 onKeyDown）

## 通知 Agent 设计

### 数据流
```
SSE 收到通知 → app.js handleNotification()
  → localStorage.setItem('ntf_current', JSON.stringify(ntf))  # 写入
  → 8s 定时器自动清除
页面 refresh() 每秒读 localStorage → setData({ ntf }) → ink:if 渲染卡片
硬件键 → localStorage.removeItem + setData({ ntf: null }) 关闭
```

### 通知卡片（monochrome-green 设计系统）
- 单色绿 `#40FF5E`，480x352 画布，透明度分级表达层级
- 优先级：high=全亮+2px 边框 / normal=48% 边框 / low=24% 边框+72% 不透明度
- 连接状态角标（已连接=实心绿 / 重连中=24% 绿）
- 8 秒自动关闭 + 硬件键立即关闭

### 配置（app.js 顶部）
| 配置 | 说明 |
|:---|:---|
| `NOTIFY_URL` | 通知中心 SSE 地址（https://hermes.fanc.link/api/hermes/notifications/stream） |
| `DEVICE_ID` | `glasses-rokid-01` |
| `DEVICE_TOKEN` | 设备 token（与后端 env `NOTIFICATION_DEVICE_TOKENS` 一致） |

## 打包与发布

```bash
# CLI 打包（官方 aix 工具，Cargo 安装）
aix pack . -o rokid-notify-agent.aix --optimize
# 或 Craft 工作台（js.rokid.com/craft）生成 AIX

# 发布：灵珠平台 → 应用管理 → 创建应用 → 类型「AIUI 智能体」
# → 填名称/图标/描述 → 版本管理 → 上传 .aix → 提交审核
```

- 平台自动校验包内 `VERSION` 文件 + `AGENTS.md` 声明
- 更新：重新 `aix pack` + 上传新版本，设备按 VERSION 热更新

## 调试

- Craft 在线运行预览（InkView）
- 真机：装到眼镜后看 app.js console（AIUI 调试工具）
- 后端测试：`POST /api/hermes/mcu/notifications/push` 发测试通知（JWT，super_admin）
- SSE 验证：`curl -N 'http://<host>/api/hermes/notifications/stream?deviceId=glasses-rokid-01&token=<token>'`

## 参考

- `.agents/skills/aiui-dev/SKILL.md` — 官方开发指南（项目结构/ink 规范/事件）
- `.agents/skills/aiui-dev/design-system-green.md` — 单色绿设计 tokens
- `.agents/skills/aiui-dev/components.md` — 组件参考
- `.agents/skills/aiui-dev/apis-wx.md` — 微信兼容 API（含 EventSource/localStorage）
- 官方文档 https://js.rokid.com/AIUI/guide/bundle-publish — 灵珠发布流程

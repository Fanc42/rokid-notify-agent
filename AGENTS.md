# rokid-notify-agent — 通知中心随身通道（Rokid Glasses AIUI Agent）

> AIUI 开发技能：`.agents/skills/aiui-dev/`（官方，含 API/组件/设计规范）
> 官方文档：https://js.rokid.com/AIUI（打包/分发/API）
> 官方仓库：https://github.com/jsar-project/AIUI

## Agent Manifest

### Identity
- **Name**: 通知中心（Rokid Glasses 通知 Agent）
- **Version**: 1.0.0
- **Description**: 订阅 hermes-studio 通知中心通知流（SSE + 轮询兜底），在眼镜显示通知卡片（审批/任务/提醒）
- **Author**: Coco (Hermes)

### Capabilities
- **Permissions**:
  - network（SSE/轮询连接通知中心）
  - camera（扫码配置：BarcodeDetector 识别配置二维码）
- **Skills**:
  - 通知订阅（EventSource SSE + fetch 轮询）
  - 二维码扫码配置（wx.media.createCameraContext + BarcodeDetector）
  - localStorage 状态共享（app ↔ 页面）

### 运行
- AIUI 智能体（.aix），灵珠平台「应用管理 → 创建应用 → AIUI 智能体」发布
- 配置方式：真机扫码（配置页生成二维码）/ 模拟器 DevTools 注入 localStorage

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

### 分发与配置（多用户自定服务器）

本 agent 是**分发版**——不写死服务器地址，每个用户扫码配置自己的通知服务器：

```
① 用户访问服务器配置页（如 hermes.fanc.link/rokid-config.html）
   → 填 sseUrl / deviceId / token → 生成配置二维码
② 眼镜装好 agent 首次打开 → 显示「未配置，按镜腿键扫码」
③ 按镜腿键 → 拍照 → BarcodeDetector 识别二维码
   → 解析配置 JSON → 写入 localStorage(ntf_config) → 自动连接
```

- **配置 JSON**（二维码载荷 `hermes-notify://config?json=<encoded>`）：
  `{"v":1,"sseUrl":"https://...","deviceId":"glasses-rokid-01","token":"..."}`
- **连接机制**：app.js onLaunch 读 `ntf_config` → 有则连接；无则 2s 轮询检测（AIUI 无 getApp/全局事件总线，页面写 localStorage，app 层轮询发现即连接）
- **配置页**：`hermes-studio packages/client/public/rokid-config.html`（部署后任意用户可访问生成二维码）
- **重新配置**：清 localStorage `ntf_config` 或重新扫码覆盖

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
- **高优先级保护**：当前显示 high 时，低优先级通知不覆盖
- 连接状态角标（已连接=实心绿 / 重连中=24% 绿）
- 8 秒自动关闭 + 硬件键立即关闭（onKeyUp 需 preventDefault 拦截系统返回）

### 扫码配置实现要点
- 相机：`wx.media.createCameraContext()` → `takePhoto({ quality:'low', resultType:'imageData' })`
- 识别：`new BarcodeDetector({ formats:['qr_code'] })` → `detect(imageData)` → `rawValue`
- 载荷兼容：直接 JSON `{...}` 或 `hermes-notify://config?json=<encoded>`

### 配置存储（localStorage）
| key | 说明 |
|:---|:---|
| `ntf_config` | 用户配置 JSON（{ v, sseUrl, deviceId, token }）——扫码写入 |
| `ntf_current` | 当前通知 JSON（app.js 写入，页面读取渲染） |
| `ntf_connected` | SSE 连接状态（'true'/'false'） |

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

# rokid-notify-agent — 通知中心随身通道

Rokid Glasses AIUI 通知 Agent：订阅 Hermes 设备通知中心的通知流，在眼镜显示通知卡片。

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
  - 通知订阅（EventSource SSE + fetch 轮询兜底）
  - 二维码扫码配置（wx.media.createCameraContext + BarcodeDetector）
  - localStorage 状态共享（app ↔ 页面）

## 架构

```
hermes-studio 通知中心
    │ SSE: /api/hermes/notifications/stream（实时）
    │ 轮询: /api/hermes/notifications/poll（30s 兜底，蓝牙中继友好）
    ▼
Rokid AI App（手机，蓝牙网络中继）
    ▼
本 Agent（app.js 订阅 → localStorage → pages/index 渲染卡片）
```

- **双通道**：SSE 实时 + 30s 轮询兜底（AIUI 网络经蓝牙中继，长连可能不实时）
- **配置**：localStorage `ntf_config`（真机扫码写入；模拟器 DevTools 注入）
- **通知显示**：localStorage `ntf_current`（app.js 写入，页面 2s 轮询渲染）

## 通知卡片（monochrome-green 设计系统）

- 单色绿 `#40FF5E`，480x352 画布，透明度分级表达层级
- 优先级：high=全亮+2px 边框 / normal=48% 边框 / low=24% 边框+72% 不透明度
- **高优先级保护**：当前显示 high 时，低优先级通知不覆盖
- 连接状态角标（已连接=实心绿 / 重连中=24% 绿）
- 8 秒自动关闭 + 硬件键立即关闭（onKeyUp 需 preventDefault 拦截系统返回）

## 扫码配置

```
① 用户访问服务器配置页（hermes.fanc.link/rokid-config.html）
   → 填 sseUrl / deviceId / token → 生成配置二维码
② 眼镜首次打开 → 显示「未配置，按镜腿键扫码」
③ 按镜腿键 → 拍照（takePhoto 回调式 API）→ BarcodeDetector.detect(ImageData)
   → 解析配置 JSON → 写入 localStorage(ntf_config) → 自动连接
```

- 配置 JSON：`{"v":1,"sseUrl":"...","deviceId":"glasses-rokid-01","token":"..."}`
- 载荷：直接 JSON `{...}` 或 `hermes-notify://config?json=<encoded>`

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

## 配置存储（localStorage）

| key | 说明 |
|:---|:---|
| `ntf_config` | 用户配置 JSON（{ v, sseUrl, deviceId, token }）——扫码写入 |
| `ntf_current` | 当前通知 JSON（app.js 写入，页面读取渲染） |
| `ntf_connected` | 连接状态（'true'/'false'） |

## 调试

- 后端测试：`POST /api/hermes/notifications/devices/test` 发测试通知（JWT，super_admin）
- 连接验证：`curl -N 'https://<host>/api/hermes/notifications/stream?deviceId=<id>&token=<token>'`
- 模拟器：DevTools 注入 localStorage `ntf_config` 后刷新

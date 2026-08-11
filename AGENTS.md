# rokid-notify-agent

Rokid 眼镜通知 Agent —— 设备通知中心的「随身通知」通道。

## 功能

- 启动即订阅 hermes-studio 通知中心 SSE 流（`/api/hermes/notifications/stream`）
- 收到通知在眼镜显示通知卡片（monochrome-green 设计系统，优先级亮度分级）
- 8 秒自动关闭 + 硬件键（GlobalHook/Enter）立即关闭
- 断线指数退避重连（5s→60s 封顶）
- 过期事件（expireAt）自动忽略

## 架构

```
hermes-studio 通知中心
    │ SSE（GET /api/hermes/notifications/stream?deviceId=glasses&token=）
    ▼
Rokid AI App（手机，蓝牙网络中继）
    ▼
本 Agent（.aix，app.js 订阅 → pages/index 渲染卡片）
```

## 配置（app.js 顶部）

- `NOTIFY_URL`：通知中心 SSE 地址（默认 hermes.fanc.link）
- `DEVICE_ID` / `DEVICE_TOKEN`：设备注册后签发

## 开发

```bash
npm install
npm start        # 本地开发服务器
```

打包为 `.aix` 后经 AIUI Studio 扫码安装到眼镜。

## 设计约束

- 单色绿显示（#40FF5E），480x352 画布
- 信息层级用亮度/线宽表达（颜色不可编码语义）
- 通知 8s 自动关闭，防打扰

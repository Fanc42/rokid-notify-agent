# Agent Manifest

## Identity
- **Name**: 通知中心
- **Version**: 1.0.0
- **Description**: Rokid Glasses 通知 Agent——订阅 Hermes 设备通知中心通知流（SSE + 轮询兜底），在眼镜显示通知卡片（审批/任务/提醒）。支持扫码配置服务器地址。
- **Author**: Coco

## Capabilities
- **Permissions**:
  - network
  - camera
- **Skills**:
  - notification-subscribe
  - qr-scan-config
  - localStorage-state

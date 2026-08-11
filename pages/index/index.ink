<script type="application/json" def>
{
  "navigationBarTitleText": "通知中心",
  "description": "显示 Hermes 设备通知中心推送的通知卡片（审批/任务/提醒）。未配置时引导扫码配置服务器；已配置时轮询 localStorage 渲染当前通知（优先级亮度分级），支持镜腿键关闭。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "ntf": {
          "type": "object",
          "description": "当前通知（title/body/priority/type）；null 表示无通知"
        },
        "connected": {
          "type": "boolean",
          "description": "SSE/轮询连接状态"
        },
        "needConfig": {
          "type": "boolean",
          "description": "是否未配置（显示扫码引导）"
        }
      }
    }
  }
}
</script>

<script setup>
// 通知中心 agent（分发版）
// 两种模式：
//  - 已配置：轮询 localStorage 读通知卡片（monochrome-green，优先级亮度分级）
//  - 未配置：扫码配置模式——拍照扫配置二维码 → 解析 JSON → 保存并连接
// 扫码链路：cameraContext.takePhoto → BarcodeDetector.detect → JSON.parse → app.saveConfig

import wx from 'wx'
import { BarcodeDetector } from 'barcode'

const KEY_CONFIG = 'ntf_config'
const KEY_CURRENT = 'ntf_current'
const KEY_CONNECTED = 'ntf_connected'

const BARCODE_FORMATS = ['qr_code']

function readJson(key) {
  const raw = localStorage.getItem(key)
  if (!raw) return null
  try { return JSON.parse(raw) } catch (e) { return null }
}

export default {
  data: {
    ntf: null,            // 当前通知
    connected: false,     // SSE 连接状态
    needConfig: false,    // 未配置 → 扫码引导
    scanning: false,      // 拍照解析中
    configMsg: '',        // 配置结果提示
  },

  onShow() {
    this.refresh()
    if (this._poll) clearInterval(this._poll)
    // 2s 轮询（省电；通知 8s 窗口内足够）
    this._poll = setInterval(() => this.refresh(), 2000)
  },

  onHide() {
    if (this._poll) clearInterval(this._poll)
    this._poll = null
  },

  refresh() {
    const configured = !!localStorage.getItem(KEY_CONFIG)
    const ntf = readJson(KEY_CURRENT)
    const connected = localStorage.getItem(KEY_CONNECTED) === 'true'

    const sameNtf = this.data.ntf && ntf && this.data.ntf.id === ntf.id
    const stateChanged =
      this.data.needConfig !== !configured ||
      this.data.connected !== connected ||
      !sameNtf
    if (!stateChanged) return
    this.setData({ ntf, connected, needConfig: !configured })
  },

  // ---- 拍照（AIUI 相机回调式 API 封装，参考 rokid-aiui-lab 真机验证模式）----
  takePhotoCallback(camera) {
    return new Promise((resolve, reject) => {
      let done = false
      const finish = (fn, payload) => { if (!done) { done = true; fn(payload) } }
      try {
        const ret = camera.takePhoto({
          quality: 'low',
          resultType: 'imageData',
          dataType: 'imageData',
          success: (res) => finish(resolve, res),
          fail: (err) => finish(reject, err),
        })
        if (ret && typeof ret.then === 'function') {
          ret.then((res) => finish(resolve, res)).catch((err) => finish(reject, err))
        } else if (ret && typeof ret === 'object' && Object.keys(ret).length > 0) {
          finish(resolve, ret)
        } else if (!ret) {
          setTimeout(() => finish(reject, new Error('takePhoto no result')), 12000)
        }
      } catch (err) {
        finish(reject, err)
      }
    })
  },

  // ---- 从 photo 提取 ImageData（须为真 ImageData 实例——QuickJS 原生桥转换 plain object 报错）----
  toImageDataObj(photo) {
    if (!photo) return null
    const candidates = [photo.imageData, photo.rgba, photo.pixels, photo.frame, photo]
    for (let i = 0; i < candidates.length; i++) {
      const c = candidates[i]
      if (c && c.data && c.width && c.height) {
        const result = this.toImageData(c.data, c.width, c.height)
        if (result) return result
      }
    }
    if (photo.data && photo.width && photo.height && photo.data.byteLength !== undefined) {
      return this.toImageData(photo.data, photo.width, photo.height)
    }
    return null
  },

  toImageData(data, width, height) {
    const w = Number(width)
    const h = Number(height)
    if (!w || !h || !data) return null
    const clamped = data instanceof Uint8ClampedArray ? data : new Uint8ClampedArray(data)
    if (clamped.length < w * h * 4) return null
    // ⚠️ AIUI 环境有 ImageData 构造器——必须返回真 ImageData 实例（原生桥转换）
    if (typeof ImageData !== 'undefined') {
      try { return new ImageData(clamped, w, h) } catch (e) { /* fall through */ }
    }
    return { data: clamped, width: w, height: h }
  },

  // ---- 扫码配置 ----
  async scanConfig() {
    if (this.data.scanning) return
    this.setData({ scanning: true, configMsg: '拍照解析中…' })

    try {
      // 1. 获取相机
      let camera = this.cameraContext
      if (!camera || typeof camera.takePhoto !== 'function') {
        if (wx.media && typeof wx.media.createCameraContext === 'function') {
          camera = wx.media.createCameraContext()
          this.cameraContext = camera
        }
      }
      if (!camera || typeof camera.takePhoto !== 'function') {
        this.setData({ scanning: false, configMsg: '相机不可用' })
        return
      }

      // 2. 拍照——AIUI 相机是回调式 API（success/fail），不是 Promise
      const photo = await this.takePhotoCallback(camera)
      if (!photo) {
        this.setData({ scanning: false, configMsg: '拍照无结果' })
        return
      }

      // 3. 从 photo 提取 ImageData（{data, width, height}）——BarcodeDetector 需要 ImageData
      const imageData = this.toImageDataObj(photo)
      if (!imageData) {
        console.log('[notify-agent] no imageData in photo', Object.keys(photo || {}))
        this.setData({ scanning: false, configMsg: '拍照格式不支持' })
        return
      }

      // 4. 二维码识别
      const detector = new BarcodeDetector({ formats: BARCODE_FORMATS })
      const codes = await detector.detect(imageData)
      if (!codes || codes.length === 0) {
        this.setData({ scanning: false, configMsg: '未识别到二维码，请对准后重试' })
        return
      }
      const raw = codes[0].rawValue || ''
      console.log('[notify-agent] qr raw', raw.slice(0, 120))

      // 4. 解析配置 JSON（支持直接 JSON 或 hermes-notify://config?json=<encoded>）
      // ⚠️ 避免 new URL()——AIUI 环境可能不支持标准 URL 构造（报 converting from js 类型错误）
      let cfg = null
      const trimmed = String(raw).trim()
      if (trimmed.startsWith('{')) {
        try { cfg = JSON.parse(trimmed) } catch (e) { console.error('[notify-agent] direct json parse fail', e) }
      } else {
        const jsonMark = 'json='
        const idx = trimmed.indexOf(jsonMark)
        if (idx >= 0) {
          const encoded = trimmed.slice(idx + jsonMark.length).split('&')[0]
          try {
            cfg = JSON.parse(decodeURIComponent(encoded))
          } catch (e) {
            console.error('[notify-agent] encoded json parse fail', e)
          }
        }
      }
      if (!cfg || !cfg.sseUrl || !cfg.token) {
        console.log('[notify-agent] invalid qr cfg', cfg)
        this.setData({ scanning: false, configMsg: '二维码不是有效配置，请重新生成' })
        return
      }

      // 5. 保存配置（AIUI 无 getApp——页面直接写 localStorage，app 层 2s 轮询发现后连接）
      const normalized = {
        v: 1,
        sseUrl: String(cfg.sseUrl).replace(/\/+$/, ''),
        deviceId: cfg.deviceId || 'glasses-rokid-01',
        token: cfg.token,
      }
      localStorage.setItem(KEY_CONFIG, JSON.stringify(normalized))
      this.setData({
        scanning: false,
        configMsg: '配置已保存，正在连接…',
      })
    } catch (e) {
      console.error('[notify-agent] scan error', e)
      this.setData({ scanning: false, configMsg: '扫码失败：' + String(e).slice(0, 40) })
    }
  },

  // 硬件键：镜腿单击=Enter/GlobalHook，双击=Backspace
  onKeyUp(event) {
    if (event.code === 'GlobalHook' || event.code === 'Enter' || event.code === 'Backspace' || event.code === 'Escape') {
      // 必须 preventDefault——否则 Backspace 会触发系统「返回上一页」导致 agent 退出
      event.preventDefault()
      if (this.data.needConfig) {
        // 配置模式：镜腿键触发扫码
        this.scanConfig()
      } else {
        // 通知模式：关闭当前通知
        localStorage.removeItem(KEY_CURRENT)
        this.setData({ ntf: null })
      }
    }
  },
}
</script>

<page>
  <!-- 未配置：扫码引导 -->
  <view class="config-panel" ink:if="{{ needConfig }}">
    <text class="config-title">通知中心 · 未配置</text>
    <text class="config-hint">按镜腿键扫描配置二维码</text>
    <text class="config-sub">在服务器打开配置页生成二维码：</text>
    <text class="config-url">hermes.fanc.link/rokid-config.html</text>
    <text class="config-status {{ scanning ? 'active' : '' }}">{{ configMsg || (scanning ? '拍照解析中…' : '') }}</text>
  </view>

  <!-- 已配置：连接状态角标 + 通知卡片 -->
  <block ink:else>
    <view class="status-bar">
      <view class="status-dot {{ connected ? 'on' : 'off' }}"></view>
      <text class="status-text">{{ connected ? '已连接' : '重连中' }}</text>
    </view>

    <view class="ntf-card priority-{{ ntf.priority }}" ink:if="{{ ntf }}">
      <view class="ntf-header">
        <text class="ntf-type">{{ ntf.type }}</text>
        <text class="ntf-close-hint">按返回键关闭</text>
      </view>
      <text class="ntf-title">{{ ntf.title }}</text>
      <text class="ntf-body">{{ ntf.body }}</text>
    </view>

    <view class="empty" ink:else>
      <text class="empty-icon">●</text>
      <text class="empty-text">暂无通知</text>
    </view>
  </block>
</page>

<style>
/* monochrome-green 设计系统：单色绿 #40FF5E，透明度分级表达层级 */
page {
  background: #000;
  width: 480px;
  height: 352px;
  overflow: hidden;
}

/* ---- 配置面板 ---- */
.config-panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  padding: 0 24px;
}

.config-title {
  color: #40FF5E;
  font-size: 20px;
  font-weight: bold;
  margin-bottom: 14px;
}

.config-hint {
  color: #40FF5E;
  font-size: 16px;
  margin-bottom: 10px;
  border: 1px solid rgba(64, 255, 94, 0.48);
  border-radius: 8px;
  padding: 8px 16px;
}

.config-sub {
  color: rgba(64, 255, 94, 0.48);
  font-size: 12px;
  margin-top: 8px;
}

.config-url {
  color: rgba(64, 255, 94, 0.72);
  font-size: 12px;
  margin-top: 4px;
}

.config-status {
  color: rgba(64, 255, 94, 0.72);
  font-size: 13px;
  margin-top: 14px;
}
.config-status.active {
  color: #40FF5E;
}

/* ---- 状态角标 ---- */
.status-bar {
  display: flex;
  flex-direction: row;
  align-items: center;
  padding: 8px 12px;
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-right: 6px;
}
.status-dot.on {
  background: #40FF5E;
}
.status-dot.off {
  background: rgba(64, 255, 94, 0.24);
}

.status-text {
  color: rgba(64, 255, 94, 0.48);
  font-size: 12px;
}

/* ---- 通知卡片 ---- */
.ntf-card {
  margin: 4px 12px;
  padding: 14px 16px;
  border-radius: 8px;
  border: 1px solid rgba(64, 255, 94, 0.48);
  background: rgba(64, 255, 94, 0.06);
  display: flex;
  flex-direction: column;
}

/* 优先级亮度分级 */
.priority-high {
  border: 2px solid #40FF5E;
  background: rgba(64, 255, 94, 0.12);
}
.priority-normal {
  border: 1px solid rgba(64, 255, 94, 0.48);
}
.priority-low {
  border: 1px solid rgba(64, 255, 94, 0.24);
  opacity: 0.72;
}

.ntf-header {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.ntf-type {
  color: rgba(64, 255, 94, 0.48);
  font-size: 12px;
}

.ntf-close-hint {
  color: rgba(64, 255, 94, 0.24);
  font-size: 10px;
}

.ntf-title {
  color: #40FF5E;
  font-size: 22px;
  line-height: 28px;
  font-weight: bold;
  margin-bottom: 6px;
}

.ntf-body {
  color: rgba(64, 255, 94, 0.72);
  font-size: 14px;
  line-height: 20px;
}

.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 260px;
}

.empty-icon {
  color: rgba(64, 255, 94, 0.24);
  font-size: 32px;
  margin-bottom: 10px;
}

.empty-text {
  color: rgba(64, 255, 94, 0.24);
  font-size: 16px;
}
</style>

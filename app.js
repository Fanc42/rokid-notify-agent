// rokid-notify-agent — 通知中心随身通道
// 启动即订阅 hermes-studio 通知中心的 SSE 流，收到事件写入 localStorage，
// 页面轮询读取并渲染通知卡片（AIUI 无全局数据总线，用标准 Web Storage 共享）。

// ⚙️ 配置（真机验证时填写）
const NOTIFY_URL = 'https://hermes.fanc.link/api/hermes/notifications/stream'
const DEVICE_ID = 'glasses-rokid-01'
const DEVICE_TOKEN = 'REPLACE_WITH_DEVICE_TOKEN'

// 通知自动关闭时长（ms）
const AUTO_CLOSE_MS = 8000

// localStorage key
const KEY_CURRENT = 'ntf_current'      // 当前通知 JSON（页面读取渲染）
const KEY_CONNECTED = 'ntf_connected'  // SSE 连接状态

export default {
  onLaunch: function () {
    console.log('[notify-agent] launch')
    this.startStream()
  },

  onShow: function () {
    console.log('[notify-agent] show')
  },

  onHide: function () {
    // 保持订阅（断线重连由 startStream 内部处理）
  },

  // ---- SSE 订阅 ----
  startStream() {
    if (this._es) return
    const url = `${NOTIFY_URL}?deviceId=${DEVICE_ID}&token=${DEVICE_TOKEN}`
    console.log('[notify-agent] connecting SSE', url)

    const es = new EventSource(url)
    this._es = es

    es.onopen = () => {
      console.log('[notify-agent] SSE connected')
      localStorage.setItem(KEY_CONNECTED, 'true')
      this._retryMs = 5000
    }

    es.onmessage = (event) => {
      try {
        const ntf = JSON.parse(event.data)
        console.log('[notify-agent] received', ntf.type, ntf.priority)
        this.handleNotification(ntf)
      } catch (e) {
        console.error('[notify-agent] parse error', e)
      }
    }

    es.onerror = () => {
      console.error('[notify-agent] SSE error, reconnecting in', this._retryMs)
      localStorage.setItem(KEY_CONNECTED, 'false')
      es.close()
      this._es = null
      // 指数退避重连：5s → 10s → 20s → 40s → 60s 封顶
      const delay = this._retryMs || 5000
      this._retryMs = Math.min(delay * 2, 60000)
      setTimeout(() => this.startStream(), delay)
    }
  },

  // ---- 通知处理 ----
  handleNotification(ntf) {
    // 过期事件直接忽略
    if (ntf.expireAt && Date.now() > ntf.expireAt) {
      console.log('[notify-agent] expired, ignore', ntf.id)
      return
    }

    // 写入 localStorage 供页面渲染
    localStorage.setItem(KEY_CURRENT, JSON.stringify(ntf))

    // 重置自动关闭定时器
    if (this._closeTimer) clearTimeout(this._closeTimer)
    this._closeTimer = setTimeout(() => {
      console.log('[notify-agent] auto close after', AUTO_CLOSE_MS)
      localStorage.removeItem(KEY_CURRENT)
    }, AUTO_CLOSE_MS)
  },
}

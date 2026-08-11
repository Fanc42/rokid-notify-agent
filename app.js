// rokid-notify-agent — 通知中心随身通道（分发版）
// 启动读取本地配置（localStorage ntf_config）→ 连接用户自定的通知中心 SSE 流。
// 无配置时进入「扫码配置」模式：用户扫配置二维码（含 sseUrl/deviceId/token）。
// 分发友好：每个用户扫码配置自己的服务器地址，无需改代码重新打包。

// 配置 key
const KEY_CONFIG = 'ntf_config'       // 用户配置 JSON { v, sseUrl, deviceId, token }
const KEY_CURRENT = 'ntf_current'      // 当前通知 JSON（页面读取渲染）
const KEY_CONNECTED = 'ntf_connected'  // SSE 连接状态

// 通知自动关闭时长（ms）
const AUTO_CLOSE_MS = 8000

export default {
  onLaunch: function () {
    console.log('[notify-agent] launch')
    // 配置：localStorage 扫码配置（真机扫码写入；模拟器可用 DevTools 注入）
    const cfg = this.loadConfig()
    if (cfg) {
      console.log('[notify-agent] config found, connecting')
      this.startStream(cfg)
      this.startPolling(cfg)   // 轮询兜底（蓝牙中继下 SSE 可能不实时）
    } else {
      console.log('[notify-agent] no config, watching for scan result')
      localStorage.setItem(KEY_CONNECTED, 'false')
      this.startConfigWatch()
    }
  },

  // 无配置时轮询检测 localStorage（AIUI 无全局事件总线/getApp，页面扫码后写配置，
  // app 层定时发现变化即连接——简单可靠）
  startConfigWatch() {
    if (this._configWatch) return
    this._configWatch = setInterval(() => {
      const cfg = this.loadConfig()
      if (cfg) {
        console.log('[notify-agent] config detected, connecting')
        clearInterval(this._configWatch)
        this._configWatch = null
        this.startStream(cfg)
      }
    }, 2000)
  },

  onShow: function () {
    console.log('[notify-agent] show')
  },

  onHide: function () {
    // 保持订阅（断线重连由 startStream 内部处理）
  },

  // ---- 配置 ----
  loadConfig() {
    const raw = localStorage.getItem(KEY_CONFIG)
    if (!raw) return null
    try {
      const cfg = JSON.parse(raw)
      if (cfg && typeof cfg.sseUrl === 'string' && cfg.sseUrl && typeof cfg.token === 'string' && cfg.token) {
        return cfg
      }
    } catch (e) {
      console.error('[notify-agent] config parse error', e)
    }
    return null
  },

  // ---- SSE 订阅（wx.createEventSource——AIUI 运行时标准；标准 EventSource 仅兜底）----
  createEventSource(url, handlers) {
    if (typeof wx !== 'undefined' && wx.createEventSource) {
      const task = wx.createEventSource({ url, method: 'GET' })
      if (task.onOpen) task.onOpen(handlers.onOpen)
      if (task.onMessage) task.onMessage((event) => handlers.onMessage({ data: event && event.data, type: event && event.event }))
      if (task.onError) task.onError(handlers.onError)
      return task
    }
    // 标准 EventSource 兜底（模拟器/浏览器环境）
    const es = new EventSource(url)
    es.onopen = handlers.onOpen
    es.onmessage = handlers.onMessage
    es.onerror = handlers.onError
    return es
  },

  startStream(cfg) {
    if (this._es) return
    const url = `${cfg.sseUrl}/api/hermes/notifications/stream?deviceId=${encodeURIComponent(cfg.deviceId)}&token=${encodeURIComponent(cfg.token)}`
    console.log('[notify-agent] connecting SSE', url)

    const handlers = {
      onOpen: () => {
        console.log('[notify-agent] SSE connected')
        localStorage.setItem(KEY_CONNECTED, 'true')
        this._retryMs = 5000
      },
      onMessage: (event) => {
        try {
          const ntf = JSON.parse(event.data)
          console.log('[notify-agent] received', ntf.type, ntf.priority)
          if (ntf.ts && ntf.ts > (this._lastTs || 0)) this._lastTs = ntf.ts
          this.handleNotification(ntf)
        } catch (e) {
          console.error('[notify-agent] parse error', e)
        }
      },
      onError: () => {
        console.error('[notify-agent] SSE error, reconnecting in', this._retryMs)
        localStorage.setItem(KEY_CONNECTED, 'false')
        try { this._es && this._es.close && this._es.close() } catch (e) { /* ignore */ }
        this._es = null
        // 指数退避重连：5s → 10s → 20s → 40s → 60s 封顶
        const delay = this._retryMs || 5000
        this._retryMs = Math.min(delay * 2, 60000)
        setTimeout(() => this.startStream(cfg), delay)
      },
    }

    this._es = this.createEventSource(url, handlers)
  },

  // ---- 轮询兜底（蓝牙中继下 SSE 长连可能不实时；30s 短请求拉取）----
  startPolling(cfg) {
    if (this._pollTimer) return
    this._cfg = cfg
    this._lastTs = this._lastTs || Date.now()
    this._pollTimer = setInterval(() => this.pollNotifications(), 30000)
  },

  async pollNotifications() {
    const cfg = this._cfg
    if (!cfg) return
    try {
      const url = `${cfg.sseUrl}/api/hermes/notifications/poll?deviceId=${encodeURIComponent(cfg.deviceId)}&token=${encodeURIComponent(cfg.token)}&since=${this._lastTs || 0}`
      const response = await fetch(url, { cache: 'no-store' })
      if (!response.ok) return
      const body = await response.json()
      const items = (body && body.notifications) || []
      if (items.length === 0) return
      let maxTs = this._lastTs || 0
      for (const ntf of items) {
        if (ntf.ts && ntf.ts > maxTs) maxTs = ntf.ts
        this.handleNotification(ntf)
      }
      if (maxTs > (this._lastTs || 0)) this._lastTs = maxTs
      localStorage.setItem(KEY_CONNECTED, 'true')
    } catch (e) {
      console.error('[notify-agent] poll error', e)
    }
  },

  // ---- 通知处理 ----
  handleNotification(ntf) {
    // 过期事件直接忽略
    if (ntf.expireAt && Date.now() > ntf.expireAt) {
      console.log('[notify-agent] expired, ignore', ntf.id)
      return
    }

    // 高优先级保护：当前显示 high 时，低优先级通知不覆盖（只刷新显示时长）
    const current = this._currentNtf
    const PRIORITY_RANK = { high: 3, normal: 2, low: 1 }
    const incomingRank = PRIORITY_RANK[ntf.priority] || 2
    if (current && (PRIORITY_RANK[current.priority] || 2) > incomingRank) {
      console.log('[notify-agent] keep high-priority', current.id, 'ignore', ntf.id)
      return
    }

    // 写入 localStorage 供页面渲染
    this._currentNtf = ntf
    localStorage.setItem(KEY_CURRENT, JSON.stringify(ntf))

    // 重置自动关闭定时器
    if (this._closeTimer) clearTimeout(this._closeTimer)
    this._closeTimer = setTimeout(() => {
      console.log('[notify-agent] auto close after', AUTO_CLOSE_MS)
      this._currentNtf = null
      localStorage.removeItem(KEY_CURRENT)
    }, AUTO_CLOSE_MS)
  },
}

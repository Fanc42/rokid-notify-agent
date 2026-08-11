<script type="application/json" def>
{
  "navigationBarTitleText": "通知中心",
  "description": "显示 Hermes 设备通知中心推送的通知卡片（审批/任务/提醒）。未配置时引导扫码配置服务器；已配置时轮询 localStorage 渲染当前通知（优先级亮度分级），支持镜腿键关闭。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "ntfTitle": { "type": "string", "description": "当前通知标题" },
        "ntfBody": { "type": "string", "description": "当前通知正文" },
        "ntfType": { "type": "string", "description": "通知类型" },
        "ntfPriority": { "type": "string", "enum": ["high", "normal", "low"], "description": "通知优先级" },
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
import { decodeQrFromBytesAsync } from '../../lib/local-qr.js'

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
    ntfTitle: '',         // 当前通知标题（扁平字段——ink-core 模板不支持嵌套路径）
    ntfBody: '',
    ntfType: '',
    ntfPriority: 'normal',
    hasNtf: false,        // 是否有通知（模板 ink:if 用布尔）
    connected: false,     // SSE 连接状态
    needConfig: false,    // 未配置 → 扫码引导
    scanning: false,      // 拍照解析中
    configMsg: '',        // 配置结果提示
    timeText: '',         // 右下角时间 HH:MM
    battery: 0,           // 右下角电量百分比（0-100；获取失败显示 --）
    batteryKnown: false,  // 电量是否成功读取
  },

  onShow() {
    this.refresh()
    if (this._poll) clearInterval(this._poll)
    // 2s 轮询（省电；通知 8s 窗口内足够）
    this._poll = setInterval(() => this.refresh(), 2000)
    // 时间/电量：30s 刷新（省电——HH:MM 分钟级变化，电量变化慢；实时性不需要 1s）
    this.updateStatusBar()
    if (this._statusTimer) clearInterval(this._statusTimer)
    this._statusTimer = setInterval(() => this.updateStatusBar(), 30000)
  },

  onHide() {
    if (this._poll) clearInterval(this._poll)
    this._poll = null
    if (this._statusTimer) clearInterval(this._statusTimer)
    this._statusTimer = null
  },

  // 右下角状态栏：时间（HH:MM）+ 电量（wx.getSystemInfoSync 防御性读取）
  updateStatusBar() {
    const d = new Date()
    const hh = String(d.getHours()).padStart(2, '0')
    const mm = String(d.getMinutes()).padStart(2, '0')
    const timeText = hh + ':' + mm
    let battery = this.data.battery
    let batteryKnown = this.data.batteryKnown
    try {
      if (typeof wx !== 'undefined' && wx.getSystemInfoSync) {
        const info = wx.getSystemInfoSync()
        const raw = info && (info.battery || info.batteryLevel || info.battery_level)
        if (raw !== undefined && raw !== null && raw !== '') {
          const num = Number(raw)
          if (Number.isFinite(num)) {
            battery = Math.max(0, Math.min(100, Math.round(num)))
            batteryKnown = true
          }
        }
      }
    } catch (e) { /* 环境不支持则保留上次值 */ }
    if (timeText !== this.data.timeText || battery !== this.data.battery || batteryKnown !== this.data.batteryKnown) {
      this.setData({ timeText, battery, batteryKnown })
    }
  },

  refresh() {
    const configured = !!localStorage.getItem(KEY_CONFIG)
    const ntf = readJson(KEY_CURRENT)
    const connected = localStorage.getItem(KEY_CONNECTED) === 'true'
    const hasNtf = !!ntf

    const sameId = hasNtf && ntf && this.data.ntfTitle === ntf.title && this.data.ntfBody === ntf.body
    const stateChanged =
      this.data.needConfig !== !configured ||
      this.data.connected !== connected ||
      this.data.hasNtf !== hasNtf ||
      !sameId
    if (!stateChanged) return
    this.setData({
      ntfTitle: ntf ? (ntf.title || '') : '',
      ntfBody: ntf ? (ntf.body || '') : '',
      ntfType: ntf ? (ntf.type || '') : '',
      ntfPriority: ntf ? (ntf.priority || 'normal') : 'normal',
      hasNtf,
      connected,
      needConfig: !configured,
    })
  },

  // ---- 拍照（AIUI 相机回调式 API；多档参数降级，参考 rokid-aiui-lab 真机验证模式）----
  // 3 档从全参数到最简逐档尝试：环境（真机/模拟器/网页端）支持程度不同，
  // 单档参数在部分环境报「拍照格式不支持」——降级可兜底。
  takePhotoOnce(camera, options) {
    return new Promise((resolve, reject) => {
      let done = false
      const finish = (fn, payload) => { if (!done) { done = true; fn(payload) } }
      try {
        const ret = camera.takePhoto(Object.assign({}, options, {
          success: (res) => finish(resolve, res),
          fail: (err) => finish(reject, err),
        }))
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

  takePhotoCallback(camera) {
    return new Promise((resolve, reject) => {
      (async () => {
        const profiles = [
          { name: '极速', options: { quality: 'low', width: 512, height: 384, maxWidth: 512, maxHeight: 384, size: 'small', resolution: 'low', mode: 'fast', format: 'rgba', imageFormat: 'rgba', output: 'imageData', resultType: 'imageData', dataType: 'imageData', returnImageData: true } },
          { name: '小图', options: { quality: 'low', width: 640, height: 480, maxWidth: 640, maxHeight: 480, size: 'small', resolution: 'low' } },
          { name: '低清', options: { quality: 'low' } },
        ]
        let lastErr = null
        for (let i = 0; i < profiles.length; i++) {
          const profile = profiles[i]
          try {
            const photo = await this.takePhotoOnce(camera, profile.options)
            console.log('[notify-agent] takePhoto ok', profile.name)
            resolve(photo)
            return
          } catch (err) {
            lastErr = err
            console.warn('[notify-agent] takePhoto profile fail', profile.name, err)
          }
        }
        reject(lastErr || new Error('takePhoto failed'))
      })()
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

  // ---- 从 photo 取文件路径（小图/低清档返回 tempFilePath 而非 imageData）----
  getPhotoFilePath(photo) {
    if (!photo) return null
    const c = photo.tempFilePath || photo.tempFile || photo.filePath || photo.path || photo.file
    return typeof c === 'string' && c ? c : null
  },

  // ---- 从 photo 取 base64（极速档返回 {data, mimeType}——data 可能是 base64 字符串或字节）----
  getPhotoBase64(photo) {
    if (!photo) return ''
    const candidates = [photo.base64, photo.imageBase64, photo.dataBase64]
    for (let i = 0; i < candidates.length; i++) {
      const text = String(candidates[i] || '').trim()
      if (text) return this.stripDataUrl(text)
    }
    if (typeof photo.data === 'string' && photo.data) return this.stripDataUrl(photo.data.trim())
    // 字节（ArrayBuffer/Uint8Array）→ base64
    const bytes = photo.data instanceof ArrayBuffer || (photo.data && photo.data.byteLength !== undefined)
      ? photo.data : null
    if (bytes) {
      const b64 = this.bytesToBase64(bytes)
      if (b64) return b64
    }
    return ''
  },

  stripDataUrl(text) {
    const idx = text.indexOf(',')
    if (idx >= 0 && /^data:[\w/+.-]+;base64/i.test(text.slice(0, idx + 1))) return text.slice(idx + 1)
    return text
  },

  bytesToBase64(bytes) {
    const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let out = ''
    for (let i = 0; i < u8.length; i += 3) {
      const b0 = u8[i]
      const b1 = i + 1 < u8.length ? u8[i + 1] : 0
      const b2 = i + 2 < u8.length ? u8[i + 2] : 0
      out += B64[b0 >> 2]
      out += B64[((b0 & 3) << 4) | (b1 >> 4)]
      out += i + 1 < u8.length ? B64[((b1 & 15) << 2) | (b2 >> 6)] : '='
      out += i + 2 < u8.length ? B64[b2 & 63] : '='
    }
    return out
  },

  base64ToBytes(b64) {
    const text = String(b64 || '').replace(/\s+/g, '')
    if (!text) return null
    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    const len = text.length
    const pad = text.charAt(len - 1) === '=' ? (text.charAt(len - 2) === '=' ? 2 : 1) : 0
    const out = new Uint8Array(Math.floor((len * 3) / 4) - pad)
    let p = 0
    for (let i = 0; i < len; i += 4) {
      const c0 = B64.indexOf(text.charAt(i))
      const c1 = B64.indexOf(text.charAt(i + 1))
      const c2 = B64.indexOf(text.charAt(i + 2))
      const c3 = B64.indexOf(text.charAt(i + 3))
      const n = (c0 << 18) | (c1 << 12) | ((c2 < 0 ? 0 : c2) << 6) | (c3 < 0 ? 0 : c3)
      out[p++] = (n >> 16) & 0xff
      if (p < out.length) out[p++] = (n >> 8) & 0xff
      if (p < out.length) out[p++] = n & 0xff
    }
    return out
  },

  // ---- 从 photo 取图片字节（local-qr 解码输入；data 支持 ArrayBuffer/Uint8Array/base64 字符串）----
  getPhotoBinary(photo) {
    if (!photo) return null
    const data = photo.data || photo.arrayBuffer || photo.buffer || photo.bytes
    if (data && data.byteLength !== undefined) return data instanceof Uint8Array ? data : new Uint8Array(data)
    const b64 = this.getPhotoBase64(photo)
    if (b64) return this.base64ToBytes(b64)
    return null
  },

  // ---- photo → data URL（canvas.drawImage 支持；mimeType 缺失时按前缀猜）----
  photoToDataUrl(photo) {
    const base64 = this.getPhotoBase64(photo)
    if (!base64) return ''
    let mime = photo.mimeType || photo.mime || ''
    if (!mime) {
      if (base64.slice(0, 8) === 'iVBORw0K') mime = 'image/png'
      else if (base64.slice(0, 5) === 'UklGR') mime = 'image/webp'
      else mime = 'image/jpeg'
    }
    return 'data:' + mime + ';base64,' + base64
  },

  // ---- canvas 兜底：文件路径 → 等比缩放绘制到画布 → ImageData ----
  // 参考 rokid-aiui-lab 真机验证链路（BARCODE_CANVAS_SIZE=360：小图识别稳、快）
  // ⚠️ 等比缩放（非拉伸）：二维码变形会导致识别失败；小图不放大（防模糊）
  canvasImageDataFromPath(filePath) {
    const maxSize = 360
    return new Promise((resolve, reject) => {
      if (!wx || !wx.createCanvasContext || !wx.canvasGetImageData) {
        reject(new Error('canvas 像素接口不可用'))
        return
      }
      const drawAndRead = (w, h) => {
        // 等比缩放：最大边 maxSize；小于 maxSize 的原图保持原尺寸（放大模糊）
        let tw = w
        let th = h
        if (tw > maxSize || th > maxSize) {
          const scale = Math.min(maxSize / tw, maxSize / th)
          tw = Math.round(tw * scale)
          th = Math.round(th * scale)
        }
        const canvasW = Math.max(tw, 1)
        const canvasH = Math.max(th, 1)
        const ctx = wx.createCanvasContext('ntfDecodeCanvas', this)
        if (!ctx || !ctx.drawImage) {
          reject(new Error('canvas.drawImage 不存在'))
          return
        }
        try {
          if (ctx.clearRect) ctx.clearRect(0, 0, canvasW, canvasH)
          ctx.drawImage(filePath, 0, 0, canvasW, canvasH)
          ctx.draw(false, () => {
            wx.canvasGetImageData({
              canvasId: 'ntfDecodeCanvas',
              x: 0,
              y: 0,
              width: canvasW,
              height: canvasH,
              success: (res) => {
                const imageData = this.toImageData(res.data, res.width || canvasW, res.height || canvasH)
                if (imageData) resolve(imageData)
                else reject(new Error('canvas 未返回 ImageData'))
              },
              fail: (err) => reject(err || new Error('canvasGetImageData fail')),
            }, this)
          })
        } catch (err) {
          reject(err)
        }
      }
      // 原图尺寸（等比缩放需要）；getImageInfo 失败则退化 360 正方形（原行为）
      if (wx.getImageInfo) {
        wx.getImageInfo({
          src: filePath,
          success: (info) => drawAndRead(Number(info.width) || maxSize, Number(info.height) || maxSize),
          fail: () => drawAndRead(maxSize, maxSize),
        })
      } else {
        drawAndRead(maxSize, maxSize)
      }
    })
  },

  // ---- photo → ImageData：优先直接取 imageData 字段，失败走官方 Blob→Canvas 链路 ----
  async photoToImageData(photo) {
    const direct = this.toImageDataObj(photo)
    if (direct) return direct
    // 官方链路（AIUI image_apis sample）：photo.data(ArrayBuffer) → Blob → createImageBitmap → Canvas → getImageData
    const viaBlob = await this.photoToImageDataViaBlob(photo)
    if (viaBlob) return viaBlob
    // 兜底：文件路径 / base64 dataUrl → wx 老式 canvas（真机环境可能可用）
    const filePath = this.getPhotoFilePath(photo)
    if (filePath) {
      try {
        return await this.canvasImageDataFromPath(filePath)
      } catch (e) {
        console.warn('[notify-agent] canvas convert (path) fail', e)
      }
    }
    const dataUrl = this.photoToDataUrl(photo)
    if (dataUrl) {
      try {
        return await this.canvasImageDataFromPath(dataUrl)
      } catch (e) {
        console.warn('[notify-agent] canvas convert (dataUrl) fail', e)
      }
    }
    return null
  },

  // ---- 官方链路：data(ArrayBuffer) → Blob → createImageBitmap → Canvas → ImageData ----
  // maxSize>0 时等比缩放到最大边 maxSize（≤360 小图识别稳）；maxSize=0 返回原尺寸（二维码细节保留）
  async photoToImageDataViaBlob(photo, maxSize) {
    try {
      const data = photo.data || photo.arrayBuffer || photo.buffer
      if (!data || typeof data === 'string') return null
      if (typeof createImageBitmap !== 'function' || typeof Canvas === 'undefined') return null
      const blob = new Blob([data], { type: photo.mimeType || 'image/jpeg' })
      const bitmap = await createImageBitmap(blob)
      if (!bitmap || !bitmap.width || !bitmap.height) return null
      // 等比缩放：仅当 maxSize>0 且超出才缩放（原尺寸保留二维码细节）
      const limit = Number(maxSize) || 0
      let w = bitmap.width
      let h = bitmap.height
      if (limit > 0 && (w > limit || h > limit)) {
        const scale = Math.min(limit / w, limit / h)
        w = Math.round(w * scale)
        h = Math.round(h * scale)
      }
      const canvas = new Canvas(w, h)
      const ctx = canvas.getContext('2d')
      ctx.drawImage(bitmap, 0, 0, w, h)
      const imageData = ctx.getImageData(0, 0, w, h)
      if (!imageData || !imageData.data) return null
      return this.toImageData(imageData.data, w, h)
    } catch (e) {
      console.warn('[notify-agent] blob canvas fail', e)
      return null
    }
  },

  // ---- BarcodeDetector.detect 带超时（大图 detect 慢/卡——3.2s 超时兜底，参考 rokid-aiui-lab）----
  detectWithTimeout(detector, source, timeoutMs) {
    return new Promise((resolve) => {
      let done = false
      const finish = (v) => { if (!done) { done = true; resolve(v) } }
      try {
        Promise.resolve(detector.detect(source))
          .then((codes) => finish(codes))
          .catch((err) => { console.warn('[notify-agent] detect err', err); finish(null) })
        setTimeout(() => finish([]), timeoutMs || 3200)
      } catch (err) {
        console.warn('[notify-agent] detect throw', err)
        finish(null)
      }
    })
  },

  // ---- 扫码配置 ----
  async scanConfig() {
    if (this.data.scanning) return
    this.setData({ scanning: true, configMsg: '拍照解析中…' })

    // 环境能力检查（QuickJS 运行时可能缺对象）
    if (typeof BarcodeDetector === 'undefined') {
      this.setData({ scanning: false, configMsg: '当前环境无条码识别能力' })
      return
    }

    try {
      // 1. 获取相机——兼容两种入口：wx.createCameraContext()（文档）/ wx.media.createCameraContext()（sample）
      let camera = this.cameraContext
      if (!camera || typeof camera.takePhoto !== 'function') {
        const createCamera =
          (wx.media && typeof wx.media.createCameraContext === 'function' && wx.media.createCameraContext.bind(wx.media)) ||
          (typeof wx.createCameraContext === 'function' && wx.createCameraContext.bind(wx))
        if (createCamera) {
          try {
            camera = createCamera()
          } catch (e) {
            console.error('[notify-agent] createCameraContext error', e)
            camera = null
          }
        }
        this.cameraContext = camera
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

      // 3. 构建候选 ImageData（多尺寸逐试——原尺寸保留二维码细节，缩放小图 detect 稳/快）
      const candidates = []
      const direct = this.toImageDataObj(photo)
      if (direct) candidates.push({ label: 'direct ' + direct.width + 'x' + direct.height, img: direct })
      const viaBlob = await this.photoToImageDataViaBlob(photo, 0)
      if (viaBlob && viaBlob !== direct) {
        candidates.push({ label: '原尺寸 ' + viaBlob.width + 'x' + viaBlob.height, img: viaBlob })
        if (viaBlob.width > 360 || viaBlob.height > 360) {
          const scaled = await this.photoToImageDataViaBlob(photo, 360)
          if (scaled) candidates.push({ label: '缩放360 ' + scaled.width + 'x' + scaled.height, img: scaled })
        }
      }
      if (candidates.length === 0) {
        console.log('[notify-agent] no imageData in photo', Object.keys(photo || {}))
        this.setData({ scanning: false, configMsg: '无法解析拍照结果（无像素数据）' })
        return
      }

      // 4. 二维码识别——逐候选试，命中即停
      const detector = new BarcodeDetector({ formats: BARCODE_FORMATS })
      let codes = null
      const attempts = []
      for (let i = 0; i < candidates.length; i++) {
        const c = candidates[i]
        const found = await this.detectWithTimeout(detector, c.img)
        attempts.push(c.label + ':' + (found && found.length ? '命中' : '空'))
        if (found && found.length > 0) { codes = found; break }
      }
      console.log('[notify-agent] detect attempts:', attempts.join(' | '))
      if (!codes || codes.length === 0) {
        // 5. 兜底：BarcodeDetector 全空（模拟器 stub 等）→ local-qr 纯 JS 解码（jpg/png/webp）
        let localRaw = ''
        try {
          const bytes = this.getPhotoBinary(photo)
          if (bytes && bytes.byteLength > 32) {
            const qrResult = await decodeQrFromBytesAsync(bytes)
            console.log('[notify-agent] local-qr', qrResult ? (qrResult.found ? '命中 ' + qrResult.rawPreview : qrResult.rawPreview) : '无结果')
            if (qrResult && qrResult.found && qrResult.text) localRaw = String(qrResult.text)
          }
        } catch (e) {
          console.warn('[notify-agent] local-qr fail', e)
        }
        if (!localRaw) {
          this.setData({ scanning: false, configMsg: '未识别到二维码，请对准后重试' })
          return
        }
        codes = [{ rawValue: localRaw }]
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
      const errText = String((e && e.message) || e || 'unknown')
      this.setData({ scanning: false, configMsg: '扫码失败：' + errText.slice(0, 80) })
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
        this.setData({ ntfTitle: '', ntfBody: '', ntfType: '', hasNtf: false })
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

  <!-- 已配置：通知卡片 + 底部状态栏（左下连接状态 / 右下时间电量） -->
  <!-- 已配置：通知卡片 + 底部状态栏（左下连接状态 / 右下时间电量）（ink-core 不认识 <block>——用 view 包裹） -->
  <view class="main-body" ink:else>
    <view class="ntf-area">
      <view class="ntf-card priority-{{ ntfPriority }}" ink:if="{{ hasNtf }}">
        <view class="ntf-header">
          <text class="ntf-type">{{ ntfType }}</text>
          <text class="ntf-close-hint">按返回键关闭</text>
        </view>
        <text class="ntf-title">{{ ntfTitle }}</text>
        <text class="ntf-body">{{ ntfBody }}</text>
      </view>
    </view>

    <view class="status-bar">
      <view class="status-left">
        <view class="status-dot {{ connected ? 'on' : 'off' }}"></view>
        <text class="status-text">{{ connected ? '已连接' : '重连中' }}</text>
      </view>
      <view class="status-right">
        <text class="status-power">{{ batteryKnown ? battery + '%' : '--' }}</text>
        <text class="status-time">{{ timeText }}</text>
      </view>
    </view>
  </view>
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

/* ---- 主区域 + 底部状态栏 ---- */
.main-body {
  display: flex;
  flex-direction: column;
  height: 100%;
}

/* 通知卡片区域：垂直居中，无通知时留白（不再显示「暂无通知」圆点） */
.ntf-area {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
}

/* ---- 底部状态栏（左下连接状态 / 右下时间电量）---- */
.status-bar {
  flex: 0 0 auto;
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: 6px 14px 8px;
}

.status-left {
  display: flex;
  flex-direction: row;
  align-items: center;
}

.status-right {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 8px;
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

.status-power {
  color: rgba(64, 255, 94, 0.48);
  font-size: 12px;
}

.status-time {
  color: #40FF5E;
  font-size: 14px;
  font-weight: bold;
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
</style>

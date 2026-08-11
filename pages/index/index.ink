<script type="application/json" def>
{
  "navigationBarTitleText": "通知中心"
}
</script>

<script setup>
// 通知卡片页：轮询 localStorage 读取 app.js 写入的当前通知
// monochrome-green 设计系统：优先级亮度分级，硬件键关闭

const KEY_CURRENT = 'ntf_current'
const KEY_CONNECTED = 'ntf_connected'

function readNtf() {
  const raw = localStorage.getItem(KEY_CURRENT)
  if (!raw) return null
  try {
    return JSON.parse(raw)
  } catch (e) {
    return null
  }
}

export default {
  data: {
    ntf: null,
    connected: false,
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
    const ntf = readNtf()
    const connected = localStorage.getItem(KEY_CONNECTED) === 'true'
    const sameNtf = this.data.ntf && ntf && this.data.ntf.id === ntf.id
    if (sameNtf && this.data.connected === connected) return
    this.setData({ ntf, connected })
  },

  // 关闭当前通知（硬件键：镜腿单击=Enter/GlobalHook，双击=Backspace）
  onKeyUp(event) {
    if (event.code === 'GlobalHook' || event.code === 'Enter' || event.code === 'Backspace' || event.code === 'Escape') {
      // 必须 preventDefault——否则 Backspace 会触发系统「返回上一页」导致 agent 退出
      event.preventDefault()
      localStorage.removeItem(KEY_CURRENT)
      this.setData({ ntf: null })
    }
  },
}
</script>

<page>
  <!-- 连接状态角标 -->
  <view class="status-bar">
    <view class="status-dot {{ connected ? 'on' : 'off' }}"></view>
    <text class="status-text">{{ connected ? '已连接' : '重连中' }}</text>
  </view>

  <!-- 通知卡片 -->
  <view class="ntf-card priority-{{ ntf.priority }}" ink:if="{{ ntf }}">
    <view class="ntf-header">
      <text class="ntf-type">{{ ntf.type }}</text>
      <text class="ntf-close-hint">按返回键关闭</text>
    </view>
    <text class="ntf-title">{{ ntf.title }}</text>
    <text class="ntf-body">{{ ntf.body }}</text>
  </view>

  <!-- 空态 -->
  <view class="empty" ink:else>
    <text class="empty-icon">●</text>
    <text class="empty-text">暂无通知</text>
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

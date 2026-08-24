<script setup lang="ts">
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import ModalSheet from "../components/ModalSheet.vue";
import { partitionName, useStore } from "../store";

const store = useStore();
const confirmation = ref<"stop" | "restart" | "uninstall" | null>(null);

const serviceBusy = computed(() => Object.keys(store.busy).some((key) => key.startsWith("service-")));
const serviceLabel = computed(() => {
  const service = store.snapshot?.service;
  if (!service?.installed) return "未安装";
  if (service.running && store.snapshot?.daemon) return "运行中";
  if (service.running) return "启动中";
  if (!service.enabled) return "已停止";
  return "异常";
});

function requestServiceAction(action: "install" | "start" | "stop" | "restart" | "uninstall") {
  if ((action === "stop" || action === "restart") && store.activeSessions.length > 0) {
    confirmation.value = action;
    return;
  }
  if (action === "uninstall") {
    confirmation.value = action;
    return;
  }
  void executeServiceAction(action);
}

async function executeServiceAction(action: "install" | "start" | "stop" | "restart" | "uninstall") {
  confirmation.value = null;
  try {
    await store.serviceAction(action);
  } catch {
    // Store has already surfaced the structured error.
  }
}
</script>

<template>
  <div class="view settings-view">
    <header class="view-title"><div><h1>设置</h1><p>管理后台服务、系统权限与运行环境。</p></div></header>

    <div class="settings-grid">
      <section class="settings-card service-card wide">
        <div class="card-heading">
          <span class="settings-icon"><AppIcon name="shield" /></span>
          <div><h2>后台服务</h2><p>GUI 退出不会停止服务；停止状态在 Mac 重启后仍会保持。</p></div>
          <span class="badge" :class="store.snapshot?.service.running ? 'success' : 'neutral'">{{ serviceLabel }}</span>
        </div>

        <div class="metric-row">
          <div><span>版本</span><strong>v{{ store.snapshot?.daemon?.version ?? "0.4.0" }}</strong></div>
          <div><span>活动会话</span><strong>{{ store.snapshot?.daemon?.mounted_sessions ?? store.activeSessions.length }}</strong></div>
          <div><span>凭据</span><strong>{{ store.snapshot?.daemon?.keystore_entries ?? store.snapshot?.credentials.length ?? 0 }}</strong></div>
          <div><span>运行时间</span><strong>{{ store.snapshot?.daemon ? `${Math.floor(store.snapshot.daemon.uptime_s / 60)} 分钟` : "—" }}</strong></div>
        </div>

        <div class="service-actions">
          <button v-if="!store.snapshot?.service.installed" class="button primary" :disabled="serviceBusy" @click="requestServiceAction('install')">安装后台服务</button>
          <button v-if="store.snapshot?.service.installed && !store.snapshot.service.running" class="button primary" :disabled="serviceBusy" @click="requestServiceAction('start')">启动服务</button>
          <button v-if="store.snapshot?.service.running" class="button secondary" :disabled="serviceBusy" @click="requestServiceAction('stop')">安全停止</button>
          <button v-if="store.snapshot?.service.running" class="button secondary" :disabled="serviceBusy" @click="requestServiceAction('restart')">重新启动</button>
        </div>
        <p class="service-note">服务操作将请求 macOS 管理员授权。安全停止会先正常卸载全部加密卷，任一卷卸载失败都会取消停止。</p>
      </section>

      <section class="settings-card">
        <div class="card-heading">
          <span class="settings-icon"><AppIcon name="devices" /></span>
          <div><h2>macFUSE</h2><p>加密卷文件系统桥接</p></div>
          <span class="badge" :class="store.snapshot?.macfuse.installed ? 'success' : 'warning'">{{ store.snapshot?.macfuse.installed ? "已安装" : "未安装" }}</span>
        </div>
        <div class="setting-value">{{ store.snapshot?.macfuse.version ? `版本 ${store.snapshot.macfuse.version}` : "未检测到可用版本" }}</div>
        <p v-if="!store.snapshot?.macfuse.installed" class="muted">请从 macFUSE 官方安装程序完成安装，并在“隐私与安全性”中允许系统扩展。</p>
      </section>

      <section class="settings-card">
        <div class="card-heading">
          <span class="settings-icon"><AppIcon name="lock" /></span>
          <div><h2>磁盘权限</h2><p>读取外置磁盘原始设备</p></div>
          <span class="badge" :class="store.snapshot?.daemon?.disk_access_ok ? 'success' : 'warning'">{{ store.snapshot?.daemon?.disk_access_ok ? "正常" : "需要检查" }}</span>
        </div>
        <p v-if="store.snapshot?.daemon?.disk_access_ok" class="setting-value">后台服务能够读取受支持的 EDP 磁盘。</p>
        <div v-else class="permission-help">
          <p>在“系统设置 → 隐私与安全性 → 完整磁盘访问权限”中添加：</p>
          <code>/usr/local/libexec/usbcore</code>
          <p>授权后返回此页重新启动服务。</p>
        </div>
      </section>

      <section class="settings-card wide about-card">
        <div class="card-heading">
          <span class="settings-icon"><AppIcon name="info" /></span>
          <div><h2>EDP USB Vault</h2><p>简体中文 · Tauri + Vue · 客户端版本 0.4.0</p></div>
        </div>
        <p>自动挂载总开关仅位于窗口顶部；每台设备的授权与分区选择在“设备”页面管理。</p>
      </section>

      <section v-if="store.snapshot?.service.installed" class="settings-card wide danger-zone">
        <div><h2>危险操作</h2><p>卸载后台服务不会删除设备策略、配置或密码库。</p></div>
        <button class="button danger" :disabled="serviceBusy" @click="requestServiceAction('uninstall')">卸载后台服务</button>
      </section>
    </div>

    <ModalSheet
      v-if="confirmation === 'stop' || confirmation === 'restart'"
      :title="confirmation === 'stop' ? '安全停止后台服务？' : '重新启动后台服务？'"
      description="以下加密卷将先被正常卸载。卸载失败时服务会保持运行。"
      @close="confirmation = null"
    >
      <div class="volume-confirm-list">
        <div v-for="session in store.activeSessions" :key="session.session_id">
          <span class="partition-icon"><AppIcon :name="session.partition.partition_type === 2 ? 'activity' : 'lock'" /></span>
          <div><strong>{{ partitionName(session.partition.partition_type) }}</strong><span>{{ session.mountpoints[0] || "挂载点建立中" }}</span></div>
        </div>
      </div>
      <template #footer>
        <button class="button secondary" @click="confirmation = null">取消</button>
        <button class="button primary" @click="executeServiceAction(confirmation)">{{ confirmation === "stop" ? "卸载并停止" : "卸载并重启" }}</button>
      </template>
    </ModalSheet>

    <ModalSheet v-if="confirmation === 'uninstall'" title="卸载后台服务？" description="服务二进制和 launchd 项目会被移除，现有配置与密码库默认保留。" @close="confirmation = null">
      <p>卸载后，设备识别、自动挂载和手动挂载都会停止，直到再次安装服务。</p>
      <template #footer>
        <button class="button secondary" @click="confirmation = null">取消</button>
        <button class="button danger" @click="executeServiceAction('uninstall')">保留数据并卸载</button>
      </template>
    </ModalSheet>
  </div>
</template>

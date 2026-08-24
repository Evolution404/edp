<script setup lang="ts">
import { computed, ref } from "vue";
import { api } from "../api";
import AppIcon from "../components/AppIcon.vue";
import ModalSheet from "../components/ModalSheet.vue";
import { partitionName, useStore } from "../store";

const store = useStore();
const confirmation = ref<"stop" | "restart" | "uninstall" | null>(null);

const serviceBusy = computed(() => Object.keys(store.busy).some((key) => key.startsWith("service-")));
const serviceLabel = computed(() => {
  const service = store.snapshot?.service;
  if (service?.requires_approval) return "等待系统批准";
  if (service?.legacy_installed) return "需要迁移";
  if (!service?.installed) return "未启用";
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
          <div><h2>嵌入式后台服务</h2><p>服务随应用提供，不会向 /usr/local 或 LaunchDaemons 复制文件。</p></div>
          <span class="badge" :class="store.snapshot?.service.running ? 'success' : 'neutral'">{{ serviceLabel }}</span>
        </div>

        <div class="metric-row">
          <div><span>版本</span><strong>v{{ store.snapshot?.daemon?.version ?? "0.4.1" }}</strong></div>
          <div><span>活动会话</span><strong>{{ store.snapshot?.daemon?.mounted_sessions ?? store.activeSessions.length }}</strong></div>
          <div><span>凭据</span><strong>{{ store.snapshot?.daemon?.keystore_entries ?? store.snapshot?.credentials.length ?? 0 }}</strong></div>
          <div><span>运行时间</span><strong>{{ store.snapshot?.daemon ? `${Math.floor(store.snapshot.daemon.uptime_s / 60)} 分钟` : "—" }}</strong></div>
        </div>

        <div class="service-actions">
          <button v-if="!store.snapshot?.service.installed" class="button primary" :disabled="serviceBusy" @click="requestServiceAction('install')">启用后台服务</button>
          <button v-if="store.snapshot?.service.requires_approval" class="button primary" :disabled="serviceBusy" @click="api.openLoginItemsSettings()">打开后台项目设置</button>
          <button v-else-if="store.snapshot?.service.installed && !store.snapshot.service.running" class="button primary" :disabled="serviceBusy" @click="requestServiceAction('start')">启动服务</button>
          <button v-if="store.snapshot?.service.running" class="button secondary" :disabled="serviceBusy" @click="requestServiceAction('stop')">安全停止</button>
          <button v-if="store.snapshot?.service.running" class="button secondary" :disabled="serviceBusy" @click="requestServiceAction('restart')">重新启动</button>
        </div>
        <p class="service-note">首次启用需要在 macOS“登录项与扩展”中批准。安全停止会先正常卸载全部加密卷，任一卷失败都会取消停止。</p>
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
          <code>/Applications/EDP USB Vault.app</code>
          <p>授权后返回此页重新启动服务。</p>
        </div>
      </section>

      <section class="settings-card wide about-card">
        <div class="card-heading">
          <span class="settings-icon"><AppIcon name="info" /></span>
          <div><h2>EDP USB Vault</h2><p>简体中文 · Tauri + Vue · 客户端版本 0.4.1</p></div>
        </div>
        <p>紧急暂停开关仅位于窗口顶部；每台设备只需在“设备”页面选择交换区或保密区。</p>
      </section>

      <section v-if="store.snapshot?.service.installed || store.snapshot?.service.legacy_installed" class="settings-card wide danger-zone">
        <div><h2>清除应用数据</h2><p>安全卸载所有会话、注销后台服务，并永久删除设备策略、配置和密码库。</p></div>
        <button class="button danger" :disabled="serviceBusy" @click="requestServiceAction('uninstall')">完全清理</button>
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

    <ModalSheet v-if="confirmation === 'uninstall'" title="完全清理 EDP USB Vault？" description="所有加密卷会先安全卸载，后台服务会被注销，配置、分区设置和密码库会永久删除。" @close="confirmation = null">
      <p>此操作不可撤销。应用包仍会保留，可稍后重新启用并从空白状态开始。</p>
      <template #footer>
        <button class="button secondary" @click="confirmation = null">取消</button>
        <button class="button danger" @click="executeServiceAction('uninstall')">清除全部数据</button>
      </template>
    </ModalSheet>
  </div>
</template>

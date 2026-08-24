<script setup lang="ts">
import { computed, onMounted, onUnmounted } from "vue";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { useStore } from "./store";
import type { AppSnapshot, OperationEvent, RawDaemonEvent } from "./types";
import AppIcon from "./components/AppIcon.vue";
import ToggleSwitch from "./components/ToggleSwitch.vue";

const store = useStore();
const unlisteners: UnlistenFn[] = [];

const serviceTone = computed(() => {
  if (store.snapshot?.service.running) return "success";
  if (store.snapshot?.service.installed) return "warning";
  return "danger";
});

const serviceText = computed(() => {
  if (!store.initialized) return "正在连接";
  if (store.snapshot?.service.running && store.snapshot.daemon) return "后台服务运行中";
  if (store.snapshot?.service.requires_approval) return "后台服务等待系统批准";
  if (store.snapshot?.service.legacy_installed) return "旧后台服务需要清理";
  if (store.snapshot?.service.installed && store.snapshot.service.enabled) return "后台服务异常";
  if (store.snapshot?.service.installed) return "后台服务已停止";
  return "后台服务未启用";
});

onMounted(async () => {
  unlisteners.push(
    await listen<AppSnapshot>("ui://snapshot", (event) => store.applySnapshot(event.payload)),
    await listen<OperationEvent>("ui://operation", (event) => store.setOperation(event.payload)),
    await listen<RawDaemonEvent>("edp://event", (event) => store.recordEvent(event.payload)),
  );
  await store.initialize();
});

onUnmounted(() => unlisteners.forEach((unlisten) => unlisten()));
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand-block">
        <span class="brand-symbol"><AppIcon name="lock" :size="19" /></span>
        <div><strong>EDP USB Vault</strong><span>安全磁盘客户端</span></div>
      </div>

      <nav class="sidebar-nav" aria-label="主导航">
        <RouterLink to="/devices"><AppIcon name="devices" /><span>设备</span></RouterLink>
        <RouterLink to="/activity"><AppIcon name="activity" /><span>活动</span></RouterLink>
        <RouterLink to="/settings"><AppIcon name="settings" /><span>设置</span></RouterLink>
      </nav>

      <div class="sidebar-status">
        <span class="status-dot" :class="serviceTone"></span>
        <div><strong>{{ serviceText }}</strong><span>v{{ store.snapshot?.daemon?.version ?? "0.4.0" }}</span></div>
      </div>
    </aside>

    <section class="workspace">
      <header class="toolbar">
        <div class="toolbar-service">
          <span class="status-dot" :class="serviceTone"></span>
          <span>{{ serviceText }}</span>
        </div>
        <ToggleSwitch
          class="toolbar-toggle"
          :model-value="store.snapshot?.auto_mount_mode === 'active'"
          :disabled="!store.daemonOnline || !!store.busy['auto-mode']"
          :label="store.snapshot?.auto_mount_mode === 'active' ? '自动挂载运行中' : '自动挂载已暂停'"
          @update:model-value="store.setAutoMount"
        />
      </header>

      <div v-if="store.operation && !['succeeded', 'cancelled'].includes(store.operation.phase)" class="operation-banner" :class="store.operation.phase">
        <span class="spinner" v-if="!['failed'].includes(store.operation.phase)"></span>
        <span class="status-dot danger" v-else></span>
        <div><strong>{{ store.operation.message }}</strong><span v-if="store.operation.error?.detail">{{ store.operation.error.detail }}</span></div>
      </div>

      <main class="workspace-content">
        <div v-if="!store.initialized" class="loading-shell">
          <span class="spinner large"></span><p>正在读取设备状态…</p>
        </div>
        <RouterView v-else />
      </main>
    </section>

    <div class="toast-stack" aria-live="polite">
      <button
        v-for="toast in store.toasts"
        :key="toast.id"
        class="toast"
        :class="toast.tone"
        @click="store.dismissToast(toast.id)"
      >
        <strong>{{ toast.title }}</strong><span v-if="toast.detail">{{ toast.detail }}</span>
      </button>
    </div>
  </div>
</template>

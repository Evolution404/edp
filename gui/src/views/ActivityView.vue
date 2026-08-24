<script setup lang="ts">
import { ref } from "vue";
import { api } from "../api";
import AppIcon from "../components/AppIcon.vue";
import { partitionName, useStore } from "../store";
import type { DiagnosticsResult } from "../types";

const store = useStore();
const diagnostics = ref<DiagnosticsResult | null>(null);
const diagnosticsBusy = ref(false);

async function loadDiagnostics() {
  diagnosticsBusy.value = true;
  try {
    diagnostics.value = await api.diagnostics();
  } catch (error) {
    store.showError(error, "无法读取诊断信息");
  } finally {
    diagnosticsBusy.value = false;
  }
}

function unmount(sessionId: string) {
  const session = store.activeSessions.find((item) => item.session_id === sessionId);
  if (session) void store.unmount(session).catch(() => undefined);
}
</script>

<template>
  <div class="view activity-view">
    <header class="view-title"><div><h1>活动</h1><p>查看当前挂载卷与最近发生的设备事件。</p></div></header>

    <section class="section-block">
      <div class="section-heading"><h2>已挂载卷</h2><span>{{ store.activeSessions.length }}</span></div>
      <div v-if="store.activeSessions.length" class="activity-grid">
        <article v-for="session in store.activeSessions" :key="session.session_id" class="session-card">
          <div class="session-symbol"><AppIcon :name="session.partition.partition_type === 2 ? 'activity' : 'lock'" /></div>
          <div class="session-main">
            <span class="badge success">已挂载</span>
            <h3>{{ partitionName(session.partition.partition_type) }}</h3>
            <p>{{ session.mountpoints[0] || "挂载点建立中" }}</p>
          </div>
          <div class="session-actions">
            <button class="button secondary" :disabled="!session.mountpoints[0] || !!store.busy[`finder-${session.mountpoints[0]}`]" @click="store.openFinder(session.mountpoints[0]).catch(() => undefined)"><AppIcon name="folder" />Finder</button>
            <button class="button secondary" :disabled="!!store.busy[`unmount-${session.session_id}`]" @click="unmount(session.session_id)"><span v-if="store.busy[`unmount-${session.session_id}`]" class="spinner"></span><AppIcon v-else name="eject" />{{ store.busy[`unmount-${session.session_id}`] ? "正在卸载…" : "正常卸载" }}</button>
          </div>
        </article>
      </div>
      <div v-else class="empty-state compact"><AppIcon name="activity" :size="28" /><h3>当前没有挂载中的加密卷</h3><p>完成挂载后会在这里显示。</p></div>
    </section>

    <section class="section-block">
      <div class="section-heading"><h2>最近活动</h2><span>{{ store.activity.length }}</span></div>
      <div v-if="store.activity.length" class="timeline">
        <article v-for="item in store.activity" :key="item.id" class="timeline-item">
          <span class="status-dot" :class="item.tone"></span>
          <time>{{ item.time }}</time>
          <div><strong>{{ item.title }}</strong><span v-if="item.detail">{{ item.detail }}</span></div>
        </article>
      </div>
      <div v-else class="empty-state compact"><p>本次启动后还没有新的设备事件。</p></div>
    </section>

    <details class="diagnostic-box" @toggle="($event.currentTarget as HTMLDetailsElement).open && !diagnostics && loadDiagnostics()">
      <summary>诊断详情</summary>
      <p>这里包含 session_id、原始路径和 daemon 日志，供故障排查使用。</p>
      <div v-if="diagnosticsBusy" class="inline-loading"><span class="spinner"></span>正在读取…</div>
      <template v-else-if="diagnostics">
        <div class="diagnostic-session" v-for="session in diagnostics.snapshot.sessions" :key="session.session_id">
          <strong>{{ partitionName(session.partition.partition_type) }}</strong>
          <code>session_id: {{ session.session_id }}</code>
          <code>source: {{ session.source }}</code>
          <code v-for="path in session.mountpoints" :key="path">mountpoint: {{ path }}</code>
        </div>
        <div v-for="log in diagnostics.logs" :key="log.file" class="log-section">
          <h3>{{ log.file }}</h3><pre>{{ log.lines.join("\n") }}</pre>
        </div>
      </template>
    </details>
  </div>
</template>

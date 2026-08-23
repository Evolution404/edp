<script setup lang="ts">
import { onMounted, onUnmounted } from "vue";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { useStore } from "./store";

const store = useStore();
let unlisten: UnlistenFn | undefined;
let timer: number | undefined;

onMounted(async () => {
  await store.refreshAll();
  timer = window.setInterval(() => void store.refreshAll(), 5000);
  unlisten = await listen<any>("edp://event", (e) => store.pushEvent(e.payload));
});
onUnmounted(() => {
  if (timer) window.clearInterval(timer);
  unlisten?.();
});
</script>

<template>
  <div class="app">
    <header class="app-header">
      <div class="brand">
        <span class="brand-dot">🔒</span>
        <span>EDP 加密 U 盘</span>
      </div>
      <div class="daemon-badge" :class="store.daemonOnline ? 'ok' : 'off'">
        {{
          store.daemonOnline
            ? `daemon 在线 · v${store.status?.version ?? ""}`
            : "daemon 离线"
        }}
      </div>
    </header>

    <nav class="tabs">
      <RouterLink to="/sessions">挂载</RouterLink>
      <RouterLink to="/keys">密码库</RouterLink>
      <RouterLink to="/settings">设置</RouterLink>
      <RouterLink to="/logs">日志</RouterLink>
    </nav>

    <main class="content">
      <RouterView />
    </main>
  </div>
</template>

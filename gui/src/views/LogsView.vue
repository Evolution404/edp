<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api } from "../api";
import { useStore } from "../store";

const store = useStore();
const daemonLogs = ref<any[]>([]);
const err = ref("");

async function loadLogs() {
  if (!store.daemonOnline) {
    daemonLogs.value = [];
    return;
  }
  try {
    daemonLogs.value = (await api.logsRead(200)).logs ?? [];
  } catch (e) {
    err.value = String(e);
  }
}
onMounted(loadLogs);
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>日志</h2>
      <button @click="loadLogs()">刷新</button>
    </div>

    <section class="card">
      <h3>实时事件</h3>
      <div class="logbox">
        <div v-if="store.eventLog.length === 0" class="empty">暂无事件</div>
        <pre v-for="(e, i) in store.eventLog" :key="i" class="line">
{{ e.time }}  {{ e.event }}  {{ JSON.stringify(e.data) }}</pre
        >
      </div>
    </section>

    <section class="card">
      <h3>daemon 日志</h3>
      <div v-if="!store.daemonOnline" class="hint">
        daemon 离线，无日志。启动后（launchd 重定向到 /var/db/edp-usbcore/logs/）可查看。
      </div>
      <div v-else class="logbox">
        <div v-if="daemonLogs.length === 0" class="empty">暂无日志文件</div>
        <template v-for="l in daemonLogs" :key="l.file">
          <h4 class="file">{{ l.file }}</h4>
          <pre class="line">{{ l.lines.join("\n") }}</pre>
        </template>
      </div>
    </section>

    <p v-if="err" class="err">{{ err }}</p>
  </div>
</template>

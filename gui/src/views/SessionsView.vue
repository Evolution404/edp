<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api } from "../api";
import { useStore } from "../store";

const store = useStore();
const busy = ref(false);
const err = ref("");

onMounted(() => store.refreshSessions());

async function doUnmount(sid: string, force = false) {
  err.value = "";
  busy.value = true;
  try {
    await api.unmount(sid, force);
    await store.refreshSessions();
  } catch (e) {
    err.value = String(e);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>挂载中的卷</h2>
      <button @click="store.refreshSessions()" :disabled="busy">刷新</button>
    </div>

    <p v-if="!store.daemonOnline" class="hint">
      daemon 离线——插入的 EDP 盘不会被自动挂载。请到「设置」安装并启动 daemon。
    </p>

    <table v-else class="tbl">
      <thead>
        <tr>
          <th>会话</th>
          <th>挂载点</th>
          <th>来源</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="s in store.sessions" :key="s.session_id">
          <td class="mono">{{ s.session_id }}</td>
          <td>
            <a @click="api.openInFinder(s.mountpoints?.[0])" class="link">{{ s.mountpoints?.[0] }}</a>
          </td>
          <td class="mono">{{ s.source ?? "—" }}</td>
          <td class="row">
            <button @click="api.openInFinder(s.mountpoints?.[0])">Finder</button>
            <button class="danger" @click="doUnmount(s.session_id)" :disabled="busy">卸载</button>
            <button class="ghost" @click="doUnmount(s.session_id, true)" :disabled="busy">
              强制卸载
            </button>
          </td>
        </tr>
        <tr v-if="store.sessions.length === 0">
          <td colspan="4" class="empty">当前没有已挂载的卷</td>
        </tr>
      </tbody>
    </table>
    <p v-if="err" class="err">{{ err }}</p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from "vue";
import { api } from "../api";
import { useStore } from "../store";

const store = useStore();
const busy = ref(false);
const err = ref("");
const ok = ref("");

const autoMount = computed({
  get: () => !!store.config?.auto_mount_enabled,
  set: async (v: boolean) => {
    err.value = "";
    try {
      await api.configSet({ auto_mount_enabled: v });
      await store.refreshAll();
    } catch (e) {
      err.value = String(e);
    }
  },
});

const types = computed({
  get: () => (store.config?.default_partition_types as number[]) ?? [4],
  set: (v: number[]) => {
    void (async () => {
      try {
        await api.configSet({ default_partition_types: v });
        await store.refreshAll();
      } catch (e) {
        err.value = String(e);
      }
    })();
  },
});

function toggleType(t: number) {
  const cur = new Set(types.value);
  if (cur.has(t)) cur.delete(t);
  else cur.add(t);
  types.value = [...cur].sort();
}

async function runInstall() {
  err.value = "";
  ok.value = "";
  busy.value = true;
  try {
    const r = await api.installDaemon();
    ok.value = `daemon 已安装（${r.bin}）`;
    setTimeout(() => void store.refreshAll(), 1500);
  } catch (e) {
    err.value = String(e);
  } finally {
    busy.value = false;
  }
}

async function runUninstall() {
  err.value = "";
  ok.value = "";
  busy.value = true;
  try {
    await api.uninstallDaemon();
    ok.value = "daemon 已卸载";
    setTimeout(() => void store.refreshAll(), 1500);
  } catch (e) {
    err.value = String(e);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="page">
    <h2>设置</h2>

    <section class="card">
      <h3>守护进程（daemon）</h3>
      <p class="row">
        <span class="dot" :class="store.daemonOnline ? 'ok' : 'off'"></span>
        {{ store.daemonOnline ? "运行中" : "未运行" }}
        <template v-if="store.daemonOnline">
          · v{{ store.status?.version }} · 已挂载 {{ store.status?.mounted_sessions }} 会话 ·
          密码库 {{ store.status?.keystore_entries }} 条
        </template>
      </p>
      <p class="hint">
        daemon 常驻后台：监听 U 盘插入 → 匹配密码库 → 自动挂载。GUI 退出不影响它。
      </p>
      <div class="row">
        <button @click="runInstall" :disabled="busy">安装 / 启动 daemon</button>
        <button class="ghost danger" @click="runUninstall" :disabled="busy">卸载 daemon</button>
      </div>
      <p class="hint">安装会弹出系统授权（管理员密码），并把二进制装入 /usr/local/libexec。</p>
      <div v-if="store.daemonOnline && store.status && store.status.disk_access_ok === false" class="warn">
        ⚠️ daemon 无法访问磁盘（macOS 15 权限）：请到
        系统设置 → 隐私与安全性 → <b>完整磁盘访问权限</b> → 添加
        <span class="mono">/usr/local/libexec/usbcore</span>，然后重启 daemon。
        不授予则插入 U 盘不会自动挂载。
      </div>
    </section>

    <section class="card">
      <h3>自动挂载</h3>
      <label class="chk">
        <input type="checkbox" :checked="autoMount" @change="autoMount = ($event.target as HTMLInputElement).checked" />
        插入 EDP 盘时自动挂载（有匹配密码时）
      </label>
      <div class="row">
        <span>自动挂载的分区类型：</span>
        <label class="chk"><input type="checkbox" :checked="types.includes(2)" @change="toggleType(2)" /> 2 · 交换区</label>
        <label class="chk"><input type="checkbox" :checked="types.includes(4)" @change="toggleType(4)" /> 4 · 保密区</label>
      </div>
    </section>

    <section class="card">
      <h3>macFUSE</h3>
      <p v-if="store.macfuse?.installed" class="ok">
        已安装 · v{{ store.macfuse?.version ?? "?" }}
      </p>
      <p v-else class="hint">
        未安装。EDP 数据分区需经 macFUSE 桥接后才能挂载，请先安装：
      </p>
      <ol v-if="!store.macfuse?.installed" class="steps">
        <li>下载安装 macFUSE（https://macfuse.github.io）</li>
        <li>系统提示“系统扩展被阻止”时：系统设置 → 隐私与安全性 → 允许</li>
        <li>若需降低安全策略：按住电源键进入恢复模式 → 实用工具 → 启动安全性实用工具 → 降低安全性</li>
      </ol>
    </section>

    <p v-if="err" class="err">{{ err }}</p>
    <p v-if="ok" class="ok">{{ ok }}</p>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api } from "../api";
import { useStore } from "../store";

const store = useStore();
const showAdd = ref(false);
const disks = ref<any[]>([]);
const confirmId = ref("");
const msg = ref("");
const err = ref("");
const busy = ref(false);

const form = ref({
  label: "我的 EDP 盘",
  disk: "",
  device_id: "",
  partition_type: 4,
  password: "",
  auto_mount: true,
});

async function loadDisks() {
  try {
    disks.value = await api.listDisks();
  } catch {
    disks.value = [];
  }
}
onMounted(loadDisks);

function resetForm() {
  form.value = { label: "我的 EDP 盘", disk: "", device_id: "", partition_type: 4, password: "", auto_mount: true };
  err.value = "";
  msg.value = "";
}

async function doAdd() {
  err.value = "";
  msg.value = "";
  if (!form.value.password) {
    err.value = "请填写密码";
    return;
  }
  if (!form.value.device_id && !form.value.disk) {
    err.value = "请选择插入的磁盘，或填写 device_id";
    return;
  }
  busy.value = true;
  try {
    const params: Record<string, unknown> = {
      label: form.value.label,
      partition_type: form.value.partition_type,
      password: form.value.password,
      auto_mount: form.value.auto_mount,
    };
    if (form.value.device_id) params.device_id = form.value.device_id;
    else params.disk = form.value.disk;
    const r = await api.keysAdd(params);
    msg.value = `已入库（id ${r.id}）`;
    showAdd.value = false;
    resetForm();
    await store.refreshKeys();
  } catch (e) {
    err.value = String(e);
  } finally {
    busy.value = false;
  }
}

async function doDel(id: string) {
  err.value = "";
  try {
    await api.keysRm(id);
    confirmId.value = "";
    await store.refreshKeys();
  } catch (e) {
    err.value = String(e);
  }
}

async function toggleAuto(rec: any) {
  try {
    await api.keysUpdate(rec.id, { auto_mount: !rec.auto_mount });
    await store.refreshKeys();
  } catch (e) {
    err.value = String(e);
  }
}
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>密码库</h2>
      <button @click="showAdd = true; resetForm()" :disabled="!store.daemonOnline">
        ＋ 添加密码
      </button>
    </div>

    <p v-if="!store.daemonOnline" class="hint">
      daemon 离线——密码库由 daemon 加密保管，请先在「设置」安装并启动 daemon。
    </p>

    <table v-else class="tbl">
      <thead>
        <tr>
          <th>标签</th>
          <th>device_id</th>
          <th>分区</th>
          <th>密码（脱敏）</th>
          <th>自动挂载</th>
          <th>最近使用</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="k in store.keys" :key="k.id">
          <td>{{ k.label }}</td>
          <td class="mono">{{ k.device_id }}</td>
          <td>{{ k.partition_type }}</td>
          <td class="mono">{{ k.password_hint }} · {{ k.password_crc }}</td>
          <td>
            <input type="checkbox" :checked="k.auto_mount" @change="toggleAuto(k)" />
          </td>
          <td>{{ k.last_used_at ?? "—" }}</td>
          <td>
            <button v-if="confirmId !== k.id" class="danger" @click="confirmId = k.id">删除</button>
            <span v-else class="row">
              <button class="danger" @click="doDel(k.id)">确认</button>
              <button class="ghost" @click="confirmId = ''">取消</button>
            </span>
          </td>
        </tr>
        <tr v-if="store.keys.length === 0">
          <td colspan="7" class="empty">暂无密码</td>
        </tr>
      </tbody>
    </table>

    <div v-if="showAdd" class="modal">
      <div class="modal-card">
        <h3>添加密码</h3>
        <label>标签<input v-model="form.label" /></label>
        <label>插入的磁盘
          <select v-model="form.disk">
            <option value="">— 手动指定 device_id —</option>
            <option v-for="d in disks" :key="d.bsd" :value="d.rbsd">
              {{ d.bsd }} · {{ d.media_name }}（{{ (d.size / 1e9).toFixed(0) }}GB）
            </option>
          </select>
        </label>
        <label>device_id（选盘后自动解析；也可手填）
          <input v-model="form.device_id" class="mono" placeholder="disk&ven_lexar&prod_usb_flash_drive" />
        </label>
        <label>分区类型
          <select v-model.number="form.partition_type">
            <option :value="4">4 · 保密区</option>
            <option :value="2">2 · 交换区</option>
          </select>
        </label>
        <label>密码<input v-model="form.password" type="password" /></label>
        <label class="chk">
          <input v-model="form.auto_mount" type="checkbox" /> 插入后自动挂载
        </label>
        <p v-if="err" class="err">{{ err }}</p>
        <div class="row">
          <button @click="doAdd" :disabled="busy">保存</button>
          <button class="ghost" @click="showAdd = false; err = ''">取消</button>
        </div>
      </div>
    </div>

    <p v-if="msg && !showAdd" class="ok">{{ msg }}</p>
  </div>
</template>

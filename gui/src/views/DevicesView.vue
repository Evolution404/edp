<script setup lang="ts">
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import ModalSheet from "../components/ModalSheet.vue";
import ToggleSwitch from "../components/ToggleSwitch.vue";
import { deviceKey, partitionName, useStore } from "../store";
import type { CredentialInfo, DeviceInfo, DevicePolicy, PartitionType } from "../types";

const store = useStore();
const credentialSheet = ref<PartitionType | null>(null);
const editingCredential = ref<CredentialInfo | null>(null);
const credentialLabel = ref("");
const credentialPassword = ref("");
const deleteTarget = ref<CredentialInfo | null>(null);

const device = computed(() => store.selectedDevice);
const autoPaused = computed(() => store.snapshot?.auto_mount_mode === "paused");

function policyFor(item: DeviceInfo): DevicePolicy {
  const partitionTypes = [...(item.policy?.partition_types ?? [])];
  return {
    device_id: item.device_id ?? "",
    label: item.policy?.label || item.media_name || "EDP 设备",
    authorized: partitionTypes.length > 0,
    partition_types: partitionTypes,
    last_media_name: item.media_name || item.policy?.last_media_name || null,
  };
}

function savePolicy(item: DeviceInfo, policy: DevicePolicy) {
  if (!item.device_id) return;
  void store.savePolicy(policy).catch(() => undefined);
}

function setPartitionSelected(item: DeviceInfo, type: PartitionType, selected: boolean) {
  const policy = policyFor(item);
  const types = new Set(policy.partition_types);
  if (selected) types.add(type);
  else types.delete(type);
  const partitionTypes = [...types].sort() as PartitionType[];
  savePolicy(item, {
    ...policy,
    authorized: partitionTypes.length > 0,
    partition_types: partitionTypes,
  });
}

function credentialsFor(item: DeviceInfo, type: PartitionType) {
  return store.snapshot?.credentials.filter(
    (credential) => credential.device_id === item.device_id && credential.partition_type === type,
  ) ?? [];
}

function sessionFor(item: DeviceInfo, type: PartitionType) {
  return store.activeSessions.find(
    (session) => session.device_id === item.device_id && session.partition.partition_type === type,
  );
}

function openCredentialSheet(type: PartitionType, credential?: CredentialInfo) {
  credentialSheet.value = type;
  editingCredential.value = credential ?? null;
  credentialLabel.value = credential?.label ?? `${partitionName(type)}密码`;
  credentialPassword.value = "";
}

function closeCredentialSheet() {
  credentialSheet.value = null;
  editingCredential.value = null;
  credentialPassword.value = "";
}

async function submitCredential() {
  const item = device.value;
  const type = credentialSheet.value;
  if (!item?.device_id || !item.rbsd || !type || !credentialPassword.value) return;
  try {
    await store.saveCredential({
      id: editingCredential.value?.id,
      label: credentialLabel.value.trim() || `${partitionName(type)}密码`,
      device_id: item.device_id,
      disk: item.rbsd,
      partition_type: type,
      password: credentialPassword.value,
    });
    closeCredentialSheet();
  } catch {
    // Store has already surfaced the structured error.
  }
}

async function confirmCredentialDelete() {
  if (!deleteTarget.value) return;
  try {
    await store.deleteCredential(deleteTarget.value.id);
    deleteTarget.value = null;
    closeCredentialSheet();
  } catch {
    // Store has already surfaced the structured error.
  }
}

function formatSize(bytes: number) {
  if (!bytes) return "容量未知";
  return `${(bytes / 1_000_000_000).toFixed(bytes >= 10_000_000_000 ? 0 : 1)} GB`;
}

function deviceState(item: DeviceInfo) {
  if (item.kind === "ordinary") return "未受管理";
  if (item.kind === "unknown") return "正在识别";
  if (!item.connected) return "已保存 · 离线";
  if (item.session_ids.length) return `已挂载 ${item.session_ids.length} 个分区`;
  if (!item.policy) return "待配置";
  const selected = item.policy.partition_types.length;
  return selected ? `已设置 ${selected} 个分区` : "未设置自动挂载";
}

function runMount(item: DeviceInfo, type: PartitionType) {
  void store.mount(item, type).catch(() => undefined);
}

function runUnmount(item: DeviceInfo, type: PartitionType) {
  const session = sessionFor(item, type);
  if (session) void store.unmount(session).catch(() => undefined);
}

function openFinder(item: DeviceInfo, type: PartitionType) {
  const path = sessionFor(item, type)?.mountpoints[0];
  if (path) void store.openFinder(path).catch(() => undefined);
}
</script>

<template>
  <div class="view devices-view">
    <header class="view-title">
      <div><h1>设备</h1><p>选择一台 EDP 设备，集中管理分区自动挂载、凭据与当前会话。</p></div>
      <button class="button icon-only" :disabled="!!store.busy.refresh" aria-label="刷新设备状态" @click="store.refresh">
        <AppIcon name="refresh" />
      </button>
    </header>

    <div v-if="!store.daemonOnline" class="notice warning">
      <AppIcon name="info" />
      <div><strong>后台服务未运行</strong><span>设备识别和挂载暂不可用，请前往“设置”启动服务。</span></div>
    </div>

    <section class="device-workbench">
      <aside class="device-list-pane" aria-label="设备列表">
        <div class="device-section">
          <h2>已连接 <span>{{ store.connectedManagedDevices.length }}</span></h2>
          <button
            v-for="item in store.connectedManagedDevices"
            :key="deviceKey(item)"
            class="device-row"
            :class="{ selected: deviceKey(item) === deviceKey(store.selectedDevice ?? item) }"
            @click="store.selectDevice(item)"
          >
            <span class="device-glyph"><AppIcon name="devices" /></span>
            <span><strong>{{ item.policy?.label || item.media_name }}</strong><small>{{ deviceState(item) }}</small></span>
            <span class="status-dot" :class="item.session_ids.length ? 'success' : 'neutral'"></span>
          </button>
          <p v-if="store.connectedManagedDevices.length === 0" class="list-empty">没有已连接的 EDP 设备</p>
        </div>

        <div class="device-section" v-if="store.offlineManagedDevices.length">
          <h2>已保存 <span>{{ store.offlineManagedDevices.length }}</span></h2>
          <button
            v-for="item in store.offlineManagedDevices"
            :key="deviceKey(item)"
            class="device-row"
            :class="{ selected: deviceKey(item) === store.selectedDeviceKey }"
            @click="store.selectDevice(item)"
          >
            <span class="device-glyph muted"><AppIcon name="devices" /></span>
            <span><strong>{{ item.policy?.label || item.media_name }}</strong><small>未连接</small></span>
          </button>
        </div>

        <div class="device-section ordinary-section" v-if="store.ordinaryDevices.length">
          <button class="ordinary-disclosure" @click="store.ordinaryExpanded = !store.ordinaryExpanded">
            <AppIcon name="chevron" :class="{ expanded: store.ordinaryExpanded }" />
            <span>未受管理设备</span><small>{{ store.ordinaryDevices.length }}</small>
          </button>
          <p>应用不会操作这些磁盘</p>
          <template v-if="store.ordinaryExpanded">
            <button
              v-for="item in store.ordinaryDevices"
              :key="deviceKey(item)"
              class="device-row"
              :class="{ selected: deviceKey(item) === store.selectedDeviceKey }"
              @click="store.selectDevice(item)"
            >
              <span class="device-glyph muted"><AppIcon name="devices" /></span>
              <span><strong>{{ item.media_name || item.bsd }}</strong><small>普通 U 盘</small></span>
            </button>
          </template>
        </div>
      </aside>

      <main class="device-detail-pane">
        <div v-if="!device" class="empty-state">
          <AppIcon name="devices" :size="34" /><h2>没有设备</h2><p>插入 EDP 设备后会显示在这里。</p>
        </div>

        <template v-else-if="device.kind === 'ordinary'">
          <header class="detail-header">
            <div><span class="badge neutral">未受管理</span><h1>{{ device.media_name || device.bsd }}</h1><p>{{ formatSize(device.size) }}</p></div>
          </header>
          <div class="safe-panel">
            <AppIcon name="shield" :size="28" />
            <div><h2>普通 U 盘，本应用不会操作</h2><p>不会卸载、重新挂载、尝试密码或修改 Finder 中的状态。</p></div>
          </div>
        </template>

        <template v-else-if="device.kind === 'unknown'">
          <div class="empty-state"><span class="spinner large"></span><h2>正在只读识别设备</h2><p>识别完成前不会卸载或挂载此磁盘。</p></div>
        </template>

        <template v-else>
          <header class="detail-header">
            <div>
              <span class="badge" :class="device.connected ? 'success' : 'neutral'">{{ deviceState(device) }}</span>
              <h1>{{ device.policy?.label || device.media_name || "EDP 设备" }}</h1>
              <p>{{ formatSize(device.size) }} · {{ device.connected ? "已连接" : "离线" }}</p>
              <code>{{ device.device_id }}</code>
            </div>
          </header>

          <div v-if="autoPaused" class="notice warning compact">
            <AppIcon name="info" /><div><strong>全局自动挂载已暂停</strong><span>下方分区选择保持不变，手动操作仍可使用。</span></div>
          </div>

          <section class="partition-list">
            <article v-for="type in ([2, 4] as PartitionType[])" :key="type" class="partition-row">
              <div class="partition-info">
                <span class="partition-icon"><AppIcon :name="type === 2 ? 'activity' : 'lock'" /></span>
                <div>
                  <h2>{{ partitionName(type) }}</h2>
                  <p>{{ type === 2 ? "用于受控交换的加密分区" : "用于保密资料的加密分区" }}</p>
                  <div class="partition-badges">
                    <span class="badge" :class="credentialsFor(device, type).length ? 'success' : 'warning'">
                      {{ credentialsFor(device, type).length ? "凭据已验证" : "未设置凭据" }}
                    </span>
                    <span class="badge" :class="sessionFor(device, type) ? 'success' : 'neutral'">
                      {{ sessionFor(device, type) ? "已挂载" : "未挂载" }}
                    </span>
                  </div>
                </div>
              </div>

              <div class="partition-controls-row">
                <ToggleSwitch
                  :model-value="device.policy?.partition_types.includes(type) ?? false"
                  :disabled="!device.device_id || !!store.busy[`policy-${device.device_id}`]"
                  :label="`自动挂载${partitionName(type)}`"
                  @update:model-value="setPartitionSelected(device, type, $event)"
                />
                <div class="partition-actions">
                  <template v-if="sessionFor(device, type)">
                    <button class="button secondary" :disabled="!!store.busy[`finder-${sessionFor(device, type)?.mountpoints[0]}`]" @click="openFinder(device, type)"><AppIcon name="folder" />Finder</button>
                    <button class="button secondary" :disabled="!!store.busy[`unmount-${sessionFor(device, type)?.session_id}`]" @click="runUnmount(device, type)"><span v-if="store.busy[`unmount-${sessionFor(device, type)?.session_id}`]" class="spinner"></span><AppIcon v-else name="eject" />{{ store.busy[`unmount-${sessionFor(device, type)?.session_id}`] ? "正在卸载…" : "正常卸载" }}</button>
                  </template>
                  <template v-else>
                    <button
                      v-if="credentialsFor(device, type).length"
                      class="button primary"
                      :disabled="!device.connected || !!store.busy[`mount-${device.device_id}-${type}`]"
                      @click="runMount(device, type)"
                    ><span v-if="store.busy[`mount-${device.device_id}-${type}`]" class="spinner"></span>{{ store.busy[`mount-${device.device_id}-${type}`] ? "正在挂载…" : "手动挂载" }}</button>
                    <button v-else class="button primary" :disabled="!device.connected" @click="openCredentialSheet(type)"><AppIcon name="key" />设置密码</button>
                  </template>
                  <button v-if="credentialsFor(device, type).length" class="button ghost" @click="openCredentialSheet(type, credentialsFor(device, type)[0])">管理凭据</button>
                </div>
              </div>
            </article>
          </section>
        </template>
      </main>
    </section>

    <ModalSheet
      v-if="credentialSheet && device"
      :title="`${editingCredential ? '更新' : '设置'}${partitionName(credentialSheet)}凭据`"
      description="密码会先对当前磁盘进行只读验证，验证成功后才会保存。"
      @close="closeCredentialSheet"
    >
      <div v-if="credentialsFor(device, credentialSheet).length" class="credential-list">
        <div v-for="credential in credentialsFor(device, credentialSheet)" :key="credential.id" class="credential-item">
          <div><strong>{{ credential.label }}</strong><span>{{ credential.password_hint }} · {{ credential.last_used_at ? `最近使用 ${credential.last_used_at}` : "尚未使用" }}</span></div>
          <button class="button danger ghost" @click="deleteTarget = credential">删除</button>
        </div>
      </div>
      <div class="form-grid">
        <label class="field"><span>名称</span><input v-model="credentialLabel" autocomplete="off" /></label>
        <label class="field"><span>密码</span><input v-model="credentialPassword" type="password" autocomplete="new-password" autofocus @keyup.enter="submitCredential" /></label>
      </div>
      <template #footer>
        <button class="button secondary" @click="closeCredentialSheet">取消</button>
        <button class="button primary" :disabled="!credentialPassword || !device.connected || !!store.busy[`credential-${device.device_id}-${credentialSheet}`]" @click="submitCredential">验证并保存</button>
      </template>
    </ModalSheet>

    <ModalSheet v-if="deleteTarget" title="删除凭据？" description="删除后，该分区将失去自动挂载资格；当前已挂载会话不会被卸载。" @close="deleteTarget = null">
      <p>将删除“{{ deleteTarget.label }}”。此操作不会修改该分区的自动挂载选择。</p>
      <template #footer>
        <button class="button secondary" @click="deleteTarget = null">取消</button>
        <button class="button danger" :disabled="!!store.busy[`credential-delete-${deleteTarget.id}`]" @click="confirmCredentialDelete">删除凭据</button>
      </template>
    </ModalSheet>
  </div>
</template>

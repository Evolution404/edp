import { defineStore } from "pinia";
import { api, uiError } from "./api";
import type {
  ActivityEntry,
  AppSnapshot,
  CredentialInput,
  DeviceInfo,
  DevicePolicy,
  OperationEvent,
  PartitionType,
  RawDaemonEvent,
  SessionInfo,
  UiError,
} from "./types";

interface Toast {
  id: number;
  tone: "success" | "danger" | "neutral";
  title: string;
  detail?: string;
}

let toastId = 0;

function eventPresentation(event: RawDaemonEvent): Omit<ActivityEntry, "id" | "time" | "raw"> {
  const mountpoint = Array.isArray(event.data.mountpoints)
    ? String(event.data.mountpoints[0] ?? "")
    : "";
  const table: Record<string, { title: string; tone: ActivityEntry["tone"] }> = {
    mounted: { title: "加密卷已挂载", tone: "success" },
    unmounted: { title: "加密卷已卸载", tone: "neutral" },
    mount_failed: { title: "挂载失败", tone: "danger" },
    password_needed: { title: "设备需要有效密码", tone: "warning" },
    device_needs_setup: { title: "发现待配置 EDP 设备", tone: "warning" },
    device_policy_changed: { title: "设备授权已更新", tone: "neutral" },
    auto_mount_mode_changed: { title: "自动挂载状态已更新", tone: "neutral" },
    disk_appeared: { title: "检测到外置设备", tone: "neutral" },
    disk_removed: { title: "外置设备已移除", tone: "neutral" },
  };
  const presentation = table[event.event] ?? { title: event.event, tone: "neutral" as const };
  return {
    ...presentation,
    detail: mountpoint || String(event.data.device_id ?? event.data.bsd ?? ""),
  };
}

export const useStore = defineStore("ui-v2", {
  state: () => ({
    snapshot: null as AppSnapshot | null,
    initialized: false,
    selectedDeviceKey: "",
    busy: {} as Record<string, boolean>,
    operation: null as OperationEvent | null,
    activity: [] as ActivityEntry[],
    toasts: [] as Toast[],
    ordinaryExpanded: false,
  }),
  getters: {
    daemonOnline: (state) => state.snapshot?.daemon !== null && !!state.snapshot,
    managedDevices: (state): DeviceInfo[] =>
      state.snapshot?.devices.filter((device) => device.kind !== "ordinary") ?? [],
    connectedManagedDevices(): DeviceInfo[] {
      return this.managedDevices.filter((device) => device.connected);
    },
    offlineManagedDevices(): DeviceInfo[] {
      return this.managedDevices.filter((device) => !device.connected);
    },
    ordinaryDevices: (state): DeviceInfo[] =>
      state.snapshot?.devices.filter((device) => device.kind === "ordinary") ?? [],
    selectedDevice(): DeviceInfo | null {
      const devices = [...this.managedDevices, ...this.ordinaryDevices];
      return (
        devices.find((device) => deviceKey(device) === this.selectedDeviceKey) ??
        this.connectedManagedDevices[0] ??
        this.offlineManagedDevices[0] ??
        this.ordinaryDevices[0] ??
        null
      );
    },
    activeSessions: (state): SessionInfo[] => state.snapshot?.sessions ?? [],
  },
  actions: {
    applySnapshot(snapshot: AppSnapshot) {
      if (this.snapshot && snapshot.revision <= this.snapshot.revision) return;
      this.snapshot = snapshot;
      this.initialized = true;
      if (!this.selectedDeviceKey) {
        const first = snapshot.devices.find((device) => device.kind !== "ordinary");
        if (first) this.selectedDeviceKey = deviceKey(first);
      }
    },
    async initialize() {
      try {
        this.applySnapshot(await api.snapshot());
      } catch (error) {
        this.initialized = true;
        this.showError(error, "无法读取应用状态");
      }
    },
    async refresh() {
      await this.run("refresh", async () => this.applySnapshot(await api.refresh()));
    },
    selectDevice(device: DeviceInfo) {
      this.selectedDeviceKey = deviceKey(device);
    },
    setOperation(operation: OperationEvent) {
      this.operation = operation;
      if (operation.phase === "succeeded") {
        this.toast("success", operation.message);
        window.setTimeout(() => {
          if (this.operation?.id === operation.id) this.operation = null;
        }, 1800);
      } else if (operation.phase === "failed") {
        this.toast("danger", operation.message, operation.error?.detail ?? undefined);
      } else if (operation.phase === "cancelled") {
        this.toast("neutral", operation.message);
        this.operation = null;
      }
    },
    recordEvent(event: RawDaemonEvent) {
      const presentation = eventPresentation(event);
      this.activity.unshift({
        id: `${Date.now()}-${Math.random()}`,
        time: new Date().toLocaleTimeString("zh-CN", { hour12: false }),
        raw: event,
        ...presentation,
      });
      if (this.activity.length > 200) this.activity.length = 200;
    },
    async setAutoMount(active: boolean) {
      await this.run(
        "auto-mode",
        async () => this.applySnapshot(await api.setAutoMountMode(active ? "active" : "paused")),
        active ? "自动挂载已恢复" : "自动挂载已暂停",
      );
    },
    async savePolicy(policy: DevicePolicy) {
      await this.run(
        `policy-${policy.device_id}`,
        async () => this.applySnapshot(await api.setDevicePolicy(policy)),
        "设备授权已保存",
      );
    },
    async mount(device: DeviceInfo, partitionType: PartitionType) {
      if (!device.rbsd || !device.device_id) return;
      await this.run(
        `mount-${device.device_id}-${partitionType}`,
        async () =>
          this.applySnapshot(await api.mountPartition(device.rbsd!, device.device_id!, partitionType)),
        `${partitionName(partitionType)}已挂载`,
      );
    },
    async unmount(session: SessionInfo) {
      await this.run(
        `unmount-${session.session_id}`,
        async () => this.applySnapshot(await api.unmountSession(session.session_id)),
        `${partitionName(session.partition.partition_type)}已卸载`,
      );
    },
    async openFinder(path: string) {
      if (!path) return;
      await this.run(`finder-${path}`, async () => api.openInFinder(path));
    },
    async saveCredential(input: CredentialInput) {
      await this.run(
        `credential-${input.device_id}-${input.partition_type}`,
        async () => this.applySnapshot(await api.saveCredential(input)),
        "凭据已验证并保存",
      );
    },
    async deleteCredential(id: string) {
      await this.run(
        `credential-delete-${id}`,
        async () => this.applySnapshot(await api.deleteCredential(id)),
        "凭据已删除",
      );
    },
    async serviceAction(action: "install" | "start" | "stop" | "restart" | "uninstall") {
      await this.run(`service-${action}`, async () => {
        const result = await api.serviceAction(action);
        this.applySnapshot(result.snapshot);
      });
    },
    async run(key: string, work: () => Promise<void>, success?: string) {
      if (this.busy[key]) return;
      this.busy[key] = true;
      try {
        await work();
        if (success) this.toast("success", success);
      } catch (error) {
        this.showError(error);
        throw error;
      } finally {
        delete this.busy[key];
      }
    },
    showError(error: unknown, fallback?: string) {
      const value: UiError = uiError(error);
      this.toast("danger", fallback ?? value.message, value.detail ?? undefined);
    },
    toast(tone: Toast["tone"], title: string, detail?: string) {
      const id = ++toastId;
      this.toasts.push({ id, tone, title, detail });
      window.setTimeout(() => this.dismissToast(id), 4500);
    },
    dismissToast(id: number) {
      this.toasts = this.toasts.filter((toast) => toast.id !== id);
    },
  },
});

export function deviceKey(device: DeviceInfo): string {
  return device.device_id || device.bsd || device.media_name;
}

export function partitionName(type: PartitionType): string {
  return type === 2 ? "交换区" : "保密区";
}

import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, it } from "vitest";
import { useStore } from "./store";
import type { AppSnapshot, DeviceInfo } from "./types";

function snapshot(revision: number, devices: DeviceInfo[] = []): AppSnapshot {
  return {
    revision,
    generated_at: "2026-08-24T00:00:00Z",
    service: { installed: true, running: true, enabled: true },
    daemon: {
      version: "0.4.0",
      uptime_s: 1,
      mounted_sessions: 0,
      keystore_entries: 0,
      disk_access_ok: true,
      auto_mount_mode: "active",
    },
    auto_mount_mode: "active",
    devices,
    sessions: [],
    credentials: [],
    macfuse: { installed: true, version: "5.2.0" },
    last_error: null,
  };
}

const ordinary: DeviceInfo = {
  bsd: "disk9",
  rbsd: "/dev/rdisk9",
  media_name: "普通磁盘",
  size: 64_000_000_000,
  connected: true,
  kind: "ordinary",
  device_id: null,
  policy: null,
  credential_partition_types: [],
  mounted_partition_types: [],
  session_ids: [],
};

describe("UI snapshot reducer", () => {
  beforeEach(() => setActivePinia(createPinia()));

  it("拒绝旧 revision 覆盖新快照", () => {
    const store = useStore();
    store.applySnapshot(snapshot(7));
    store.applySnapshot({ ...snapshot(6), auto_mount_mode: "paused" });
    expect(store.snapshot?.revision).toBe(7);
    expect(store.snapshot?.auto_mount_mode).toBe("active");
  });

  it("普通磁盘只进入未受管理分组", () => {
    const store = useStore();
    store.applySnapshot(snapshot(1, [ordinary]));
    expect(store.ordinaryDevices).toEqual([ordinary]);
    expect(store.managedDevices).toEqual([]);
  });
});

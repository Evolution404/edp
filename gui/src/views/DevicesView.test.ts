import { mount } from "@vue/test-utils";
import { createPinia, setActivePinia } from "pinia";
import { describe, expect, it, vi } from "vitest";
import DevicesView from "./DevicesView.vue";
import { useStore } from "../store";
import type { AppSnapshot, DeviceInfo } from "../types";

const edpDevice: DeviceInfo = {
  bsd: "disk4",
  rbsd: "/dev/rdisk4",
  media_name: "Test EDP",
  size: 128_000_000_000,
  connected: true,
  kind: "edp",
  device_id: "test-device",
  policy: {
    device_id: "test-device",
    label: "Test EDP",
    authorized: true,
    partition_types: [2],
    last_media_name: "Test EDP",
  },
  credential_partition_types: [],
  mounted_partition_types: [],
  session_ids: [],
};

function snapshot(): AppSnapshot {
  return {
    revision: 1,
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
    devices: [edpDevice],
    sessions: [],
    credentials: [],
    macfuse: { installed: true, version: "5.2.0" },
    last_error: null,
  };
}

describe("设备分区自动挂载设置", () => {
  it("不显示设备总开关，并由分区选择推导授权兼容字段", async () => {
    const pinia = createPinia();
    setActivePinia(pinia);
    const store = useStore();
    store.applySnapshot(snapshot());
    const savePolicy = vi.spyOn(store, "savePolicy").mockResolvedValue();
    const wrapper = mount(DevicesView, { global: { plugins: [pinia] } });

    expect(wrapper.text()).not.toContain("允许此设备自动挂载");

    await wrapper.get('input[aria-label="自动挂载保密区"]').setValue(true);
    expect(savePolicy).toHaveBeenLastCalledWith(
      expect.objectContaining({ authorized: true, partition_types: [2, 4] }),
    );

    await wrapper.get('input[aria-label="自动挂载交换区"]').setValue(false);
    expect(savePolicy).toHaveBeenLastCalledWith(
      expect.objectContaining({ authorized: false, partition_types: [] }),
    );
  });
});

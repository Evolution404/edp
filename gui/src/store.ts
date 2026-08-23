import { defineStore } from "pinia";
import { api } from "./api";

export interface DaemonStatus {
  version: string;
  macfuse: string | null;
  keystore_entries: number;
  auto_mount_enabled: boolean;
  mounted_sessions: number;
  disk_access_ok: boolean;
  uptime_s?: number;
}

/** 全局状态：daemon 状态 / 会话 / 密码库 / 配置 / 事件日志。 */
export const useStore = defineStore("main", {
  state: () => ({
    daemonOnline: false,
    status: null as DaemonStatus | null,
    macfuse: null as { installed: boolean; version: string | null } | null,
    sessions: [] as any[],
    keys: [] as any[],
    config: null as Record<string, unknown> | null,
    eventLog: [] as { time: string; event: string; data: any }[],
  }),
  actions: {
    async refreshDaemon() {
      try {
        this.status = await api.daemonStatus();
        this.daemonOnline = true;
      } catch {
        this.daemonOnline = false;
        this.status = null;
      }
    },
    async refreshMacfuse() {
      try {
        this.macfuse = await api.macfuse();
      } catch {
        this.macfuse = null;
      }
    },
    async refreshSessions() {
      if (!this.daemonOnline) {
        this.sessions = [];
        return;
      }
      try {
        this.sessions = (await api.sessions()).sessions ?? [];
      } catch {
        this.sessions = [];
      }
    },
    async refreshKeys() {
      if (!this.daemonOnline) {
        this.keys = [];
        return;
      }
      try {
        this.keys = await api.keysLs();
      } catch {
        this.keys = [];
      }
    },
    async refreshConfig() {
      if (!this.daemonOnline) {
        this.config = null;
        return;
      }
      try {
        this.config = await api.configGet();
      } catch {
        this.config = null;
      }
    },
    async refreshAll() {
      await this.refreshDaemon();
      await Promise.all([
        this.refreshMacfuse(),
        this.refreshSessions(),
        this.refreshKeys(),
        this.refreshConfig(),
      ]);
    },
    pushEvent(ev: { event: string; data: any }) {
      this.eventLog.unshift({
        time: new Date().toLocaleTimeString(),
        event: ev.event,
        data: ev.data,
      });
      if (this.eventLog.length > 300) this.eventLog.length = 300;
      void this.refreshSessions();
      void this.refreshKeys();
    },
  },
});

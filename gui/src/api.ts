import { invoke } from "@tauri-apps/api/core";

/** 前端 → Tauri 命令 / daemon RPC 的统一封装。 */
export const api = {
  // 本地命令（GUI 后端）
  daemonStatus: () => invoke<any>("daemon_status"),
  macfuse: () => invoke<any>("macfuse_status"),
  installDaemon: () => invoke<any>("install_daemon"),
  uninstallDaemon: () => invoke<any>("uninstall_daemon"),
  openInFinder: (path: string) => invoke("open_in_finder", { path }),

  // daemon RPC 转发
  rpc: (method: string, params: Record<string, unknown> = {}) =>
    invoke<any>("rpc", { method, params }),

  status: () => api.rpc("status"),
  sessions: () => api.rpc("sessions"),
  listDisks: () => api.rpc("list_disks"),
  keysLs: () => api.rpc("keys.ls"),
  keysAdd: (p: Record<string, unknown>) => api.rpc("keys.add", p),
  keysRm: (id: string) => api.rpc("keys.rm", { id }),
  keysUpdate: (id: string, patch: Record<string, unknown>) =>
    api.rpc("keys.update", { id, ...patch }),
  mount: (disk: string, password?: string, partition_type = 4) =>
    api.rpc("mount", { disk, password, partition_type }),
  unmount: (session_id: string, force = false) =>
    api.rpc("unmount", { session_id, force }),
  configGet: () => api.rpc("config.get"),
  configSet: (patch: Record<string, unknown>) => api.rpc("config.set", patch),
  logsRead: (lines = 200) => api.rpc("logs.read", { lines }),
};

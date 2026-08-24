import { invoke } from "@tauri-apps/api/core";
import type {
  AppSnapshot,
  AutoMountMode,
  CredentialInput,
  DevicePolicy,
  DiagnosticsResult,
  PartitionType,
  UiError,
} from "./types";

function normalizeError(error: unknown): UiError {
  if (typeof error === "object" && error !== null && "message" in error) {
    const value = error as Partial<UiError>;
    return {
      code: value.code ?? "UNKNOWN",
      message: String(value.message),
      detail: value.detail ? String(value.detail) : null,
    };
  }
  return { code: "UNKNOWN", message: String(error) };
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>(command, args);
  } catch (error) {
    throw normalizeError(error);
  }
}

export const api = {
  snapshot: () => call<AppSnapshot>("get_app_snapshot"),
  refresh: () => call<AppSnapshot>("refresh_app_snapshot"),
  setAutoMountMode: (mode: AutoMountMode) =>
    call<AppSnapshot>("set_auto_mount_mode", { mode }),
  setDevicePolicy: (policy: DevicePolicy) =>
    call<AppSnapshot>("set_device_policy", { policy }),
  mountPartition: (disk: string, deviceId: string, partitionType: PartitionType) =>
    call<AppSnapshot>("mount_partition", { disk, deviceId, partitionType }),
  unmountSession: (sessionId: string, force = false) =>
    call<AppSnapshot>("unmount_session", { sessionId, force }),
  saveCredential: (input: CredentialInput) =>
    call<AppSnapshot>("save_credential", { input }),
  deleteCredential: (id: string) =>
    call<AppSnapshot>("delete_credential", { id }),
  serviceAction: (action: "install" | "start" | "stop" | "restart" | "uninstall") =>
    call<{ action: string; snapshot: AppSnapshot }>("run_service_action", { action }),
  diagnostics: () => call<DiagnosticsResult>("get_diagnostics"),
  openInFinder: (path: string) => call<void>("open_in_finder", { path }),
};

export function uiError(error: unknown): UiError {
  return normalizeError(error);
}

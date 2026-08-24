export type AutoMountMode = "active" | "paused";
export type PartitionType = 2 | 4;

export interface ServiceStatus {
  installed: boolean;
  running: boolean;
  enabled: boolean;
  online?: boolean;
  macfuse?: string | null;
  error?: string;
}

export interface DaemonStatus {
  version: string;
  uptime_s: number;
  mounted_sessions: number;
  keystore_entries: number;
  disk_access_ok: boolean;
  auto_mount_mode: AutoMountMode;
}

export interface DevicePolicy {
  device_id: string;
  label: string;
  authorized: boolean;
  partition_types: PartitionType[];
  last_media_name?: string | null;
}

export interface DeviceInfo {
  bsd: string | null;
  rbsd: string | null;
  media_name: string;
  size: number;
  connected: boolean;
  kind: "edp" | "ordinary" | "unknown";
  device_id: string | null;
  policy: DevicePolicy | null;
  credential_partition_types: PartitionType[];
  mounted_partition_types: PartitionType[];
  session_ids: string[];
}

export interface PartitionDescriptor {
  partition_type: PartitionType;
  start_bytes: number;
  size_bytes: number;
  algo: number;
}

export interface SessionInfo {
  session_id: string;
  source: string;
  active: boolean;
  bridge_alive?: boolean;
  mountpoints: string[];
  devices?: string[];
  device_id: string;
  partition: PartitionDescriptor;
}

export interface CredentialInfo {
  id: string;
  label: string;
  device_id: string;
  partition_type: PartitionType;
  password_crc: string;
  password_hint: string;
  created_at: string;
  last_used_at?: string | null;
}

export interface MacfuseStatus {
  installed: boolean;
  version: string | null;
}

export interface AppSnapshot {
  revision: number;
  generated_at: string;
  service: ServiceStatus;
  daemon: DaemonStatus | null;
  auto_mount_mode: AutoMountMode;
  devices: DeviceInfo[];
  sessions: SessionInfo[];
  credentials: CredentialInfo[];
  macfuse: MacfuseStatus;
  last_error: string | null;
}

export interface UiError {
  code: string;
  message: string;
  detail?: string | null;
}

export interface OperationEvent {
  id: string;
  action: string;
  phase: "authorizing" | "verifying" | "succeeded" | "failed" | "cancelled";
  message: string;
  error?: UiError | null;
}

export interface RawDaemonEvent {
  event: string;
  data: Record<string, unknown>;
}

export interface ActivityEntry {
  id: string;
  time: string;
  title: string;
  detail: string;
  tone: "neutral" | "success" | "warning" | "danger";
  raw: RawDaemonEvent;
}

export interface CredentialInput {
  id?: string;
  label: string;
  device_id: string;
  disk?: string | null;
  partition_type: PartitionType;
  password: string;
}

export interface DiagnosticsResult {
  snapshot: AppSnapshot;
  logs: Array<{ file: string; lines: string[] }>;
}

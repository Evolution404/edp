use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const CONFIG_SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutoMountMode {
    #[default]
    Active,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DevicePolicy {
    pub device_id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub authorized: bool,
    #[serde(default)]
    pub partition_types: Vec<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_media_name: Option<String>,
}

impl DevicePolicy {
    pub fn validate(&mut self) -> Result<()> {
        self.device_id = self.device_id.trim().to_string();
        if self.device_id.is_empty() {
            bail!("device_id 不能为空");
        }
        self.partition_types.sort_unstable();
        self.partition_types.dedup();
        if self
            .partition_types
            .iter()
            .any(|partition_type| !matches!(partition_type, 2 | 4))
        {
            bail!("partition_types 仅允许 2（交换区）或 4（保密区）");
        }
        // `authorized` remains serialized for schema/RPC compatibility, but is no
        // longer an independent user decision. Selecting at least one partition is
        // the complete per-device auto-mount policy.
        self.authorized = !self.partition_types.is_empty();
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub schema_version: u32,
    #[serde(default)]
    pub auto_mount_mode: AutoMountMode,
    #[serde(default)]
    pub device_policies: Vec<DevicePolicy>,
    pub socket_path: String,
    #[serde(default)]
    pub allowed_uids: Vec<u32>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            schema_version: CONFIG_SCHEMA_VERSION,
            auto_mount_mode: AutoMountMode::Active,
            device_policies: Vec::new(),
            socket_path: "/var/run/com.edp.usbvault.daemon.sock".to_string(),
            allowed_uids: Vec::new(),
        }
    }
}

impl Config {
    /// Read both the v2 schema and the legacy v1 shape. Legacy auto-mount flags are
    /// deliberately not migrated: every physical device must be approved again.
    pub fn from_json(value: Value) -> Result<Self> {
        if value.get("schema_version").and_then(Value::as_u64) == Some(CONFIG_SCHEMA_VERSION as u64)
        {
            let mut config: Self = serde_json::from_value(value)?;
            config.validate()?;
            return Ok(config);
        }

        let mut config = Self::default();
        if let Some(socket) = value.get("socket_path").and_then(Value::as_str) {
            config.socket_path = socket.to_string();
        }
        if let Some(uids) = value.get("allowed_uids").and_then(Value::as_array) {
            config.allowed_uids = uids
                .iter()
                .filter_map(Value::as_u64)
                .map(|uid| uid as u32)
                .collect();
        }
        // v1 had no per-device authorization. v2 therefore always starts active
        // with an empty policy list: no disk can mount until explicitly approved.
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&mut self) -> Result<()> {
        if self.socket_path.is_empty() {
            bail!("socket_path 不能为空");
        }
        for policy in &mut self.device_policies {
            policy.validate()?;
        }
        self.device_policies
            .sort_by(|left, right| left.device_id.cmp(&right.device_id));
        for pair in self.device_policies.windows(2) {
            if pair[0].device_id == pair[1].device_id {
                bail!("device_policies 存在重复 device_id: {}", pair[0].device_id);
            }
        }
        self.schema_version = CONFIG_SCHEMA_VERSION;
        Ok(())
    }

    pub fn policy(&self, candidates: &[String]) -> Option<&DevicePolicy> {
        self.device_policies
            .iter()
            .find(|policy| candidates.contains(&policy.device_id))
    }

    pub fn set_policy(&mut self, mut policy: DevicePolicy) -> Result<()> {
        policy.validate()?;
        if let Some(existing) = self
            .device_policies
            .iter_mut()
            .find(|existing| existing.device_id == policy.device_id)
        {
            *existing = policy;
        } else {
            self.device_policies.push(policy);
        }
        self.validate()
    }
}

pub fn load(path: &Path) -> Result<Config> {
    if !path.exists() {
        return Ok(Config::default());
    }
    let bytes = std::fs::read(path).with_context(|| format!("读取配置 {} 失败", path.display()))?;
    let value = serde_json::from_slice(&bytes)
        .with_context(|| format!("解析配置 {} 失败", path.display()))?;
    Config::from_json(value)
}

pub fn save_atomic(path: &Path, config: &Config) -> Result<()> {
    let mut validated = config.clone();
    validated.validate()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut temporary = PathBuf::from(path);
    temporary.set_extension(format!("tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(&validated)?;
    std::fs::write(&temporary, bytes)
        .with_context(|| format!("写入临时配置 {} 失败", temporary.display()))?;
    std::fs::rename(&temporary, path)
        .with_context(|| format!("原子替换配置 {} 失败", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_config_starts_active_but_clears_authorizations() {
        let config = Config::from_json(serde_json::json!({
            "auto_mount_enabled": false,
            "default_partition_types": [2, 4],
            "socket_path": "/tmp/legacy.sock",
            "allowed_uids": [501]
        }))
        .unwrap();
        assert_eq!(config.schema_version, CONFIG_SCHEMA_VERSION);
        assert_eq!(config.auto_mount_mode, AutoMountMode::Active);
        assert!(config.device_policies.is_empty());
        assert_eq!(config.socket_path, "/tmp/legacy.sock");
    }

    #[test]
    fn policy_validation_is_atomic_and_deduplicates_types() {
        let mut config = Config::default();
        config
            .set_policy(DevicePolicy {
                device_id: "disk-id".into(),
                label: "My disk".into(),
                authorized: true,
                partition_types: vec![4, 2, 4],
                last_media_name: None,
            })
            .unwrap();
        assert_eq!(config.device_policies[0].partition_types, vec![2, 4]);
        assert!(config.device_policies[0].authorized);

        config
            .set_policy(DevicePolicy {
                device_id: "disk-id".into(),
                label: "My disk".into(),
                authorized: true,
                partition_types: vec![],
                last_media_name: None,
            })
            .unwrap();
        assert!(!config.device_policies[0].authorized);
    }
}

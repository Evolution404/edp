//! root-only 加密密码库。
//!
//! daemon 私有数据目录（0700 root:wheel）：
//! - `kek.bin`：32B CSPRNG 密钥加密密钥（0600 root:wheel）
//! - `store.enc`：`"EDPSTOR1" ‖ nonce[12] ‖ AES-256-GCM(json)`（0600）
//!   json 明文含密码（以密码 CRC 为主要索引，绝不外泄）
//!
//! 威胁模型：防同机非 root 进程窃取密码。root 攻击者可读 daemon 内存，
//! 任何方案（含 Keychain）都不可防。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const MAGIC: &[u8; 8] = b"EDPSTOR1";

/// 密码库条目（明文含密码）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyRecord {
    pub id: String,
    pub label: String,
    pub device_id: String,
    pub partition_type: u32,
    pub password: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
}

/// 密码库（内存视图 + 落盘）。
pub struct Keystore {
    dir: PathBuf,
    kek: [u8; 32],
    records: Vec<KeyRecord>,
    /// (device_id, partition_type) → ids（匹配用索引）
    index: HashMap<(String, u32), Vec<String>>,
}

fn now_str() -> String {
    chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%z")
        .to_string()
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

impl Keystore {
    /// 打开（目录不存在则初始化）。
    pub fn open(dir: &Path) -> Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(dir)
            .with_context(|| format!("创建密码库目录 {}", dir.display()))?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;

        let kek_path = dir.join("kek.bin");
        let store_path = dir.join("store.enc");
        let kek = if kek_path.exists() {
            let data = std::fs::read(&kek_path)?;
            data.try_into()
                .map_err(|_| anyhow::anyhow!("kek.bin 长度非法"))?
        } else {
            let k = random_32();
            let tmp = dir.join("kek.bin.tmp");
            std::fs::write(&tmp, k)?;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
            std::fs::rename(&tmp, &kek_path)?;
            k
        };

        let mut ks = Keystore {
            dir: dir.to_path_buf(),
            kek,
            records: Vec::new(),
            index: HashMap::new(),
        };
        if store_path.exists() {
            ks.load()?;
        }
        Ok(ks)
    }

    fn load(&mut self) -> Result<()> {
        let data = std::fs::read(self.dir.join("store.enc"))?;
        if data.len() < 8 + 12 + 16 {
            bail!("store.enc 损坏");
        }
        if &data[..8] != MAGIC {
            bail!("store.enc magic 不符");
        }
        let nonce = Nonce::from_slice(&data[8..20]);
        let cipher = Aes256Gcm::new_from_slice(&self.kek)
            .map_err(|_| anyhow::anyhow!("AES-256-GCM 初始化失败"))?;
        let plain = cipher
            .decrypt(nonce, data[20..].as_ref())
            .map_err(|_| anyhow::anyhow!("store.enc 解密失败（KEK 不匹配或损坏）"))?;
        let v: Value = serde_json::from_slice(&plain)?;
        let arr = v
            .get("records")
            .and_then(|x| x.as_array())
            .context("store.enc 缺少 records")?;
        self.records = serde_json::from_value(serde_json::Value::Array(arr.clone()))?;
        self.rebuild_index();
        Ok(())
    }

    fn save(&self) -> Result<()> {
        let v = serde_json::json!({ "records": self.records });
        let plain = serde_json::to_vec(&v)?;
        let cipher = Aes256Gcm::new_from_slice(&self.kek)
            .map_err(|_| anyhow::anyhow!("AES-256-GCM 初始化失败"))?;
        let nonce_bytes = random_12();
        let nonce = Nonce::from_slice(&nonce_bytes);
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&nonce_bytes);
        let ct = cipher
            .encrypt(nonce, plain.as_slice())
            .map_err(|_| anyhow::anyhow!("store.enc 加密失败"))?;
        out.extend_from_slice(&ct);
        let tmp = self.dir.join("store.enc.tmp");
        std::fs::write(&tmp, &out)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        std::fs::rename(&tmp, self.dir.join("store.enc"))?;
        Ok(())
    }

    fn rebuild_index(&mut self) {
        self.index.clear();
        for r in &self.records {
            self.index
                .entry((r.device_id.clone(), r.partition_type))
                .or_default()
                .push(r.id.clone());
        }
    }

    /// 按 (device_id, partition_type) 取所有密码条目（同型号盘可能多条，
    /// 返回 owned 副本以避免借用逃逸）。
    pub fn candidates(&self, device_id: &str, partition_type: u32) -> Vec<KeyRecord> {
        self.index
            .get(&(device_id.to_string(), partition_type))
            .map(|ids| {
                ids.iter()
                    .filter_map(|id| self.records.iter().find(|r| &r.id == id).cloned())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// 列出全部（对外脱敏在调用方）。
    pub fn all(&self) -> &[KeyRecord] {
        &self.records
    }

    /// 添加条目。
    pub fn add(&mut self, mut rec: KeyRecord) -> Result<String> {
        rec.id = new_id();
        rec.created_at = now_str();
        self.records.push(rec);
        self.save()?;
        self.rebuild_index();
        Ok(self.records.last().unwrap().id.clone())
    }

    /// 删除条目。
    pub fn remove(&mut self, id: &str) -> Result<bool> {
        let before = self.records.len();
        self.records.retain(|r| r.id != id);
        if self.records.len() == before {
            return Ok(false);
        }
        self.save()?;
        self.rebuild_index();
        Ok(true)
    }

    /// 更新凭据字段。密码仅在调用方完成只读 probe 验证后传入。
    pub fn update(&mut self, id: &str, patch: Value) -> Result<bool> {
        let Some(rec) = self.records.iter_mut().find(|r| r.id == id) else {
            return Ok(false);
        };
        if let Some(b) = patch.get("label").and_then(|x| x.as_str()) {
            rec.label = b.to_string();
        }
        if let Some(password) = patch.get("password").and_then(|x| x.as_str()) {
            if password.is_empty() {
                bail!("password 不能为空");
            }
            rec.password = password.to_string();
        }
        self.save()?;
        self.rebuild_index();
        Ok(true)
    }

    /// 标记最近使用。
    pub fn touch(&mut self, id: &str) {
        if let Some(rec) = self.records.iter_mut().find(|r| r.id == id) {
            rec.last_used_at = Some(now_str());
        }
    }
}

fn random_32() -> [u8; 32] {
    let mut b = [0u8; 32];
    getrandom(&mut b);
    b
}

fn random_12() -> [u8; 12] {
    let mut b = [0u8; 12];
    getrandom(&mut b);
    b
}

fn getrandom(buf: &mut [u8]) {
    // 用 /dev/urandom（避免引入 rand crate）
    use std::io::Read;
    let mut f = std::fs::File::open("/dev/urandom").expect("打开 /dev/urandom");
    f.read_exact(buf).expect("读 /dev/urandom");
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes_gcm::aead::Aead;

    fn temp_dir(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("edp-ks-{}-{tag}", std::process::id()))
    }

    #[test]
    fn gcm_roundtrip() {
        let cipher = Aes256Gcm::new_from_slice(&[0x42u8; 32]).unwrap();
        let nonce = Nonce::from_slice(&[0x24u8; 12]);
        let plain = br#"{"records":[]}"#;
        let ct = cipher.encrypt(nonce, plain.as_slice()).unwrap();
        let dec = cipher.decrypt(nonce, ct.as_slice()).unwrap();
        assert_eq!(dec, plain);
    }

    #[test]
    fn open_creates_layout() {
        let dir = temp_dir("layout");
        let _ = std::fs::remove_dir_all(&dir);
        let ks = Keystore::open(&dir).unwrap();
        assert!(dir.join("kek.bin").exists());
        assert_eq!(ks.all().len(), 0);
        // 权限 0600/0700
        use std::os::unix::fs::PermissionsExt;
        let m = std::fs::metadata(dir.join("kek.bin"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(m, 0o600, "kek.bin 应 0600");
    }

    #[test]
    fn add_ls_remove_persist() {
        let dir = temp_dir("crud");
        let _ = std::fs::remove_dir_all(&dir);
        let mut ks = Keystore::open(&dir).unwrap();
        let id = ks
            .add(KeyRecord {
                id: String::new(),
                label: "测试".into(),
                device_id: "disk&ven_test".into(),
                partition_type: 4,
                password: "0000aaaa".into(),
                created_at: String::new(),
                last_used_at: None,
            })
            .unwrap();
        assert_eq!(ks.all().len(), 1);
        // 重新打开（落盘持久化）
        drop(ks);
        let ks2 = Keystore::open(&dir).unwrap();
        assert_eq!(ks2.all().len(), 1);
        assert_eq!(ks2.all()[0].password, "0000aaaa");
        // 匹配
        let cand = ks2.candidates("disk&ven_test", 4);
        assert_eq!(cand.len(), 1);
        let cand = ks2.candidates("disk&ven_other", 4);
        assert!(cand.is_empty());
        // 删除
        let mut ks2 = ks2;
        assert!(ks2.remove(&id).unwrap());
        assert!(!ks2.remove(&id).unwrap());
        assert_eq!(ks2.all().len(), 0);
    }

    #[test]
    fn store_enc_is_encrypted() {
        let dir = temp_dir("enc");
        let _ = std::fs::remove_dir_all(&dir);
        let mut ks = Keystore::open(&dir).unwrap();
        ks.add(KeyRecord {
            id: String::new(),
            label: "x".into(),
            device_id: "d".into(),
            partition_type: 4,
            password: "supersecret".into(),
            created_at: String::new(),
            last_used_at: None,
        })
        .unwrap();
        // 明文密码绝不出现在 store.enc
        let raw = std::fs::read(dir.join("store.enc")).unwrap();
        let text = String::from_utf8_lossy(&raw);
        assert!(!text.contains("supersecret"), "store.enc 泄露明文密码");
        assert_eq!(&raw[..8], MAGIC);
    }
}

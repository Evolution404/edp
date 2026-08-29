use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;

pub fn load_json(name: &str) -> Option<serde_json::Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join(name);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            eprintln!("SKIP golden test: {} 不存在；本地可用 tools/ 生成，真实盘数据不入库", path.display());
            return None;
        }
        Err(e) => panic!("读取 {} 失败: {e}", path.display()),
    };
    Some(serde_json::from_str(&text).unwrap_or_else(|e| panic!("解析 {} 失败: {e}", path.display())))
}

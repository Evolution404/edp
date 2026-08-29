use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use edpopen_core::sector::{decode_sector, SectorDecodeContext};
use edpopen_core::Identity;
use serde::Serialize;

#[derive(Serialize)]
struct DecodeResponse {
    ok: bool,
    error: Option<String>,
    decoded_hex: Option<String>,
    method: Option<String>,
    fields: Vec<edpopen_core::parser::FieldRow>,
}

fn hexs(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn json_c_string(response: &DecodeResponse) -> *mut c_char {
    let json = serde_json::to_string(response).unwrap_or_else(|e| {
        format!(r#"{{"ok":false,"error":"serialization failed: {e}","decoded_hex":null,"method":null,"fields":[]}}"#)
    });
    CString::new(json).expect("serde_json must escape NUL").into_raw()
}

fn error_response(message: impl Into<String>) -> *mut c_char {
    json_c_string(&DecodeResponse {
        ok: false,
        error: Some(message.into()),
        decoded_hex: None,
        method: None,
        fields: Vec::new(),
    })
}

unsafe fn opt_cstr<'a>(ptr: *const c_char) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(Some)
        .map_err(|_| "VID/PID 必须是 UTF-8 字符串".to_string())
}

#[no_mangle]
pub extern "C" fn edp_core_version() -> *const c_char {
    static VERSION: &[u8] = b"edpopen-core/0.1.0\0";
    VERSION.as_ptr().cast()
}

#[no_mangle]
pub unsafe extern "C" fn edp_core_crc32(data: *const u8, len: usize) -> u32 {
    if data.is_null() || len == 0 {
        return edpopen_core::crypto::crc32_bare(&[]);
    }
    edpopen_core::crypto::crc32_bare(slice::from_raw_parts(data, len))
}

/// Decode one 512-byte EDP sector and return UTF-8 JSON owned by Rust.
/// The caller must release the returned pointer with `edp_string_free`.
///
/// `has_identity != 0` enables CRC/K0 based decode for LBA7/8/9/12.
/// `vid`/`pid`/`size_bytes` are only needed by LBA11 and may otherwise be null/zero.
#[no_mangle]
pub unsafe extern "C" fn edp_decode_sector_json(
    lba: u64,
    raw: *const u8,
    raw_len: usize,
    has_identity: i32,
    crc: u32,
    k0: u16,
    vid: *const c_char,
    pid: *const c_char,
    size_bytes: u64,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<*mut c_char, String> {
        if raw.is_null() {
            return Err("raw pointer is null".into());
        }
        if raw_len != 512 {
            return Err(format!("raw_len 必须为 512，实际 {raw_len}"));
        }
        let bytes = slice::from_raw_parts(raw, raw_len);
        let identity = (has_identity != 0).then(|| Identity {
            device_id: String::new(),
            crc,
            k0,
        });
        let vid = opt_cstr(vid)?;
        let pid = opt_cstr(pid)?;
        let ctx = SectorDecodeContext {
            identity: identity.as_ref(),
            vid,
            pid,
            size_bytes: (size_bytes != 0).then_some(size_bytes),
        };
        let decoded = decode_sector(lba, bytes, &ctx)?;
        Ok(json_c_string(&DecodeResponse {
            ok: true,
            error: None,
            decoded_hex: decoded.decoded.as_deref().map(hexs),
            method: decoded.method,
            fields: decoded.fields,
        }))
    }));

    match result {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(e)) => error_response(e),
        Err(_) => error_response("edpopen-core panic was contained at FFI boundary"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn edp_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_lba0_json_roundtrip() {
        let mut raw = vec![0u8; 512];
        raw[0x1fe] = 0x55;
        raw[0x1ff] = 0xaa;
        let ptr = unsafe {
            edp_decode_sector_json(0, raw.as_ptr(), raw.len(), 0, 0, 0, std::ptr::null(), std::ptr::null(), 0)
        };
        assert!(!ptr.is_null());
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        unsafe { edp_string_free(ptr) };
        assert!(text.contains("\"ok\":true"));
        assert!(text.contains("55AA"));
    }
}

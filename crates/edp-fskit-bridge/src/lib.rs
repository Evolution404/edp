//! Minimal C ABI used by the native macOS FSKit extension.
//!
//! Keep this layer intentionally narrow.  FSKit owns block-resource access and
//! passes two already-read 512-byte reserved sectors into Rust.  `edp-core`
//! remains the single source of truth for EDP format recognition.

use edp_core::probe::probe_edp_reserved_sectors;
use std::ffi::c_char;

pub const EDP_PROBE_SECTOR_SIZE: usize = 512;
pub const EDP_PROBE_SERIAL_CAPACITY: usize = 128;

/// The two reserved-sector signals identify an EDP disk and `serial_out`
/// contains a NUL-terminated serial string.
pub const EDP_PROBE_RECOGNIZED: i32 = 1;
/// The supplied sectors do not satisfy the conservative EDP probe.
pub const EDP_PROBE_NOT_RECOGNIZED: i32 = 0;
/// A required pointer is null or the output capacity is otherwise invalid.
pub const EDP_PROBE_INVALID_ARGUMENT: i32 = -1;
/// The caller-provided serial buffer is too small for the recognized serial.
pub const EDP_PROBE_SERIAL_BUFFER_TOO_SMALL: i32 = -2;

/// Probe passwordless EDP reserved-sector evidence through a stable C ABI.
///
/// # Safety
///
/// - `lba4` and `lba7` must each point to at least 512 readable bytes.
/// - `serial_out` must point to at least `serial_capacity` writable bytes.
/// - All three memory regions must remain valid and non-overlapping for the
///   duration of this call.
#[no_mangle]
pub unsafe extern "C" fn edp_probe_reserved_sectors(
    lba4: *const u8,
    lba7: *const u8,
    serial_out: *mut c_char,
    serial_capacity: usize,
) -> i32 {
    if lba4.is_null() || lba7.is_null() || serial_out.is_null() || serial_capacity == 0 {
        return EDP_PROBE_INVALID_ARGUMENT;
    }

    let mut lba4_bytes = [0u8; EDP_PROBE_SECTOR_SIZE];
    let mut lba7_bytes = [0u8; EDP_PROBE_SECTOR_SIZE];
    // SAFETY: validated non-null above; caller contract guarantees each source
    // points to at least one complete sector and does not overlap the outputs.
    unsafe {
        std::ptr::copy_nonoverlapping(lba4, lba4_bytes.as_mut_ptr(), EDP_PROBE_SECTOR_SIZE);
        std::ptr::copy_nonoverlapping(lba7, lba7_bytes.as_mut_ptr(), EDP_PROBE_SECTOR_SIZE);
    }

    let Some(evidence) = probe_edp_reserved_sectors(&lba4_bytes, &lba7_bytes) else {
        // Make even a negative result deterministic for callers that reuse a
        // buffer between probes.
        // SAFETY: serial_out is non-null and capacity is at least one byte.
        unsafe {
            serial_out.write(0);
        }
        return EDP_PROBE_NOT_RECOGNIZED;
    };

    let serial = evidence.serial.as_bytes();
    let Some(required) = serial.len().checked_add(1) else {
        return EDP_PROBE_SERIAL_BUFFER_TOO_SMALL;
    };
    if required > serial_capacity {
        // SAFETY: serial_out is non-null and capacity is at least one byte.
        unsafe {
            serial_out.write(0);
        }
        return EDP_PROBE_SERIAL_BUFFER_TOO_SMALL;
    }

    // SAFETY: the caller guarantees `serial_capacity` writable bytes and the
    // bounds check above proves `serial.len() + 1` fits. c_char and u8 both
    // occupy one byte, so byte-wise copy is valid.
    unsafe {
        std::ptr::copy_nonoverlapping(serial.as_ptr(), serial_out.cast::<u8>(), serial.len());
        serial_out.add(serial.len()).write(0);
    }

    EDP_PROBE_RECOGNIZED
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    const DISK4_LBA4: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk4/LBA4.bin"
    ));
    const DISK4_LBA7: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk4/LBA7.bin"
    ));

    #[test]
    fn ffi_recognizes_real_fixture_and_returns_serial() {
        let mut serial = [0 as c_char; EDP_PROBE_SERIAL_CAPACITY];
        // SAFETY: fixture arrays and output buffer satisfy the function contract.
        let rc = unsafe {
            edp_probe_reserved_sectors(
                DISK4_LBA4.as_ptr(),
                DISK4_LBA7.as_ptr(),
                serial.as_mut_ptr(),
                serial.len(),
            )
        };
        assert_eq!(rc, EDP_PROBE_RECOGNIZED);
        // SAFETY: success guarantees NUL termination inside the output buffer.
        let value = unsafe { CStr::from_ptr(serial.as_ptr()) }
            .to_str()
            .unwrap();
        assert!(!value.is_empty());
    }

    #[test]
    fn ffi_rejects_non_edp_media() {
        let zeros = [0u8; EDP_PROBE_SECTOR_SIZE];
        let mut serial = [1 as c_char; EDP_PROBE_SERIAL_CAPACITY];
        // SAFETY: arrays satisfy the function contract.
        let rc = unsafe {
            edp_probe_reserved_sectors(
                zeros.as_ptr(),
                zeros.as_ptr(),
                serial.as_mut_ptr(),
                serial.len(),
            )
        };
        assert_eq!(rc, EDP_PROBE_NOT_RECOGNIZED);
        assert_eq!(serial[0], 0);
    }

    #[test]
    fn ffi_validates_output_capacity() {
        let mut serial = [0 as c_char; 1];
        // SAFETY: arrays satisfy the function contract.
        let rc = unsafe {
            edp_probe_reserved_sectors(
                DISK4_LBA4.as_ptr(),
                DISK4_LBA7.as_ptr(),
                serial.as_mut_ptr(),
                serial.len(),
            )
        };
        assert_eq!(rc, EDP_PROBE_SERIAL_BUFFER_TOO_SMALL);
        assert_eq!(serial[0], 0);
    }
}

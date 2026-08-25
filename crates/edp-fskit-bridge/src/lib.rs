//! Narrow C ABI used by the native macOS FSKit extension.
//!
//! Swift owns FSKit objects and direct block-resource access. Rust owns EDP
//! recognition and transparent crypto. This crate is the intentionally small
//! boundary between those worlds.

use edp_core::probe::probe_edp_reserved_sectors;
use edp_core::volume::RawIo;
use std::ffi::{c_char, c_void};
use std::io;
use std::sync::Arc;

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

/// Callback success convention for the block-resource read thunk.
pub const EDP_RAW_CALLBACK_OK: i32 = 0;
/// Public bridge operation succeeded.
pub const EDP_RAW_IO_OK: i32 = 0;
/// A required handle, callback, pointer, or size is invalid.
pub const EDP_RAW_IO_INVALID_ARGUMENT: i32 = -10;
/// The Swift/host read callback failed or the requested range is out of bounds.
pub const EDP_RAW_IO_READ_FAILED: i32 = -11;

/// Reads exactly `length` bytes at `offset` into `out`.
///
/// The callback may be invoked concurrently once the handle is used by the EDP
/// volume layer. Its context must therefore remain alive and support concurrent
/// reads until `edp_raw_io_destroy` and every dependent volume handle are gone.
pub type EDPRawReadCallback =
    unsafe extern "C" fn(context: *mut c_void, offset: u64, out: *mut u8, length: usize) -> i32;

/// Rust-side adapter from a C/Swift callback to edp-core's `RawIo` trait.
struct CallbackRawIo {
    context: usize,
    read_callback: EDPRawReadCallback,
    size: u64,
}

// SAFETY: `RawIo` requires Send + Sync because encrypted reads may run in
// parallel. The C ABI contract above explicitly requires the caller-owned
// context and callback to remain valid and support concurrent reads for the
// lifetime of this object. The context is opaque to Rust and never dereferenced
// here except by passing it back to that callback.
unsafe impl Send for CallbackRawIo {}
unsafe impl Sync for CallbackRawIo {}

impl RawIo for CallbackRawIo {
    fn pread_exact(&self, off: u64, buf: &mut [u8]) -> io::Result<()> {
        if buf.is_empty() {
            return Ok(());
        }

        let len = u64::try_from(buf.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "read length overflow"))?;
        let end = off
            .checked_add(len)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "read range overflow"))?;
        if end > self.size {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "read exceeds callback RawIo size",
            ));
        }

        // SAFETY: the callback contract is established at handle creation. `buf`
        // provides exactly `buf.len()` writable bytes for the duration of the call.
        let rc = unsafe {
            (self.read_callback)(
                self.context as *mut c_void,
                off,
                buf.as_mut_ptr(),
                buf.len(),
            )
        };
        if rc == EDP_RAW_CALLBACK_OK {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "FSKit raw read callback failed with status {rc}"
            )))
        }
    }

    fn pwrite_all(&self, _off: u64, _data: &[u8]) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "native FSKit RawIo bridge is read-only",
        ))
    }

    fn size(&self) -> u64 {
        self.size
    }

    fn fsync(&self) -> io::Result<()> {
        // Read-only phase has no dirty state to flush.
        Ok(())
    }

    fn is_device(&self) -> bool {
        true
    }
}

/// Opaque C handle. Future encrypted-volume handles clone this Arc so the same
/// callback-backed RawIo can outlive the caller's temporary C handle safely.
pub struct EDPRawIoHandle {
    io: Arc<CallbackRawIo>,
}

impl EDPRawIoHandle {
    fn clone_io(&self) -> Arc<dyn RawIo> {
        self.io.clone()
    }
}

/// Create a read-only edp-core RawIo backed by an FSKit/host callback.
///
/// A null context is allowed because some C callbacks do not require state. A
/// null callback or zero logical size is rejected.
#[no_mangle]
pub extern "C" fn edp_raw_io_create(
    context: *mut c_void,
    read_callback: Option<EDPRawReadCallback>,
    size: u64,
) -> *mut EDPRawIoHandle {
    let Some(read_callback) = read_callback else {
        return std::ptr::null_mut();
    };
    if size == 0 {
        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(EDPRawIoHandle {
        io: Arc::new(CallbackRawIo {
            context: context as usize,
            read_callback,
            size,
        }),
    }))
}

/// Destroy a callback RawIo handle. Null is a no-op.
///
/// # Safety
///
/// `handle` must be null or a live pointer returned by `edp_raw_io_create` that
/// has not already been destroyed.
#[no_mangle]
pub unsafe extern "C" fn edp_raw_io_destroy(handle: *mut EDPRawIoHandle) {
    if !handle.is_null() {
        // SAFETY: caller contract guarantees this pointer came from Box::into_raw
        // in edp_raw_io_create and is consumed exactly once here.
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// Regression/smoke entry point that exercises the same `RawIo::pread_exact`
/// path future encrypted-volume handles will use.
///
/// # Safety
///
/// - `handle` must reference a live `EDPRawIoHandle`.
/// - when `length > 0`, `out` must point to at least `length` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn edp_raw_io_read_exact(
    handle: *const EDPRawIoHandle,
    offset: u64,
    out: *mut u8,
    length: usize,
) -> i32 {
    if handle.is_null() {
        return EDP_RAW_IO_INVALID_ARGUMENT;
    }
    if length == 0 {
        return EDP_RAW_IO_OK;
    }
    if out.is_null() {
        return EDP_RAW_IO_INVALID_ARGUMENT;
    }

    // SAFETY: pointers were validated above and the caller guarantees the output
    // region contains at least `length` writable bytes.
    let (handle, out) = unsafe {
        (
            &*handle,
            std::slice::from_raw_parts_mut(out, length),
        )
    };

    match handle.io.pread_exact(offset, out) {
        Ok(()) => EDP_RAW_IO_OK,
        Err(_) => EDP_RAW_IO_READ_FAILED,
    }
}

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

    struct TestReadContext {
        bytes: Vec<u8>,
    }

    unsafe extern "C" fn test_read_callback(
        context: *mut c_void,
        offset: u64,
        out: *mut u8,
        length: usize,
    ) -> i32 {
        if context.is_null() || (length > 0 && out.is_null()) {
            return -1;
        }

        // SAFETY: tests pass a live TestReadContext for the handle lifetime.
        let context = unsafe { &*(context.cast::<TestReadContext>()) };
        let Ok(start) = usize::try_from(offset) else {
            return -2;
        };
        let Some(end) = start.checked_add(length) else {
            return -2;
        };
        if end > context.bytes.len() {
            return -3;
        }
        if length > 0 {
            // SAFETY: output capacity is guaranteed by the bridge contract.
            unsafe {
                std::ptr::copy_nonoverlapping(context.bytes[start..end].as_ptr(), out, length);
            }
        }
        EDP_RAW_CALLBACK_OK
    }

    #[test]
    fn callback_raw_io_reads_exact_bytes() {
        let context = TestReadContext {
            bytes: (0u8..=255).cycle().take(4096).collect(),
        };
        let handle = edp_raw_io_create(
            (&context as *const TestReadContext).cast_mut().cast::<c_void>(),
            Some(test_read_callback),
            context.bytes.len() as u64,
        );
        assert!(!handle.is_null());

        let mut out = [0u8; 37];
        // SAFETY: handle and output buffer remain live for the call.
        let rc = unsafe { edp_raw_io_read_exact(handle, 123, out.as_mut_ptr(), out.len()) };
        assert_eq!(rc, EDP_RAW_IO_OK);
        assert_eq!(&out[..], &context.bytes[123..160]);

        // SAFETY: handle is consumed exactly once here.
        unsafe {
            edp_raw_io_destroy(handle);
        }
    }

    #[test]
    fn callback_raw_io_enforces_logical_size() {
        let context = TestReadContext {
            bytes: vec![0x5a; 512],
        };
        let handle = edp_raw_io_create(
            (&context as *const TestReadContext).cast_mut().cast::<c_void>(),
            Some(test_read_callback),
            context.bytes.len() as u64,
        );
        assert!(!handle.is_null());

        let mut out = [0u8; 32];
        // SAFETY: handle and output buffer remain live for the call.
        let rc = unsafe { edp_raw_io_read_exact(handle, 500, out.as_mut_ptr(), out.len()) };
        assert_eq!(rc, EDP_RAW_IO_READ_FAILED);

        // SAFETY: handle is consumed exactly once here.
        unsafe {
            edp_raw_io_destroy(handle);
        }
    }

    #[test]
    fn callback_raw_io_rejects_missing_callback() {
        let handle = edp_raw_io_create(std::ptr::null_mut(), None, 512);
        assert!(handle.is_null());
    }

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
        let value = unsafe { CStr::from_ptr(serial.as_ptr()) }.to_str().unwrap();
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

    #[test]
    fn callback_raw_io_arc_is_ready_for_volume_ownership() {
        let context = TestReadContext {
            bytes: vec![0; 512],
        };
        let handle = edp_raw_io_create(
            (&context as *const TestReadContext).cast_mut().cast::<c_void>(),
            Some(test_read_callback),
            context.bytes.len() as u64,
        );
        assert!(!handle.is_null());

        // SAFETY: handle remains live throughout this test.
        let raw: Arc<dyn RawIo> = unsafe { &*handle }.clone_io();
        assert_eq!(raw.size(), 512);
        assert!(raw.is_device());

        // SAFETY: cloned Arc is dropped before the caller-owned context leaves
        // scope, then the original handle is consumed exactly once.
        drop(raw);
        unsafe {
            edp_raw_io_destroy(handle);
        }
    }
}

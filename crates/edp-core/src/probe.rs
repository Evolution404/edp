//! Passwordless EDP disk recognition for filesystem probing.
//!
//! FSKit's `probeResource` must decide whether a block device belongs to EDP
//! before any user password is available.  Claiming media based on a single
//! four-byte magic would be too permissive, so this module requires two
//! independent reserved-sector signals:
//!
//! 1. LBA4 contains the plaintext `$$$<serial>$$$` EDP marker.
//! 2. LBA7 can be recovered without a password and contains the documented
//!    three consecutive EDPF entries for Boot / Share / Encrypt.

use crate::lba7::recover_lba7;

const LBA4_DELIMITER: &[u8; 3] = b"$$$";
const LBA7_ENTRY_SIZE: usize = 0x40;
const EXPECTED_PARTITION_TYPES: [u32; 3] = [1, 2, 4];

/// Evidence returned by the conservative passwordless EDP probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EdpProbeEvidence {
    /// Plaintext serial embedded in LBA4.
    pub serial: String,
    /// Rolling-XOR seed recovered from LBA7.
    pub lba7_k0: u16,
    /// Partition types observed in the first three LBA7 EDPF entries.
    pub partition_types: [u32; 3],
}

/// Extract the plaintext EDP serial marker from LBA4.
///
/// Real media place the marker at the beginning of the reserved sector.  The
/// parser tolerates a small prefix (up to 64 bytes) so this remains compatible
/// with devices that prepend a short vendor field, while still rejecting an
/// arbitrary `$$$...$$$` string elsewhere in a sector.
pub fn lba4_serial(raw: &[u8; 512]) -> Option<String> {
    let marker_start = raw
        .windows(LBA4_DELIMITER.len())
        .position(|window| window == LBA4_DELIMITER)?;
    if marker_start > 64 {
        return None;
    }

    let payload_start = marker_start + LBA4_DELIMITER.len();
    let rest = &raw[payload_start..];
    let payload_len = rest
        .windows(LBA4_DELIMITER.len())
        .position(|window| window == LBA4_DELIMITER)?;
    if !(1..=96).contains(&payload_len) {
        return None;
    }

    let serial = &rest[..payload_len];
    if serial
        .iter()
        .any(|byte| *byte == b'$' || !(byte.is_ascii_graphic() || *byte == b' '))
    {
        return None;
    }

    std::str::from_utf8(serial).ok().map(ToOwned::to_owned)
}

/// Conservatively identify EDP media using only passwordless reserved-sector
/// evidence suitable for an automatic filesystem probe.
pub fn probe_edp_reserved_sectors(lba4: &[u8; 512], lba7: &[u8; 512]) -> Option<EdpProbeEvidence> {
    let serial = lba4_serial(lba4)?;
    let (lba7_k0, plain) = recover_lba7(lba7).ok()?;

    for (index, expected_type) in EXPECTED_PARTITION_TYPES.iter().enumerate() {
        let offset = index * LBA7_ENTRY_SIZE;
        let entry = plain.get(offset..offset + LBA7_ENTRY_SIZE)?;
        if entry.get(..4)? != b"EDPF" {
            return None;
        }

        let partition_type = u32::from_le_bytes(entry.get(0x0c..0x10)?.try_into().ok()?);
        let start_sector = u64::from_le_bytes(entry.get(0x18..0x20)?.try_into().ok()?);
        let size_bytes = u64::from_le_bytes(entry.get(0x28..0x30)?.try_into().ok()?);

        if partition_type != *expected_type || start_sector == 0 || size_bytes == 0 {
            return None;
        }
    }

    Some(EdpProbeEvidence {
        serial,
        lba7_k0,
        partition_types: EXPECTED_PARTITION_TYPES,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISK4_LBA4: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk4/LBA4.bin"
    ));
    const DISK4_LBA7: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk4/LBA7.bin"
    ));
    const DISK5_LBA4: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk5/LBA4.bin"
    ));
    const DISK5_LBA7: &[u8; 512] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/real_disks/disk5/LBA7.bin"
    ));

    #[test]
    fn recognizes_real_reserved_sectors_without_password() {
        for (lba4, lba7) in [(DISK4_LBA4, DISK4_LBA7), (DISK5_LBA4, DISK5_LBA7)] {
            let evidence = probe_edp_reserved_sectors(lba4, lba7)
                .expect("real EDP reserved sectors must be recognized");
            assert!(!evidence.serial.is_empty());
            assert_eq!(evidence.partition_types, [1, 2, 4]);
        }
    }

    #[test]
    fn requires_both_independent_signals() {
        let zeros = [0u8; 512];
        assert!(probe_edp_reserved_sectors(&zeros, DISK4_LBA7).is_none());
        assert!(probe_edp_reserved_sectors(DISK4_LBA4, &zeros).is_none());
        assert!(probe_edp_reserved_sectors(&zeros, &zeros).is_none());
    }

    #[test]
    fn rejects_structurally_wrong_lba7_even_with_valid_lba4() {
        let mut corrupted = *DISK4_LBA7;
        // Preserve the first ciphertext word (which determines K0) but corrupt
        // later bytes so the recovered consecutive EDPF layout cannot survive.
        corrupted[0x40..0x80].fill(0);
        assert!(probe_edp_reserved_sectors(DISK4_LBA4, &corrupted).is_none());
    }
}

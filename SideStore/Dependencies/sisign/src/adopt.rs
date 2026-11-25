//! LiveContainer+SideStore addition: hand SideStore's certificate key to
//! isideload, so both use one certificate instead of requesting a second.

use std::ffi::c_char;
use std::path::PathBuf;

use isideload::util::{fs_storage::FsStorage, storage::SideloadingStorage};
use rsa::pkcs1::DecodeRsaPrivateKey;
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use rsa::RsaPrivateKey;
use sha2::{Digest, Sha256};

fn parse(key: &[u8]) -> Option<RsaPrivateKey> {
    match std::str::from_utf8(key) {
        Ok(pem) if pem.starts_with("-----BEGIN") => RsaPrivateKey::from_pkcs8_pem(pem)
            .ok()
            .or_else(|| RsaPrivateKey::from_pkcs1_pem(pem).ok()),
        _ => RsaPrivateKey::from_pkcs8_der(key)
            .ok()
            .or_else(|| RsaPrivateKey::from_pkcs1_der(key).ok()),
    }
}

fn adopt(storage_dir: PathBuf, apple_id: &str, key: &[u8]) -> Result<(), String> {
    let der = parse(key)
        .ok_or("unreadable RSA key")?
        .to_pkcs8_der()
        .map_err(|e| e.to_string())?;
    // Same location as CertificateIdentity::retrieve_private_key.
    let name = format!("{}/key", hex::encode(Sha256::digest(apple_id.as_bytes())));
    FsStorage::new(storage_dir)
        .store_data(&name, der.as_bytes())
        .map_err(|e| e.to_string())
}

/// Returns 0 on success, 1 on failure. `apple_id` must be spelled exactly as
/// it is passed to `si_apple_signin`.
///
/// # Safety
/// Strings must be NUL-terminated; `key` must be valid for `key_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn si_adopt_key(
    storage_dir: *const c_char,
    apple_id: *const c_char,
    key: *const u8,
    key_len: usize,
) -> i32 {
    let (Some(dir), Some(id)) = (
        crate::ffi_util::req_str(storage_dir),
        crate::ffi_util::req_str(apple_id),
    ) else {
        return 1;
    };
    if key.is_null() {
        return 1;
    }
    match adopt(PathBuf::from(dir), &id, std::slice::from_raw_parts(key, key_len)) {
        Ok(()) => 0,
        Err(e) => {
            tracing::error!("Couldn't adopt the signing key: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs8::LineEnding;

    #[test]
    fn stores_pem_and_der_keys_where_isideload_reads_them() {
        let key = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let der = key.to_pkcs8_der().unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let dir = std::env::temp_dir().join(format!("adopt-{}", std::process::id()));
        for input in [der.as_bytes(), pem.as_bytes()] {
            adopt(dir.clone(), "a@example.com", input).unwrap();
            let name = format!("{}/key", hex::encode(Sha256::digest(b"a@example.com")));
            let stored = FsStorage::new(dir.clone()).retrieve_data(&name).unwrap().unwrap();
            assert_eq!(stored, der.as_bytes());
        }
        assert!(adopt(dir.clone(), "a@example.com", b"junk").is_err());
        std::fs::remove_dir_all(dir).ok();
    }
}

use ente_core::{b64, crypto::Key};
use wasm_bindgen::prelude::*;

use crate::session::Session;

#[derive(Debug, thiserror::Error)]
#[error(transparent)]
pub struct Error(#[from] ente_collections::Error);

impl From<Error> for JsValue {
    fn from(error: Error) -> Self {
        crate::js_error(&error, None)
    }
}

#[wasm_bindgen(js_name = collectionsOpenKey)]
pub fn open_key(
    session: &Session,
    owner_id: i64,
    encrypted_key: &str,
    key_decryption_nonce: Option<String>,
) -> Result<String, Error> {
    Ok(ente_core::b64::encode(
        ente_collections::open_collection_key(
            session.inner(),
            owner_id,
            encrypted_key,
            key_decryption_nonce.as_deref(),
        )?
        .as_bytes(),
    ))
}

#[wasm_bindgen(js_name = collectionsPublicAlbumShareUrl)]
pub fn public_album_share_url(public_url: &str, collection_key: &str) -> Result<String, Error> {
    let collection_key = b64::decode(collection_key).map_err(ente_collections::Error::from)?;
    let collection_key =
        Key::try_from_slice(&collection_key).map_err(ente_collections::Error::from)?;
    Ok(ente_collections::public_album_share_url(
        public_url,
        &collection_key,
    ))
}

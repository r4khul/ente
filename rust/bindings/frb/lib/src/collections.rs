use ente_core::crypto::Key;
use flutter_rust_bridge::frb;

#[frb(non_opaque)]
pub enum CollectionsError {
    Other { message: String },
}

impl From<ente_collections::Error> for CollectionsError {
    fn from(error: ente_collections::Error) -> Self {
        Self::Other {
            message: ente_core::error::chain(&error),
        }
    }
}

#[frb(non_opaque)]
pub struct PublicAlbumLink {
    pub access_token: String,
    pub collection_key: Vec<u8>,
}

#[frb(sync)]
pub fn public_album_share_url(
    public_url: String,
    collection_key: Vec<u8>,
) -> Result<String, CollectionsError> {
    let collection_key =
        Key::try_from_slice(&collection_key).map_err(ente_collections::Error::from)?;
    Ok(ente_collections::public_album_share_url(
        &public_url,
        &collection_key,
    ))
}

#[frb(sync)]
pub fn parse_public_album_share_url(url: String) -> Result<PublicAlbumLink, CollectionsError> {
    let link = ente_collections::parse_public_album_share_url(&url)?;
    Ok(PublicAlbumLink {
        access_token: link.access_token,
        collection_key: link.collection_key.as_bytes().to_vec(),
    })
}

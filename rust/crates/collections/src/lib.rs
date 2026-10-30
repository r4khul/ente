pub mod client;

use ente_core::{
    Session, b64,
    crypto::{self, Key, Nonce, sealed, secretbox},
};
use url::Url;

const HEX_KEY_FRAGMENT_MIN_LENGTH: usize = 50;

pub struct PublicAlbumLink {
    pub access_token: String,
    pub collection_key: Key,
}

pub fn open_collection_key(
    session: &Session,
    owner_id: i64,
    encrypted_key: &str,
    key_decryption_nonce: Option<&str>,
) -> Result<Key> {
    let encrypted_key = b64::decode(encrypted_key)?;
    let key = if owner_id == session.user_id {
        let nonce = key_decryption_nonce.ok_or(Error::MissingKeyDecryptionNonce)?;
        secretbox::decrypt(
            &encrypted_key,
            &Nonce::try_from_slice(&b64::decode(nonce)?)?,
            &session.master_key,
        )?
    } else {
        sealed::open(
            &encrypted_key,
            &session.secret_key.public_key(),
            &session.secret_key,
        )?
    };
    Ok(Key::try_from_slice(&key)?)
}

pub fn public_album_share_url(public_url: &str, collection_key: &Key) -> String {
    format!(
        "{public_url}#{}",
        bs58::encode(collection_key.as_bytes()).into_string()
    )
}

pub fn parse_public_album_share_url(url: &str) -> Result<PublicAlbumLink> {
    let url = Url::parse(url).map_err(|_| Error::InvalidPublicLink("malformed URL"))?;
    let access_token = url
        .query_pairs()
        .find(|(name, value)| name == "t" && !value.is_empty())
        .map(|(_, value)| value.into_owned())
        .or_else(|| {
            url.path_segments()?
                .find(|segment| !segment.is_empty())
                .map(str::to_owned)
        })
        .ok_or(Error::InvalidPublicLink("missing access token"))?;
    let fragment = url
        .fragment()
        .filter(|fragment| !fragment.is_empty())
        .ok_or(Error::InvalidPublicLink("missing collection key"))?;
    let collection_key = if fragment.len() < HEX_KEY_FRAGMENT_MIN_LENGTH {
        bs58::decode(fragment).into_vec().ok()
    } else {
        hex::decode(fragment).ok()
    }
    .ok_or(Error::InvalidPublicLink("undecodable collection key"))?;
    Ok(PublicAlbumLink {
        access_token,
        collection_key: Key::try_from_slice(&collection_key)?,
    })
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Http(#[from] ente_core::http::Error),
    #[error(transparent)]
    Decode(#[from] b64::DecodeError),
    #[error(transparent)]
    Crypto(#[from] crypto::Error),
    #[error("Owned collection is missing its key decryption nonce")]
    MissingKeyDecryptionNonce,
    #[error("invalid collection {id}: {reason}")]
    InvalidCollection { id: i64, reason: &'static str },
    #[error("file changes did not advance the cursor for collection {0}")]
    CursorDidNotAdvance(i64),
    #[error("invalid source page: {0}")]
    InvalidPage(&'static str),
    #[error("invalid public album link: {0}")]
    InvalidPublicLink(&'static str),
}

#[cfg(test)]
mod tests {
    use super::*;
    use ente_core::{crypto::SecretKey, http::ApiConfig};

    #[test]
    fn opens_owned_and_shared_collection_keys() {
        let master_key = Key::generate();
        let secret_key = SecretKey::generate();
        let session = Session::new(
            ApiConfig {
                origin: "http://localhost".into(),
                client_package: None,
                client_version: None,
                user_agent: None,
                auth: None,
            },
            42,
            master_key,
            Key::generate(),
            secret_key,
        )
        .unwrap();

        let owned_key = Key::generate();
        let encrypted_owned_key = secretbox::encrypt(owned_key.as_bytes(), &session.master_key);
        assert_eq!(
            open_collection_key(
                &session,
                42,
                &b64::encode(&encrypted_owned_key.encrypted_data),
                Some(&b64::encode(encrypted_owned_key.nonce.as_bytes())),
            )
            .unwrap(),
            owned_key,
        );

        let shared_key = Key::generate();
        let encrypted_shared_key =
            sealed::seal(shared_key.as_bytes(), &session.secret_key.public_key()).unwrap();
        assert_eq!(
            open_collection_key(&session, 7, &b64::encode(&encrypted_shared_key), None).unwrap(),
            shared_key,
        );
    }

    const KEY_BYTES: [u8; 32] = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32,
    ];
    const KEY_BASE58: &str = "4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw";
    const KEY_HEX: &str = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    #[test]
    fn share_url_round_trips_through_base58_fragment() {
        let key = Key::try_from_slice(&KEY_BYTES).unwrap();
        let url = public_album_share_url("https://albums.ente.com/?t=token", &key);
        assert_eq!(
            url,
            format!("https://albums.ente.com/?t=token#{KEY_BASE58}")
        );
        let link = parse_public_album_share_url(&url).unwrap();
        assert_eq!(link.access_token, "token");
        assert_eq!(link.collection_key, key);
    }

    #[test]
    fn parses_legacy_hex_fragment_and_path_segment_token() {
        let key = Key::try_from_slice(&KEY_BYTES).unwrap();
        let link =
            parse_public_album_share_url(&format!("https://albums.ente.com/?t=token#{KEY_HEX}"))
                .unwrap();
        assert_eq!(link.collection_key, key);
        let link =
            parse_public_album_share_url(&format!("ente://albums.ente.com/token#{KEY_BASE58}"))
                .unwrap();
        assert_eq!(link.access_token, "token");
        assert_eq!(link.collection_key, key);
    }

    #[test]
    fn rejects_links_without_token_or_usable_key() {
        for url in [
            "not a url",
            &format!("https://albums.ente.com/#{KEY_BASE58}"),
            &format!("https://albums.ente.com/?t=#{KEY_BASE58}"),
            "https://albums.ente.com/?t=token",
            "https://albums.ente.com/?t=token#",
            "https://albums.ente.com/?t=token#0OIl",
            "https://albums.ente.com/?t=token#2VfUX",
        ] {
            assert!(parse_public_album_share_url(url).is_err(), "{url}");
        }
    }
}

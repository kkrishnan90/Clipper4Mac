use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("database error: {0}")]
    Db(String),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("image error: {0}")]
    Image(String),

    #[error("item not found: {0}")]
    NotFound(u64),

    #[error("blob missing: {0}")]
    BlobMissing(String),

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;

impl From<redb::DatabaseError> for CoreError {
    fn from(e: redb::DatabaseError) -> Self {
        CoreError::Db(e.to_string())
    }
}
impl From<redb::TransactionError> for CoreError {
    fn from(e: redb::TransactionError) -> Self {
        CoreError::Db(e.to_string())
    }
}
impl From<redb::TableError> for CoreError {
    fn from(e: redb::TableError) -> Self {
        CoreError::Db(e.to_string())
    }
}
impl From<redb::StorageError> for CoreError {
    fn from(e: redb::StorageError) -> Self {
        CoreError::Db(e.to_string())
    }
}
impl From<redb::CommitError> for CoreError {
    fn from(e: redb::CommitError) -> Self {
        CoreError::Db(e.to_string())
    }
}
impl From<image::ImageError> for CoreError {
    fn from(e: image::ImageError) -> Self {
        CoreError::Image(e.to_string())
    }
}

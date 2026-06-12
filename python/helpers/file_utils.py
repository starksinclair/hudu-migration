from typing import Literal, Optional
from dataclasses import dataclass

UploadType = Literal["public_photo", "attachment"]


@dataclass
class DownloadResult:
    data: bytes
    content_type: str
    filename: str
    size_bytes: int


@dataclass
class UploadResult:
    slug: str
    url: str


def invoke_hudu_attach_download(
    url: str,
    api_key: str,
    max_file_size_mb: int,
) -> Optional[DownloadResult]:
    """Download with auth fallback: no-auth -> x-api-key -> bearer -> api-key param."""
    raise NotImplementedError


def upload_file_to_hudu(
    data: bytes,
    filename: str,
    content_type: str,
    upload_type: UploadType,
    associated_id: Optional[int] = None,
) -> UploadResult:
    raise NotImplementedError


def test_and_register_file_signature(data: bytes, registry: set[str]) -> bool:
    """Returns False if already seen (duplicate), True if newly registered."""
    raise NotImplementedError

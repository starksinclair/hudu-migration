from typing import TypedDict, NotRequired
from dataclasses import dataclass, field

class PublicPhoto(TypedDict):
    """Inline embeddable image (/public_photo/<slug>)."""

    id: int
    slug: NotRequired[str]
    url: NotRequired[str]
    file_name: NotRequired[str]
    numeric_id: NotRequired[int]


class ArticleUpload(TypedDict):
    """Article file attachment (/file/<slug>)."""

    id: int
    slug: NotRequired[str]
    url: NotRequired[str]
    file_url: NotRequired[str]
    file_name: NotRequired[str]


class Article(TypedDict):
    id: int
    name: str
    content: str
    enable_sharing: bool
    company_id: NotRequired[int]
    folder_id: NotRequired[int]
    slug: NotRequired[str]
    url: NotRequired[str]
    public_photos: NotRequired[list[PublicPhoto]]
    uploads: NotRequired[list[ArticleUpload]]


class CreateArticlePayload(TypedDict, total=False):
    name: str
    content: str
    company_id: int
    folder_id: int
    enable_sharing: bool


# "/public_photo/old-slug" -> "/public_photo/new-slug"
PhotoMap = dict[str, str]

# "/file/old-path" -> "/file/new-path"
FileMap = dict[str, str]


@dataclass
class ArticleMapEntry:
    source_id: int
    target_id: int
    target_url: str
    name: str
    migrated_name: str
    photo_map: PhotoMap = field(default_factory=dict)
    file_map: FileMap = field(default_factory=dict)


# sourceId -> ArticleMapEntry
ArticleMap = dict[int, ArticleMapEntry]

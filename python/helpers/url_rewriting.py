from ..types.article import ArticleMap, PhotoMap, FileMap


def relink_article_content(
    content: str,
    article_map: ArticleMap,
    photo_map: PhotoMap,
    file_map: FileMap,
    source_base_url: str,
    target_base_url: str,
) -> str:
    """Rewrite internal URLs in article HTML content after migration:
    - Cross-article source URLs -> target URLs (via article_map)
    - Public photo slugs -> target paths (via photo_map)
    - Upload/file paths -> target paths (via file_map)
    - Remaining source domain references -> target base URL
    """
    raise NotImplementedError

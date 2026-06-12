from python.clients.hudu_client import HuduClient


def preflight_check(source: HuduClient, target: HuduClient) -> None:
    """Preflight check to ensure the source and target are compatible."""
    # Check if the source and target are compatible
    print(f"Source base URL: {source.base_url}")
    print(f"Target base URL: {target.base_url}")
    if source.base_url == target.base_url:
        raise ValueError("Source and target base URLs are the same")
    if source.api_key == target.api_key:
        raise ValueError("Source and target API keys are the same")
    return None
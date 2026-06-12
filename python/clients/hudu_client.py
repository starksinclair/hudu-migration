import json
import urllib.request
import urllib.parse
import urllib.error
from typing import Any, Optional


class HuduClient:
    """Low-level HTTPS client for the Hudu API using native urllib.

    All importers and exporters accept an instance of this class so the caller
    decides whether they are talking to the source or target instance.
    """

    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        # Common headers required for interacting with the Hudu API
        self.headers = {
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
        }

    def _execute_request(self, req: urllib.request.Request) -> Any:
        """Internal helper to execute a request, catch HTTP errors, and parse JSON."""
        try:
            with urllib.request.urlopen(req) as response:
                # Read, decode, and parse JSON response payload
                raw_data = response.read().decode("utf-8")
                return json.loads(raw_data) if raw_data else None
        except urllib.error.HTTPError as e:
            # Read detailed error message from the Hudu server if available
            try:
                error_body = e.read().decode("utf-8")
            except Exception:
                error_body = "Could not read error body."
            raise RuntimeError(f"HTTP Error {e.code}: {e.reason}\nDetails: {error_body}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Network connection failed: {e.reason}") from e

    # ------------------------------------------------------------------
    # Core HTTP verbs
    # ------------------------------------------------------------------

    def get(self, path: str, params: Optional[dict[str, Any]] = None) -> Any:
        """Send a GET request and return the parsed JSON body."""
        url = f"{self.base_url}{path}"
        if params:
            encoded_params = urllib.parse.urlencode(params)
            url = f"{url}?{encoded_params}"

        req = urllib.request.Request(url, headers=self.headers, method="GET")
        return self._execute_request(req)

    def post(self, path: str, body: Any = None) -> Any:
        """Send a POST request with a JSON body and return the parsed JSON response."""
        url = f"{self.base_url}{path}"
        headers = {**self.headers, "Content-Type": "application/json"}
        
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        return self._execute_request(req)

    def put(self, path: str, body: Any = None) -> Any:
        """Send a PUT request with a JSON body and return the parsed JSON response."""
        url = f"{self.base_url}{path}"
        headers = {**self.headers, "Content-Type": "application/json"}
        
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method="PUT")
        return self._execute_request(req)

    def patch(self, path: str, body: Any = None) -> Any:
        """Send a PATCH request with a JSON body and return the parsed JSON response."""
        url = f"{self.base_url}{path}"
        headers = {**self.headers, "Content-Type": "application/json"}
        
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method="PATCH")
        return self._execute_request(req)

    def delete(self, path: str) -> None:
        """Send a DELETE request."""
        url = f"{self.base_url}{path}"
        req = urllib.request.Request(url, headers=self.headers, method="DELETE")
        self._execute_request(req)

    # ------------------------------------------------------------------
    # Pagination helper
    # ------------------------------------------------------------------

    def get_all_pages(self, path: str, items_key: str) -> list[Any]:
        """Fetch every page of a paginated endpoint and return a flat list.

        Args:
            path: API path, e.g. "/api/v1/companies"
            items_key: JSON key that holds the list in each page response,
                       e.g. "companies"
        """
        all_items = []
        current_page = 1
        per_page = 50  # Hudu standard chunk size per API page

        while True:
            params = {"page": current_page, "per_page": per_page}
            response_data = self.get(path, params=params)
            
            # Extract items list using targeted key
            items = response_data.get(items_key, [])
            if not items:
                break
                
            all_items.extend(items)
            
            # Check if we have gathered fewer items than requested, signaling the final page
            if len(items) < per_page:
                break
                
            current_page += 1

        return all_items

    # ------------------------------------------------------------------
    # File / multipart helper
    # ------------------------------------------------------------------

    def post_multipart(
        self, 
        path: str, 
        fields: dict[str, Any], 
        file_data: Optional[bytes] = None, 
        filename: Optional[str] = None, 
        content_type: Optional[str] = None
    ) -> Any:
        """Send a multipart/form-data POST (used for file and photo uploads)."""
        url = f"{self.base_url}{path}"
        boundary = "----HuduMigrationBoundaryChunkXYZ123"
        
        # Build the multipart byte body payload manually
        body_parts = []

        # 1. Append text metadata form fields
        for key, value in fields.items():
            body_parts.append(f"--{boundary}".encode("utf-8"))
            body_parts.append(f'Content-Disposition: form-data; name="{key}"'.encode("utf-8"))
            body_parts.append(b"")
            body_parts.append(str(value).encode("utf-8"))

        # 2. Append binary data stream if asset file attachment exists
        if file_data is not None and filename:
            c_type = content_type or "application/octet-stream"
            body_parts.append(f"--{boundary}".encode("utf-8"))
            body_parts.append(f'Content-Disposition: form-data; name="file"; filename="{filename}"'.encode("utf-8"))
            body_parts.append(f"Content-Type: {c_type}".encode("utf-8"))
            body_parts.append(b"")
            body_parts.append(file_data)

        # 3. Close payload boundary definition block
        body_parts.append(f"--{boundary}--".encode("utf-8"))
        body_parts.append(b"")

        # Combine items into unified byte sequence
        payload = b"\r\n".join(body_parts)

        # Merge custom multi-part payload headers with standard authentication blocks
        headers = {
            **self.headers,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(payload))
        }

        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        return self._execute_request(req)
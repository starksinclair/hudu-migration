from typing import TypedDict, NotRequired, Literal

PasswordFolderSecurity = Literal["all_users", "specific"]


class PasswordFolder(TypedDict):
    id: int
    name: str
    security: PasswordFolderSecurity
    description: NotRequired[str]
    company_id: NotRequired[int]
    allowed_groups: NotRequired[list[str]]


class Password(TypedDict):
    id: int
    name: str
    password: str
    username: NotRequired[str]
    company_id: NotRequired[int]
    password_folder_id: NotRequired[int]
    notes: NotRequired[str]
    description: NotRequired[str]
    otp_secret: NotRequired[str]
    otp_uri: NotRequired[str]
    login_url: NotRequired[str]
    slug: NotRequired[str]


class CreatePasswordFolderPayload(TypedDict, total=False):
    name: str
    description: str
    security: PasswordFolderSecurity
    allowed_groups: list[str]


class CreatePasswordPayload(TypedDict, total=False):
    name: str
    password: str
    username: str
    company_id: int
    password_folder_id: int
    notes: str
    description: str
    otp_secret: str
    otp_uri: str
    login_url: str


# sourceId -> targetId
PasswordFolderMap = dict[int, int]

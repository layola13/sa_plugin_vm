from __future__ import annotations

class FileReference:
    def __init__(self, path: str, members: list[int]) -> None:
        self.path = path
        self.members = members

    def touches(self) -> list[int]:
        return list(self.members)

FILE_REFERENCES = [
    FileReference(path='original/user-triggered', members=[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
]

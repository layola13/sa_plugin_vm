from __future__ import annotations

class FileReference:
    def __init__(self, path: str, members: list[int]) -> None:
        self.path = path
        self.members = members

    def touches(self) -> list[int]:
        return list(self.members)

FILE_REFERENCES = [
    FileReference(path='dlopen/dlsym', members=[0, 2, 6]),
    FileReference(path='original/user-triggered', members=[0, 1, 3, 4, 5, 6, 7, 8, 9]),
    FileReference(path='projects/sci/docs', members=[0, 1, 3, 4, 5, 6, 7, 8, 9]),
    FileReference(path='src/ffi.zig', members=[0, 9]),
    FileReference(path='src/parser.zig', members=[0, 9]),
    FileReference(path='src/plugin.zig', members=[0, 9]),
    FileReference(path='src/vm.zig', members=[0, 9]),
    FileReference(path='todo.md', members=[0, 9]),
    FileReference(path='继续按照todo.md', members=[0, 1, 3, 4, 5, 6, 7, 8, 9]),
]

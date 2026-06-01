from __future__ import annotations

class FileReference:
    def __init__(self, path: str, members: list[int]) -> None:
        self.path = path
        self.members = members

    def touches(self) -> list[int]:
        return list(self.members)

FILE_REFERENCES = [
    FileReference(path='README.md', members=[1, 2]),
    FileReference(path='TheAlgorithms/Sa', members=[0, 1, 6, 7]),
    FileReference(path='home/vscode/projects/TheAlgorithms/Sa/README.md', members=[1, 2]),
    FileReference(path='home/vscode/projects/TheAlgorithms/Sa/data_structures/fenwick_tree_2d.sa', members=[1, 2]),
    FileReference(path='home/vscode/projects/sa_plugins/sa_plugin_vm/src/parser.zig', members=[1, 2]),
    FileReference(path='home/vscode/projects/sa_plugins/sa_plugin_vm/src/plugin.zig', members=[0, 1, 2]),
    FileReference(path='home/vscode/projects/sa_plugins/sa_plugin_vm/src/vm.zig', members=[0, 1, 2]),
    FileReference(path='original/user-triggered', members=[0, 1, 2, 3, 4, 5]),
    FileReference(path='projects/sci/demos', members=[3, 5]),
    FileReference(path='sci/demos', members=[3, 5]),
    FileReference(path='src/parser.zig', members=[1, 2]),
    FileReference(path='src/plugin.zig', members=[0, 1, 2]),
    FileReference(path='src/vm.zig', members=[0, 1, 2, 7]),
]

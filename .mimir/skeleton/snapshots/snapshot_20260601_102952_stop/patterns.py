from __future__ import annotations

class PatternGroup:
    def __init__(self, name: str, members: list[int]) -> None:
        self.name = name
        self.members = members

    def repeats(self) -> list[int]:
        return list(self.members)

REPEATED_PATTERNS = [
    PatternGroup(name='problem', members=[0, 1, 2, 3, 6, 7]),
]

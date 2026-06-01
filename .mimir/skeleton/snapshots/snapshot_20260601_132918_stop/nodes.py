from __future__ import annotations

class MemoryNode:
    def __init__(self, index: int, memory_type: str, preview: str, topics: list[str], files: list[str]) -> None:
        self.index = index
        self.memory_type = memory_type
        self.preview = preview
        self.topics = topics
        self.files = files

    def signature(self) -> tuple[int, str]:
        return (self.index, self.memory_type)

NODES = [
    MemoryNode(index=0, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=1, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=2, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=3, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=4, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=5, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=6, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=7, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=8, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=9, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=10, memory_type='decision', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['goal', 'work', 'blocked'], files=['original/user-triggered']),
    MemoryNode(index=11, memory_type='problem', preview='> <goal_context> Continue working toward the active thread goal.  The objective below is user-provided data. Treat it as', topics=['benchmark', 'timeout', 'goal'], files=['N/A', 'README.md', 'Sa/Rust', 'TheAlgorithms/Sa', 'bench_merge/sorting', 'home/vscode/projects/TheAlgorithms/Sa', 'home/vscode/projects/TheAlgorithms/Sa/README.md', 'home/vscode/projects/sa_plugins/sa_plugin_vm', 'home/vscode/projects/sa_plugins/scripts/plugin-manager.sh', 'native/Rust', 'original/user-triggered', 'plugin-manager.sh', 'scripts/plugin-manager.sh', 'search/merge', 'src/vm.zig', 'tests/trait_vtable.sa', 'trait/vtable', '允许结构体/胖指针覆盖', '分配/释放常量替换内容', '包括未跟踪的备份/临时', '区分本次需要提交的代码/文档变更与自动生成的', '是预处理/解析/解释执行总耗时', '最终代码/文档状态已验证', '测试/构建还在跑', '的现有测试/示例', '编译/运行', '转换后用错误切片类型/长度释放']),
]

NODE_TYPES = {'decision': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 'problem': [11]}
NODE_TOPICS = {'benchmark': [11], 'blocked': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 'goal': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], 'timeout': [11], 'work': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}
NODE_FILES = {'N/A': [11], 'README.md': [11], 'Sa/Rust': [11], 'TheAlgorithms/Sa': [11], 'bench_merge/sorting': [11], 'home/vscode/projects/TheAlgorithms/Sa': [11], 'home/vscode/projects/TheAlgorithms/Sa/README.md': [11], 'home/vscode/projects/sa_plugins/sa_plugin_vm': [11], 'home/vscode/projects/sa_plugins/scripts/plugin-manager.sh': [11], 'native/Rust': [11], 'original/user-triggered': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], 'plugin-manager.sh': [11], 'scripts/plugin-manager.sh': [11], 'search/merge': [11], 'src/vm.zig': [11], 'tests/trait_vtable.sa': [11], 'trait/vtable': [11], '允许结构体/胖指针覆盖': [11], '分配/释放常量替换内容': [11], '包括未跟踪的备份/临时': [11], '区分本次需要提交的代码/文档变更与自动生成的': [11], '是预处理/解析/解释执行总耗时': [11], '最终代码/文档状态已验证': [11], '测试/构建还在跑': [11], '的现有测试/示例': [11], '编译/运行': [11], '转换后用错误切片类型/长度释放': [11]}

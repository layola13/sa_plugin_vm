# __index__.py  (auto-generated navigation bus)
# ════════════════════════════════════════════════════════════════
# CONVERSATION SKELETON INDEX — compact navigation layer
# Read this file first, then open a specific snapshot package only if needed.
# ════════════════════════════════════════════════════════════════
from __future__ import annotations

# ── 1. Global Overview ─────────────────────────────────────────
SNAPSHOT_COUNT = 3
TOTAL_MEMORY_COUNT = 30
GLOBAL_TOP_TOPICS = ['goal', 'work', 'blocked', 'crash', 'parser']
GLOBAL_TOP_FILES = ['original/user-triggered', 'projects/sci/docs', '继续按照todo.md', 'TheAlgorithms/Sa', 'src/vm.zig']
GLOBAL_TASK_TOPICS = []

# ── 2. Snapshot Routing ────────────────────────────────────────
SNAPSHOTS = ['snapshot_20260531_212634_stop', 'snapshot_20260601_102952_stop', 'snapshot_20260601_132918_stop']
LATEST_SNAPSHOT = 'snapshot_20260601_132918_stop'
SNAPSHOT_SUMMARIES = [{'name': 'snapshot_20260531_212634_stop', 'summary_module': None, 'nodes_module': 'snapshot_20260531_212634_stop.nodes', 'edges_module': 'snapshot_20260531_212634_stop.edges', 'memory_count': 10, 'memory_types': ['decision', 'emotional', 'milestone'], 'task_description': '', 'task_topics': [], 'top_topics': ['goal', 'work', 'blocked'], 'top_files': ['original/user-triggered', 'projects/sci/docs', '继续按照todo.md'], 'mtime': 1780233994}, {'name': 'snapshot_20260601_102952_stop', 'summary_module': None, 'nodes_module': 'snapshot_20260601_102952_stop.nodes', 'edges_module': 'snapshot_20260601_102952_stop.edges', 'memory_count': 8, 'memory_types': ['decision', 'milestone', 'problem'], 'task_description': '', 'task_topics': [], 'top_topics': ['goal', 'crash', 'parser'], 'top_files': ['original/user-triggered', 'TheAlgorithms/Sa', 'src/vm.zig'], 'mtime': 1780280992}, {'name': 'snapshot_20260601_132918_stop', 'summary_module': None, 'nodes_module': 'snapshot_20260601_132918_stop.nodes', 'edges_module': 'snapshot_20260601_132918_stop.edges', 'memory_count': 12, 'memory_types': ['decision', 'problem'], 'task_description': '', 'task_topics': [], 'top_topics': ['goal', 'blocked', 'work'], 'top_files': ['original/user-triggered', 'N/A', 'README.md'], 'mtime': 1780291758}]

# ── 3. Session Routing ─────────────────────────────────────────
SESSIONS = ['019e7de4-cac7-7433-9902-52b395a95b76']
LATEST_SESSION = '019e7de4-cac7-7433-9902-52b395a95b76'
SESSION_SUMMARIES = [{'session_id': '019e7de4-cac7-7433-9902-52b395a95b76', 'summary_module': 'sessions.019e7de4-cac7-7433-9902-52b395a95b76', 'snapshots': ['snapshot_20260531_212634_stop', 'snapshot_20260601_102952_stop', 'snapshot_20260601_132918_stop'], 'latest_snapshot': 'snapshot_20260601_132918_stop', 'latest_task_description': '<goal_context>', 'latest_task_topics': ['goal_context', 'turn_aborted'], 'updated_at': '2026-06-01T05:29:18Z'}]

def available_snapshots() -> list[str]:
    return list(SNAPSHOTS)

def latest_snapshot() -> str | None:
    return LATEST_SNAPSHOT

def summary_for(snapshot_name: str) -> dict | None:
    for item in SNAPSHOT_SUMMARIES:
        if item['name'] == snapshot_name:
            return dict(item)
    return None

def summary_module_for(snapshot_name: str) -> str | None:
    summary = summary_for(snapshot_name)
    if summary is None:
        return None
    return summary['summary_module']

def nodes_module_for(snapshot_name: str) -> str | None:
    summary = summary_for(snapshot_name)
    if summary is None:
        return None
    return summary['nodes_module']

def edges_module_for(snapshot_name: str) -> str | None:
    summary = summary_for(snapshot_name)
    if summary is None:
        return None
    return summary['edges_module']

def task_topics(snapshot_name: str) -> list[str]:
    summary = summary_for(snapshot_name)
    if summary is None:
        return []
    return list(summary['task_topics'])

def task_description(snapshot_name: str) -> str | None:
    summary = summary_for(snapshot_name)
    if summary is None:
        return None
    return summary['task_description']

def top_topics(snapshot_name: str) -> list[str]:
    summary = summary_for(snapshot_name)
    if summary is None:
        return []
    return list(summary['top_topics'])

def top_files(snapshot_name: str) -> list[str]:
    summary = summary_for(snapshot_name)
    if summary is None:
        return []
    return list(summary['top_files'])

def available_sessions() -> list[str]:
    return list(SESSIONS)

def latest_session() -> str | None:
    return LATEST_SESSION

def session_summary_for(session_id: str) -> dict | None:
    for item in SESSION_SUMMARIES:
        if item['session_id'] == session_id:
            return dict(item)
    return None

def global_overview() -> dict:
    return {
        'snapshot_count': SNAPSHOT_COUNT,
        'total_memory_count': TOTAL_MEMORY_COUNT,
        'global_top_topics': list(GLOBAL_TOP_TOPICS),
        'global_top_files': list(GLOBAL_TOP_FILES),
        'global_task_topics': list(GLOBAL_TASK_TOPICS),
        'latest_snapshot': LATEST_SNAPSHOT,
        'session_count': len(SESSIONS),
        'latest_session': LATEST_SESSION,
    }


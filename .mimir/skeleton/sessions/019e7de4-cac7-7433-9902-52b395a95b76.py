from __future__ import annotations

SESSION_ID = '019e7de4-cac7-7433-9902-52b395a95b76'
SNAPSHOTS = ['snapshot_20260531_212634_stop', 'snapshot_20260601_102952_stop']
LATEST_SNAPSHOT = 'snapshot_20260601_102952_stop'
LATEST_TASK_DESCRIPTION = '<goal_context>'
LATEST_TASK_TOPICS = ['goal_context', 'turn_aborted', 'sa_vm']
UPDATED_AT = '2026-06-01T02:29:52Z'

def session_overview() -> dict:
    return {
        'session_id': SESSION_ID,
        'snapshots': list(SNAPSHOTS),
        'latest_snapshot': LATEST_SNAPSHOT,
        'latest_task_description': LATEST_TASK_DESCRIPTION,
        'latest_task_topics': list(LATEST_TASK_TOPICS),
        'updated_at': UPDATED_AT,
    }

# Workspace Rules & Context

This file governs agent behavior in this workspace and ensures continuity across sessions.

## 🛠️ Agent Bootstrapping (Amnesia Prevention)

Every time a new session starts, the agent **MUST** follow these steps before executing any task:
1. **Read the Dev Journal**: View the latest entries in [.agents/journal.md](.agents/journal.md) to understand the current workspace state, active tasks, and notes from previous sessions.
2. **Consult the Documentation Map**: For architectural or operational guidance, refer to the centralized documentation map at [.agents/doc_map.md](.agents/doc_map.md).
3. **Align with Repository Context**: Review the general repository context (Build, Architecture, Key Patterns, Git Conventions) defined in the root [AGENTS.md](AGENTS.md).
4. **Check Git Status**: Align with the current state of the workspace by checking untracked/modified files.

## 📓 Dev Journal Enforcement

Before completing a task, ending a session, or providing a final response, the agent **MUST** append a new entry to the Dev Journal at [.agents/journal.md](.agents/journal.md).
Each entry must follow this format:
```markdown
### Session: YYYY-MM-DD [UTC / Local Time]
- **Goal**: What was the primary objective of the session.
- **Changes Completed**: Bullet points of files modified, new files created, deleted, or config updates.
- **Findings & Decisions**: Crucial learnings, architectural choices, build outcomes, or benchmark results.
- **Current State**: Status of work (`COMPLETED`, `IN_PROGRESS`, `BLOCKED`).
- **Next Steps**: Explicit actions/recommendations for the next agent/session.
```

## 📚 Centralized Documentation

To locate documentation quickly:
- **Main Map**: Refer to [.agents/doc_map.md](.agents/doc_map.md) for a categorized index of all `docs/` and `notes/` files.
- **Local Context**: Refer to the root [AGENTS.md](AGENTS.md) for quick-access instructions on building, architecture, files, and conventions.

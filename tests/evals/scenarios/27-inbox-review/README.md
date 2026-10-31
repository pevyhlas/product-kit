# Inbox review reconciles answers before asking, updates governing intent and respects filters

The owner invokes the installed inbox workflow for `copy` topics. One answer is valid despite
reordered options; a second answer cites an older question revision and needs clarification.
Another topic already has an answer but is outside the selected scope. An agent-only test task
was incorrectly put in the inbox. The agent must update the governing requirement and its change,
preserve the execution hold, route the task, retain the stale answer and ask just its clarification.

Assertions check actual spec text, stable IDs and answer provenance, unmodified out-of-scope
content, no implementation/commit/archive, and the next question in the transcript. Native
interactive controls require a separate human pilot; this scenario uses the conversational fallback.

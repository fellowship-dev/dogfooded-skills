# Search feedback behavioral checks

Status: experimental. These are review scenarios, not claims of five production workloads or measured retrieval gains. The integrating host must test its storage, transcript parser, budgets and ranking implementation independently.

| Request and evidence | Expected behavior |
|---|---|
| "Find the repository I starred last week"; repository created last week, star time unknown | Exclude from date-qualified hits; show separate undated candidate if useful, with source link |
| Search returns two papers; user says "The second one, https://example.org/b, is irrelevant" | Log exact user quote and source turn against that search and revision; no labeler page or repeated rating question |
| Agent says "These look relevant"; user changes topic | Log usage; no human relevance feedback |
| User supplies a missing URL; item was imported only after original search | Historical collection gap, not original retrieval miss |
| Weekly model predicts a result relevant, no human verdict exists | Model evidence only; cannot become independent evaluation gold |
| Two paraphrases in different sessions mention the same target | Keep related intent evidence together; do not split it across optimization and acceptance |
| Candidate improves development but worsens independent acceptance | Retain incumbent, record rejected candidate and acceptance exposure |
| Repeat the same query after cache hit | Fresh usage ID with full response; reuse cached judgments without extra inference |

Motivating user correction: search happens mid-conversation; gather normal conversational feedback and recover omissions weekly, without a separate labeler UI. One weekly recovery-and-learning run; do not replace unrelated schedules.

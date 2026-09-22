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


Public discovery additions:
- A user requests meme reply opportunities: all acquired unique posts are screened;
  a manual shortlist is not represented as full semantic screening.
- A matching question has a parent complaining about repetitive promotional replies:
  preserve parent context and reject or flag the apparent opportunity.
- A 109-item dataset is replayed forty times: report 109 unique items, not 4,360.
- The user confirms displayed results: preserve exact response/source-turn mapping;
  do not label unseen or rejected candidates negative.
- A corpus has only model judgments: throughput is measurable, human precision is
  unavailable; it cannot be promoted to independent acceptance gold.

- Same target and query, different meme or announcement asset: recompute fit using
  the changed campaign identity; do not reuse the earlier fit judgment.
- New parent/reply evidence reveals hostility or an existing answer: invalidate
  the deep-stage judgment using context revisions and coverage, preserving the
  unchanged first-stage screening cache where its actual inputs are identical.

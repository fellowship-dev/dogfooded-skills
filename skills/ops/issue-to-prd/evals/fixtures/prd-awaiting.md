# Let requesters delete attachments from a request (#512)

**Status:** awaiting-owner-decisions

**Source:** https://github.com/example/app/issues/512

## Problem Statement
Requesters cannot remove an attachment they uploaded by mistake; support deletes them by hand
(`app/controllers/attachments_controller.rb:12` has no destroy action).

## User Stories
- As a requester, I want to delete an attachment I uploaded so that wrong files do not reach the lawyer.

## Success Metrics
- Support tickets asking to remove an attachment: from 6 in September to 0.

## Smallest version that works
A destroy action on the requester's own attachments, exposed as a delete button on the request page.

## Measurable Impact
Not applicable — the issue states no goal, eval, or outcome contract.

## Scope

### In Scope
- Delete button and destroy endpoint for the requester's own attachments.

### Out of Scope
- Bulk deletion and restoring deleted attachments.

## What this lets us delete
The manual support runbook step `docs/support.md:40` ("remove attachment via console").

## Technical Requirements
- Destroy follows the existing `DocumentsController#destroy` pattern (`app/controllers/documents_controller.rb:58`).
- Deletion is allowed at every request state (pending Q1).

## Implementation Constraints
- Do NOT add a soft-delete framework; hard delete the record and the stored file.
- Only touch the attachments controller, its route, the request page view and their specs.

## Testing Strategy

### Prerequisites
- None; `spec/factories/attachments.rb` already exists.

### Pre-merge Verification
- [ ] Request spec: owner deletes own attachment; another user gets 403.

## Questions for the owner

### Q1. Can a requester delete an attachment after the request is submitted?
- **Why it matters:** a submitted request may already be under review (`app/models/request.rb:30`).
- **Options:**
  - A. Yes, at any state, with no constraints.
  - B. Only before submission.
- **Recommended:** A — the issue states no constraint, and B blocks the main case (a wrong file noticed after submitting).
- **Blocks implementation:** yes

# GitHub queries — what `dxm-ingest-github.sh` asks for, and why

Every call goes through `gh` (which carries auth). No token is ever read,
stored, printed or passed. `gh` is shimmed in some environments and will run
**unauthenticated without complaint** if it cannot resolve a target repo, so
every invocation carries `GH_REPO=owner/name`.

---

## 1. Repo enumeration

```bash
gh repo list "$ORG" --limit "$MAX" --no-archived --source \
  --json nameWithOwner,isArchived,isFork,isEmpty,defaultBranchRef
```

Skipped, and why:

| Skipped | Reason |
| --- | --- |
| archived | frozen history; contributes a flat tail that reads as a slowdown |
| forks | inherited upstream history would double-count other people's commits as yours |
| empty | nothing to clone; the assertion path would report a false shallow |
| no `defaultBranchRef` | same |

`--no-archived` and `--source` do the filtering server-side; the `jq` filter
repeats it so an older `gh` without those flags still behaves.

---

## 2. Pull requests — one GraphQL document, paged manually

```graphql
query($owner:String!,$name:String!,$n:Int!,$cursor:String){
  repository(owner:$owner,name:$name){
    pullRequests(first:$n, after:$cursor,
                 orderBy:{field:UPDATED_AT,direction:DESC},
                 states:[OPEN,CLOSED,MERGED]){
      pageInfo{ hasNextPage endCursor }
      nodes{
        number title state isDraft
        createdAt mergedAt closedAt updatedAt
        additions deletions changedFiles
        baseRefName headRefName
        bodyText
        author{ login __typename }
        mergedBy{ login }
        mergeCommit{ oid }
        labels(first:20){ nodes{ name } }
        reviews{ totalCount }
        commits(first:100){ totalCount nodes{ commit{ oid authoredDate } } }
      }
    }
  }
}
```

### Why not `gh api --paginate`

`--paginate` fetches **every** page. The entire point of the watermark is to
stop early. Pagination is therefore driven by hand: read
`pageInfo.endCursor`, and stop at the first node whose `updatedAt` is at or
before the stored watermark. Because the order is `UPDATED_AT desc`, that node
is a hard floor — nothing after it can be new.

`updatedAt` is compared as a string. ISO-8601 UTC sorts lexicographically in
chronological order, which is why the schema insists on the `Z` form.

### Why `UPDATED_AT` and not `CREATED_AT` or `MERGED_AT`

A PR opened last month and merged today must be re-fetched today. Only
`updatedAt` moves whenever anything about the PR changes, so it is the only
ordering that cannot miss a late edit. The cost is re-fetching PRs that were
merely commented on; that is the cheap half of the trade.

### Node budget

`first:50` PRs × `first:100` commits = 5 000 nodes, comfortably inside GitHub's
500 000-node ceiling but heavy enough that a repo with very large PRs can time
the query out. `--page-size` exists for exactly that; lower it to 25 and retry.

### `commits(first:100)` truncation

PR commits come back **oldest first**, so `first:100` always contains the
earliest one and `first_commit_at` — the start of cycle time — is correct even
on a 300-commit PR. What truncation costs is `pr_commits` rows past #100, which
can only cause an AI-assisted PR to be missed, never a false positive. The run
counts these and reports `prs_commit_list_truncated`.

### `mergeCommit{ oid }` — the squash-merge fix

A squash-merged PR's branch commits never reach the default branch, so
`dxm-ingest-git.sh` never sees them and their `Co-Authored-By` trailers would
disappear from the analysis entirely. The squash commit *is* on the default
branch and GitHub concatenates the branch commit messages (trailers included)
into it. So `pr_commits` stores the branch SHAs **and** the merge/squash SHA,
and `v_prs_enriched.is_ai_assisted` finds the trailer via whichever one exists.

### `author{ __typename }`

`Bot` is GitHub stating outright that the account is an app. That is better
evidence than any regex, and is recorded with `bot_reason='github:author.__typename=Bot'`.

Note the asymmetry: GraphQL reports a bot PR author as `some-app`, while the
REST/commit side reports the same account as `some-app[bot]`. Both become
`identities` rows and both are flagged as bots (by `__typename` and by the
`\[bot\]$` pattern respectively), so no human is double-counted. Merging them
would need an account-ID lookup that buys nothing, since bots are excluded
either way.

---

## 3. Identity resolution — per distinct email, not per commit

The naive approach — page `repos/{owner}/{repo}/commits` and read
`.author.login` — is 100 commits per request. A 20 000-commit repo is 200
requests, per repo, per run.

But logins are being resolved for **emails**, and a repo with 20 000 commits
usually has ~40 distinct author emails. So the query is built from the commits
already in the database:

```sql
SELECT c.author_email, MIN(c.sha), MAX(c.sha)
  FROM commits c
  LEFT JOIN identity_emails e ON e.email = c.author_email
 WHERE c.repo_id = ? AND (e.email IS NULL)
 GROUP BY c.author_email;
```

and resolved in batches of 40 emails, aliased into one document:

```graphql
query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    a0: object(oid:"<sha>"){ ... on Commit { author { email name user { login } } } }
    b0: object(oid:"<other sha>"){ ... on Commit { author { email name user { login } } } }
    a1: ...
  }
}
```

200 requests become **one**. GitHub does the email→account mapping server-side,
which is what makes corporate addresses resolve without any client-side
guessing.

Two candidate SHAs (`a`/`b`) per email because `object(oid:)` returns `null` for
a commit GitHub does not have — an unpushed local commit, or one orphaned by a
history rewrite. The first non-null answer wins.

### `user: null` is an answer, not a failure

It means no GitHub account is linked to that email — a deleted account, or a
machine identity. The row is written with `identity_id IS NULL` and
`resolution_source='unresolved'`, which is precisely what `v_unresolved_emails`
surfaces as the human-attention queue.

**There is deliberately no email-mining fallback.** Parsing
`12345+someone@users.noreply.github.com` for a login, or matching on the local
part, attaches commits to the wrong person silently and permanently. An
unresolved email stays visible; a wrongly-resolved one never gets found.

In practice the unresolved set is dominated by CI and container identities
(`worker@…internal`, `ubuntu@ip-10-0-0-1.ec2.internal`, `bot@…`), which is the
correct outcome: they are not people and should not become contributors.

---

## 4. Rate limits

Authenticated REST is 5 000 req/hr (15 000 for a GitHub App installation);
GraphQL is budgeted by point cost. Neither is the bottleneck for this workload —
a repo costs roughly `(PR pages) + (distinct emails / 40) + 1` calls, so a
20-repo org runs in well under 200 requests.

Detection covers both shapes it takes:

* a non-zero `gh` exit whose stderr mentions a rate/secondary/abuse limit;
* **HTTP 200 with an `errors` array** containing `type: "RATE_LIMITED"` — the
  GraphQL trap, where checking the exit code alone tells you everything is fine.

Either one ends the run with **exit 3**. Rows already parsed are committed;
**the watermark is not advanced**. The next run re-walks the overlap, which is
cheap, instead of leaving a hole in the series, which is permanent and
undetectable.

There is no backoff ladder. At these volumes it would be untested code guarding
a case that does not occur.

---

## 5. Known blind spot: merged PRs with no commit on the branch

If the default branch is rewritten after a PR merges (force-push, squash of a
squash, a history rewrite), GitHub keeps pointing `mergeCommit.oid` at a SHA
that is no longer an ancestor of the branch. Every SHA linked to that PR is then
absent from `commits`, so `v_prs_enriched.is_ai_assisted` reads `0` and AI
adoption is understated.

Observed in the wild on a young repo: 9 of 32 merged PRs.

This is **counted, not repaired** — the envelope reports
`merged_prs_with_no_git_commit` and the run warns on stderr. Recovering the
linkage would mean matching orphaned commits to their rewritten equivalents,
for which `git patch-id` is the deterministic tool. That is a real future rule
and a good one; inferring the link from a title or a merge timestamp is not,
and would put a guess where the reader expects a measurement.

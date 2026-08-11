# dxm-classify-rules.awk -- the deterministic PR classification rule engine.
#
# OWNERSHIP: W3 (classification). Called only by scripts/dxm-classify.sh.
#
# WHY a separate awk file rather than a shell loop:
#   * one process for N pull requests instead of N subshells;
#   * ERE matching that SQLite does not have (no REGEXP without an extension);
#   * it is testable with a synthetic TSV and NO database, which is how the
#     rule table is actually verified.
#
# INPUT  (stdin, tab separated, no header, one row per PR):
#   1 pr_id
#   2 repo_full_name         owner/name
#   3 number
#   4 title                  flattened (tabs/newlines already replaced in SQL)
#   5 label_csv              lowercased, comma separated, may be empty
#   6 head_ref               may be empty
#   7 base_ref               may be empty
#   8 has_issue_link         0|1  (body mentions fixes/closes/resolves #N)
#   9 is_dep_bot             0|1  (author login matched a dependency-bot pattern)
#
#   Note field 9 is a BOOLEAN, not a login. No author login ever leaves SQLite:
#   the dependency-bot test is done in SQL so this file cannot leak an identity
#   into a temp file (CONTRACT.md Sec.8).
#
# OUTPUT (files, via -v):
#   sqlfile   INSERT..ON CONFLICT statements for pr_classifications (no BEGIN/COMMIT)
#   covfile   TSV for dxm_coverage_batch: unit_kind \t unit_key \t method \t detail
#   cntfile   TSV counters: <bucket> \t <key> \t <count>
#   unresfile optional TSV of unresolved PRs (only written if non-empty path)
#
# VARIABLES (-v):
#   ver        classifier_version string, stored on every row
#   heur       1 = enable the low-confidence leading-verb heuristics, 0 = off
#
# CLASS VOCABULARY -- schema.sql is authoritative:
#   feature | bugfix | refactor | chore | docs | test | revert | deps | unclassified
# The brief's `hotfix`, `release` and `dependency` are NOT separate classes here.
# `dependency` is spelled `deps`; `hotfix` and `release` are carried as SUBTYPES
# in the rule name and in the subtype counters, because adding a class value the
# frozen schema and agg_org_period do not know about would silently drop those
# PRs out of every ratio. See references/classification-rules.md.

BEGIN {
  FS = "\t"; OFS = "\t"
  if (ver  == "") ver  = "0"
  if (heur == "")  heur = 1

  # ---- conventional-commit type -> class ---------------------------------
  CC["feat"]="feature";   CC["feature"]="feature"
  CC["fix"]="bugfix";     CC["bugfix"]="bugfix";  CC["bug"]="bugfix"
  CC["hotfix"]="bugfix";  CC["security"]="bugfix"; CC["sec"]="bugfix"
  CC["perf"]="refactor";  CC["refactor"]="refactor"
  CC["style"]="chore";    CC["build"]="chore";    CC["ci"]="chore"
  CC["chore"]="chore";    CC["infra"]="chore";    CC["ops"]="chore"
  CC["docs"]="docs";      CC["doc"]="docs"
  CC["test"]="test";      CC["tests"]="test"
  CC["spec"]="test";      CC["specs"]="test"
  CC["remove"]="refactor"; CC["cleanup"]="refactor"; CC["deprecate"]="refactor"
  CC["config"]="chore"
  CC["deps"]="deps";      CC["dep"]="deps"
  CC["release"]="chore"
  CC["revert"]="revert"
  CCSUB["hotfix"]="hotfix"; CCSUB["release"]="release"

  # ---- label -> class ----------------------------------------------------
  # Prefixes such as `type:`, `kind/`, `c-` are stripped before lookup.
  LBL["bug"]="bugfix";        LBL["bugfix"]="bugfix";   LBL["bug-fix"]="bugfix"
  LBL["defect"]="bugfix";     LBL["regression"]="bugfix"; LBL["fix"]="bugfix"
  LBL["hotfix"]="bugfix";     LBL["security"]="bugfix"
  LBL["feature"]="feature";   LBL["enhancement"]="feature"; LBL["feat"]="feature"
  LBL["new feature"]="feature"; LBL["new-feature"]="feature"
  LBL["improvement"]="feature"
  LBL["documentation"]="docs"; LBL["docs"]="docs"; LBL["doc"]="docs"
  LBL["test"]="test";         LBL["tests"]="test";      LBL["testing"]="test"
  LBL["refactor"]="refactor"; LBL["refactoring"]="refactor"
  LBL["tech-debt"]="refactor"; LBL["technical-debt"]="refactor"
  LBL["cleanup"]="refactor";  LBL["performance"]="refactor"; LBL["perf"]="refactor"
  LBL["chore"]="chore";       LBL["maintenance"]="chore"; LBL["housekeeping"]="chore"
  LBL["ci"]="chore";          LBL["build"]="chore";     LBL["infrastructure"]="chore"
  LBL["infra"]="chore";       LBL["release"]="chore"
  LBL["revert"]="revert"
  LBL["dependencies"]="deps"; LBL["deps"]="deps";       LBL["dependency"]="deps"
  LBL["dependabot"]="deps";   LBL["renovate"]="deps"
  LBLSUB["hotfix"]="hotfix";  LBLSUB["release"]="release"

  # ---- head-branch first segment -> class --------------------------------
  BR["feature"]="feature"; BR["feat"]="feature"; BR["features"]="feature"
  BR["fix"]="bugfix";      BR["bugfix"]="bugfix"; BR["bug"]="bugfix"
  BR["fixes"]="bugfix";    BR["hotfix"]="bugfix"; BR["patch"]="bugfix"
  BR["chore"]="chore";     BR["task"]="chore";    BR["maint"]="chore"
  BR["maintenance"]="chore"; BR["ci"]="chore";    BR["build"]="chore"
  BR["docs"]="docs";       BR["doc"]="docs"
  BR["refactor"]="refactor"; BR["refac"]="refactor"; BR["cleanup"]="refactor"
  BR["perf"]="refactor"
  BR["test"]="test";       BR["tests"]="test"
  BR["deps"]="deps";       BR["dependencies"]="deps"
  BR["release"]="chore";   BR["rel"]="chore"
  BRSUB["hotfix"]="hotfix"; BRSUB["release"]="release"

  # ---- release-promotion branch sets -------------------------------------
  PROMO_HEAD["develop"]=1; PROMO_HEAD["dev"]=1; PROMO_HEAD["staging"]=1
  PROMO_HEAD["stage"]=1;   PROMO_HEAD["release"]=1; PROMO_HEAD["rc"]=1
  PROMO_BASE["main"]=1;    PROMO_BASE["master"]=1; PROMO_BASE["production"]=1
  PROMO_BASE["prod"]=1;    PROMO_BASE["release"]=1; PROMO_BASE["stable"]=1
}

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
function sqlq(s) { gsub(/'/, "''", s); return "'" s "'" }

function cap(s, n) { if (length(s) > n) return substr(s, 1, n - 1) "~"; return s }

# Parse a conventional-commit prefix. Sets CCTYPE and CCSCOPE globally.
function parse_cc(t,   s, p) {
  CCTYPE = ""; CCSCOPE = ""
  s = tolower(t)
  if (!match(s, /^[a-z][a-z-]*(\([^)]*\))?!?:/)) return
  p = substr(s, 1, RLENGTH)
  match(p, /^[a-z][a-z-]*/); CCTYPE = substr(p, RSTART, RLENGTH)
  if (match(p, /\([^)]*\)/)) CCSCOPE = substr(p, RSTART + 1, RLENGTH - 2)
}

# Normalise one label: trim, drop a `type:` / `kind/` / `c-` style prefix.
function norm_label(l) {
  l = tolower(l)   # SQL already lowercases label_csv; belt and braces for
                   # anyone driving this file directly with a synthetic TSV.
  gsub(/^[ \t]+/, "", l); gsub(/[ \t]+$/, "", l)
  sub(/^(type|kind|cat|category|area|t|c|a|p)[:\/ -]+/, "", l)
  gsub(/^[ \t]+/, "", l); gsub(/[ \t]+$/, "", l)
  return l
}

# First path segment of a branch name, lowercased.
function branch_seg(b,   s) {
  s = tolower(b)
  if (match(s, /^[a-z0-9._]+[\/_-]/)) return substr(s, RSTART, RLENGTH - 1)
  if (s ~ /^[a-z]+$/) return s
  return ""
}

function setc(c, r, m, cf, rv, sb) {
  CLASS = c; RULE = r; METH = m; CONF = cf; ISREV = rv; SUB = sb
}

# --------------------------------------------------------------------------
# one PR per record
# --------------------------------------------------------------------------
{
  pr_id = $1; repo = $2; num = $3
  title = $4; labels = $5; head = $6; base = $7
  hasissue = ($8 + 0); depbot = ($9 + 0)

  lt = tolower(title); lh = tolower(head); lb = tolower(base)

  CLASS = ""; RULE = ""; METH = ""; CONF = 0; ISREV = 0; SUB = ""
  gap = ""

  # -- label set ----------------------------------------------------------
  delete LSET
  nlab = 0
  if (labels != "") {
    n = split(labels, LA, ",")
    for (i = 1; i <= n; i++) {
      nl = norm_label(LA[i])
      if (nl != "") { LSET[nl] = 1; nlab++ }
    }
  }

  parse_cc(title)
  seg = branch_seg(head)

  # ======================================================================
  # 1. REVERT -- structural, highest precedence. A revert is never anything
  #    else, and revert rate must not be swallowed by the bugfix bucket.
  # ======================================================================
  if (lh ~ /^revert-[0-9]+-/) {
    setc("revert", "revert:head-branch", "script", 0.99, 1, "")
  } else if (CCTYPE == "revert") {
    setc("revert", "revert:cc-prefix", "script", 0.95, 1, "")
  } else if (lt ~ /^revert[ :"']/ || lt == "revert") {
    setc("revert", "revert:title", "script", 0.95, 1, "")
  } else if (lt ~ /^reapply[ :"']/) {
    # Reverting a revert. Structurally a roll-forward, NOT churn: counting it
    # as a revert would double-count the same incident.
    setc("chore", "revert:reapply-rollforward", "script-with-fallback", 0.60, 0, "")
  } else if (lh ~ /^revert[\/_-]/) {
    setc("revert", "revert:head-prefix", "script-with-fallback", 0.80, 1, "")
  } else if ("revert" in LSET) {
    setc("revert", "revert:label", "script-with-fallback", 0.80, 1, "")
  }

  # ======================================================================
  # 2. DEPENDENCY -- bot authorship and bump titles are unambiguous.
  # ======================================================================
  if (CLASS == "") {
    if (depbot) {
      setc("deps", "deps:bot-author", "script", 0.99, 0, "")
    } else if (lh ~ /^(dependabot|renovate|snyk-fix|greenkeeper|depfu|pyup|whitesource|mend)[\/_-]/) {
      setc("deps", "deps:head-branch", "script", 0.95, 0, "")
    } else if (CCTYPE != "" && CCSCOPE ~ /^(dev-?)?deps/) {
      setc("deps", "deps:cc-scope", "script", 0.95, 0, "")
    } else if (lt ~ /^bump .+ from .+ to /) {
      setc("deps", "deps:bump-title", "script", 0.90, 0, "")
    } else if (("dependencies" in LSET) || ("deps" in LSET) || ("dependency" in LSET)) {
      setc("deps", "deps:label", "script-with-fallback", 0.85, 0, "")
    }
  }

  # ======================================================================
  # 3. CONVENTIONAL-COMMIT PREFIX -- the strongest declared intent there is.
  # ======================================================================
  if (CLASS == "" && CCTYPE != "") {
    if (CCTYPE in CC) {
      setc(CC[CCTYPE], "cc:" CCTYPE, "script", 0.95, 0,
           (CCTYPE in CCSUB) ? CCSUB[CCTYPE] : "")
    } else {
      # Name the prefix. The set of prefixes a codebase uses is small and
      # finite, so this still groups usefully in v_llm_backlog, and it turns
      # the backlog row into a one-line fix: "add `sync` to the CC map".
      gap = gap "+unmapped-cc-prefix(" CCTYPE ")"
    }
  } else if (CLASS == "" && CCTYPE == "") {
    gap = gap "+no-cc-prefix"
  }

  # ======================================================================
  # 4. RELEASE -- before labels, because a release PR usually carries the
  #    labels of everything inside it.
  # ======================================================================
  if (CLASS == "") {
    if (lt ~ /^release[ :v_-]/ || lt ~ /^v?[0-9]+\.[0-9]+\.[0-9]+([ )]|$)/) {
      setc("chore", "release:title", "script-with-fallback", 0.70, 0, "release")
    } else if (lh ~ /^release[\/_-]/ || lh ~ /^rc[\/_-]/) {
      setc("chore", "release:head-branch", "script-with-fallback", 0.75, 0, "release")
    }
  }

  # ======================================================================
  # 5. LABELS -- a real signal, but a weaker one, and only when the labels
  #    agree with each other. Conflicting labels decide nothing.
  # ======================================================================
  if (CLASS == "") {
    hit = ""; hitlab = ""; conflict = 0; ndist = 0
    delete SEEN
    for (l in LSET) {
      if (l in LBL) {
        c = LBL[l]
        if (!(c in SEEN)) { SEEN[c] = 1; ndist++ }
        if (hit == "" || c == hit) { hit = c; if (hitlab == "") hitlab = l }
      }
    }
    if (ndist > 1) {
      conflict = 1
      gap = gap "+label-conflict"
    } else if (ndist == 1) {
      # `hit` may have been overwritten by iteration order; recompute cleanly.
      for (c in SEEN) hit = c
      hitlab = ""
      for (l in LSET) if ((l in LBL) && LBL[l] == hit) { if (hitlab == "" || l < hitlab) hitlab = l }
      setc(hit, "label:" hitlab, "script-with-fallback", 0.80, (hit == "revert" ? 1 : 0),
           (hitlab in LBLSUB) ? LBLSUB[hitlab] : "")
    } else if (nlab == 0) {
      gap = gap "+no-labels"
    } else {
      gap = gap "+no-mapped-label"
    }
  }

  # ======================================================================
  # 6. BRANCH NAME -- convention, not declaration. Weaker still.
  # ======================================================================
  if (CLASS == "") {
    if (seg != "" && (seg in BR)) {
      setc(BR[seg], "branch:" seg, "script-with-fallback", 0.70, 0,
           (seg in BRSUB) ? BRSUB[seg] : "")
    } else if (head == "") {
      gap = gap "+no-head-ref"
    } else {
      gap = gap "+no-branch-pattern"
    }
  }

  # ======================================================================
  # 7. RELEASE PROMOTION -- develop -> main and friends. Weak, and only
  #    when nothing above spoke.
  # ======================================================================
  if (CLASS == "") {
    if ((lh in PROMO_HEAD) && (lb in PROMO_BASE) && lh != lb) {
      setc("chore", "release:promotion", "script-with-fallback", 0.60, 0, "release")
    }
  }

  # ======================================================================
  # 7b. BACKPORT / CHERRY-PICK -- structural, and deliberately NOT a bugfix.
  #     The original PR was already counted; counting the backport too would
  #     report one defect as two. Bucketed as chore so it leaves the defect
  #     ratio alone instead of inflating it.
  # ======================================================================
  if (CLASS == "") {
    if (lt ~ /^(automated )?cherry[- ]pick/ || lt ~ /^\[?backport\]?[ :]/ ||
        lh ~ /^(backport|cherry-pick|automated-cherry-pick)/ ||
        ("backport" in LSET) || ("cherry-pick" in LSET)) {
      setc("chore", "backport:cherry-pick", "script-with-fallback", 0.80, 0, "")
    }
  }

  # ======================================================================
  # 8. LEADING-VERB HEURISTICS -- opinionated, low confidence, and switchable
  #    off with --no-heuristics so a client can see the un-guessed coverage.
  # ======================================================================
  if (CLASS == "" && heur == 1) {
    # Normalise a leading tag before matching a verb. Two forms are extremely
    # common and both hide the verb from an anchored pattern:
    #   "[8-1-stable] Warn when ..."   -> "warn when ..."
    #   "test/images: bump agnhost"    -> "bump agnhost"
    # Only the verb stage sees this; conventional-commit parsing already ran
    # against the untouched title, so nothing here can invent a cc prefix.
    lt2 = lt
    sub(/^\[[^]]*\][ \t]*/, "", lt2)
    sub(/^[a-z0-9\/_.-]+:[ \t]+/, "", lt2)

    if (lt2 ~ /^(bump|prepare|cut|tag) (the )?(version|release)/ ||
        lt2 ~ /^release[ :]/) {
      # ordered before verb:bump on purpose: "Bump version to 3.0.0" is a
      # release chore, not a dependency upgrade.
      setc("chore", "verb:release", "script-with-fallback", 0.60, 0, "release")
    } else if (lt2 ~ /^(bump|upgrade|revendor|vendor) / ||
        lt2 ~ /^update .+ (to|from) v?[0-9]/ ||
        lt2 ~ /^update (dependenc|package|gem|npm|yarn|pnpm|cargo|go\.mod|lock|vendor)/) {
      setc("deps", "verb:bump", "script-with-fallback", 0.60, 0, "")
    } else if (lt2 ~ /^(document|readme|changelog)/ ||
               lt2 ~ /^(add(s|ed|ing)?|update[sd]?|improve[sd]?|fix(es|ed)?) (the )?(docs|documentation|readme|changelog|comment)/) {
      # before verb:test / verb:add / verb:fix: a docs PR usually opens with
      # one of their verbs and only the object says it is documentation.
      setc("docs", "verb:docs", "script-with-fallback", 0.60, 0, "")
    } else if (lt2 ~ /^(add(s|ed|ing)?|write|writes|improve[sd]?|fix(es|ed)?) (unit |integration |e2e |flaky |failing )*(test|spec)/ ||
               lt2 ~ /^(test|spec)(s|ing)? /) {
      setc("test", "verb:test", "script-with-fallback", 0.60, 0, "")
    } else if (lt2 ~ /^(fix(es|ed|ing)?|resolve[sd]?|correct(s|ed)?|repair(s|ed)?|patch(es|ed)?|handle|prevent|guard against|escape|sanitiz|sanitis) /) {
      setc("bugfix", "verb:fix", "script-with-fallback", 0.55, 0, "")
    } else if (lt2 ~ /^(refactor|rename|extract|simplify|reorganis|reorganiz|restructure|deduplicate|dedupe|inline|split|move|remove|delete|drop|replace|convert|migrate|switch|unify|consolidate|normalis|normaliz|modernis|moderniz|deprecate|stop|avoid|reduce|optimis|optimiz|tidy) / ||
               lt2 ~ /^clean ?up / ||
               lt2 ~ /^(speed up|improve performance|make .*(thread|ractor|memory)[- ]safe)/) {
      setc("refactor", "verb:refactor", "script-with-fallback", 0.55, 0, "")
    } else if (lt2 ~ /^(add(s|ed|ing)?|implement(s|ed)?|introduce[sd]?|create[sd]?|support|enable|allow|expose|extend|expand) /) {
      setc("feature", "verb:add", "script-with-fallback", 0.55, 0, "")
    } else {
      gap = gap "+no-title-verb"
    }
  } else if (CLASS == "" && heur != 1) {
    gap = gap "+heuristics-disabled"
  }

  # ======================================================================
  # 9. GIVE UP -- and say precisely why, because that string is the spec for
  #    the rule that should have existed.
  # ======================================================================
  if (CLASS == "") {
    if (hasissue) gap = gap "+has-issue-link"
    sub(/^\+/, "", gap)
    if (gap == "") gap = "no-signal"
    CLASS = "unclassified"; METH = "llm"; CONF = ""; ISREV = 0; SUB = ""
    RULE = "needs-llm labels=[" cap(labels, 60) "] head=[" cap(head, 40) "]"
    detail = gap
    GAPC[gap]++
    if (unresfile != "")
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", repo, num, title, labels, head, base, gap > unresfile
  } else {
    detail = RULE
  }

  # -- emit ---------------------------------------------------------------
  printf "INSERT INTO pr_classifications(pr_id,class,is_revert,confidence,method,rule,classifier_version,classified_at) VALUES(%s,%s,%d,%s,%s,%s,%s,strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')) ON CONFLICT(pr_id) DO UPDATE SET class=excluded.class,is_revert=excluded.is_revert,confidence=excluded.confidence,method=excluded.method,rule=excluded.rule,classifier_version=excluded.classifier_version,classified_at=excluded.classified_at;\n", \
    pr_id, sqlq(CLASS), ISREV, (CONF == "" ? "NULL" : sprintf("%.2f", CONF)), \
    sqlq(METH), sqlq(cap(RULE, 200)), sqlq(ver) > sqlfile

  printf "pr_classification\t%s#%s\t%s\t%s\n", repo, num, METH, detail > covfile

  TOT++
  CLSC[CLASS]++
  METHC[METH]++
  if (SUB != "") SUBC[SUB]++
  if (CONF != "" && CONF < 0.70) WEAK++
  if (ISREV) REVC++
}

END {
  printf "tot\trows\t%d\n", TOT + 0        > cntfile
  printf "tot\tweak\t%d\n", WEAK + 0       > cntfile
  printf "tot\treverts\t%d\n", REVC + 0    > cntfile
  for (k in CLSC)  printf "class\t%s\t%d\n",  k, CLSC[k]  > cntfile
  for (k in METHC) printf "method\t%s\t%d\n", k, METHC[k] > cntfile
  for (k in SUBC)  printf "subtype\t%s\t%d\n", k, SUBC[k] > cntfile
  for (k in GAPC)  printf "gap\t%s\t%d\n",    k, GAPC[k]  > cntfile
}

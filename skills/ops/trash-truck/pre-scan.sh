#!/usr/bin/env bash
# Pre-scan for trash-truck: cheap static analysis before Claude reviews.
# Uses rg + python3 ast to find dead code candidates. Outputs structured JSON.
# Usage: bash pre-scan.sh [focus] [repo-root]
#   focus: dead-code | misplaced | committed-by-error | unused-functions | all (default: all)
#   repo-root: path to scan (default: current directory)

set -euo pipefail

FOCUS="${1:-all}"
ROOT="${2:-.}"
ROOT=$(cd "$ROOT" && pwd)

# Respect .gitignore — only scan tracked files
tracked_files() {
  git -C "$ROOT" ls-files --cached --others --exclude-standard 2>/dev/null || find "$ROOT" -type f
}

# --- dead-code: orphaned imports, debug statements, commented-out blocks ---
scan_dead_code() {
  local results="[]"

  # Debug statements left behind
  local debug_hits
  debug_hits=$(rg -n --json '(console\.log|console\.debug|debugger;|binding\.pry|import pdb|print\(f?["\x27]DEBUG)' "$ROOT" \
    --glob '!node_modules' --glob '!vendor' --glob '!*.min.*' --glob '!*.lock' --glob '!dist/' \
    --glob '!*.md' --glob '!*.txt' --glob '!SKILL.md' \
    2>/dev/null | python3 -c "
import sys, json
hits = []
for line in sys.stdin:
    try:
        obj = json.loads(line)
        if obj.get('type') == 'match':
            d = obj['data']
            hits.append({
                'file': d['path']['text'],
                'line': d['line_number'],
                'text': d['lines']['text'].strip()[:120],
                'kind': 'debug-statement'
            })
    except: pass
print(json.dumps(hits))
" 2>/dev/null) || debug_hits="[]"

  # Commented-out code blocks (3+ consecutive comment lines that look like code)
  local commented
  commented=$(rg -n --json '^\s*(//|#)\s*(if|for|while|return|const|let|var|def |class |import |from |function)' "$ROOT" \
    --glob '!node_modules' --glob '!vendor' --glob '!*.min.*' --glob '!*.lock' --glob '!dist/' \
    --glob '!*.md' --glob '!*.txt' --glob '!*.yml' --glob '!*.yaml' --glob '!SKILL.md' \
    2>/dev/null | python3 -c "
import sys, json
hits = []
for line in sys.stdin:
    try:
        obj = json.loads(line)
        if obj.get('type') == 'match':
            d = obj['data']
            hits.append({
                'file': d['path']['text'],
                'line': d['line_number'],
                'text': d['lines']['text'].strip()[:120],
                'kind': 'commented-code'
            })
    except: pass
print(json.dumps(hits))
" 2>/dev/null) || commented="[]"

  local debug_file commented_file
  debug_file=$(mktemp)
  commented_file=$(mktemp)
  printf '%s' "$debug_hits" > "$debug_file"
  printf '%s' "$commented" > "$commented_file"
  python3 -c "
import json
with open('$debug_file') as f: debug = json.loads(f.read() or '[]')
with open('$commented_file') as f: commented = json.loads(f.read() or '[]')
print(json.dumps(debug + commented))
" 2>/dev/null || echo "[]"
  rm -f "$debug_file" "$commented_file"
}

# --- misplaced: files in wrong directories ---
scan_misplaced() {
  python3 -c "
import os, json

root = '$ROOT'
findings = []

patterns = [
    # Test files outside test directories
    {'glob': r'(test_|_test\.|\.test\.|\.spec\.)', 'should_be_in': ['test', 'tests', '__tests__', 'spec', 'specs'],
     'kind': 'test-outside-test-dir'},
    # Config files deep in source trees
    {'names': ['.env.example', 'docker-compose.yml', 'Dockerfile', 'Makefile'],
     'should_be_in': ['.', 'infra', 'deploy', 'docker'],
     'kind': 'config-buried-in-source'},
]

import re
for dirpath, dirnames, filenames in os.walk(root):
    # Skip common vendor dirs
    dirnames[:] = [d for d in dirnames if d not in ('node_modules', 'vendor', '.git', 'dist', 'build', '__pycache__')]
    rel_dir = os.path.relpath(dirpath, root)

    for f in filenames:
        rel_path = os.path.join(rel_dir, f)
        # Test files outside test dirs
        if re.search(r'(test_|_test\.|\.test\.|\.spec\.)', f):
            parts = rel_dir.split(os.sep)
            if not any(p in ('test', 'tests', '__tests__', 'spec', 'specs', 'e2e') for p in parts):
                findings.append({'file': rel_path, 'kind': 'test-outside-test-dir', 'detail': 'Test file not in a test directory'})

print(json.dumps(findings))
" 2>/dev/null || echo "[]"
}

# --- committed-by-error: files that shouldn't be in version control ---
scan_committed_by_error() {
  python3 -c "
import os, json

root = '$ROOT'
findings = []

suspect_patterns = [
    # Secrets / credentials
    ('.env', 'dotenv file — may contain secrets'),
    ('.env.local', 'local env — may contain secrets'),
    ('credentials.json', 'credentials file'),
    ('service-account.json', 'GCP service account key'),
    ('*.pem', 'private key file'),
    ('*.key', 'private key file'),
    # Build artifacts
    ('*.pyc', 'compiled Python bytecode'),
    ('.DS_Store', 'macOS metadata'),
    ('Thumbs.db', 'Windows thumbnail cache'),
    ('*.swp', 'vim swap file'),
    ('*.swo', 'vim swap file'),
    # IDE files (not always wrong, but worth flagging)
    ('.idea/', 'JetBrains IDE config'),
    ('.vscode/launch.json', 'VS Code debug config — often personal'),
    # Large binaries
    ('*.sqlite', 'SQLite database'),
    ('*.db', 'database file'),
]

import fnmatch, subprocess
# Only check files actually tracked by git
try:
    result = subprocess.run(['git', '-C', root, 'ls-files', '--cached'], capture_output=True, text=True, timeout=10)
    tracked_files = set(result.stdout.strip().splitlines())
except:
    tracked_files = None  # fallback to os.walk if not a git repo

if tracked_files is not None:
    for rel in tracked_files:
        f = os.path.basename(rel)
        for pattern, reason in suspect_patterns:
            if fnmatch.fnmatch(f, pattern) or f == pattern:
                findings.append({'file': rel, 'kind': 'committed-by-error', 'detail': reason})
                break
else:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('node_modules', 'vendor', '.git', 'dist')]
        for f in filenames:
            rel = os.path.relpath(os.path.join(dirpath, f), root)
            for pattern, reason in suspect_patterns:
                if fnmatch.fnmatch(f, pattern) or f == pattern:
                    findings.append({'file': rel, 'kind': 'committed-by-error', 'detail': reason})
                    break

print(json.dumps(findings))
" 2>/dev/null || echo "[]"
}

# --- unused-functions: Python ast-based scan for defined-but-never-called functions ---
scan_unused_functions() {
  python3 << 'PYEOF'
import ast, os, json, sys

root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SCAN_ROOT", ".")

py_files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('node_modules', 'vendor', '.git', 'dist', 'build', '__pycache__', '.venv', 'venv')]
    for f in filenames:
        if f.endswith('.py'):
            py_files.append(os.path.join(dirpath, f))

if not py_files:
    print(json.dumps([]))
    sys.exit(0)

defined = {}  # name -> [(file, line)]
referenced = set()

for fpath in py_files:
    try:
        with open(fpath) as fh:
            tree = ast.parse(fh.read(), filename=fpath)
    except:
        continue

    rel = os.path.relpath(fpath, root)

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            name = node.name
            if name.startswith('_'):
                continue  # skip private/dunder
            defined.setdefault(name, []).append((rel, node.lineno))
        elif isinstance(node, ast.Name):
            referenced.add(node.id)
        elif isinstance(node, ast.Attribute):
            referenced.add(node.attr)

findings = []
for name, locations in defined.items():
    if name not in referenced and not name.startswith('test_'):
        for fpath, lineno in locations:
            findings.append({
                'file': fpath,
                'line': lineno,
                'kind': 'unused-function',
                'detail': f'Function "{name}" defined but never referenced in codebase'
            })

print(json.dumps(findings[:50]))  # cap output
PYEOF
}

# --- JS/TS unused exports: grep for exported names, check if imported anywhere ---
scan_unused_exports() {
  local exports_file
  exports_file=$(mktemp)

  # Find all named exports
  rg --no-heading 'export\s+(const|function|class|let|var|type|interface|enum|async function)\s+(\w+)' "$ROOT" \
    --glob '!node_modules' --glob '!dist' --glob '!build' --glob '!*.min.*' --glob '!*.d.ts' \
    -r '$2' --only-matching 2>/dev/null | sort -u > "$exports_file" || true

  python3 -c "
import subprocess, json, os

root = '$ROOT'
exports_file = '$exports_file'
findings = []

with open(exports_file) as f:
    for line in f:
        line = line.strip()
        if not line or ':' not in line:
            continue
        parts = line.split(':', 1)
        if len(parts) != 2:
            continue
        filepath, name = parts
        if len(name) < 3:
            continue  # skip short names, high false-positive rate

        # Check if this name is imported/used anywhere else
        try:
            result = subprocess.run(
                ['rg', '-l', '--glob', '!node_modules', '--glob', '!dist',
                 '--glob', '!' + filepath, name, root],
                capture_output=True, text=True, timeout=5
            )
            if not result.stdout.strip():
                findings.append({
                    'file': os.path.relpath(filepath, root),
                    'kind': 'unused-export',
                    'detail': f'Export \"{name}\" not imported anywhere else'
                })
        except:
            pass

        if len(findings) >= 30:
            break

print(json.dumps(findings))
" 2>/dev/null || echo "[]"

  rm -f "$exports_file"
}

# --- Main ---
echo "{"
echo '  "scan_root": "'"$ROOT"'",'
echo '  "focus": "'"$FOCUS"'",'

case "$FOCUS" in
  dead-code)
    echo '  "dead_code": '"$(scan_dead_code)"
    ;;
  misplaced)
    echo '  "misplaced": '"$(scan_misplaced)"
    ;;
  committed-by-error)
    echo '  "committed_by_error": '"$(scan_committed_by_error)"
    ;;
  unused-functions)
    echo '  "unused_functions": '"$(SCAN_ROOT="$ROOT" scan_unused_functions "$ROOT")"','
    echo '  "unused_exports": '"$(scan_unused_exports)"
    ;;
  all)
    echo '  "dead_code": '"$(scan_dead_code)"','
    echo '  "misplaced": '"$(scan_misplaced)"','
    echo '  "committed_by_error": '"$(scan_committed_by_error)"
    ;;
  *)
    echo '  "error": "Unknown focus: '"$FOCUS"'. Use: dead-code|misplaced|committed-by-error|unused-functions|all"'
    ;;
esac

echo "}"

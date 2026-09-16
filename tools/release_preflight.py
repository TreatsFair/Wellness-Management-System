#!/usr/bin/env python3
"""Read-only release preflight for the Treats Wellness Management System.

The default command only observes the repository and configured environments.
The optional integration path is separately gated, STAGING-only, and never
available to production mode.
"""

from __future__ import annotations

import argparse
import dataclasses
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Optional
from urllib.parse import unquote, urlsplit


PASS = "PASS"
WARN = "WARN"
BLOCKED = "BLOCKED"
FAIL = "FAIL"
NOT_RUN = "NOT_RUN"
UNKNOWN = "UNKNOWN"
STATUSES = {PASS, WARN, BLOCKED, FAIL, NOT_RUN, UNKNOWN}

CATEGORY_ORDER = [
    "GIT",
    "MIGRATIONS",
    "ENVIRONMENT",
    "FLUTTER",
    "EDGE FUNCTIONS",
    "WEB",
    "SECURITY",
    "PAYMENT CONFIG",
    "INTEGRATION",
    "PRODUCTION DELTA",
    "KNOWN BLOCKERS",
]

CONFLICT_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
MIGRATION_VERSION_RE = re.compile(r"(?<!\d)(\d{8,14})(?!\d)")
SECRET_LITERAL_RE = re.compile(
    r"(?:sb_secret_|service_role\s*[=:]\s*['\"])\S+", re.IGNORECASE
)


@dataclasses.dataclass
class CheckResult:
    id: str
    category: str
    status: str
    summary: str
    details: Any = None
    severity: str = "info"
    required: bool = True
    blocking: bool = False
    technical_gate: bool = True

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            raise ValueError(f"Unsupported check status: {self.status}")

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "category": self.category,
            "status": self.status,
            "summary": self.summary,
            "details": self.details,
            "severity": self.severity,
            "required": self.required,
            "blocking": self.blocking,
            "technical_gate": self.technical_gate,
        }


@dataclasses.dataclass
class ProcessOutcome:
    available: bool
    returncode: Optional[int] = None
    stdout: str = ""
    stderr: str = ""
    timed_out: bool = False

    @property
    def output(self) -> str:
        return (self.stdout + "\n" + self.stderr).strip()


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def load_config(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    if config.get("schema_version") != 1:
        raise ValueError("unsupported release-preflight config schema")
    for target in ("local", "staging", "production"):
        if target not in config.get("environments", {}):
            raise ValueError(f"missing environment configuration: {target}")
    return config


def path_from_config(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def rel_path(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def normalize_path(value: str) -> str:
    return value.replace("\\", "/").lstrip("./").lower()


def redact_sensitive(value: str) -> str:
    """Remove credentials/tokens from command errors before they are retained."""

    value = re.sub(
        r"(?i)(postgres(?:ql)?://)[^@\s]+@",
        r"\1<redacted>@",
        value,
    )
    value = re.sub(
        r"(?i)\bsb_(?:secret|publishable)_[A-Za-z0-9._-]+",
        "sb_<redacted>",
        value,
    )
    value = re.sub(
        r"(?i)(password|secret|token|api[_-]?key|authorization|x-signature-key|cleanup-secret)\s*[=:]\s*[^\s,;]+",
        r"\1=<redacted>",
        value,
    )
    # A test or CLI may print a sensitive environment value without its
    # variable name. Redact values from conventionally sensitive variables as
    # a second line of defense; never include their names or values in output.
    sensitive_names = ("KEY", "TOKEN", "SECRET", "PASSWORD", "SIGNATURE")
    for name, secret in os.environ.items():
        if len(secret) >= 4 and any(marker in name.upper() for marker in sensitive_names):
            value = value.replace(secret, "<redacted>")
    return value


def short_output(value: str, limit: int = 1200) -> str:
    value = redact_sensitive(value.strip())
    if len(value) <= limit:
        return value
    return value[-limit:]


def find_executable(name: str) -> Optional[str]:
    if name == "python":
        return sys.executable
    override = os.environ.get(f"PREFLIGHT_{name.upper()}", "").strip()
    if override:
        override_path = Path(override)
        return str(override_path) if override_path.is_file() else None
    candidates = [name]
    if os.name == "nt":
        candidates.extend([f"{name}.exe", f"{name}.bat", f"{name}.cmd"])
    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    return None


def run_process(
    argv: list[str],
    cwd: Path,
    timeout_seconds: int,
    env: Optional[dict[str, str]] = None,
    input_text: Optional[str] = None,
) -> ProcessOutcome:
    try:
        completed = subprocess.run(
            argv,
            cwd=str(cwd),
            env=env,
            shell=False,
            capture_output=True,
            input=input_text,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
            check=False,
        )
    except FileNotFoundError:
        return ProcessOutcome(available=False)
    except OSError as error:
        return ProcessOutcome(available=False, stderr=redact_sensitive(str(error)))
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        return ProcessOutcome(
            available=True,
            returncode=None,
            stdout=stdout,
            stderr=stderr,
            timed_out=True,
        )
    return ProcessOutcome(
        available=True,
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
    )


def run_git(root: Path, args: list[str], timeout_seconds: int = 30) -> ProcessOutcome:
    safe_root = root.resolve().as_posix()
    return run_process(
        ["git", "-c", f"safe.directory={safe_root}", *args],
        root,
        timeout_seconds,
    )


def command_details(argv: Iterable[str]) -> str:
    rendered: list[str] = []
    for value in argv:
        if value.startswith("postgresql://") or value.startswith("postgres://"):
            rendered.append("<read-only database URL redacted>")
        else:
            rendered.append(redact_sensitive(str(value)))
    return " ".join(rendered)


def result_from_process(
    check_id: str,
    category: str,
    label: str,
    argv: list[str],
    outcome: ProcessOutcome,
    *,
    required: bool = True,
    timeout_status: str = UNKNOWN,
) -> CheckResult:
    details = {
        "command": command_details(argv),
        "exit_code": outcome.returncode,
    }
    if outcome.output:
        details["output"] = short_output(outcome.output)
    if not outcome.available:
        return CheckResult(
            check_id,
            category,
            NOT_RUN,
            f"{label} unavailable on PATH",
            details,
            severity="warning",
            required=required,
        )
    if outcome.timed_out:
        details["timed_out"] = True
        return CheckResult(
            check_id,
            category,
            timeout_status,
            f"{label} did not finish within its bounded timeout",
            details,
            severity="high" if required else "warning",
            required=required,
        )
    if outcome.returncode == 0:
        return CheckResult(
            check_id,
            category,
            PASS,
            f"{label} passed",
            details,
            required=required,
        )
    return CheckResult(
        check_id,
        category,
        FAIL,
        f"{label} failed (exit {outcome.returncode})",
        details,
        severity="high" if required else "warning",
        required=required,
    )


def parse_porcelain_status(raw: str) -> list[dict[str, Any]]:
    records = raw.split("\0")
    entries: list[dict[str, Any]] = []
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if not record:
            continue
        status = record[:2]
        path = record[3:] if len(record) > 3 else ""
        paths = [path]
        if status[0] in "RC" or status[1] in "RC":
            if index < len(records) and records[index]:
                paths.append(records[index])
                index += 1
        entries.append({"status": status, "paths": paths})
    return entries


def dirty_path_matches(path: str, allowed: list[dict[str, Any]]) -> Optional[str]:
    normalized = normalize_path(path)
    for item in allowed:
        pattern = normalize_path(str(item.get("pattern", "")))
        if pattern and fnmatch.fnmatchcase(normalized, pattern):
            return str(item.get("reason", "explicitly configured exclusion"))
    return None


def git_checks(root: Path, config: dict[str, Any]) -> tuple[list[CheckResult], dict[str, Any]]:
    results: list[CheckResult] = []
    detected = run_git(root, ["rev-parse", "--show-toplevel"])
    if not detected.available or detected.returncode != 0:
        results.append(
            CheckResult(
                "git.repository",
                "GIT",
                BLOCKED,
                "repository could not be detected",
                {"output": short_output(detected.output)},
                severity="high",
                blocking=True,
            )
        )
        return results, {"branch": None, "head": None, "entries": []}

    detected_root = Path(detected.stdout.strip()).resolve()
    same_root = detected_root == root.resolve()
    results.append(
        CheckResult(
            "git.repository",
            "GIT",
            PASS if same_root else BLOCKED,
            "repository detected" if same_root else "Git root does not match the workspace",
            {"git_root": rel_path(root, detected_root), "workspace": root.as_posix()},
            severity="high" if not same_root else "info",
            blocking=not same_root,
        )
    )
    if not same_root:
        return results, {"branch": None, "head": None, "entries": []}

    branch_outcome = run_git(root, ["branch", "--show-current"])
    branch = branch_outcome.stdout.strip() if branch_outcome.returncode == 0 else ""
    expected_branch = config.get("release", {}).get("expected_branch")
    branch_ok = bool(branch) and (not expected_branch or branch == expected_branch)
    results.append(
        CheckResult(
            "git.branch",
            "GIT",
            PASS if branch_ok else BLOCKED,
            f"branch={branch or '(detached)'}"
            + (f" (expected {expected_branch})" if expected_branch and branch != expected_branch else ""),
            {"branch": branch, "expected": expected_branch},
            severity="high" if not branch_ok else "info",
            blocking=not branch_ok,
        )
    )

    head_outcome = run_git(root, ["rev-parse", "HEAD"])
    head = head_outcome.stdout.strip() if head_outcome.returncode == 0 else ""
    expected_head = str(config.get("release", {}).get("reference_head") or "").lower()
    head_matches = bool(head) and (not expected_head or head.lower() == expected_head)
    results.append(
        CheckResult(
            "git.head",
            "GIT",
            PASS if head_matches else BLOCKED,
            f"HEAD={head or '(unavailable)'}"
            + ("" if not expected_head or head.lower() == expected_head else " (frozen reference mismatch)"),
            {"head": head, "reference_head": expected_head or None},
            severity="high" if not head_matches else "info",
            blocking=not head_matches,
        )
    )

    status_outcome = run_git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    entries = parse_porcelain_status(status_outcome.stdout) if status_outcome.returncode == 0 else []
    allowed = config.get("git", {}).get("allowed_dirty", [])
    staged = 0
    unstaged = 0
    untracked = 0
    conflicts = 0
    excluded: list[dict[str, str]] = []
    unexpected: list[dict[str, Any]] = []
    for entry in entries:
        status = entry["status"]
        if status == "??":
            untracked += 1
        else:
            staged += int(status[0] not in (" ", "?"))
            unstaged += int(status[1] not in (" ", "?"))
        if status in CONFLICT_CODES or "U" in status:
            conflicts += 1
        reasons = [dirty_path_matches(path, allowed) for path in entry["paths"]]
        if reasons and all(reason is not None for reason in reasons):
            excluded.append({"path": entry["paths"][0], "reason": reasons[0] or ""})
        else:
            unexpected.append(entry)
    worktree_blocked = bool(unexpected or conflicts or not status_outcome.available or status_outcome.returncode != 0)
    results.append(
        CheckResult(
            "git.worktree",
            "GIT",
            BLOCKED if worktree_blocked else (WARN if excluded else PASS),
            f"working tree staged={staged} unstaged={unstaged} untracked={untracked} conflicts={conflicts}"
            + (f"; {len(excluded)} explicit exclusions" if excluded else "")
            + (f"; {len(unexpected)} unexpected release paths" if unexpected else ""),
            {
                "staged_count": staged,
                "unstaged_count": unstaged,
                "untracked_count": untracked,
                "conflict_count": conflicts,
                "excluded": excluded,
                "unexpected": unexpected,
            },
            severity="high" if worktree_blocked else ("warning" if excluded else "info"),
            blocking=worktree_blocked,
        )
    )

    for check_id, args, label in (
        ("git.diff_check", ["diff", "--check"], "git diff --check"),
        ("git.cached_diff_check", ["diff", "--cached", "--check"], "staged git diff --check"),
    ):
        outcome = run_git(root, args)
        results.append(
            result_from_process(
                check_id,
                "GIT",
                label,
                ["git", *args],
                outcome,
                required=True,
            )
        )
    return results, {"branch": branch, "head": head, "entries": entries}


def read_text(path: Path) -> str:
    return path.read_bytes().decode("utf-8", errors="replace")


def normalize_line_endings(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def normalized_sha256(path: Path) -> str:
    return hashlib.sha256(normalize_line_endings(path.read_bytes())).hexdigest()


def migration_integrity(
    root: Path, config: dict[str, Any]
) -> tuple[list[CheckResult], dict[str, Any]]:
    migration_cfg = config.get("migrations", {})
    migration_dir = path_from_config(root, config["paths"]["migration_directory"])
    authoring_dir = path_from_config(root, config["paths"]["authoring_sql_directory"])
    results: list[CheckResult] = []
    if not migration_dir.is_dir():
        results.append(
            CheckResult(
                "migrations.directory",
                "MIGRATIONS",
                BLOCKED,
                "Supabase migration directory is missing",
                {"path": rel_path(root, migration_dir)},
                severity="high",
                blocking=True,
            )
        )
        return results, {"ids": set(), "files": []}

    pattern = re.compile(str(migration_cfg.get("filename_pattern", r"^\d{14}_.+\.sql$")))
    legacy = {
        str(item.get("name")): str(item.get("reason", "explicit legacy migration filename"))
        for item in migration_cfg.get("legacy_files", [])
    }
    valid: list[tuple[str, str]] = []
    invalid: list[str] = []
    allowed_legacy: list[dict[str, str]] = []
    for path in sorted(migration_dir.glob("*.sql"), key=lambda item: item.name):
        name = path.name
        if pattern.fullmatch(name):
            valid.append((name[:14], name))
        elif name in legacy:
            allowed_legacy.append({"name": name, "reason": legacy[name]})
        else:
            invalid.append(name)

    by_timestamp: dict[str, list[str]] = {}
    for timestamp, name in valid:
        by_timestamp.setdefault(timestamp, []).append(name)
    duplicate_timestamps = {
        timestamp: names for timestamp, names in by_timestamp.items() if len(names) > 1
    }
    ids = {timestamp for timestamp, _ in valid}
    sequence = [name for _, name in sorted(valid, key=lambda item: (item[0], item[1]))]

    sequence_status = PASS
    sequence_blocked = False
    sequence_reasons: list[str] = []
    if duplicate_timestamps:
        sequence_status = BLOCKED
        sequence_blocked = True
        sequence_reasons.append("duplicate timestamp identities")
    if invalid:
        sequence_status = BLOCKED
        sequence_blocked = True
        sequence_reasons.append("unexpected filename pattern")
    results.append(
        CheckResult(
            "migrations.local_sequence",
            "MIGRATIONS",
            sequence_status,
            f"local migration sequence valid ({len(valid)} timestamped identities)"
            + (f"; issue: {', '.join(sequence_reasons)}" if sequence_reasons else ""),
            {
                "count": len(valid),
                "ids": sorted(ids),
                "tail": sequence[-10:],
                "duplicate_timestamps": duplicate_timestamps,
                "invalid_filenames": invalid,
                "allowed_legacy": allowed_legacy,
            },
            severity="high" if sequence_blocked else "info",
            blocking=sequence_blocked,
        )
    )
    if allowed_legacy:
        results.append(
            CheckResult(
                "migrations.legacy_convention",
                "MIGRATIONS",
                WARN,
                f"{len(allowed_legacy)} explicitly documented legacy filename excluded from timestamp identity comparison",
                {"files": allowed_legacy},
                severity="warning",
                required=False,
            )
        )
    if authoring_dir.is_dir():
        authoring_files = sorted(authoring_dir.glob("*.sql"), key=lambda item: item.name)
        results.append(
            CheckResult(
                "migrations.authoring_convention",
                "MIGRATIONS",
                PASS,
                f"numbered SQL authoring directory kept separate ({len(authoring_files)} files; not treated as migration identities)",
                {"path": rel_path(root, authoring_dir), "file_count": len(authoring_files)},
                required=True,
            )
        )
    else:
        results.append(
            CheckResult(
                "migrations.authoring_convention",
                "MIGRATIONS",
                BLOCKED,
                "expected SQL authoring directory is missing",
                {"path": rel_path(root, authoring_dir)},
                severity="high",
                blocking=True,
            )
        )
    return results, {"ids": ids, "files": sequence}


def project_url_matches(url: str, expected_ref: str) -> bool:
    try:
        host = (urlsplit(url).hostname or "").lower()
    except ValueError:
        return False
    return host == f"{expected_ref.lower()}.supabase.co"


def db_url_matches(db_url: str, expected_ref: str) -> bool:
    try:
        parsed = urlsplit(db_url)
        host = (parsed.hostname or "").lower()
        username = unquote(parsed.username or "").lower()
    except ValueError:
        return False
    ref = expected_ref.lower()
    # Supabase direct connections identify the project in the db host; pooler
    # URLs commonly identify it in the username (postgres.<project-ref>).
    host_labels = set(host.split("."))
    trusted_host_suffix = host.endswith(".supabase.co") or host.endswith(
        ".pooler.supabase.com"
    )
    return (
        (trusted_host_suffix and ref in host_labels)
        or ref in username.split(".")
    )


def extract_configured_url(text: str) -> Optional[str]:
    match = re.search(r"https://[a-z0-9-]+\.supabase\.co", text, re.IGNORECASE)
    return match.group(0) if match else None


def environment_identity_check(
    root: Path, target: str, config: dict[str, Any]
) -> CheckResult:
    paths = config["paths"]
    env_cfg = config["environments"][target]
    problems: list[str] = []
    observations: dict[str, Any] = {"target": target}

    staging_config = path_from_config(root, paths["staging_config"])
    production_config = path_from_config(root, paths["production_config"])
    staging_text = read_text(staging_config) if staging_config.is_file() else ""
    production_text = read_text(production_config) if production_config.is_file() else ""
    if not staging_text or not project_url_matches(
        extract_configured_url(staging_text) or "", config["environments"]["staging"]["project_ref"]
    ):
        problems.append("staging Flutter config does not identify the configured STAGING project")
    if not production_text or not project_url_matches(
        extract_configured_url(production_text) or "", config["environments"]["production"]["project_ref"]
    ):
        problems.append("production Flutter config does not identify the configured PRODUCTION project")

    entrypoint_path = path_from_config(root, env_cfg["flutter_entrypoint"])
    entrypoint_text = read_text(entrypoint_path) if entrypoint_path.is_file() else ""
    observations["flutter_entrypoint"] = rel_path(root, entrypoint_path)
    if not entrypoint_text:
        problems.append(f"configured Flutter entrypoint is missing: {rel_path(root, entrypoint_path)}")
    elif target == "local" and "main_staging.dart" not in entrypoint_text:
        problems.append("local/default Flutter entrypoint is not staging-compatible")
    elif target == "staging" and "supabase_config.dart" not in entrypoint_text:
        problems.append("STAGING entrypoint does not import the staging Supabase config")
    elif target == "production" and "production_supabase_config.dart" not in entrypoint_text:
        problems.append("PRODUCTION entrypoint does not import the production Supabase config")

    staging_website = path_from_config(root, paths["website_staging_config"])
    production_website = path_from_config(root, paths["website_production_config"])
    staging_website_text = read_text(staging_website) if staging_website.is_file() else ""
    production_website_text = read_text(production_website) if production_website.is_file() else ""
    if config["environments"]["staging"]["project_ref"] not in staging_website_text:
        problems.append("shared website config does not retain the STAGING project reference")
    if config["environments"]["production"]["project_ref"] not in production_website_text:
        problems.append("production website config does not identify the PRODUCTION project")
    if target == "production" and "STAGING — DUMMY DATA" in entrypoint_text:
        problems.append("PRODUCTION entrypoint contains the STAGING safety banner")

    if target in {"staging", "production"}:
        db_env = remote_db_url_env(config, target)
        db_url = os.environ.get(db_env, "").strip() if db_env else ""
        observations["read_only_db_url_configured"] = bool(db_url)
        if db_url and not db_url_matches(db_url, env_cfg["project_ref"]):
            problems.append(f"configured {target.upper()} database URL does not identify the target project")

    for label, path in (
        ("staging config", staging_config),
        ("production config", production_config),
        ("website staging config", staging_website),
        ("website production config", production_website),
    ):
        if not path.is_file():
            problems.append(f"{label} is missing")

    linked_ref_path = path_from_config(root, "thebest-app/supabase/.temp/project-ref")
    if linked_ref_path.is_file():
        linked_ref = read_text(linked_ref_path).strip()
        observations["linked_project_ref"] = linked_ref
        if target == "staging" and linked_ref != config["environments"]["staging"]["project_ref"]:
            problems.append("linked Supabase project is not the configured STAGING project")
    else:
        observations["linked_project_ref"] = None

    if problems:
        return CheckResult(
            "environment.identity",
            "ENVIRONMENT",
            BLOCKED,
            "environment identity guard failed: " + "; ".join(problems),
            observations | {"problems": problems},
            severity="high",
            blocking=True,
        )
    return CheckResult(
        "environment.identity",
        "ENVIRONMENT",
        PASS,
        f"{env_cfg['label']} identity matches repository configuration",
        observations | {"project_ref": env_cfg.get("project_ref")},
    )


def local_source_safety_check(root: Path, config: dict[str, Any]) -> CheckResult:
    paths = config["paths"]
    checked = [
        path_from_config(root, paths["staging_config"]),
        path_from_config(root, paths["production_config"]),
        path_from_config(root, paths["website_staging_config"]),
        path_from_config(root, paths["website_production_config"]),
        path_from_config(root, paths["booking_function"]),
    ]
    hits: list[str] = []
    missing: list[str] = []
    for path in checked:
        if not path.is_file():
            missing.append(rel_path(root, path))
            continue
        if SECRET_LITERAL_RE.search(read_text(path)):
            hits.append(rel_path(root, path))
    if hits:
        return CheckResult(
            "environment.secret_literals",
            "ENVIRONMENT",
            BLOCKED,
            "literal secret/service-role material detected in a checked source file",
            {"files": hits},
            severity="high",
            blocking=True,
        )
    if missing:
        return CheckResult(
            "environment.secret_literals",
            "ENVIRONMENT",
            UNKNOWN,
            "secret scan could not inspect all expected source files",
            {"missing": missing},
            severity="high",
        )
    return CheckResult(
        "environment.secret_literals",
        "ENVIRONMENT",
        PASS,
        "no literal Supabase secret/service-role value found in checked config/source files",
        {"files_checked": [rel_path(root, path) for path in checked]},
    )


def local_security_metadata_check(root: Path, config: dict[str, Any]) -> CheckResult:
    source_paths = [path_from_config(root, value) for value in config["migrations"]["promotion_security_sources"]]
    missing = [rel_path(root, path) for path in source_paths if not path.is_file()]
    if missing:
        return CheckResult(
            "security.local_promotion_contract",
            "SECURITY",
            UNKNOWN,
            "promotion security source inspection incomplete",
            {"missing": missing},
            severity="high",
        )
    core = read_text(source_paths[0]).lower()
    financial = read_text(source_paths[1]).lower()
    metadata = read_text(source_paths[2]).lower()
    normalized_metadata = re.sub(r"\s+", " ", metadata)
    normalized_all = re.sub(r"\s+", " ", core + "\n" + financial)
    expected_tables = [
        "promotions",
        "promotion_codes",
        "promotion_outlets",
        "promotion_services",
        "promotion_redemptions",
    ]
    missing_invariants: list[str] = []
    if "security definer" not in metadata:
        missing_invariants.append("SECURITY DEFINER")
    if "set search_path = ''" not in normalized_metadata:
        missing_invariants.append("empty search_path")
    if "usage_type text" not in normalized_metadata or "maximum_discount numeric" not in normalized_metadata:
        missing_invariants.append("usage_type/maximum_discount result columns")
    if "grant execute on function public.get_booking_promotion_metadata" not in normalized_metadata or "to service_role" not in normalized_metadata:
        missing_invariants.append("service_role-only execute grant")
    if "revoke all on function public.get_booking_promotion_metadata" not in normalized_metadata:
        missing_invariants.append("public/anon/authenticated execute revoke")
    # The historical migration intentionally contains the old claim gate, and
    # the latest ACL-fix migration documents that history in comments. Inspect
    # executable gate syntax rather than treating a comment mentioning the
    # claim as an active authorization check.
    if re.search(
        r"if\s+coalesce\s*\(\s*current_setting\s*\(\s*'request\.jwt\.claim\.role'",
        normalized_metadata,
    ):
        missing_invariants.append("redundant JWT claim gate")
    for table in expected_tables:
        if f"alter table public.{table} enable row level security" not in normalized_all:
            missing_invariants.append(f"RLS on {table}")
    if "create policy promotions_staff_select on public.promotions" not in normalized_all or "public.is_admin()" not in normalized_all:
        missing_invariants.append("admin promotion RLS policy")
    if re.search(r"grant\s+[^;]*on\s+public\.(promotions|promotion_codes|promotion_outlets|promotion_services|promotion_redemptions)[^;]*to\s+anon", normalized_all):
        missing_invariants.append("anonymous promotion-table grant")
    if missing_invariants:
        return CheckResult(
            "security.local_promotion_contract",
            "SECURITY",
            BLOCKED,
            "local promotion security invariants missing: " + ", ".join(missing_invariants),
            {"missing_invariants": missing_invariants},
            severity="high",
            blocking=True,
        )
    return CheckResult(
        "security.local_promotion_contract",
        "SECURITY",
        PASS,
        "local promotion metadata RPC and promotion-table security invariants are present",
        {
            "security_definer": True,
            "service_role_only": True,
            "jwt_claim_gate": False,
            "returns": ["usage_type", "maximum_discount"],
            "promotion_tables_rls": True,
            "anonymous_table_grant": False,
        },
    )


def static_checks(root: Path, config: dict[str, Any], target: str) -> list[CheckResult]:
    results: list[CheckResult] = []
    unit_argv = [sys.executable, "-B", "-m", "unittest", "tools.test_release_preflight"]
    unit_outcome = run_process(unit_argv, root, 120)
    results.append(
        result_from_process(
            "framework.unit_tests",
            "GIT",
            "framework unit tests",
            unit_argv,
            unit_outcome,
        )
    )

    frontend = path_from_config(root, config["paths"]["frontend"])
    flutter = find_executable("flutter")
    if not flutter:
        results.append(
            CheckResult(
                "flutter.analyze",
                "FLUTTER",
                NOT_RUN,
                "flutter unavailable on PATH",
                {"command": "flutter analyze --no-pub", "cwd": rel_path(root, frontend)},
                severity="high",
            )
        )
    else:
        argv = [flutter, "analyze", "--no-pub"]
        outcome = run_process(argv, frontend, 600)
        results.append(
            result_from_process(
                "flutter.analyze",
                "FLUTTER",
                "flutter analyze --no-pub",
                argv,
                outcome,
            )
        )

    deno = find_executable("deno")
    edge_checks = config.get("edge_static_checks", [])
    if not edge_checks:
        edge_checks = [
            {
                "id": "edge.booking_api_deno_check",
                "label": "booking-api deno check",
                "path": config["paths"]["booking_function"],
                "required": True,
            }
        ]
    for item in edge_checks:
        check_id = str(item["id"])
        label = str(item.get("label", check_id))
        function_path = path_from_config(root, str(item["path"]))
        required = bool(item.get("required", True))
        if not function_path.is_file():
            results.append(
                CheckResult(
                    check_id,
                    "EDGE FUNCTIONS",
                    BLOCKED,
                    f"{label}: source is missing",
                    {"path": rel_path(root, function_path)},
                    severity="high",
                    blocking=True,
                    required=required,
                )
            )
        elif not deno:
            results.append(
                CheckResult(
                    check_id,
                    "EDGE FUNCTIONS",
                    NOT_RUN,
                    f"{label}: deno unavailable on PATH",
                    {"command": "deno check " + rel_path(root, function_path)},
                    severity="high" if required else "warning",
                    required=required,
                )
            )
        else:
            argv = [deno, "check", str(function_path)]
            outcome = run_process(argv, root, 180)
            results.append(
                result_from_process(
                    check_id,
                    "EDGE FUNCTIONS",
                    label,
                    argv,
                    outcome,
                    required=required,
                )
            )

    node = find_executable("node")
    website_paths = [path_from_config(root, value) for value in config.get("website_syntax_files", [])]
    missing = [rel_path(root, path) for path in website_paths if not path.is_file()]
    if missing:
        results.append(
            CheckResult(
                "web.node_syntax",
                "WEB",
                BLOCKED,
                "website JavaScript syntax set is incomplete",
                {"missing": missing},
                severity="high",
                blocking=True,
            )
        )
    elif not node:
        results.append(
            CheckResult(
                "web.node_syntax",
                "WEB",
                NOT_RUN,
                "node unavailable on PATH",
                {"files": [rel_path(root, path) for path in website_paths]},
                severity="high",
            )
        )
    else:
        file_results: list[dict[str, Any]] = []
        any_failed = False
        any_unknown = False
        for path in website_paths:
            # The repository's existing syntax gate feeds source through
            # stdin. It avoids platform-specific realpath restrictions while
            # retaining Node's parser-only --check behavior.
            argv = [node, "--check", "-"]
            outcome = run_process(argv, root, 60, input_text=read_text(path))
            file_result = {
                "path": rel_path(root, path),
                "command": command_details(argv),
                "exit_code": outcome.returncode,
            }
            if not outcome.available or outcome.timed_out:
                any_unknown = True
                file_result["status"] = NOT_RUN if not outcome.available else UNKNOWN
            elif outcome.returncode != 0:
                any_failed = True
                file_result["status"] = FAIL
                file_result["output"] = short_output(outcome.output)
            else:
                file_result["status"] = PASS
            file_results.append(file_result)
        status = FAIL if any_failed else (UNKNOWN if any_unknown else PASS)
        results.append(
            CheckResult(
                "web.node_syntax",
                "WEB",
                status,
                f"Node syntax checks {status.lower()} for {len(website_paths)} website JavaScript files",
                {"files": file_results},
                severity="high" if status in (FAIL, UNKNOWN) else "info",
            )
        )
    return results


def resolve_supabase_cli() -> Optional[list[str]]:
    configured = os.environ.get("PREFLIGHT_SUPABASE_CLI", "").strip()
    if configured:
        resolved = find_executable(configured) or (configured if Path(configured).is_file() else None)
        return [resolved] if resolved else None
    direct = find_executable("supabase")
    if direct:
        return [direct]
    if os.environ.get("PREFLIGHT_DISABLE_NPX", "").lower() not in {"1", "true", "yes"}:
        npx = find_executable("npx")
        if npx:
            return [npx, "supabase"]
    return None


def supabase_command_is_read_only(argv: list[str]) -> bool:
    lowered = [Path(token).name.lower() if index == 0 else token.lower() for index, token in enumerate(argv)]
    banned = {
        "deploy",
        "repair",
        "push",
        "reset",
        "up",
        "down",
        "new",
        "link",
        "unlink",
        "delete",
        "remove",
        "set",
        "unset",
        "serve",
        "start",
        "stop",
    }
    if any(token in banned for token in lowered):
        return False
    try:
        supabase_index = next(
            index for index, token in enumerate(lowered) if token in {"supabase", "supabase.exe"}
        )
    except StopIteration:
        supabase_index = 0
    tail = lowered[supabase_index + 1 :]
    return (
        len(tail) >= 2
        and ((tail[0], tail[1]) == ("migration", "list") or (tail[0], tail[1]) == ("functions", "list")
             or (tail[0], tail[1]) == ("functions", "download"))
    )


def remote_db_url_env(config: dict[str, Any], target: str) -> Optional[str]:
    value = config["environments"][target].get("db_url_env")
    return str(value) if value else None


def linked_project_ref(root: Path) -> Optional[str]:
    path = path_from_config(root, "thebest-app/supabase/.temp/project-ref")
    if not path.is_file():
        return None
    value = read_text(path).strip()
    return value or None


def remote_ledger_plan(
    root: Path, target: str, config: dict[str, Any], cli: Optional[list[str]]
) -> tuple[str, Optional[list[str]], Optional[str]]:
    if target == "local":
        return "not_applicable", None, None
    expected_ref = config["environments"][target]["project_ref"]
    db_env = remote_db_url_env(config, target)
    db_url = os.environ.get(db_env, "").strip() if db_env else ""
    if db_url:
        if not db_url_matches(db_url, expected_ref):
            return "mismatch", None, db_env
        if not cli:
            return "cli_unavailable", None, db_env
        argv = [*cli, "migration", "list", "--db-url", db_url]
        return ("ready", argv if supabase_command_is_read_only(argv) else None, db_env)
    if target == "staging":
        linked = linked_project_ref(root)
        if linked and linked != expected_ref:
            return "mismatch", None, "linked project ref"
        if linked == expected_ref and cli:
            argv = [*cli, "migration", "list", "--linked"]
            return ("ready", argv if supabase_command_is_read_only(argv) else None, "linked STAGING project")
        return "access_unavailable", None, "PREFLIGHT_STAGING_DB_URL or matching linked project"
    return "access_unavailable", None, "PREFLIGHT_PRODUCTION_DB_URL"


def parse_migration_list(output: str) -> dict[str, set[str]]:
    local: set[str] = set()
    remote: set[str] = set()
    for line in output.splitlines():
        if "|" in line:
            columns = line.split("|")
            left = set(MIGRATION_VERSION_RE.findall(columns[0])) if columns else set()
            right = set(MIGRATION_VERSION_RE.findall(columns[1])) if len(columns) > 1 else set()
            local.update(left)
            remote.update(right)
        else:
            remote.update(MIGRATION_VERSION_RE.findall(line))
    return {"local": local, "remote": remote}


def compare_migration_ids(local: set[str], remote: set[str]) -> dict[str, Any]:
    local_only = sorted(local - remote)
    remote_only = sorted(remote - local)
    if not local_only and not remote_only:
        alignment = "aligned"
    elif local_only and not remote_only:
        alignment = "ahead"
    elif remote_only and not local_only:
        alignment = "behind"
    else:
        alignment = "diverged"
    return {
        "alignment": alignment,
        "local_only": local_only,
        "remote_only": remote_only,
        "local_count": len(local),
        "remote_count": len(remote),
    }


def remote_migration_check(
    root: Path, target: str, config: dict[str, Any], local_ids: set[str]
) -> CheckResult:
    if target == "local":
        return CheckResult(
            "migrations.remote_local",
            "MIGRATIONS",
            NOT_RUN,
            "remote migration ledger is not applicable to LOCAL mode",
            required=False,
        )
    cli = resolve_supabase_cli()
    state, argv, source = remote_ledger_plan(root, target, config, cli)
    if state == "mismatch":
        return CheckResult(
            f"migrations.remote_{target}",
            "MIGRATIONS",
            BLOCKED,
            f"{target.upper()} ledger access blocked because the detected project identity does not match the target",
            {"access_source": source},
            severity="high",
            blocking=True,
        )
    if state in {"access_unavailable", "cli_unavailable"} or not argv:
        return CheckResult(
            f"migrations.remote_{target}",
            "MIGRATIONS",
            NOT_RUN,
            f"{target.upper()} migration ledger: NOT_RUN; safe read-only access unavailable",
            {"reason": source, "access_source": source},
            severity="high",
        )
    outcome = run_process(argv, root, 90)
    if not outcome.available:
        return CheckResult(
            f"migrations.remote_{target}",
            "MIGRATIONS",
            NOT_RUN,
            f"{target.upper()} migration ledger: NOT_RUN; Supabase CLI unavailable",
            {"command": command_details(argv)},
            severity="high",
        )
    if outcome.timed_out or outcome.returncode != 0:
        return CheckResult(
            f"migrations.remote_{target}",
            "MIGRATIONS",
            UNKNOWN,
            f"{target.upper()} migration ledger could not be read safely",
            {"command": command_details(argv), "exit_code": outcome.returncode, "output": short_output(outcome.output)},
            severity="high",
        )
    parsed = parse_migration_list(outcome.stdout)
    remote_all = parsed["remote"]
    remote_ids = {value for value in remote_all if len(value) == 14}
    unrepresentable = sorted(value for value in remote_all if len(value) != 14)
    if unrepresentable:
        return CheckResult(
            f"migrations.remote_{target}",
            "MIGRATIONS",
            UNKNOWN,
            f"{target.upper()} ledger contains identities the local timestamp convention cannot represent",
            {"unrepresentable_remote_versions": unrepresentable, "remote_versions": sorted(remote_all)},
            severity="high",
        )
    comparison = compare_migration_ids(local_ids, remote_ids)
    alignment = comparison["alignment"]
    status = PASS if alignment == "aligned" else WARN
    if alignment in {"behind", "diverged"}:
        status = BLOCKED
    return CheckResult(
        f"migrations.remote_{target}",
        "MIGRATIONS",
        status,
        f"{target.upper()} ledger {alignment} (local={len(local_ids)} remote={len(remote_ids)})",
        {**comparison, "command": command_details(argv), "access_source": source},
        severity="high" if status == BLOCKED else ("warning" if status == WARN else "info"),
        blocking=status == BLOCKED,
    )


def parse_function_version(output: str, slug: str) -> Optional[str]:
    try:
        decoded = json.loads(output)
    except json.JSONDecodeError:
        decoded = None
    if decoded is not None:
        candidates: list[Any] = []

        def walk(value: Any) -> None:
            if isinstance(value, dict):
                identity = str(value.get("slug", value.get("name", "")))
                if identity == slug:
                    candidates.append(value.get("version", value.get("version_number")))
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(decoded)
        for candidate in candidates:
            if candidate is not None:
                return str(candidate)
    for line in output.splitlines():
        if slug.lower() not in line.lower():
            continue
        numbers = re.findall(r"(?<!\d)(\d{1,6})(?!\d)", line)
        if numbers:
            return numbers[-1]
    return None


def find_downloaded_function_source(directory: Path, slug: str) -> Optional[Path]:
    candidates = [path for path in directory.rglob("index.ts") if path.is_file()]
    exact = [path for path in candidates if path.parent.name == slug]
    if len(exact) == 1:
        return exact[0]
    if len(candidates) == 1:
        return candidates[0]
    return None


def remote_function_source_check(
    root: Path, target: str, config: dict[str, Any]
) -> CheckResult:
    if target == "local":
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            NOT_RUN,
            "deployed booking-api comparison is not applicable to LOCAL mode",
            required=False,
        )
    cli = resolve_supabase_cli()
    if not cli:
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            NOT_RUN,
            f"{target.upper()} booking-api source comparison: NOT_RUN; Supabase CLI unavailable",
            severity="high",
        )
    expected_ref = config["environments"][target]["project_ref"]
    slug = str(config.get("edge_functions", {}).get("booking_api_slug", "booking-api"))
    list_argv = [*cli, "functions", "list", "--project-ref", expected_ref]
    download_argv = [*cli, "functions", "download", slug, "--project-ref", expected_ref, "--use-api"]
    if not supabase_command_is_read_only(list_argv) or not supabase_command_is_read_only(download_argv):
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            BLOCKED,
            "internal Supabase command allowlist rejected the source-comparison plan",
            {"list_command": command_details(list_argv), "download_command": command_details(download_argv)},
            severity="high",
            blocking=True,
        )
    listed = run_process(list_argv, root, 90)
    if not listed.available:
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            NOT_RUN,
            f"{target.upper()} booking-api source comparison: NOT_RUN; CLI unavailable",
            {"command": command_details(list_argv)},
            severity="high",
        )
    if listed.timed_out or listed.returncode != 0:
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api function list could not be read",
            {"command": command_details(list_argv), "exit_code": listed.returncode, "output": short_output(listed.output)},
            severity="high",
        )
    version = parse_function_version(listed.stdout, slug)
    with tempfile.TemporaryDirectory(prefix="treats-release-preflight-") as temporary:
        temporary_path = Path(temporary)
        downloaded = run_process(download_argv, temporary_path, 120)
        if not downloaded.available:
            return CheckResult(
                "edge.booking_api_source_match",
                "EDGE FUNCTIONS",
                NOT_RUN,
                f"{target.upper()} booking-api source download: NOT_RUN; CLI unavailable",
                {"command": command_details(download_argv), "version": version},
                severity="high",
            )
        if downloaded.timed_out or downloaded.returncode != 0:
            return CheckResult(
                "edge.booking_api_source_match",
                "EDGE FUNCTIONS",
                UNKNOWN,
                f"{target.upper()} deployed booking-api source could not be obtained",
                {"command": command_details(download_argv), "exit_code": downloaded.returncode, "version": version, "output": short_output(downloaded.output)},
                severity="high",
            )
        remote_path = find_downloaded_function_source(temporary_path, slug)
        local_path = path_from_config(root, config["paths"]["booking_function"])
        if not remote_path or not local_path.is_file():
            return CheckResult(
                "edge.booking_api_source_match",
                "EDGE FUNCTIONS",
                UNKNOWN,
                f"{target.upper()} booking-api source download did not yield a comparable index.ts",
                {"version": version, "download_output": short_output(downloaded.output)},
                severity="high",
            )
        local_hash = normalized_sha256(local_path)
        remote_hash = normalized_sha256(remote_path)
        matches = local_hash == remote_hash
        return CheckResult(
            "edge.booking_api_source_match",
            "EDGE FUNCTIONS",
            PASS if matches else BLOCKED,
            f"{target.upper()} booking-api deployed source {'matches' if matches else 'differs from'} repository after CRLF/LF normalization"
            + (f" (version {version})" if version else ""),
            {
                "local_hash": local_hash,
                "deployed_hash": remote_hash,
                "version": version,
                "normalization": "CRLF/LF line endings only",
                "download_command": command_details(download_argv),
            },
            severity="high" if not matches else "info",
            blocking=not matches,
        )


def remote_health_check(target: str, config: dict[str, Any]) -> CheckResult:
    if target == "local":
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            NOT_RUN,
            "deployed booking-api health is not applicable to LOCAL mode",
            required=False,
        )
    env_cfg = config["environments"][target]
    slug = str(config.get("edge_functions", {}).get("booking_api_slug", "booking-api"))
    url = env_cfg["supabase_url"].rstrip("/") + f"/functions/v1/{slug}/health"
    request = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    response_project_ref: Optional[str] = None
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status_code = response.status
            response_project_ref = response.headers.get("sb-project-ref")
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health returned HTTP {error.code}",
            {"url": url, "http_status": error.code},
            severity="high",
        )
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health could not be read",
            {"url": url, "error": redact_sensitive(str(error))},
            severity="high",
        )
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health returned non-JSON data",
            {"url": url, "http_status": status_code},
            severity="high",
        )
    expected_ref = str(env_cfg.get("project_ref") or "").lower()
    if not response_project_ref:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health did not expose a project identity header",
            {"url": url, "http_status": status_code},
            severity="high",
        )
    if response_project_ref.lower() != expected_ref:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            BLOCKED,
            f"{target.upper()} booking-api health identified project {response_project_ref}, not the configured target",
            {
                "url": url,
                "http_status": status_code,
                "observed_project_ref": response_project_ref,
                "expected_project_ref": expected_ref,
            },
            severity="high",
            blocking=True,
        )
    missing_fields = [
        field for field in ("payment_enabled", "auto_confirm") if field not in payload
    ]
    if missing_fields:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health omitted required safety fields",
            {
                "url": url,
                "http_status": status_code,
                "observed_project_ref": response_project_ref,
                "missing_fields": missing_fields,
            },
            severity="high",
        )
    auto_confirm = payload.get("auto_confirm")
    payment_enabled = payload.get("payment_enabled")
    if not isinstance(auto_confirm, bool) or not isinstance(payment_enabled, bool):
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            UNKNOWN,
            f"{target.upper()} booking-api health returned non-boolean safety fields",
            {
                "url": url,
                "http_status": status_code,
                "observed_project_ref": response_project_ref,
                "payment_enabled_type": type(payment_enabled).__name__,
                "auto_confirm_type": type(auto_confirm).__name__,
            },
            severity="high",
        )
    problems: list[str] = []
    if auto_confirm is True:
        problems.append("auto-confirm is enabled")
    if payment_enabled is False:
        problems.append("payment is disabled")
    if problems:
        return CheckResult(
            "edge.booking_api_health",
            "EDGE FUNCTIONS",
            BLOCKED,
            f"{target.upper()} booking-api health is unsafe: " + "; ".join(problems),
            {
                "url": url,
                "http_status": status_code,
                "observed_project_ref": response_project_ref,
                "payment_enabled": payment_enabled,
                "payment_collection_mode": payload.get("payment_collection_mode"),
                "payment_cleanup_enabled": payload.get("payment_cleanup_enabled"),
                "auto_confirm": auto_confirm,
            },
            severity="high",
            blocking=True,
        )
    return CheckResult(
        "edge.booking_api_health",
        "EDGE FUNCTIONS",
        PASS,
        f"{target.upper()} booking-api health is reachable; payment_enabled={payment_enabled}; auto_confirm={auto_confirm}",
        {
            "url": url,
            "http_status": status_code,
            "observed_project_ref": response_project_ref,
            "payment_enabled": payment_enabled,
            "payment_collection_mode": payload.get("payment_collection_mode"),
            "payment_cleanup_enabled": payload.get("payment_cleanup_enabled"),
            "auto_confirm": auto_confirm,
        },
    )


READ_ONLY_SECURITY_SQL = """
select json_build_object(
  'function_exists', to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null,
  'security_definer', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then
    (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_booking_promotion_metadata(uuid,text)')) else false end,
  'public_execute', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then has_function_privilege('public', 'public.get_booking_promotion_metadata(uuid,text)', 'execute') else false end,
  'anon_execute', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then has_function_privilege('anon', 'public.get_booking_promotion_metadata(uuid,text)', 'execute') else false end,
  'authenticated_execute', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then has_function_privilege('authenticated', 'public.get_booking_promotion_metadata(uuid,text)', 'execute') else false end,
  'service_role_execute', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then has_function_privilege('service_role', 'public.get_booking_promotion_metadata(uuid,text)', 'execute') else false end,
  'returns_metadata', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then
    pg_get_function_result(to_regprocedure('public.get_booking_promotion_metadata(uuid,text)')) ilike '%usage_type%maximum_discount%' else false end,
  'jwt_claim_gate', case when to_regprocedure('public.get_booking_promotion_metadata(uuid,text)') is not null then
    pg_get_functiondef(to_regprocedure('public.get_booking_promotion_metadata(uuid,text)')) ilike '%request.jwt.claim.role%' else false end,
  'promotion_tables_rls', coalesce((select bool_and(c.relrowsecurity)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = any(array['promotions','promotion_codes','promotion_outlets','promotion_services','promotion_redemptions'])), false),
  'anonymous_table_select', coalesce((select bool_or(has_table_privilege('anon', 'public.' || c.relname, 'select'))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = any(array['promotions','promotion_codes','promotion_outlets','promotion_services','promotion_redemptions'])), false),
  'admin_promotion_policies', (select count(*) >= 5 from pg_policies
    where schemaname = 'public' and tablename = any(array['promotions','promotion_codes','promotion_outlets','promotion_services','promotion_redemptions'])
      and coalesce(qual, '') ilike '%is_admin%')
)::text;
""".strip()


def read_only_sql_is_safe(sql: str) -> bool:
    return not re.search(
        r"\b(insert|update|delete|alter|drop|create|grant|revoke|truncate|vacuum|copy|do)\b",
        sql,
        re.IGNORECASE,
    )


def remote_security_check(root: Path, target: str, config: dict[str, Any]) -> CheckResult:
    if target == "local":
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            NOT_RUN,
            "remote security metadata is not applicable to LOCAL mode",
            required=False,
        )
    db_env = remote_db_url_env(config, target)
    db_url = os.environ.get(db_env, "").strip() if db_env else ""
    expected_ref = config["environments"][target]["project_ref"]
    if not db_url:
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            NOT_RUN,
            f"{target.upper()} promotion security metadata: NOT_RUN; safe read-only database access unavailable",
            {"reason": "safe read-only access unavailable", "db_url_env": db_env},
            severity="high",
        )
    if not db_url_matches(db_url, expected_ref):
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            BLOCKED,
            f"{target.upper()} security query blocked because the configured read-only database URL is not the target project",
            {"db_url_env": db_env, "expected_project_ref": expected_ref},
            severity="high",
            blocking=True,
        )
    psql = find_executable("psql")
    if not psql:
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            NOT_RUN,
            f"{target.upper()} promotion security metadata: NOT_RUN; psql unavailable",
            {"db_url_env": db_env},
            severity="high",
        )
    if not read_only_sql_is_safe(READ_ONLY_SECURITY_SQL):
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            BLOCKED,
            "internal security metadata query failed its read-only safety assertion",
            {},
            severity="high",
            blocking=True,
        )
    argv = [psql, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", READ_ONLY_SECURITY_SQL, db_url]
    outcome = run_process(argv, root, 90)
    if not outcome.available:
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            NOT_RUN,
            f"{target.upper()} promotion security metadata: NOT_RUN; psql unavailable",
            {"db_url_env": db_env},
            severity="high",
        )
    if outcome.timed_out or outcome.returncode != 0:
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            UNKNOWN,
            f"{target.upper()} promotion security metadata could not be read",
            {"command": command_details(argv), "exit_code": outcome.returncode, "output": short_output(outcome.output)},
            severity="high",
        )
    lines = [line.strip() for line in outcome.stdout.splitlines() if line.strip()]
    try:
        metadata = json.loads(lines[-1])
    except (IndexError, json.JSONDecodeError):
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            UNKNOWN,
            f"{target.upper()} promotion security metadata returned an unparseable result",
            {"command": command_details(argv), "output": short_output(outcome.output)},
            severity="high",
        )
    required_values = {
        "function_exists": True,
        "security_definer": True,
        "public_execute": False,
        "anon_execute": False,
        "authenticated_execute": False,
        "service_role_execute": True,
        "returns_metadata": True,
        "jwt_claim_gate": False,
        "promotion_tables_rls": True,
        "anonymous_table_select": False,
        "admin_promotion_policies": True,
    }
    mismatches = [
        key for key, expected in required_values.items() if metadata.get(key) is not expected
    ]
    if mismatches:
        return CheckResult(
            "security.remote_promotion_metadata",
            "SECURITY",
            BLOCKED,
            f"{target.upper()} promotion security metadata invariant mismatch: {', '.join(mismatches)}",
            {"observed": metadata, "expected": required_values},
            severity="high",
            blocking=True,
        )
    return CheckResult(
        "security.remote_promotion_metadata",
        "SECURITY",
        PASS,
        f"{target.upper()} promotion metadata RPC ACL/RLS invariants verified read-only",
        {"observed": metadata, "expected": required_values},
    )


def billplz_mode_check(target: str, config: dict[str, Any]) -> CheckResult:
    if target == "local":
        return CheckResult(
            "payment.billplz_mode",
            "PAYMENT CONFIG",
            PASS,
            "Billplz mode is not applicable to LOCAL-only checks; no payment call made",
            {"mode": None, "remote_call": False},
            required=False,
        )
    expected = str(config["environments"][target].get("expected_billplz_mode") or "").lower()
    marker_name = f"PREFLIGHT_BILLPLZ_MODE_{target.upper()}"
    observed = os.environ.get(marker_name, "").strip().lower()
    if not observed:
        return CheckResult(
            "payment.billplz_mode",
            "PAYMENT CONFIG",
            UNKNOWN,
            f"BILLPLZ_MODE: UNKNOWN ({marker_name} not configured; secrets are not read)",
            {"mode": None, "expected": expected, "marker": marker_name},
            severity="high",
        )
    if observed not in {"sandbox", "live"}:
        return CheckResult(
            "payment.billplz_mode",
            "PAYMENT CONFIG",
            BLOCKED,
            "Billplz mode marker is invalid; refusing to infer environment safety",
            {"mode": "UNKNOWN", "expected": expected, "marker": marker_name},
            severity="high",
            blocking=True,
        )
    if observed != expected:
        return CheckResult(
            "payment.billplz_mode",
            "PAYMENT CONFIG",
            BLOCKED,
            f"BILLPLZ_MODE: {observed.upper()} conflicts with {target.upper()} policy ({expected.upper()})",
            {"mode": observed, "expected": expected, "marker": marker_name},
            severity="high",
            blocking=True,
        )
    return CheckResult(
        "payment.billplz_mode",
        "PAYMENT CONFIG",
        PASS,
        f"BILLPLZ_MODE: {observed.upper()} matches {target.upper()} policy",
        {"mode": observed, "expected": expected, "marker": marker_name, "remote_call": False},
    )


def integration_checks(
    root: Path, target: str, config: dict[str, Any], extended: bool
) -> list[CheckResult]:
    results: list[CheckResult] = []
    for item in config.get("integration_checks", []):
        check_id = str(item["id"])
        classification = str(item.get("classification", "classified integration check"))
        safety = str(item.get("safety", "safety classification unavailable"))
        common = {
            "classification": classification,
            "safety": safety,
            "path": item.get("path"),
            "executed": False,
        }
        if not extended:
            results.append(
                CheckResult(
                    check_id,
                    "INTEGRATION",
                    NOT_RUN,
                    f"{check_id}: NOT_RUN by default ({classification})",
                    common,
                    required=False,
                )
            )
            continue
        if target != "staging":
            results.append(
                CheckResult(
                    check_id,
                    "INTEGRATION",
                    NOT_RUN,
                    f"{check_id}: NOT_RUN; staging-only integration cannot run for {target.upper()}",
                    common,
                    required=False,
                )
            )
            continue
        opt_in_name = str(item.get("required_opt_in", ""))
        if os.environ.get(opt_in_name) != item.get("required_opt_in_value", "I_UNDERSTAND"):
            results.append(
                CheckResult(
                    check_id,
                    "INTEGRATION",
                    NOT_RUN,
                    f"{check_id}: NOT_RUN; explicit {opt_in_name}=I_UNDERSTAND is required",
                    common | {"required_opt_in": opt_in_name},
                    required=False,
                )
            )
            continue
        required_env = [str(name) for name in item.get("required_env", [])]
        missing_env = [name for name in required_env if not os.environ.get(name)]
        if missing_env:
            results.append(
                CheckResult(
                    check_id,
                    "INTEGRATION",
                    NOT_RUN,
                    f"{check_id}: NOT_RUN; required test inputs are unavailable",
                    common | {"missing_env": missing_env},
                    required=False,
                )
            )
            continue
        kind = item.get("kind")
        if kind == "psql_sql":
            db_env = remote_db_url_env(config, "staging")
            db_url = os.environ.get(db_env, "").strip() if db_env else ""
            if not db_url or not db_url_matches(db_url, config["environments"]["staging"]["project_ref"]):
                results.append(
                    CheckResult(
                        check_id,
                        "INTEGRATION",
                        NOT_RUN,
                        f"{check_id}: NOT_RUN; matching STAGING read-only/rollback database URL unavailable",
                        common | {"db_url_env": db_env},
                        required=False,
                    )
                )
                continue
            psql = find_executable("psql")
            contract_path = path_from_config(root, str(item["path"]))
            sql = read_text(contract_path) if contract_path.is_file() else ""
            rollback_only = bool(re.search(r"\bbegin\s*;", sql, re.IGNORECASE)) and bool(
                re.search(r"\brollback\s*;", sql, re.IGNORECASE)
            ) and not bool(re.search(r"\bcommit\s*;", sql, re.IGNORECASE))
            if not rollback_only:
                results.append(
                    CheckResult(
                        check_id,
                        "INTEGRATION",
                        BLOCKED,
                        f"{check_id}: blocked because the configured SQL is not proven rollback-only",
                        common,
                        severity="high",
                        blocking=True,
                    )
                )
                continue
            if not psql:
                results.append(
                    CheckResult(
                        check_id,
                        "INTEGRATION",
                        NOT_RUN,
                        f"{check_id}: NOT_RUN; psql unavailable",
                        common,
                        required=False,
                    )
                )
                continue
            argv = [psql, "-X", "-v", "ON_ERROR_STOP=1", "-f", str(contract_path), db_url]
        elif kind == "deno_test":
            deno = find_executable("deno")
            if not deno:
                results.append(
                    CheckResult(
                        check_id,
                        "INTEGRATION",
                        NOT_RUN,
                        f"{check_id}: NOT_RUN; deno unavailable",
                        common,
                        required=False,
                    )
                )
                continue
            argv = [
                deno,
                "test",
                "--allow-env",
                "--allow-net",
                str(path_from_config(root, str(item["path"]))),
            ]
        else:
            results.append(
                CheckResult(
                    check_id,
                    "INTEGRATION",
                    BLOCKED,
                    f"{check_id}: blocked because its integration runner is not recognized",
                    common,
                    severity="high",
                    blocking=True,
                )
            )
            continue
        outcome = run_process(argv, root, 300)
        result = result_from_process(
            check_id,
            "INTEGRATION",
            check_id,
            argv,
            outcome,
            required=False,
        )
        result.details = common | (result.details or {}) | {"executed": True}
        results.append(result)
    return results


def production_delta_check(
    target: str, results: list[CheckResult]
) -> CheckResult:
    if target != "production":
        return CheckResult(
            "production.delta",
            "PRODUCTION DELTA",
            NOT_RUN,
            "Production delta is only generated in PRODUCTION mode",
            required=False,
        )
    ledger = next((item for item in results if item.id == "migrations.remote_production"), None)
    function = next((item for item in results if item.id == "edge.booking_api_source_match"), None)
    details: dict[str, Any] = {
        "migrations_missing_on_production": [],
        "migrations_only_on_production": [],
        "booking_api": "unavailable",
        "flutter_artifact": "comparison unavailable; release build is not run by default",
        "website_deployment": "deployment identity unavailable",
    }
    if ledger and isinstance(ledger.details, dict):
        details["migrations_missing_on_production"] = ledger.details.get("local_only", [])
        details["migrations_only_on_production"] = ledger.details.get("remote_only", [])
    if function:
        if function.status == PASS:
            details["booking_api"] = "matches repository"
        elif function.status == BLOCKED:
            details["booking_api"] = "deployed source differs"
        elif function.status in {NOT_RUN, UNKNOWN}:
            details["booking_api"] = "comparison unavailable"
    if ledger and ledger.status in {PASS, WARN, BLOCKED}:
        status = PASS
        summary = "Production delta generated from the read-only ledger/function observations"
    else:
        status = UNKNOWN
        summary = "Production delta is incomplete because the read-only ledger is unavailable"
    return CheckResult(
        "production.delta",
        "PRODUCTION DELTA",
        status,
        summary,
        details,
        severity="warning" if status == UNKNOWN else "info",
        required=False,
    )


def known_blocker_checks(target: str, config: dict[str, Any]) -> list[CheckResult]:
    results: list[CheckResult] = []
    for blocker in config.get("known_blockers", []):
        if not blocker.get("active", True):
            continue
        applies_to = blocker.get("applies_to", ["production"])
        if target not in applies_to and "all" not in applies_to:
            continue
        status = str(blocker.get("status", BLOCKED)).upper()
        if status not in STATUSES:
            status = BLOCKED
        results.append(
            CheckResult(
                f"known.{blocker.get('id', 'unnamed')}",
                "KNOWN BLOCKERS",
                status,
                f"{blocker.get('id', 'unnamed')}: {blocker.get('summary', 'known release blocker')}",
                {
                    "reason": blocker.get("reason"),
                    "state": blocker.get("state"),
                    "severity": blocker.get("severity"),
                    "release_scope": blocker.get("release_scope", "production"),
                },
                severity=str(blocker.get("severity", "high")),
                required=False,
                blocking=status in {BLOCKED, FAIL},
                technical_gate=False,
            )
        )
    return results


def compute_technical_status(results: list[CheckResult]) -> str:
    gated = [item for item in results if item.technical_gate and item.required]
    if any(item.status == BLOCKED for item in gated):
        return BLOCKED
    if any(item.status == FAIL for item in gated):
        return FAIL
    if any(item.status in {UNKNOWN, NOT_RUN} for item in gated):
        return UNKNOWN
    return PASS


def compute_release_status(target: str, results: list[CheckResult], technical_status: str) -> str:
    if any(item.category == "KNOWN BLOCKERS" and item.blocking for item in results):
        return "BLOCKED_FOR_PRODUCTION"
    if technical_status != PASS:
        return "NOT_READY"
    return "READY_FOR_PRODUCTION" if target == "production" else "READY_FOR_NEXT_STAGE"


def choose_exit_code(target: str, results: list[CheckResult], technical_status: str) -> int:
    if any(item.id == "environment.identity" and item.status == BLOCKED for item in results):
        return 2
    if technical_status in {BLOCKED, FAIL}:
        return 1
    if technical_status == UNKNOWN:
        return 3
    if any(item.category == "KNOWN BLOCKERS" and item.blocking for item in results):
        return 4
    return 0


def run_preflight(root: Path, target: str, config: dict[str, Any], extended: bool) -> dict[str, Any]:
    results: list[CheckResult] = []
    environment_result = environment_identity_check(root, target, config)
    results.append(environment_result)
    results.append(local_source_safety_check(root, config))
    git_result, git_state = git_checks(root, config)
    results.extend(git_result)
    migration_result, migration_state = migration_integrity(root, config)
    results.extend(migration_result)
    results.extend(static_checks(root, config, target))
    results.append(local_security_metadata_check(root, config))

    environment_safe = environment_result.status == PASS
    if target in {"staging", "production"} and environment_safe:
        results.append(remote_migration_check(root, target, config, migration_state["ids"]))
        results.append(remote_health_check(target, config))
        results.append(remote_function_source_check(root, target, config))
        results.append(remote_security_check(root, target, config))
        results.append(billplz_mode_check(target, config))
    else:
        if target in {"staging", "production"}:
            results.extend(
                [
                    CheckResult(
                        f"migrations.remote_{target}",
                        "MIGRATIONS",
                        NOT_RUN,
                        f"{target.upper()} remote checks stopped after environment identity failure",
                        required=True,
                        severity="high",
                    ),
                    CheckResult(
                        "edge.booking_api_health",
                        "EDGE FUNCTIONS",
                        NOT_RUN,
                        f"{target.upper()} booking-api health stopped after environment identity failure",
                        required=True,
                        severity="high",
                    ),
                    CheckResult(
                        "edge.booking_api_source_match",
                        "EDGE FUNCTIONS",
                        NOT_RUN,
                        f"{target.upper()} booking-api source comparison stopped after environment identity failure",
                        required=True,
                        severity="high",
                    ),
                    CheckResult(
                        "security.remote_promotion_metadata",
                        "SECURITY",
                        NOT_RUN,
                        f"{target.upper()} security metadata stopped after environment identity failure",
                        required=True,
                        severity="high",
                    ),
                    CheckResult(
                        "payment.billplz_mode",
                        "PAYMENT CONFIG",
                        NOT_RUN,
                        f"{target.upper()} payment mode stopped after environment identity failure",
                        required=True,
                        severity="high",
                    ),
                ]
            )
        else:
            results.append(billplz_mode_check(target, config))

    results.extend(integration_checks(root, target, config, extended))
    results.append(production_delta_check(target, results))
    results.extend(known_blocker_checks(target, config))
    technical_status = compute_technical_status(results)
    release_status = compute_release_status(target, results, technical_status)
    exit_code = choose_exit_code(target, results, technical_status)
    return {
        "target": target,
        "target_label": config["environments"][target]["label"],
        "project_ref": config["environments"][target].get("project_ref"),
        "branch": git_state.get("branch"),
        "head": git_state.get("head"),
        "reference_head": config.get("release", {}).get("reference_head"),
        "technical_status": technical_status,
        "release_status": release_status,
        "exit_code": exit_code,
        "checks": [item.to_dict() for item in results],
    }


def print_human(report: dict[str, Any]) -> None:
    print("=" * 40)
    print("TREATs RELEASE PREFLIGHT")
    print("=" * 40)
    print(f"Target: {report['target_label']}")
    print(f"Branch: {report.get('branch') or '(unavailable)'}")
    print(f"HEAD: {report.get('head') or '(unavailable)'}")
    if report.get("reference_head"):
        print(f"Frozen reference: {report['reference_head']}")
    print()
    grouped: dict[str, list[dict[str, Any]]] = {}
    for check in report["checks"]:
        grouped.setdefault(check["category"], []).append(check)
    for category in CATEGORY_ORDER:
        checks = grouped.get(category, [])
        if not checks:
            continue
        visible = [
            check
            for check in checks
            if not (
                check["status"] == NOT_RUN
                and not check["required"]
                and category not in {"INTEGRATION", "KNOWN BLOCKERS"}
            )
        ]
        if not visible:
            continue
        print(category)
        for check in visible:
            print(f"{check['status']:<8} {check['summary']}")
            if check["id"] == "edge.booking_api_source_match" and isinstance(check.get("details"), dict):
                details = check["details"]
                if details.get("local_hash") and details.get("deployed_hash"):
                    print(f"         Local hash: {details['local_hash']}")
                    print(f"         Deployed hash: {details['deployed_hash']}")
            if check["id"] == "production.delta" and isinstance(check.get("details"), dict):
                details = check["details"]
                missing = details.get("migrations_missing_on_production", [])
                if missing:
                    print("         Migrations missing on Production: " + ", ".join(missing))
                print(f"         booking-api: {details.get('booking_api')}")
                print(f"         Flutter artifact: {details.get('flutter_artifact')}")
                print(f"         Website deployment: {details.get('website_deployment')}")
        print()
    print("-" * 40)
    print(f"TECHNICAL PREFLIGHT: {report['technical_status']}")
    print(f"PRODUCTION RELEASE: {report['release_status']}")
    print(f"EXIT CODE: {report['exit_code']}")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Treats release preflight")
    parser.add_argument("--target", choices=("local", "staging", "production"), required=True)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--extended", action="store_true", help="consider separately gated STAGING integration checks")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).with_name("release_preflight_config.json"),
        help="path to the non-secret preflight configuration manifest",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    root = repo_root_from_script()
    try:
        config = load_config(args.config.resolve())
        report = run_preflight(root, args.target, config, args.extended)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        report = {
            "target": args.target,
            "target_label": args.target.upper(),
            "project_ref": None,
            "branch": None,
            "head": None,
            "reference_head": None,
            "technical_status": BLOCKED,
            "release_status": "NOT_READY",
            "exit_code": 3,
            "checks": [
                CheckResult(
                    "configuration.load",
                    "ENVIRONMENT",
                    BLOCKED,
                    "preflight configuration could not be loaded",
                    {"error": redact_sensitive(str(error))},
                    severity="high",
                    blocking=True,
                ).to_dict()
            ],
        }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_human(report)
    return int(report["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())

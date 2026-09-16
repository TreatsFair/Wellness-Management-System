import unittest
import json
from pathlib import Path
from unittest.mock import patch

from tools import release_preflight as preflight


class ReleasePreflightLogicTests(unittest.TestCase):
    def test_pass_aggregation(self) -> None:
        checks = [
            preflight.CheckResult("a", "GIT", preflight.PASS, "ok"),
            preflight.CheckResult("b", "WEB", preflight.PASS, "ok"),
        ]
        self.assertEqual(preflight.compute_technical_status(checks), preflight.PASS)

    def test_warn_does_not_become_failure(self) -> None:
        checks = [
            preflight.CheckResult("a", "GIT", preflight.PASS, "ok"),
            preflight.CheckResult("b", "MIGRATIONS", preflight.WARN, "legacy"),
        ]
        self.assertEqual(preflight.compute_technical_status(checks), preflight.PASS)

    def test_blocked_becomes_blocked(self) -> None:
        checks = [preflight.CheckResult("a", "ENVIRONMENT", preflight.BLOCKED, "mismatch")]
        self.assertEqual(preflight.compute_technical_status(checks), preflight.BLOCKED)

    def test_required_unknown_does_not_become_pass(self) -> None:
        checks = [preflight.CheckResult("a", "SECURITY", preflight.UNKNOWN, "not proven")]
        self.assertEqual(preflight.compute_technical_status(checks), preflight.UNKNOWN)

    def test_optional_not_run_does_not_block_local_mode(self) -> None:
        checks = [
            preflight.CheckResult("static", "GIT", preflight.PASS, "ok"),
            preflight.CheckResult("remote", "MIGRATIONS", preflight.NOT_RUN, "not applicable", required=False),
        ]
        self.assertEqual(preflight.compute_technical_status(checks), preflight.PASS)

    def test_known_blocker_prevents_production_ready_state(self) -> None:
        checks = [
            preflight.CheckResult("static", "GIT", preflight.PASS, "ok"),
            preflight.CheckResult(
                "known.payment",
                "KNOWN BLOCKERS",
                preflight.BLOCKED,
                "pending",
                blocking=True,
                required=False,
                technical_gate=False,
            ),
        ]
        technical = preflight.compute_technical_status(checks)
        self.assertEqual(technical, preflight.PASS)
        self.assertEqual(
            preflight.compute_release_status("production", checks, technical),
            "BLOCKED_FOR_PRODUCTION",
        )

    def test_project_identity_mismatch_fails_closed(self) -> None:
        self.assertTrue(
            preflight.project_url_matches(
                "https://hvyzexmsaxwendcexehx.supabase.co",
                "hvyzexmsaxwendcexehx",
            )
        )
        self.assertFalse(
            preflight.project_url_matches(
                "https://erjttzhownsxohpvzjbs.supabase.co",
                "hvyzexmsaxwendcexehx",
            )
        )
        self.assertFalse(
            preflight.db_url_matches(
                "postgresql://user:password@aws-1-ap-northeast-1.pooler.supabase.com:5432/postgres",
                "hvyzexmsaxwendcexehx",
            )
        )
        self.assertTrue(
            preflight.db_url_matches(
                "postgresql://postgres.hvyzexmsaxwendcexehx:password@aws-1-ap-northeast-1.pooler.supabase.com:5432/postgres",
                "hvyzexmsaxwendcexehx",
            )
        )

    def test_migration_comparison_states(self) -> None:
        aligned = preflight.compare_migration_ids({"1", "2"}, {"1", "2"})
        ahead = preflight.compare_migration_ids({"1", "2"}, {"1"})
        behind = preflight.compare_migration_ids({"1"}, {"1", "2"})
        diverged = preflight.compare_migration_ids({"1", "3"}, {"1", "2"})
        self.assertEqual(aligned["alignment"], "aligned")
        self.assertEqual(ahead["alignment"], "ahead")
        self.assertEqual(behind["alignment"], "behind")
        self.assertEqual(diverged["alignment"], "diverged")

    def test_migration_list_parser_keeps_local_and_remote_columns(self) -> None:
        parsed = preflight.parse_migration_list(
            "LOCAL | REMOTE | TIME\n20260903124110 | 20260903124110 | 2026-09-03\n"
            "             | 20260903124426 | 2026-09-03\n"
        )
        self.assertEqual(parsed["local"], {"20260903124110"})
        self.assertEqual(parsed["remote"], {"20260903124110", "20260903124426"})

    def test_production_remote_plan_contains_only_read_only_supabase_commands(self) -> None:
        config = {
            "environments": {
                "production": {
                    "project_ref": "erjttzhownsxohpvzjbs",
                    "db_url_env": "PREFLIGHT_PRODUCTION_DB_URL",
                }
            }
        }
        with patch.dict(
            "os.environ",
            {
                "PREFLIGHT_PRODUCTION_DB_URL": "postgresql://user:password@erjttzhownsxohpvzjbs.pooler.supabase.com:5432/postgres"
            },
            clear=False,
        ):
            state, argv, _ = preflight.remote_ledger_plan(
                Path.cwd(), "production", config, ["supabase"]
            )
        self.assertEqual(state, "ready")
        self.assertIsNotNone(argv)
        self.assertTrue(preflight.supabase_command_is_read_only(argv or []))
        self.assertNotIn("repair", [part.lower() for part in (argv or [])])
        self.assertNotIn("push", [part.lower() for part in (argv or [])])
        self.assertNotIn("deploy", [part.lower() for part in (argv or [])])

    def test_production_never_runs_staging_integration_checks(self) -> None:
        config = {
            "integration_checks": [
                {
                    "id": "fixture",
                    "kind": "deno_test",
                    "path": "missing.ts",
                    "required_opt_in": "PREFLIGHT_ALLOW_STAGING_FIXTURES",
                    "required_opt_in_value": "I_UNDERSTAND",
                }
            ],
            "environments": {
                "staging": {"project_ref": "hvyzexmsaxwendcexehx", "db_url_env": "STAGING_DB"}
            },
        }
        with patch("tools.release_preflight.run_process") as mocked_run:
            results = preflight.integration_checks(Path.cwd(), "production", config, extended=True)
        self.assertEqual(results[0].status, preflight.NOT_RUN)
        mocked_run.assert_not_called()

    def test_read_only_security_query_has_no_mutating_statement(self) -> None:
        self.assertTrue(preflight.read_only_sql_is_safe(preflight.READ_ONLY_SECURITY_SQL))

    def test_local_security_check_uses_latest_acl_fix_not_historical_comment(self) -> None:
        root = Path.cwd()
        config = preflight.load_config(root / "tools" / "release_preflight_config.json")
        result = preflight.local_security_metadata_check(root, config)
        self.assertEqual(result.status, preflight.PASS)

    def test_sensitive_environment_values_are_not_retained_in_output(self) -> None:
        with patch.dict("os.environ", {"PREFLIGHT_TEST_SECRET_TOKEN": "never-print-this"}, clear=False):
            self.assertNotIn("never-print-this", preflight.redact_sensitive("failure never-print-this"))

    def test_health_check_missing_safety_fields_is_unknown(self) -> None:
        class Response:
            status = 200
            headers = {"sb-project-ref": "hvyzexmsaxwendcexehx"}

            def read(self) -> bytes:
                return json.dumps({"status": "ok"}).encode("utf-8")

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        config = {
            "environments": {
                "staging": {
                    "project_ref": "hvyzexmsaxwendcexehx",
                    "supabase_url": "https://hvyzexmsaxwendcexehx.supabase.co",
                }
            }
        }
        with patch("urllib.request.urlopen", return_value=Response()):
            result = preflight.remote_health_check("staging", config)
        self.assertEqual(result.status, preflight.UNKNOWN)


if __name__ == "__main__":
    unittest.main()

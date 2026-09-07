import json
import re
import subprocess
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "build-image.yml"


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        cls.workflow = workflow
        start = workflow.index(
            "      - name: Create or validate VERSION-push draft release"
        )
        end = workflow.index(
            "      - name: Confirm matching GitHub release exists", start
        )
        cls.draft_step = workflow[start:end]
        cls.publish_step = workflow[workflow.index(
            "      - name: Publish verified VERSION-push release"
        ):]

    def test_release_create_retries_are_bounded(self):
        self.assertIn("release_create_delays=(2 4 8 16)", self.draft_step)
        self.assertRegex(
            self.draft_step,
            re.compile(
                r"for \(\(release_create_attempt = 1;\s*"
                r"release_create_attempt <= \$\{#release_create_delays\[@\]\};\s*"
                r"release_create_attempt\+\+\)\)"
            ),
        )
        self.assertIn(
            "Release draft did not become visible after "
            "${#release_create_delays[@]} bounded create attempts",
            self.draft_step,
        )

    def test_fresh_tag_uses_create_response_without_immediate_get(self):
        create = self.draft_step.index(
            "            tag_response=$(gh api --method POST"
        )
        visibility_start = self.draft_step.index(
            '          if [ "${tag_created}" = true ]', create
        )
        fresh_tag_create = self.draft_step[create:visibility_start]

        self.assertIn(
            '"repos/${GITHUB_REPOSITORY}/git/refs" --input -',
            fresh_tag_create,
        )
        self.assertIn(
            'resolve_tag_commit "${tag_response}"', fresh_tag_create
        )
        self.assertIn("tag_created=true", fresh_tag_create)
        self.assertNotIn(
            "git/ref/tags/${RELEASE_TAG}", fresh_tag_create
        )

    def test_fresh_tag_visibility_poll_is_bounded_and_exact(self):
        visibility_start = self.draft_step.index(
            '          if [ "${tag_created}" = true ]'
        )
        release_setup = self.draft_step.index(
            "          prerelease=false", visibility_start
        )
        visibility = self.draft_step[visibility_start:release_setup]

        self.assertIn("tag_visibility_delays=(2 4 8 16)", visibility)
        self.assertRegex(
            visibility,
            re.compile(
                r"for \(\(tag_visibility_attempt = 1;\s*"
                r"tag_visibility_attempt <= \$\{#tag_visibility_delays\[@\]\};\s*"
                r"tag_visibility_attempt\+\+\)\)"
            ),
        )
        self.assertIn("*'(HTTP 404)'*) ;;", visibility)
        self.assertIn(
            '"$(resolve_tag_commit "${tag_response}")" = "${SOURCE_COMMIT}"',
            visibility,
        )
        self.assertIn(
            "Created tag did not become visible after "
            "${#tag_visibility_delays[@]} bounded checks",
            visibility,
        )

    def test_each_post_is_guarded_by_exact_tag_and_release_recheck(self):
        loop_start = self.draft_step.index(
            "          for ((release_create_attempt = 1;"
        )
        post = self.draft_step.index(
            "            if release_response=$(gh api --method POST", loop_start
        )
        loop_prefix = self.draft_step[loop_start:post]

        self.assertIn(
            '"repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}"',
            loop_prefix,
        )
        self.assertIn(
            '"$(resolve_tag_commit "${tag_response}")" = "${SOURCE_COMMIT}"',
            loop_prefix,
        )
        self.assertIn(
            "if ! release_response=$(lookup_release)",
            loop_prefix,
        )
        self.assertIn('if [ "${release_response}" != null ]', loop_prefix)
        self.assertIn("release_found=true", loop_prefix)
        self.assertIn("break", loop_prefix)

    def test_only_not_found_create_errors_are_retried(self):
        post = self.draft_step.index(
            "            if release_response=$(gh api --method POST"
        )
        delay = self.draft_step.index(
            "            retry_delay=${release_create_delays", post
        )
        error_handling = self.draft_step[post:delay]

        self.assertIn("release_create_error=${release_response}", error_handling)
        self.assertIn("*'(HTTP 404)'*) ;;", error_handling)
        self.assertIn(
            "printf '%s\\n' \"${release_create_error}\" >&2", error_handling
        )
        self.assertIn("exit 1", error_handling)

    def test_created_or_reused_release_still_has_exact_draft_gates(self):
        required_checks = (
            ".tag_name == $tag",
            ".name == $title",
            ".draft == true",
            ".target_commitish == $source_commit",
            ".prerelease == $prerelease",
            'existing_body=$(jq -r \'.body // ""\'',
            "Draft retry contains an expected asset and cannot be reused",
        )
        for check in required_checks:
            with self.subTest(check=check):
                self.assertIn(check, self.draft_step)

    def test_draft_lookup_never_uses_the_published_tag_endpoint(self):
        self.assertNotIn("/releases/tags/", self.workflow)
        self.assertEqual(
            self.draft_step.count("if ! release_response=$(lookup_release)"), 2
        )
        self.assertRegex(
            self.draft_step,
            r"if ! release_response=\$\(lookup_release\)\s*then\s*exit 1\s*fi",
        )

    def test_release_id_is_captured_only_after_draft_and_asset_guards(self):
        self.assertIn("        id: draft_release", self.draft_step)
        capture = self.draft_step.index("printf 'release_id=%s\\n'")
        self.assertLess(
            self.draft_step.index("Existing release is not the expected matching draft"),
            capture,
        )
        self.assertLess(
            self.draft_step.index("Draft retry contains an expected asset"), capture
        )
        self.assertIn('[[ "${release_id}" =~ ^[1-9][0-9]*$ ]]', self.draft_step)
        self.assertIn('type == "number" and . > 0 and . <= 9007199254740991',
                      self.draft_step)

    def test_final_publish_fetches_and_patches_only_the_captured_id(self):
        self.assertIn(
            "RELEASE_ID: ${{ steps.draft_release.outputs.release_id }}",
            self.publish_step,
        )
        self.assertIn('[[ "${RELEASE_ID}" =~ ^[1-9][0-9]*$ ]]', self.publish_step)
        self.assertEqual(
            self.publish_step.count(
                '"repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}"'
            ), 2,
        )
        self.assertEqual(self.publish_step.count(".id == $release_id"), 2)
        for guard in (
            ".tag_name == $tag", ".name == $title", ".draft == true",
            ".target_commitish == $source_commit", ".prerelease == $prerelease",
            "Draft release notes changed during the image build",
            "Remote release digest does not match verified asset",
        ):
            with self.subTest(guard=guard):
                self.assertIn(guard, self.publish_step)
        self.assertNotIn("--clobber", self.workflow)


class DraftReleaseLookupTests(unittest.TestCase):
    """Execute the actual embedded lookup code; never invoke gh or a network."""

    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        source = workflow.split("          # BEGIN draft release lookup\n", 1)[1]
        source = source.split("          # END draft release lookup\n", 1)[0]
        cls.namespace = {"__name__": "release_lookup_test"}
        exec(compile(textwrap.dedent(source), str(WORKFLOW_PATH), "exec"), cls.namespace)
        cls.lookup = staticmethod(cls.namespace["lookup_release"])
        cls.error_type = cls.namespace["ReleaseLookupError"]

    def setUp(self):
        self.runner_patch = mock.patch.object(self.namespace["subprocess"], "run")
        self.runner = self.runner_patch.start()
        self.addCleanup(self.runner_patch.stop)
        self.repository = "example/teslausb"
        self.tag = "v1.2.0-rc.5"
        self.release = {
            "id": 123, "tag_name": self.tag, "draft": True,
            "name": "TeslaUSB Enhanced " + self.tag,
            "target_commitish": "a" * 40, "body": "Checked-in notes\n",
            "prerelease": True, "assets": [],
        }

    @staticmethod
    def response(value):
        return SimpleNamespace(stdout=json.dumps(value))

    def lookup_with(self, *responses):
        self.runner.side_effect = [self.response(value) for value in responses]
        return self.lookup(self.repository, self.tag)

    def test_successful_empty_listing_is_the_only_absent_result(self):
        self.assertIsNone(self.lookup_with([[]]))
        self.assertEqual(self.runner.call_count, 1)
        command = self.runner.call_args.args[0]
        self.assertEqual(command[:5], [
            "gh", "api", "--method", "GET", "repos/example/teslausb/releases",
        ])
        self.assertIn("--paginate", command)
        self.assertIn("--slurp", command)
        self.assertEqual(command[-2:], ["-F", "per_page=100"])
        self.assertTrue(self.runner.call_args.kwargs["check"])
        self.assertEqual(self.runner.call_args.kwargs["timeout"], 120)

    def test_unrelated_releases_do_not_match(self):
        unrelated = dict(self.release, id=234, tag_name="v1.1.0", draft=False)
        self.assertIsNone(self.lookup_with([[unrelated]]))
        self.assertEqual(self.runner.call_count, 1)

    def test_existing_draft_is_fetched_by_unique_id(self):
        self.assertEqual(self.lookup_with([[self.release]], self.release), self.release)
        self.assertEqual(self.runner.call_count, 2)
        self.assertEqual(self.runner.call_args.args[0], [
            "gh", "api", "--method", "GET", "repos/example/teslausb/releases/123",
        ])

    def test_existing_draft_on_later_page_is_not_missed(self):
        first_page = [dict(self.release, id=1000 + i, tag_name=f"v0.0.{i}")
                      for i in range(100)]
        self.assertEqual(
            self.lookup_with([first_page, [self.release]], self.release), self.release
        )

    def test_duplicate_tag_is_ambiguous_even_if_one_is_published(self):
        for draft in (True, False):
            with self.subTest(draft=draft):
                self.runner.reset_mock()
                other = dict(self.release, id=456, draft=draft)
                with self.assertRaisesRegex(self.error_type, "Multiple releases"):
                    self.lookup_with([[self.release, other]])
                self.assertEqual(self.runner.call_count, 1)

    def test_duplicate_id_is_rejected(self):
        with self.assertRaisesRegex(self.error_type, "Duplicate release ID"):
            self.lookup_with([[self.release, self.release]])

    def test_matching_published_release_is_not_treated_as_absent(self):
        with self.assertRaisesRegex(self.error_type, "already published"):
            self.lookup_with([[dict(self.release, draft=False)]])
        self.assertEqual(self.runner.call_count, 1)

    def test_malformed_or_partial_pagination_never_means_missing(self):
        for pages in (None, {}, [], [None], [self.release], [[], [self.release]],
                      [[self.release], []], [[self.release] * 101]):
            with self.subTest(pages=pages), self.assertRaises(self.error_type):
                self.lookup_with(pages)

    def test_malformed_listing_entries_are_rejected(self):
        for changes in ({"id": True}, {"id": "123"}, {"id": 0}, {"id": -1},
                        {"id": 2**53}, {"draft": "true"}, {"tag_name": None}):
            with self.subTest(changes=changes), self.assertRaises(self.error_type):
                self.lookup_with([[dict(self.release, **changes)]])

    def test_list_then_id_mismatch_tag_change_or_publication_aborts(self):
        for changes in ({"id": 456}, {"id": "123"}, {"tag_name": "v9.0.0"},
                        {"draft": False}, {"draft": 1}):
            with self.subTest(changes=changes), self.assertRaisesRegex(
                self.error_type, "identity changed"
            ):
                self.lookup_with([[self.release]], dict(self.release, **changes))

    def test_disappeared_id_404_is_not_treated_as_absent(self):
        self.runner.side_effect = [
            self.response([[self.release]]),
            subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 404 must-not-leak"),
        ]
        with self.assertRaises(self.error_type) as failure:
            self.lookup(self.repository, self.tag)
        self.assertNotIn("must-not-leak", str(failure.exception))
        self.assertEqual(self.runner.call_count, 2)

    def test_auth_network_timeout_and_partial_command_errors_abort(self):
        for error in (
            subprocess.CalledProcessError(1, ["gh"], stderr="HTTP 401 must-not-leak"),
            subprocess.CalledProcessError(1, ["gh"], output="[[]]", stderr="HTTP 404"),
            subprocess.CalledProcessError(1, ["gh"], output="[[{}]]", stderr="HTTP 500"),
            subprocess.TimeoutExpired(["gh"], 120, output="must-not-leak"),
            OSError("must-not-leak"),
        ):
            with self.subTest(error=type(error).__name__):
                self.runner.side_effect = error
                with self.assertRaises(self.error_type) as failure:
                    self.lookup(self.repository, self.tag)
                self.assertNotIn("must-not-leak", str(failure.exception))

    def test_invalid_and_duplicate_key_json_abort(self):
        for output in ("", "[[]]\nnetwork failure", '{"id":1,"id":2}'):
            with self.subTest(output=output), self.assertRaises(self.error_type):
                self.runner.side_effect = None
                self.runner.return_value = SimpleNamespace(stdout=output)
                self.lookup(self.repository, self.tag)

    def test_invalid_inputs_do_not_call_gh(self):
        for repository, tag in (("--hostname=elsewhere", self.tag),
                                ("example/repo/extra", self.tag),
                                (self.repository, "v1.2.0-rc.05"),
                                (self.repository, "latest")):
            with self.subTest(repository=repository, tag=tag), self.assertRaises(
                self.error_type
            ):
                self.lookup(repository, tag)
        self.runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()

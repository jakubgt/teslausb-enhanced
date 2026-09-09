import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
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
            "      - name: Create or validate unpublished draft release"
        )
        end = workflow.index(
            "      - name: Confirm matching GitHub draft exists", start
        )
        cls.draft_step = workflow[start:end]
        cls.handoff_step = workflow[workflow.index(
            "      - name: Verify uploaded draft and record hardware-test handoff"
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

    def test_final_handoff_reads_only_the_captured_id_and_keeps_draft(self):
        self.assertIn(
            "RELEASE_ID: ${{ steps.draft_release.outputs.release_id }}",
            self.handoff_step,
        )
        self.assertIn('[[ "${RELEASE_ID}" =~ ^[1-9][0-9]*$ ]]', self.handoff_step)
        self.assertEqual(
            self.handoff_step.count(
                '"repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}"'
            ), 1,
        )
        self.assertEqual(self.handoff_step.count(".id == $release_id"), 1)
        for guard in (
            ".tag_name == $tag", ".name == $title", ".draft == true",
            ".target_commitish == $source_commit", ".prerelease == $prerelease",
            "Draft release notes changed during the image build",
            "Remote release digest does not match verified asset",
        ):
            with self.subTest(guard=guard):
                self.assertIn(guard, self.handoff_step)
        self.assertNotIn("--clobber", self.workflow)

    def test_all_build_triggers_are_draft_only(self):
        triggers = self.workflow.split("permissions:", 1)[0]
        self.assertIn("  push:", triggers)
        self.assertIn("  workflow_dispatch:", triggers)
        self.assertNotIn("  release:", triggers)
        self.assertNotIn("types: [published]", triggers)
        self.assertNotIn("        if:", self.draft_step)
        self.assertNotIn("        if:", self.handoff_step)
        self.assertIn("draft: true", self.draft_step)
        self.assertIn("make_latest: \"false\"", self.draft_step)
        self.assertNotIn("draft: false", self.workflow)
        self.assertNotIn("gh api --method PATCH", self.workflow)
        self.assertNotIn("gh release edit", self.workflow)

    def test_manual_build_must_be_validated_main_dev_source(self):
        self.assertIn('"${GITHUB_EVENT_NAME}" = workflow_dispatch', self.workflow)
        self.assertIn('git merge-base --is-ancestor "${source_commit}" '
                      'refs/remotes/origin/main-dev', self.workflow)
        start = self.workflow.index("      - name: Require successful Validate run")
        validate = self.workflow[start:self.workflow.index(
            "      - name: Create or validate unpublished draft release", start)]
        self.assertNotIn("        if:", validate)
        self.assertIn('.workflow_runs[0].head_sha == $source_commit', validate)
        self.assertIn('[ "${conclusion}" = success ]', validate)

    def test_upload_refuses_a_published_or_replaced_draft(self):
        start = self.workflow.index("      - name: Upload verified assets")
        upload = self.workflow[start:self.workflow.index(
            "      - name: Verify uploaded draft", start)]
        guard = upload.index("Refusing to upload to a changed or published release")
        self.assertLess(guard, upload.index("gh release upload"))
        for expected in (".id == $release_id", ".tag_name == $tag",
                         ".draft == true", ".target_commitish == $source_commit"):
            self.assertIn(expected, upload[:guard])
        self.assertNotIn("--clobber", upload)

    def test_handoff_records_exact_image_and_pending_hardware_gate(self):
        for expected in ('"${SOURCE_COMMIT}"', '"${image_sha256}"',
                         '"${GITHUB_STEP_SUMMARY}"',
                         "still require hardware acceptance",
                         "Do not rebuild or replace the tested image"):
            self.assertIn(expected, self.handoff_step)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("jq"),
                     "Actual workflow shell needs POSIX bash and jq")
class DraftHandoffExecutionTests(unittest.TestCase):
    """Execute the real final workflow step against isolated, offline GitHub replies."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-handoff-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        step = workflow[workflow.index(
            "      - name: Verify uploaded draft and record hardware-test handoff"):]
        self.script = self.directory / "handoff.sh"
        self.script.write_text(textwrap.dedent(step.split("        run: |\n", 1)[1]))
        self.commit = "a" * 40
        self.tag = "v2.0.0"
        self.release = {
            "id": 123, "tag_name": self.tag, "draft": True,
            "name": "TeslaUSB Enhanced " + self.tag,
            "target_commitish": self.commit, "body": "Release notes\n",
            "prerelease": False, "assets": [],
        }
        self.environment = dict(os.environ)
        self.environment.pop("GH_TOKEN", None)
        self.environment.pop("GITHUB_TOKEN", None)
        self.environment.update({
            "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
            "GITHUB_REPOSITORY": "example/teslausb", "RELEASE_TAG": self.tag,
            "SOURCE_COMMIT": self.commit, "RELEASE_ID": "123", "VERSION": "2.0.0",
            "GITHUB_STEP_SUMMARY": str(self.directory / "summary.md"),
            "RELEASE_NOTES_PATH": str(self.directory / "notes.md"),
            "FIXTURE_DIRECTORY": str(self.directory),
        })
        Path(self.environment["RELEASE_NOTES_PATH"]).write_text("Release notes\n")
        for key, name in (("IMAGE_ASSET", "image.img.xz"),
                          ("CHECKSUM_ASSET", "image.img.xz.sha256"),
                          ("METADATA_ASSET", "metadata.json"),
                          ("PACKAGES_ASSET", "packages.tsv")):
            data = ("verified fixture " + name).encode()
            asset = self.directory / name
            asset.write_bytes(data)
            self.environment[key] = str(asset)
            self.release["assets"].append({
                "name": name, "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
            })
        self.tag_commit = self.commit
        fake_gh = self.directory / "gh"
        fake_gh.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "root = pathlib.Path(os.environ['FIXTURE_DIRECTORY'])\n"
            "with (root / 'calls.jsonl').open('a') as out:\n"
            "    out.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "assert len(sys.argv) == 3 and sys.argv[1] == 'api', sys.argv\n"
            "fixture = json.loads((root / 'replies.json').read_text())\n"
            "assert sys.argv[2] in fixture, sys.argv\n"
            "print(json.dumps(fixture[sys.argv[2]]))\n"
        )
        fake_gh.chmod(0o755)

    def execute(self):
        replies = {
            "repos/example/teslausb/git/ref/tags/" + self.tag: {
                "object": {"type": "commit", "sha": self.tag_commit},
            },
            "repos/example/teslausb/releases/123": self.release,
        }
        (self.directory / "replies.json").write_text(json.dumps(replies))
        return subprocess.run(["bash", "--noprofile", "--norc", str(self.script)],
                              env=self.environment, cwd=self.directory,
                              capture_output=True, text=True, timeout=15)

    def test_stable_verified_image_remains_draft_and_records_checksum(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = Path(self.environment["GITHUB_STEP_SUMMARY"]).read_text()
        self.assertIn(self.commit, summary)
        self.assertIn(self.tag, summary)
        self.assertIn(self.release["assets"][0]["digest"][7:], summary)
        self.assertIn("unpublished", summary)
        self.assertIn("still require hardware acceptance", summary)
        calls = [json.loads(line) for line in
                 (self.directory / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(calls, [
            ["api", "repos/example/teslausb/git/ref/tags/" + self.tag],
            ["api", "repos/example/teslausb/releases/123"],
        ])

    def test_release_candidates_also_remain_drafts(self):
        self.tag = "v2.0.0-rc.1"
        self.environment.update(RELEASE_TAG=self.tag, VERSION="2.0.0-rc.1")
        self.release.update(tag_name=self.tag, name="TeslaUSB Enhanced " + self.tag,
                            prerelease=True)
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unpublished", Path(self.environment["GITHUB_STEP_SUMMARY"]).read_text())

    def test_changed_release_identity_or_notes_fails_before_handoff(self):
        original = dict(self.release)
        for change in ({"draft": False}, {"id": 456}, {"tag_name": "v9.0.0"},
                       {"target_commitish": "b" * 40}, {"prerelease": True},
                       {"body": "Replaced notes"}):
            with self.subTest(change=change):
                self.release = dict(original, **change)
                result = self.execute()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.environment["GITHUB_STEP_SUMMARY"]).exists())

    def test_changed_source_tag_fails_before_handoff(self):
        self.tag_commit = "b" * 40
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release tag changed", result.stderr)
        self.assertFalse(Path(self.environment["GITHUB_STEP_SUMMARY"]).exists())

    def test_changed_missing_or_duplicate_remote_asset_fails(self):
        original = list(self.release["assets"])
        for assets in ([dict(original[0], digest="sha256:" + "0" * 64), *original[1:]],
                       original[1:], [*original, original[0]]):
            with self.subTest(assets=assets):
                self.release["assets"] = assets
                result = self.execute()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.environment["GITHUB_STEP_SUMMARY"]).exists())


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

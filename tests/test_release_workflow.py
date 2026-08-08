import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "build-image.yml"


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        start = workflow.index(
            "      - name: Create or validate VERSION-push draft release"
        )
        end = workflow.index(
            "      - name: Confirm matching GitHub release exists", start
        )
        cls.draft_step = workflow[start:end]

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
            '"repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}"',
            loop_prefix,
        )
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


if __name__ == "__main__":
    unittest.main()

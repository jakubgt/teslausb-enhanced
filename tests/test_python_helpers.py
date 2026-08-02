import ast
import importlib.util
import pathlib
import sys
import types
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


class PythonHelperTests(unittest.TestCase):
    def test_send_sns_forwards_named_fields(self) -> None:
        published = {}

        class FakeClient:
            def publish(self, **kwargs):
                published.update(kwargs)
                return {"MessageId": "test-id"}

        fake_boto3 = types.SimpleNamespace(client=lambda service: self._client(service, FakeClient()))
        previous = sys.modules.get("boto3")
        sys.modules["boto3"] = fake_boto3
        try:
            path = REPO_ROOT / "run" / "send_sns.py"
            spec = importlib.util.spec_from_file_location("teslausb_send_sns_test", path)
            self.assertIsNotNone(spec)
            self.assertIsNotNone(spec.loader)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            response = module.send_sns("arn:test", "subject", "body")
        finally:
            if previous is None:
                sys.modules.pop("boto3", None)
            else:
                sys.modules["boto3"] = previous

        self.assertEqual({"MessageId": "test-id"}, response)
        self.assertEqual(
            {"TopicArn": "arn:test", "Subject": "subject", "Message": "body"},
            published,
        )

    def test_matrix_password_is_read_from_standard_input(self) -> None:
        path = REPO_ROOT / "run" / "send_matrix.py"
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
        reads_stdin = any(
            isinstance(call.func, ast.Attribute)
            and call.func.attr == "read"
            and isinstance(call.func.value, ast.Attribute)
            and call.func.value.attr == "stdin"
            and isinstance(call.func.value.value, ast.Name)
            and call.func.value.value.id == "sys"
            for call in calls
        )
        self.assertTrue(reads_stdin)

    @staticmethod
    def _client(service: str, client):
        if service != "sns":
            raise AssertionError(f"unexpected boto3 service: {service}")
        return client


if __name__ == "__main__":
    unittest.main()

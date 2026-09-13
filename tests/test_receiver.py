"""Unit tests for lambda/receiver.py.

All AWS calls (boto3 clients, SSM, async Lambda invoke) are mocked — these
tests never touch a real AWS account and need no credentials.

Run with: python3 -m unittest discover -s tests -v
"""
import hashlib
import hmac
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))

os.environ.setdefault("PROCESSOR_FUNCTION_NAME", "processor-fn")
os.environ.setdefault("VERIFY_TOKEN_PARAM", "/test/verify-token")
os.environ.setdefault("APP_SECRET_PARAM", "/test/app-secret")

with patch("boto3.client"):
    import receiver

VERIFY_TOKEN = "my-verify-token"
APP_SECRET = "my-app-secret"


def sign(body, secret=APP_SECRET):
    digest = hmac.new(secret.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def api_gw_event(method, query=None, body=None, headers=None):
    return {
        "requestContext": {"http": {"method": method}},
        "queryStringParameters": query,
        "body": body,
        "headers": headers or {},
    }


class VerificationHandshakeTests(unittest.TestCase):
    def setUp(self):
        secrets = {
            os.environ["VERIFY_TOKEN_PARAM"]: VERIFY_TOKEN,
            os.environ["APP_SECRET_PARAM"]: APP_SECRET,
        }
        patcher = patch.object(receiver, "_get_secret", side_effect=lambda name: secrets[name])
        self.addCleanup(patcher.stop)
        patcher.start()

    def test_correct_token_echoes_challenge(self):
        event = api_gw_event(
            "GET",
            query={"hub.mode": "subscribe", "hub.verify_token": VERIFY_TOKEN, "hub.challenge": "12345"},
        )
        response = receiver.handler(event, None)
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(response["body"], "12345")

    def test_wrong_token_is_rejected(self):
        event = api_gw_event(
            "GET",
            query={"hub.mode": "subscribe", "hub.verify_token": "wrong", "hub.challenge": "12345"},
        )
        response = receiver.handler(event, None)
        self.assertEqual(response["statusCode"], 403)

    def test_wrong_mode_is_rejected(self):
        event = api_gw_event(
            "GET",
            query={"hub.mode": "unsubscribe", "hub.verify_token": VERIFY_TOKEN, "hub.challenge": "12345"},
        )
        response = receiver.handler(event, None)
        self.assertEqual(response["statusCode"], 403)


class SignatureVerificationTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(receiver, "_get_secret", return_value=APP_SECRET)
        self.addCleanup(patcher.stop)
        patcher.start()

    def test_valid_signature_is_forwarded_to_processor(self):
        body = '{"entry": [{"changes": [{"value": {"messages": []}}]}]}'
        event = api_gw_event("POST", body=body, headers={"x-hub-signature-256": sign(body)})
        with patch.object(receiver, "lambda_client") as mock_lambda:
            response = receiver.handler(event, None)

        self.assertEqual(response["statusCode"], 200)
        mock_lambda.invoke.assert_called_once()
        kwargs = mock_lambda.invoke.call_args.kwargs
        self.assertEqual(kwargs["FunctionName"], "processor-fn")
        self.assertEqual(kwargs["InvocationType"], "Event")
        self.assertEqual(kwargs["Payload"], body.encode("utf-8"))

    def test_invalid_signature_is_rejected_and_not_forwarded(self):
        body = '{"entry": []}'
        event = api_gw_event("POST", body=body, headers={"x-hub-signature-256": sign(body, secret="wrong-secret")})
        with patch.object(receiver, "lambda_client") as mock_lambda:
            response = receiver.handler(event, None)

        self.assertEqual(response["statusCode"], 403)
        mock_lambda.invoke.assert_not_called()

    def test_missing_signature_header_is_rejected(self):
        body = '{"entry": []}'
        event = api_gw_event("POST", body=body, headers={})
        with patch.object(receiver, "lambda_client") as mock_lambda:
            response = receiver.handler(event, None)

        self.assertEqual(response["statusCode"], 403)
        mock_lambda.invoke.assert_not_called()

    def test_tampered_body_with_stale_signature_is_rejected(self):
        original_body = '{"entry": [{"changes": [{"value": {"messages": [{"from": "111"}]}}]}]}'
        tampered_body = '{"entry": [{"changes": [{"value": {"messages": [{"from": "999"}]}}]}]}'
        event = api_gw_event("POST", body=tampered_body, headers={"x-hub-signature-256": sign(original_body)})
        with patch.object(receiver, "lambda_client") as mock_lambda:
            response = receiver.handler(event, None)

        self.assertEqual(response["statusCode"], 403)
        mock_lambda.invoke.assert_not_called()


class MethodRoutingTests(unittest.TestCase):
    def test_unsupported_method_returns_405(self):
        event = api_gw_event("PUT")
        response = receiver.handler(event, None)
        self.assertEqual(response["statusCode"], 405)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Unit tests for lambda/processor.py.

All AWS calls (boto3 clients, SSM, Bedrock) are mocked — these tests never
touch a real AWS account and need no credentials.

Run with: python3 -m unittest discover -s tests -v
"""
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))

os.environ.setdefault("BEDROCK_HARNESS_ARN", "arn:aws:bedrock-agentcore:us-east-1:111111111111:harness/test")
os.environ.setdefault("WHATSAPP_TOKEN_PARAM", "/test/token")
os.environ.setdefault("PHONE_NUMBER_ID_PARAM", "/test/phone")
os.environ.setdefault("ALLOWED_PHONE_NUMBERS", "111,222")

with patch("boto3.client"):
    import processor


def batched_payload(messages):
    return {"entry": [{"changes": [{"value": {"messages": messages}}]}]}


class ExtractMessagesTests(unittest.TestCase):
    def test_extracts_all_text_messages_in_order(self):
        payload = batched_payload(
            [
                {"type": "text", "from": "111", "text": {"body": "first"}},
                {"type": "text", "from": "111", "text": {"body": "second"}},
            ]
        )
        self.assertEqual(
            processor._extract_messages(payload),
            [("111", "first"), ("111", "second")],
        )

    def test_extracts_messages_from_different_senders(self):
        payload = batched_payload(
            [
                {"type": "text", "from": "111", "text": {"body": "hi"}},
                {"type": "text", "from": "222", "text": {"body": "hey"}},
            ]
        )
        self.assertEqual(
            processor._extract_messages(payload),
            [("111", "hi"), ("222", "hey")],
        )

    def test_status_receipt_yields_no_messages(self):
        payload = {"entry": [{"changes": [{"value": {"statuses": [{"status": "delivered"}]}}]}]}
        self.assertEqual(processor._extract_messages(payload), [])

    def test_non_text_message_skipped(self):
        payload = batched_payload([{"type": "image", "from": "111", "image": {}}])
        self.assertEqual(processor._extract_messages(payload), [])

    def test_malformed_payload_does_not_raise(self):
        self.assertEqual(processor._extract_messages({"entry": "not-a-list-of-dicts"}), [])


class SessionIdTests(unittest.TestCase):
    def test_deterministic_and_long_enough(self):
        # runtimeSessionId must be 33-100 characters (AWS constraint); a
        # bare phone number is far too short.
        session_id = processor._session_id_for("15551234567")
        self.assertGreaterEqual(len(session_id), 33)
        self.assertEqual(session_id, processor._session_id_for("15551234567"))

    def test_different_senders_get_different_sessions(self):
        self.assertNotEqual(
            processor._session_id_for("111"),
            processor._session_id_for("222"),
        )


class InvokeHarnessTests(unittest.TestCase):
    def test_calls_invoke_harness_with_expected_shape(self):
        stream = [
            {"messageStart": {}},
            {"contentBlockDelta": {"delta": {"text": "Hel"}}},
            {"contentBlockDelta": {"delta": {"text": "lo!"}}},
            {"messageStop": {}},
        ]
        with patch.object(
            processor.bedrock_agentcore, "invoke_harness", return_value={"stream": stream}
        ) as mock_call:
            result = processor._invoke_harness("111", "hi there")

        self.assertEqual(result, "Hello!")
        kwargs = mock_call.call_args.kwargs
        self.assertEqual(kwargs["harnessArn"], processor.BEDROCK_HARNESS_ARN)
        self.assertEqual(kwargs["actorId"], "111")
        self.assertEqual(kwargs["runtimeSessionId"], processor._session_id_for("111"))
        self.assertEqual(kwargs["messages"], [{"role": "user", "content": [{"text": "hi there"}]}])

    def test_events_without_content_delta_are_ignored(self):
        stream = [{"messageStart": {}}, {"metadata": {"usage": {}}}]
        with patch.object(processor.bedrock_agentcore, "invoke_harness", return_value={"stream": stream}):
            result = processor._invoke_harness("111", "hi")
        self.assertEqual(result, "")


class HandlerLoopTests(unittest.TestCase):
    def test_all_messages_in_batch_get_replies(self):
        payload = batched_payload(
            [
                {"type": "text", "from": "111", "text": {"body": "what's on my calendar today?"}},
                {"type": "text", "from": "111", "text": {"body": "and tomorrow?"}},
            ]
        )
        with patch.object(
            processor, "_invoke_harness", side_effect=["today's plan", "tomorrow's plan"]
        ) as mock_invoke, patch.object(processor, "_send_whatsapp_message") as mock_send:
            processor.handler(payload, None)

        self.assertEqual(mock_invoke.call_count, 2)
        mock_send.assert_any_call("111", "today's plan")
        mock_send.assert_any_call("111", "tomorrow's plan")

    def test_one_failing_message_does_not_block_the_others(self):
        payload = batched_payload(
            [
                {"type": "text", "from": "111", "text": {"body": "boom"}},
                {"type": "text", "from": "111", "text": {"body": "ok"}},
            ]
        )
        # Simulate a bug/edge case surfacing as a raw exception from the
        # per-message handler (not just a caught Bedrock error) and confirm
        # the second message still gets processed.
        with patch.object(
            processor, "_handle_one_message", side_effect=[RuntimeError("boom"), None]
        ) as mock_handle:
            processor.handler(payload, None)

        self.assertEqual(mock_handle.call_count, 2)

    def test_non_allowlisted_sender_is_dropped_but_others_proceed(self):
        payload = batched_payload(
            [
                {"type": "text", "from": "999", "text": {"body": "spam"}},
                {"type": "text", "from": "111", "text": {"body": "hi"}},
            ]
        )
        with patch.object(processor, "_invoke_harness", return_value="hello") as mock_invoke, patch.object(
            processor, "_send_whatsapp_message"
        ) as mock_send:
            processor.handler(payload, None)

        mock_invoke.assert_called_once_with("111", "hi")
        mock_send.assert_called_once_with("111", "hello")

    def test_empty_allowed_numbers_does_not_silently_allow_everyone(self):
        # Fail-closed guard: an empty allow-list must drop everyone, never
        # become an "allow all" mode.
        with patch.object(processor, "ALLOWED_PHONE_NUMBERS", set()):
            payload = batched_payload([{"type": "text", "from": "999", "text": {"body": "hi"}}])
            with patch.object(processor, "_invoke_harness") as mock_invoke:
                processor.handler(payload, None)
            mock_invoke.assert_not_called()

    def test_no_messages_is_a_silent_noop(self):
        payload = {"entry": [{"changes": [{"value": {"statuses": [{"status": "read"}]}}]}]}
        with patch.object(processor, "_invoke_harness") as mock_invoke, patch.object(
            processor, "_send_whatsapp_message"
        ) as mock_send:
            processor.handler(payload, None)
        mock_invoke.assert_not_called()
        mock_send.assert_not_called()

    def test_bedrock_failure_still_sends_a_fallback_reply(self):
        payload = batched_payload([{"type": "text", "from": "111", "text": {"body": "hi"}}])
        with patch.object(processor, "_invoke_harness", side_effect=RuntimeError("boom")), patch.object(
            processor, "_send_whatsapp_message"
        ) as mock_send:
            processor.handler(payload, None)
        mock_send.assert_called_once()
        self.assertIn("error", mock_send.call_args.args[1].lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)

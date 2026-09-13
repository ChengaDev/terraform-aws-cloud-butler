"""
processor.py

Invoked asynchronously by `receiver` with the raw, already-parsed WhatsApp
Cloud API webhook payload as the event. Responsible for:

1. Filtering out anything that is not an inbound user text message (e.g.
   `statuses` delivery/read receipts, which must be ignored), and handling
   every text message present — Meta's `messages` array can hold more than
   one (e.g. the user sent two texts in quick succession and Meta batched
   them into one webhook delivery), each processed independently in order.
2. Dropping messages from senders not present in `allowed_phone_numbers`.
3. Invoking the Bedrock AgentCore harness, with the sender's phone number
   as the `actorId` so the harness's managed memory keeps each
   conversation separate and continuous. `runtimeSessionId` must be at
   least 33 characters (an AWS constraint a bare phone number doesn't
   meet), so it's a SHA-256 hash of the sender, derived deterministically
   so the same sender always maps to the same session.
4. Decoding the harness's streamed response into a single string.
5. Posting the reply back to the user via the WhatsApp Cloud API.

Only the Python 3.12 standard library and boto3 (bundled with the Lambda
runtime) are used — no third-party dependencies, no build step.
"""
import hashlib
import json
import logging
import os
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ssm = boto3.client("ssm")
bedrock_agentcore = boto3.client("bedrock-agentcore")

BEDROCK_HARNESS_ARN = os.environ["BEDROCK_HARNESS_ARN"]
WHATSAPP_TOKEN_PARAM = os.environ["WHATSAPP_TOKEN_PARAM"]
PHONE_NUMBER_ID_PARAM = os.environ["PHONE_NUMBER_ID_PARAM"]
WHATSAPP_API_VERSION = os.environ.get("WHATSAPP_API_VERSION", "v21.0")
ALLOWED_PHONE_NUMBERS = {
    number.strip()
    for number in os.environ.get("ALLOWED_PHONE_NUMBERS", "").split(",")
    if number.strip()
}

# Cached for the lifetime of the execution environment to avoid an SSM call
# on every single invocation.
_secrets_cache = {}


def _get_secret(param_name):
    if param_name not in _secrets_cache:
        response = ssm.get_parameter(Name=param_name, WithDecryption=True)
        _secrets_cache[param_name] = response["Parameter"]["Value"]
    return _secrets_cache[param_name]


def _extract_messages(payload):
    """Return a list of (sender, text) tuples for every inbound text message
    found in a WhatsApp Cloud API webhook payload, in the order they appear.

    Meta's `messages` array is not always a single item: it can hold more
    than one message (e.g. the user sent two texts in quick succession and
    Meta batched them into one webhook delivery, or a delivery backlog was
    redelivered together). Every one of them must get a reply, not just the
    first. The list is empty if the payload contains none — for example
    because it is only a `statuses` delivery/read receipt, which must be
    silently ignored."""
    messages = []

    try:
        for entry in payload.get("entry", []):
            for change in entry.get("changes", []):
                value = change.get("value", {})

                # Delivery/read receipts arrive as "statuses" events, not
                # "messages" events. They are not user input and must never
                # be forwarded to Bedrock.
                if "statuses" in value:
                    continue

                for message in value.get("messages", []):
                    if message.get("type") != "text":
                        continue
                    sender = message.get("from")
                    text = message.get("text", {}).get("body")
                    if sender and text:
                        messages.append((sender, text))
    except (AttributeError, TypeError):
        logger.exception("Malformed webhook payload: %s", payload)

    return messages


def _session_id_for(sender):
    """runtimeSessionId must be 33-100 characters; a bare phone number is
    too short. Hashing gives a fixed-length, deterministic ID so the same
    sender always maps to the same session without needing to store
    anything ourselves."""
    return hashlib.sha256(sender.encode("utf-8")).hexdigest()


def _invoke_harness(sender, text):
    """Invoke the Bedrock AgentCore harness and aggregate its streamed
    response into a single string. actorId scopes the harness's managed
    memory to this sender, independently of the session ID."""
    response = bedrock_agentcore.invoke_harness(
        harnessArn=BEDROCK_HARNESS_ARN,
        runtimeSessionId=_session_id_for(sender),
        actorId=sender,
        messages=[{"role": "user", "content": [{"text": text}]}],
    )

    completion = ""
    for event in response.get("stream", []):
        delta = event.get("contentBlockDelta", {}).get("delta", {})
        completion += delta.get("text", "")

    return completion.strip()


def _send_whatsapp_message(to, text):
    """Send a plain-text reply back to the user via the WhatsApp Cloud API,
    using only the standard library (no `requests` dependency)."""
    token = _get_secret(WHATSAPP_TOKEN_PARAM)
    phone_number_id = _get_secret(PHONE_NUMBER_ID_PARAM)

    url = f"https://graph.facebook.com/{WHATSAPP_API_VERSION}/{phone_number_id}/messages"
    payload = json.dumps(
        {
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": to,
            "type": "text",
            "text": {"preview_url": False, "body": text},
        }
    ).encode("utf-8")

    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            logger.info("WhatsApp API responded with status %s.", response.status)
    except urllib.error.HTTPError as error:
        logger.error(
            "WhatsApp API returned an error: %s %s",
            error.code,
            error.read().decode("utf-8", errors="replace"),
        )
    except (urllib.error.URLError, TimeoutError):
        # A timeout while waiting on the response (as opposed to establishing
        # the connection) surfaces as a bare TimeoutError, not URLError, so
        # it must be caught explicitly too. Left uncaught, it would crash
        # this async Lambda invocation and trigger Lambda's automatic retry,
        # re-running the Bedrock call and risking a duplicate reply.
        logger.exception("Failed to reach the WhatsApp API.")


def _handle_one_message(sender, text):
    """Run the allow-list check, Bedrock AgentCore call, and WhatsApp reply
    for a single extracted message. actorId is this message's own sender, so
    multiple messages from different senders in one batch are kept in
    separate memory scopes, and multiple messages from the same sender are
    handled as sequential turns in the same conversation (the harness's
    managed memory persists across invoke_harness calls, so this behaves
    exactly like receiving the same messages as separate webhook
    deliveries)."""
    # Deliberately fails closed: an empty ALLOWED_PHONE_NUMBERS drops every
    # sender rather than allowing all of them. The Terraform module's own
    # variable validation already requires at least one allowed number, but
    # this must not silently become an "allow everyone" mode if that
    # variable is ever bypassed (e.g. the Lambda's environment variable is
    # edited directly).
    if sender not in ALLOWED_PHONE_NUMBERS:
        logger.warning("Dropping message from non-allow-listed sender %s.", sender)
        return

    try:
        reply = _invoke_harness(sender, text)
    except Exception:
        logger.exception("Bedrock AgentCore invocation failed.")
        reply = "Sorry, I ran into an error processing that. Please try again in a moment."

    if not reply:
        reply = "Sorry, I didn't catch that. Could you rephrase?"

    _send_whatsapp_message(sender, reply)


def handler(event, context):
    logger.info("Processing webhook payload.")

    messages = _extract_messages(event)

    if not messages:
        logger.info("No user text message in payload; ignoring (e.g. a status receipt).")
        return

    for sender, text in messages:
        try:
            _handle_one_message(sender, text)
        except Exception:
            # Isolate each message: this Lambda is invoked asynchronously, so
            # letting an exception escape here would fail the whole
            # invocation and trigger Lambda's automatic retry, which would
            # re-run — and re-reply to — every message in this batch,
            # including ones that already succeeded.
            logger.exception("Failed to fully process message from %s.", sender)

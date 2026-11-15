## Output format (required: a script reads your final message)

You cannot publish anything yourself; a script does that with your answer. Your final
message must be ONLY one JSON object, with no text before or after it.

If you found something:
{"summary": "one sentence", "findings": [{"file": "path", "line": 12, "problem": "what is wrong"}]}

- at most 3 findings, the most important first

If there is nothing worth reporting:
{"skip": "one-sentence reason"}

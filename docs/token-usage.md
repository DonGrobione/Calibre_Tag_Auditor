# Token Usage
The pipeline summary ends with the token usage of the run:

```text
Books without audit result:                       0
Web search queries (billed per query):            14
Tokens of interrupted or repeated requests:       0 (included in the counts below)
Prompt tokens (input):                            322,671
  of which cached (billed at a lower rate):       0
Tool use tokens (input from Google Search):       0
Completion tokens (output including thinking):    45,630
Tokens total (prompt + tool use + completion):    368,301
```

The thousands separator follows the regional settings of Windows.

- Prompt tokens are the input. The cached part is already included in them; Gemini bills it at a lower rate.
- Tool use tokens are the search results that the Google Search tool adds to the input of a web profile request.
- Completion tokens are the output including the thinking tokens, which Gemini bills as output.
- The total is the sum of prompt, tool use, and completion tokens, so it is the number of all billed tokens. Search queries are billed separately per query.
- The counts come from the token ledger `02-LLM-Result/LLM-TokenUsage.json`. The LLM step updates it after every Gemini response, so it also counts requests whose export file never got a result file (Ctrl+C, crash) or was processed again; the summary shows these tokens in their own line. A new run starts a new ledger. Each result file also stores its own counts in `token_usage`.
- The log of the LLM step shows the counts per export file and for the session (`prompt=... (cached=...), tool use=..., completion=..., total=...`).
- The log keeps only the 5 newest runs per computer, and a new run deletes the result files and the ledger of the old run. To keep the token usage of a large run, copy its log file or the ledger before the next run.

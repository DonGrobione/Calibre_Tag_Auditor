# Google Gemini
`02-Process-CalibreDataWithLLM.ps1` sends each book export file to the Gemini Interactions API (`gemini-3.8-flash`). The prompt used to validate the Calibre exports is set in `02-CalibreDataLLM-Prompt.txt` and sent as system instruction with every request. Model, thinking level (`low`, `medium`, or `high`), timeouts, and retry intervals are set near the top of the script. Requests are retried on HTTP 429, 500, 502, 503, and 504 and on connection failures (DNS lookup, connect, timeout). When Gemini blocks the request of a file for prohibited content (HTTP 400), the books of that file are sent again one at a time, so only the book that triggers the block stays without result; the file is saved with a validation warning that names it. A block is not retried, because Gemini blocks the same input again. Every book without a result (blocked, failed request, unparsable response, or left out by the LLM) is stored as `missing_books` in the result file, listed by title in the run summary under "Books without audit result", and shown in the ODS as `NOT_AUDITED`. A blocked book is blocked again on every later run that exports it, so check its tags manually. Requests are sent as UTF-8 bytes and responses are decoded as UTF-8, so umlauts and typographic characters do not depend on PowerShell's encoding defaults. A mojibake repair stays in place as a safety net for text that was already garbled at its source.

The API key file `Secrets/Gemini_API.json.key` is a JSON file. The script reads only the property `APIKey`; other properties are ignored:

```json
{
    "APIKey": "<your Gemini API key>"
}
```

## Documentation
- Gemini 3.8 Flash: https://ai.google.dev/gemini-api/docs/latest-model
- Interactions API reference: https://ai.google.dev/api/interactions-api
- Pricing: https://ai.google.dev/gemini-api/docs/pricing
- API keys: https://aistudio.google.com/docs/api-keys

## Gemini Links
- API keys: https://aistudio.google.com/apikey
- Billing: https://aistudio.google.com/billing

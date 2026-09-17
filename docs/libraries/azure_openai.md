# `azure_openai` 1.0.0

Azure OpenAI client. Handles API-key and Azure AD client-credentials authentication and provides chat completions, responses and text extraction helpers. Copy the azure_openai/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `azure_openai` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `azure_openai/azure_openai.lua`
- `azure_openai/azure_openai_auth.lua`
- `azure_openai/azure_openai_http.lua`
- `azure_openai/azure_openai_token.lua`

## Using it

A node that pins this library gets the `azure_openai/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local azure_openai = require("azure_openai.azure_openai")
```

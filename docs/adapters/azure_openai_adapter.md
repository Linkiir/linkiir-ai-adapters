# Azure OpenAI Adapter

Sends inbound data to an Azure OpenAI model (chat completions or responses endpoint) and pushes the model output downstream.

| | |
|---|---|
| **Slug** | `azure_openai_adapter` |
| **Node type id** | `LKAI_AZURE_OPENAI_ADAPTER` |
| **Node type** | transform |
| **Version** | 1.0.0 |
| **Interval driven** | no |
| **Libraries** | azure_openai 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Authentication Mode | list | `API Key` | How to authenticate with the Azure OpenAI endpoint. |
| Model URI | string | _(empty)_ | Full Azure OpenAI endpoint URL. Must contain /openai/deployments/{name}/chat/completions or /openai/responses. Found in the model deployment page in Azure Foundry. |
| API Key | password | _(empty — set on the node)_ | Azure OpenAI API key. Found in the model deployment page in Azure Foundry. |
| Azure Client ID | string | _(empty)_ | Entra ID application (client) ID for OAuth 2.0 client_credentials flow. |
| Azure Tenant ID | string | _(empty)_ | Entra ID directory (tenant) ID. |
| Azure Client Secret | password | _(empty — set on the node)_ | Entra ID client secret. Created in the Azure portal under App registrations > Certificates & secrets. |
| System Prompt | string | `You are a healthcare interoperability assistant. Based solely on the structure and coded elements of the following FHIR or HL7 v2 message, infer non-identifying attributes such as whether the context is adult or pediatric, acute or routine, lab/imaging/clinical observation, screening or diagnostic, and real-time or historical data flow. Do not restate any field values or patient-identifying information, and respond in no more than three sentences.` | Global instructions for the model. Set rules, tone, output format, and safety constraints. |
| Model Name | string | _(empty)_ | Model deployment identifier such as 'gpt-4o-mini'. Required for the responses endpoint mode. |
| Max Tokens | number | `4096` | Upper limit on the length of generated results. Increase if output is truncated. |
| Temperature | number | _(empty)_ | Controls randomness (0.0-1.0). Lower values produce more deterministic output. Leave empty to use the model default. |
| TopP | number | _(empty)_ | Controls diversity via nucleus sampling (0.0-1.0). 0.5 means half of all likelihood-weighted options are considered. Leave empty to use the model default. |
| Request Timeout | number | `30` | HTTP timeout in seconds. Increase for large prompts or high max_tokens. |
| Live Mode | bool | `true` | When off, requests are simulated and no data leaves the runtime. |

## Samples

De-identified messages you can run the node against:

- `samples/fhir_patient.json`

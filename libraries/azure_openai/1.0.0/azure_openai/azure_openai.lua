-- ---------------------------------------------------------------------------
-- azure_openai - Azure OpenAI client
--
-- Require this module. The others (auth, http, token) are internals.
--
--    local AzureOpenAI = require 'azure_openai'
--
--    function main(Data)
--       local Client, Err = AzureOpenAI.fromNodeConfig()
--       if not Client then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       local Result, Err = Client:complete{
--          messages = {
--             { role = 'system', content = 'You are a helpful assistant.' },
--             { role = 'user',   content = Data },
--          },
--          max_tokens = 4096,
--       }
--       if not Result then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       linkiir.flow.push{ data = Result }
--    end
--
-- Two endpoint modes are supported, inferred from the Model URI:
--   - chat_completions: /openai/deployments/{name}/chat/completions
--   - responses:        /openai/responses
--
-- Two authentication modes:
--   - API Key:  static bearer token
--   - Entra ID: OAuth 2.0 client_credentials against Microsoft identity
--
-- Every method returns a result, or nil plus an error table:
--    { code = 'ERROR_CODE', message = 'human readable', ... }
-- ---------------------------------------------------------------------------

local Http = require 'azure_openai_http'

local M = {}

-- ---------------------------------------------------------------------------
-- Endpoint parsing
-- ---------------------------------------------------------------------------

-- Parse the Model URI to determine the endpoint mode and extract components.
local function parseEndpoint(Endpoint)
   local Parsed = {
      base_url    = nil,
      mode        = nil,
      deployment  = nil,
      api_version = nil,
   }

   -- Extract API version from query string
   local ApiVersion = Endpoint:match('api%-version=([^&]+)')
   if ApiVersion then
      Parsed.api_version = ApiVersion
   end

   -- Remove query string for path parsing
   local PathOnly = Endpoint:match('^([^?]+)')

   -- Responses mode: /openai/responses
   if PathOnly:match('/openai/responses') then
      Parsed.mode = 'responses'
      Parsed.base_url = PathOnly:match('^(https?://[^/]+)')
      return Parsed
   end

   -- Chat completions mode: /openai/deployments/{name}/chat/completions
   local Deployment = PathOnly:match('/openai/deployments/([^/]+)/chat/completions')
   if Deployment then
      Parsed.mode = 'chat_completions'
      Parsed.deployment = Deployment
      Parsed.base_url = PathOnly:match('^(https?://[^/]+)')
      return Parsed
   end

   return nil, {
      code    = 'ENDPOINT_PARSE_ERROR',
      message = 'Unable to parse Model URI. Must contain /openai/responses '
         .. 'or /openai/deployments/{deployment}/chat/completions',
   }
end

-- ---------------------------------------------------------------------------
-- Client methods
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

-- Chat Completions API. Returns the parsed response, or nil plus an error.
--
--   T.messages              - required; array of { role=, content= }
--   T.max_tokens            - maximum completion tokens
--   T.temperature           - sampling temperature (0.0-1.0)
--   T.top_p                 - nucleus sampling (0.0-1.0)
--   T.live                  - overrides the client live flag
function Client:chatCompletionsCreate(T)
   if self.endpoint.mode ~= 'chat_completions' then
      return nil, {
         code    = 'MODE_MISMATCH',
         message = 'chatCompletionsCreate requires a chat completions endpoint',
      }
   end

   local Messages = T.messages
   if not Messages then
      return nil, {
         code    = 'MISSING_PARAM',
         message = 'messages is required for chatCompletionsCreate',
      }
   end

   local Payload = {
      messages = Messages,
      model    = self.endpoint.deployment,
   }

   if T.max_tokens then
      Payload.max_completion_tokens = T.max_tokens
   end
   if T.temperature then
      Payload.temperature = T.temperature
   end
   if T.top_p then
      Payload.top_p = T.top_p
   end

   return Http.request(self, {
      body = linkiir.json.serialize(Payload),
      live = T.live,
   })
end

-- Responses API. Returns the parsed response, or nil plus an error.
--
--   T.model                 - required; model deployment identifier
--   T.input                 - required; the input text
--   T.max_output_tokens     - maximum output tokens
--   T.temperature           - sampling temperature (0.0-1.0)
--   T.top_p                 - nucleus sampling (0.0-1.0)
--   T.live                  - overrides the client live flag
function Client:responsesCreate(T)
   if self.endpoint.mode ~= 'responses' then
      return nil, {
         code    = 'MODE_MISMATCH',
         message = 'responsesCreate requires a responses endpoint',
      }
   end

   local Model = T.model
   if not Model then
      return nil, {
         code    = 'MISSING_PARAM',
         message = 'model is required for responsesCreate',
      }
   end

   local Input = T.input
   if not Input then
      return nil, {
         code    = 'MISSING_PARAM',
         message = 'input is required for responsesCreate',
      }
   end

   local Payload = {
      model = Model,
      input = Input,
   }

   if T.max_output_tokens then
      Payload.max_output_tokens = T.max_output_tokens
   end
   if T.temperature then
      Payload.temperature = T.temperature
   end
   if T.top_p then
      Payload.top_p = T.top_p
   end

   return Http.request(self, {
      body = linkiir.json.serialize(Payload),
      live = T.live,
   })
end

-- Force a fresh token exchange (Entra ID only). Not normally needed; requests
-- authenticate on demand. Returns the token string or nil plus error.
function Client:authenticate()
   if self.auth_mode ~= 'Entra ID' then
      return nil, {
         code    = 'AUTH_NOT_APPLICABLE',
         message = 'authenticate() is only applicable in Entra ID mode',
      }
   end
   local Auth = require 'azure_openai_auth'
   return Auth.authenticate(self)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

M.Client = Client

-- Extract the text output from a chat completions response.
-- Returns the first choice's message content, or nil if missing.
function M.completionText(Response)
   if type(Response) ~= 'table' then return nil end
   if type(Response.choices) ~= 'table' then return nil end
   if #Response.choices == 0 then return nil end
   local Choice = Response.choices[1]
   if type(Choice.message) ~= 'table' then return nil end
   return Choice.message.content
end

-- Extract the text output from a responses API result.
-- Concatenates all output_text entries across message-type outputs.
function M.responseText(Response)
   if type(Response) ~= 'table' then return nil end
   if type(Response.output) ~= 'table' then return nil end

   local Parts = {}
   for _, Output in ipairs(Response.output) do
      if Output.type == 'message' and type(Output.content) == 'table' then
         for _, Content in ipairs(Output.content) do
            if Content.type == 'output_text' and Content.text then
               Parts[#Parts + 1] = Content.text
            end
         end
      end
   end

   if #Parts == 0 then return nil end
   return table.concat(Parts, '\n')
end

-- Build a client explicitly.
--
--   ModelUri          - the full Azure OpenAI endpoint URL
--   AuthMode          - 'API Key' or 'Entra ID'
--   ApiKey            - API key (required for API Key mode)
--   AzureTenantId     - Entra ID tenant (required for Entra ID mode)
--   AzureClientId     - Entra ID client (required for Entra ID mode)
--   AzureClientSecret - Entra ID secret (required for Entra ID mode)
--   Timeout           - HTTP timeout in seconds, defaults to 30
--   Live              - perform real HTTP requests, defaults to true
function M.new(T)
   T = T or {}

   -- Validate Model URI
   if not T.ModelUri or T.ModelUri == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Model URI is required',
      }
   end

   -- Parse endpoint mode
   local Endpoint, ParseErr = parseEndpoint(T.ModelUri)
   if not Endpoint then
      return nil, ParseErr
   end

   -- Validate auth mode
   local AuthMode = T.AuthMode or 'API Key'
   if AuthMode == 'API Key' then
      if not T.ApiKey or T.ApiKey == '' then
         return nil, {
            code    = 'CONFIG_ERROR',
            message = 'API Key is required when Authentication Mode is API Key',
         }
      end
   elseif AuthMode == 'Entra ID' then
      local Missing = {}
      if not T.AzureTenantId or T.AzureTenantId == '' then
         Missing[#Missing + 1] = 'Azure Tenant ID'
      end
      if not T.AzureClientId or T.AzureClientId == '' then
         Missing[#Missing + 1] = 'Azure Client ID'
      end
      if not T.AzureClientSecret or T.AzureClientSecret == '' then
         Missing[#Missing + 1] = 'Azure Client Secret'
      end
      if #Missing > 0 then
         return nil, {
            code    = 'CONFIG_ERROR',
            message = 'Missing Entra ID configuration: ' .. table.concat(Missing, ', '),
         }
      end
   else
      return nil, {
         code    = 'CONFIG_ERROR',
         message = "Authentication Mode must be 'API Key' or 'Entra ID', got: " .. tostring(AuthMode),
      }
   end

   local Instance = setmetatable({}, Client)
   Instance.model_uri           = T.ModelUri
   Instance.endpoint            = Endpoint
   Instance.auth_mode           = AuthMode
   Instance.api_key             = T.ApiKey or ''
   Instance.azure_tenant_id     = T.AzureTenantId or ''
   Instance.azure_client_id     = T.AzureClientId or ''
   Instance.azure_client_secret = T.AzureClientSecret or ''
   Instance.timeout             = tonumber(T.Timeout) or 30
   Instance.live                = T.Live ~= false

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, or nil plus an error table on
-- configuration problems.
--
--    local Client, Config = AzureOpenAI.fromNodeConfig()
--    if not Client then ... end
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance, Err = M.new{
      ModelUri          = Config['Model URI'],
      AuthMode          = Config['Authentication Mode'],
      ApiKey            = Config['API Key'],
      AzureTenantId     = Config['Azure Tenant ID'],
      AzureClientId     = Config['Azure Client ID'],
      AzureClientSecret = Config['Azure Client Secret'],
      Timeout           = Config['Request Timeout'],
      Live              = Config['Live Mode'],
   }

   if not Instance then return nil, Err end
   return Instance, Config
end

return M

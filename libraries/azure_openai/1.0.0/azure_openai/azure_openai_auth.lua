-- ---------------------------------------------------------------------------
-- azure_openai_auth - token acquisition for Entra ID (client credentials)
--
-- API Key mode does not use this module; the key goes straight into the
-- Authorization header via the entry module.
--
-- Entra ID mode obtains an OAuth 2.0 access token from the Microsoft identity
-- platform using the client_credentials grant. The token body is form-encoded
-- as required by the OAuth spec.
-- ---------------------------------------------------------------------------

local Token = require 'azure_openai_token'

local M = {}

local TOKEN_REQUEST_TIMEOUT = 30
local SCOPE = 'https://cognitiveservices.azure.com/.default'

-- Form-encode a table of key-value pairs.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Request a fresh access token from the Entra ID token endpoint.
local function requestToken(Client)
   local TokenUrl = 'https://login.microsoftonline.com/'
      .. Client.azure_tenant_id .. '/oauth2/v2.0/token'

   local Body = formEncode{
      client_id     = Client.azure_client_id,
      client_secret = Client.azure_client_secret,
      grant_type    = 'client_credentials',
      scope         = SCOPE,
   }

   local Response, WebErr = linkiir.link.web.post{
      url     = TokenUrl,
      headers = { ['Content-Type'] = 'application/x-www-form-urlencoded' },
      body    = Body,
      timeout = TOKEN_REQUEST_TIMEOUT,
      live    = true,
   }

   if not Response then
      return nil, WebErr or {
         code    = 'TOKEN_REQUEST_FAILED',
         message = 'Entra ID token request failed',
      }
   end

   if Response.code ~= 200 then
      local Detail = Response.body or ''
      return nil, {
         code      = 'TOKEN_HTTP_' .. tostring(Response.code),
         message   = 'Entra ID token endpoint returned HTTP ' .. tostring(Response.code),
         http_code = Response.code,
         body      = Detail,
      }
   end

   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok or not Parsed.access_token then
      return nil, {
         code    = 'TOKEN_PARSE_ERROR',
         message = 'Entra ID token response did not contain an access_token',
         body    = Response.body,
      }
   end

   return Parsed
end

-- Ensure the client has a valid Entra ID token. Returns the token string, or
-- nil plus an error table.
function M.ensure(Client)
   local CacheKey = Client.azure_tenant_id .. ':' .. Client.azure_client_id

   local Cached = Token.get(CacheKey)
   if Cached then
      return Cached.token
   end

   local TokenData, Err = requestToken(Client)
   if not TokenData then return nil, Err end

   local ExpiresIn = tonumber(TokenData.expires_in) or 3600
   local ExpiresAt = os.time() + ExpiresIn

   Token.put(CacheKey, TokenData.access_token, ExpiresAt)
   return TokenData.access_token
end

-- Force a fresh token exchange regardless of cache state.
function M.authenticate(Client)
   local CacheKey = Client.azure_tenant_id .. ':' .. Client.azure_client_id
   Token.clear(CacheKey)
   return M.ensure(Client)
end

return M

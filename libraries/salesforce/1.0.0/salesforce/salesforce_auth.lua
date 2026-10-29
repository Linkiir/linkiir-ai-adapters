-- ---------------------------------------------------------------------------
-- salesforce_auth - obtains a Salesforce access token
--
-- Implements the OAuth 2.0 client_credentials flow. The client posts its
-- client_id and client_secret to the token endpoint and receives a bearer
-- token in return.
--
--    1. POST client_id + client_secret to <domain>/services/oauth2/token
--    2. Cache the returned token until it nears expiry
--
-- Callers use M.ensure, which authenticates only when there is no usable token.
-- M.authenticate forces a fresh exchange.
-- ---------------------------------------------------------------------------

local TokenCache = require 'salesforce_token'

local M = {}

-- Salesforce tokens are valid for roughly two hours by default.
local DEFAULT_TOKEN_LIFETIME = 7200

-- Percent-encode a flat table as application/x-www-form-urlencoded.
--
-- The token endpoint expects its grant fields in the request body. Passing
-- them as `params` to linkiir.link.web.post would put them in the query
-- string, where Salesforce does not look for them.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Exchange client credentials for a bearer token, storing it on the client and
-- in the shared cache. Returns the token, or nil plus { code=, message= }.
function M.authenticate(Client)
   if not Client.client_id or Client.client_id == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Client ID is not configured on this node',
      }
   end

   if not Client.client_secret or Client.client_secret == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Client Secret is not configured on this node',
      }
   end

   local TokenUrl = 'https://' .. Client.domain .. '/services/oauth2/token'

   local Response, WebErr = linkiir.link.web.post{
      url = TokenUrl,
      headers = {
         ['Content-Type'] = 'application/x-www-form-urlencoded',
         ['Accept']       = 'application/json',
      },
      body = formEncode{
         grant_type    = 'client_credentials',
         client_id     = Client.client_id,
         client_secret = Client.client_secret,
      },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = true,
   }

   if not Response then
      return nil, WebErr or {
         code    = 'AUTH_FAILED',
         message = 'token request to ' .. TokenUrl .. ' failed',
      }
   end

   if Response.code ~= 200 then
      return nil, {
         code    = 'AUTH_FAILED',
         message = 'Salesforce token endpoint returned HTTP ' .. tostring(Response.code),
         body    = Response.body,
      }
   end

   local Ok, Auth = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(Auth) ~= 'table' or not Auth.access_token then
      return nil, {
         code    = 'AUTH_FAILED',
         message = 'token response was not JSON containing an access_token',
         body    = Response.body,
      }
   end

   Client.key        = Auth.access_token
   Client.key_expiry = os.time() + (tonumber(Auth.expires_in) or DEFAULT_TOKEN_LIFETIME)
   TokenCache.put(Client.cache_key, Client.key, Client.key_expiry)

   return Client.key
end

-- Return a usable token, authenticating only if needed.
--
-- Checks the token already on the client, then the shared cache, then falls
-- back to a fresh exchange.
function M.ensure(Client)
   if Client.key and Client.key_expiry
      and Client.key_expiry - TokenCache.EXPIRY_SKEW > os.time() then
      return Client.key
   end

   local Cached = TokenCache.get(Client.cache_key)
   if Cached then
      Client.key        = Cached.token
      Client.key_expiry = Cached.expires_at
      return Client.key
   end

   return M.authenticate(Client)
end

return M

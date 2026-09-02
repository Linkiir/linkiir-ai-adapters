-- ---------------------------------------------------------------------------
-- azure_openai_http - shared request path
--
-- Every Azure OpenAI API call goes through this module. It attaches the
-- appropriate authentication header, sends the request, and normalises the
-- response into the result-error convention:
--
--   Result        - the parsed response body
--   nil, Err      - Err is { code=, message= } plus optional context
-- ---------------------------------------------------------------------------

local Auth = require 'azure_openai_auth'

local M = {}

-- Build the Authorization header based on the client's auth mode.
local function getAuthHeader(Client)
   if Client.auth_mode == 'API Key' then
      return 'Bearer ' .. Client.api_key
   end

   -- Entra ID mode: obtain a token via client_credentials flow.
   local AccessToken, Err = Auth.ensure(Client)
   if not AccessToken then
      return nil, Err
   end
   return 'Bearer ' .. AccessToken
end

-- Send a POST request to the Azure OpenAI endpoint.
--
--   T.body     - serialised JSON payload
--   T.live     - overrides the client's live flag for this call
function M.request(Client, T)
   local AuthHeader, AuthErr = getAuthHeader(Client)
   if not AuthHeader then return nil, AuthErr end

   local Live = T.live
   if Live == nil then Live = Client.live end
   if Live == nil then Live = true end

   local Headers = {
      ['Content-Type']  = 'application/json',
      ['Authorization'] = AuthHeader,
   }

   local Request = {
      url     = Client.model_uri,
      headers = Headers,
      body    = T.body,
      timeout = Client.timeout,
      live    = Live,
   }

   linkiir.log.debug('azure_openai POST ' .. Request.url)

   local Response, WebErr = linkiir.link.web.post(Request)
   if not Response then
      return nil, WebErr or {
         code    = 'REQUEST_FAILED',
         message = 'POST ' .. Request.url .. ' failed',
      }
   end

   if Response.simulated then
      return { simulated = true }
   end

   if Response.body == nil or Response.body == '' then
      return nil, {
         code      = 'EMPTY_RESPONSE',
         message   = 'Azure OpenAI returned an empty response body',
         http_code = Response.code,
      }
   end

   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok then
      return nil, {
         code      = 'PARSE_ERROR',
         message   = 'Azure OpenAI response was not valid JSON',
         http_code = Response.code,
         body      = Response.body,
      }
   end

   if Response.code < 200 or Response.code >= 300 then
      local ErrMsg = 'Azure OpenAI returned HTTP ' .. tostring(Response.code)
      if type(Parsed.error) == 'table' and Parsed.error.message then
         ErrMsg = Parsed.error.message
      end
      return nil, {
         code      = 'HTTP_' .. tostring(Response.code),
         message   = ErrMsg,
         http_code = Response.code,
         body      = Parsed,
      }
   end

   return Parsed
end

return M

-- ---------------------------------------------------------------------------
-- salesforce_http - the request path every Salesforce REST call goes through
--
-- Attaches the bearer token, builds the resource URL, sends the request, and
-- turns whatever Salesforce returns into one predictable pair:
--
--    Result        - the parsed response
--    nil, Err      - Err is { code=, message= } plus optional context
--
-- On a 401 response the module re-authenticates once and retries, covering
-- the case where a cached token expired between the check and the request.
-- ---------------------------------------------------------------------------

local Auth = require 'salesforce_auth'

local M = {}

-- Verbs whose parameters belong in the query string. Everything else sends a
-- JSON body.
local QUERY_VERBS = {
   get     = true,
   head    = true,
   delete  = true,
   options = true,
}

-- Merge caller headers with the ones this module controls. Authorization is
-- applied last so a caller cannot accidentally replace it.
local function buildHeaders(CallerHeaders, Token)
   local Headers = {}
   for Key, Value in pairs(CallerHeaders or {}) do
      Headers[Key] = Value
   end
   Headers['Accept'] = Headers['Accept'] or 'application/json'
   Headers['Authorization'] = 'Bearer ' .. Token
   return Headers
end

-- Parse a response body and classify it as success or failure.
local function readBody(Response)
   -- Handle empty bodies (204 No Content on successful PATCH/DELETE)
   if Response.body == nil or Response.body == '' then
      if Response.code >= 200 and Response.code < 300 then
         return { success = true, code = Response.code }
      end
      return nil, {
         code      = 'HTTP_' .. tostring(Response.code),
         message   = 'Salesforce returned HTTP ' .. tostring(Response.code) .. ' with no body',
         http_code = Response.code,
      }
   end

   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok then
      return nil, {
         code      = 'PARSE_ERROR',
         message   = 'Salesforce response was not valid JSON',
         http_code = Response.code,
         body      = Response.body,
      }
   end

   -- Salesforce error responses are arrays of { errorCode, message, fields }
   if Response.code >= 400 then
      local ErrMsg = 'Salesforce returned HTTP ' .. tostring(Response.code)
      if type(Parsed) == 'table' and Parsed[1] and Parsed[1].message then
         ErrMsg = Parsed[1].message
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

-- Send one Salesforce REST API request.
--
--   T.method     - HTTP verb, defaults to 'get'
--   T.api        - path below /services/data/v<version>/, e.g. 'query'
--   T.parameters - query table for GET-like verbs, JSON body for the rest
--   T.headers    - extra headers
--   T.sf_method  - override HTTP method header for Salesforce (e.g. PATCH via POST)
--   T.live       - overrides the client's live flag for this call
function M.request(Client, T)
   local Token, AuthErr = Auth.ensure(Client)
   if not Token then return nil, AuthErr end

   local Method = tostring(T.method or 'get'):lower()
   local SendRequest = linkiir.link.web[Method]
   if not SendRequest then
      error("salesforce_http.request: unsupported HTTP method '" .. Method .. "'")
   end

   local Headers = buildHeaders(T.headers, Token)

   -- A per-call live flag wins over the client's; both default to true.
   local Live = T.live
   if Live == nil then Live = Client.live end
   if Live == nil then Live = true end

   local Url = 'https://' .. Client.domain .. '/services/data/v'
      .. Client.api_version .. '/' .. tostring(T.api)

   local Request = {
      url       = Url,
      headers   = Headers,
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = Live,
   }

   if QUERY_VERBS[Method] then
      Request.params = T.parameters
   elseif T.parameters ~= nil then
      Request.body = linkiir.json.serialize(T.parameters)
      Headers['Content-Type'] = Headers['Content-Type'] or 'application/json'
   end

   -- Salesforce uses X-HTTP-Method-Override for PATCH via POST
   if T.sf_method then
      Headers['X-HTTP-Method-Override'] = T.sf_method
   end

   linkiir.log.debug('salesforce ' .. Method:upper() .. ' ' .. Url)

   local Response, WebErr = SendRequest(Request)
   if not Response then
      return nil, WebErr or {
         code    = 'REQUEST_FAILED',
         message = Method:upper() .. ' ' .. Url .. ' failed',
      }
   end

   -- With live = false nothing was sent.
   if Response.simulated then
      return { simulated = true }
   end

   -- Re-authenticate on 401 and retry once
   if Response.code == 401 then
      local NewToken, ReauthErr = Auth.authenticate(Client)
      if not NewToken then return nil, ReauthErr end

      Headers['Authorization'] = 'Bearer ' .. NewToken
      Request.headers = Headers

      Response, WebErr = SendRequest(Request)
      if not Response then
         return nil, WebErr or {
            code    = 'REQUEST_FAILED',
            message = Method:upper() .. ' ' .. Url .. ' failed on retry',
         }
      end

      if Response.simulated then
         return { simulated = true }
      end
   end

   return readBody(Response)
end

return M

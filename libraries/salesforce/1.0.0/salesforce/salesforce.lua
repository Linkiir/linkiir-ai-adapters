-- ---------------------------------------------------------------------------
-- salesforce - Salesforce REST API client
--
-- Require this module. The others (auth, http, token) are internals.
--
--    local Salesforce = require 'salesforce'
--
--    function main(Data)
--       local SF = Salesforce.fromNodeConfig()
--
--       local Done, Records, Err = SF:query{
--          object = 'Account',
--          where  = "Name = 'Acme Corp'",
--       }
--       if Err then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Record in ipairs(Records) do
--          SF:modify{
--             object     = 'Account',
--             object_id  = Record.Id,
--             parameters = { Industry = 'Technology' },
--          }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = SF:modify{ object = 'Account', ... }
--    if not Result then
--       -- Err.code and Err.message are always set.
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- and later calls reuse it until it nears expiry.
-- ---------------------------------------------------------------------------

local Http = require 'salesforce_http'

local DEFAULT_API_VERSION = '59.0'
local DEFAULT_TIMEOUT     = 30

-- ---------------------------------------------------------------------------
-- SOQL value escaping
--
-- The legacy code concatenated user-provided values directly into SOQL WHERE
-- clauses, creating an injection risk. This module escapes values before
-- interpolation.
-- ---------------------------------------------------------------------------

-- Escape a string value for safe inclusion in a SOQL WHERE clause.
-- Handles single quotes, backslashes, and newlines per the SOQL specification.
local function escapeSoql(Value)
   if Value == nil then return '' end
   local S = tostring(Value)
   S = S:gsub('\\', '\\\\')
   S = S:gsub("'", "\\'")
   S = S:gsub('\n', '\\n')
   S = S:gsub('\r', '\\r')
   return S
end

-- ---------------------------------------------------------------------------
-- Client methods
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

-- Run a SOQL query. Builds SELECT from fields/object/where/limit, or accepts
-- a raw query string.
--
--   T.object  - sObject name, e.g. 'Account'
--   T.fields  - comma-separated field list (defaults to FIELDS(ALL))
--   T.where   - WHERE clause (values should be pre-escaped, or use escapeValue)
--   T.limit   - result limit (defaults to 200 when no custom fields and no raw query)
--   T.query   - raw SOQL query (overrides object/fields/where/limit)
--   T.live    - override the client's live flag
--
-- Returns: done (boolean), records (table), or nil, nil, err (error table).
function Client:query(T)
   local CustomFields = T.fields
   if CustomFields then CustomFields = CustomFields:gsub('%s', '') end

   local Soql = T.query
   if not Soql then
      Soql = 'SELECT ' .. (CustomFields or 'FIELDS(ALL)') .. ' FROM ' .. T.object
      if T.where then
         Soql = Soql .. ' WHERE ' .. T.where
      end
      if T.limit or (not CustomFields and not T.query) then
         Soql = Soql .. ' LIMIT ' .. tostring(T.limit or 200)
      end
   end

   local Result, Err = Http.request(self, {
      method     = 'get',
      api        = 'query',
      parameters = { q = Soql },
      live       = T.live,
   })

   if not Result then return nil, nil, Err end
   if Result.simulated then return true, {}, nil end

   return Result.done ~= false, Result.records or Result, nil
end

-- Create or update an sObject record.
--
--   T.object     - sObject name
--   T.object_id  - record id (if present: PATCH update; if absent: POST create)
--   T.parameters - field values
--   T.live       - override the client's live flag
--
-- Returns: result, or nil plus error table.
function Client:modify(T)
   if not T.object then
      error('salesforce.modify: object is required')
   end

   local Path = 'sobjects/' .. T.object .. '/'
   local SfMethod

   if T.object_id and T.object_id ~= '' then
      SfMethod = 'PATCH'
      Path = Path .. T.object_id
   else
      SfMethod = 'POST'
   end

   local Result, Err = Http.request(self, {
      method     = 'put',
      api        = Path,
      sf_method  = SfMethod,
      parameters = T.parameters,
      headers    = { ['Content-Type'] = 'application/json' },
      live       = T.live,
   })

   if not Result then return nil, Err end
   if Result.simulated then return { simulated = true } end

   -- Salesforce returns { id, success, errors } on create
   if Result.success then
      return { id = Result.id, success = true }
   end

   return Result
end

-- Create or update multiple sObject records in a single composite batch.
--
--   T.parameters - array of { object=, object_id=, parameters= }
--   T.live       - override the client's live flag
--
-- Returns: success (boolean), results (table), or nil, nil, err.
function Client:modifyBatch(T)
   local BatchRequests = {}
   for i = 1, #T.parameters do
      local Item = T.parameters[i]
      local ObjectPath = 'v' .. self.api_version .. '/sobjects/' .. Item.object .. '/'
      local SfMethod

      if Item.object_id and Item.object_id ~= '' then
         SfMethod = 'PATCH'
         ObjectPath = ObjectPath .. Item.object_id
      else
         SfMethod = 'POST'
      end

      BatchRequests[#BatchRequests + 1] = {
         method   = SfMethod,
         url      = ObjectPath,
         richInput = Item.parameters,
      }
   end

   local Result, Err = Http.request(self, {
      method     = 'put',
      api        = 'composite/batch',
      sf_method  = 'POST',
      parameters = { batchRequests = BatchRequests },
      headers    = { ['Content-Type'] = 'application/json' },
      live       = T.live,
   })

   if not Result then return nil, nil, Err end
   if Result.simulated then return true, {}, nil end

   return not Result.hasErrors, Result, nil
end

-- Delete an sObject record.
--
--   T.object     - sObject name
--   T.object_id  - record id to delete
--   T.live       - override the client's live flag
--
-- Returns: result, or nil plus error table.
function Client:delete(T)
   if not T.object or not T.object_id then
      error('salesforce.delete: object and object_id are required')
   end

   local Path = 'sobjects/' .. T.object .. '/' .. T.object_id

   return Http.request(self, {
      method = 'delete',
      api    = Path,
      live   = T.live,
   })
end

-- Escape hatch for anything the methods above do not cover.
--
--   T.method     - HTTP verb
--   T.api        - path below /services/data/v<version>/
--   T.parameters - query or body depending on method
--   T.sf_method  - optional HTTP method override
--   T.headers    - extra headers
--   T.live       - override the client's live flag
function Client:request(T)
   return Http.request(self, T)
end

-- Force a token exchange. Not normally needed since requests authenticate on
-- demand; useful to validate credentials at startup.
function Client:authenticate()
   local Auth = require 'salesforce_auth'
   return Auth.authenticate(self)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

M.Client = Client

-- Expose the escape helper so callers can safely build WHERE clauses with
-- user-supplied values.
M.escapeValue = escapeSoql

-- Build a client explicitly.
--
--   Domain       - Salesforce instance domain (e.g. 'myorg.my.salesforce.com')
--   ClientId     - connected app client id
--   ClientSecret - connected app client secret
--   Key          - pre-existing bearer token (optional, overrides auth)
--   ApiVersion   - REST API version, defaults to 59.0
--   Timeout      - request timeout in seconds, defaults to 30
--   VerifyTls    - verify the server certificate, defaults to true
--   Live         - perform real requests, defaults to true
function M.new(T)
   T = T or {}

   local Domain = T.Domain or ''
   -- Strip protocol prefix if provided
   Domain = Domain:gsub('^https?://', '')
   -- Strip trailing slash
   Domain = Domain:gsub('/$', '')

   local ApiVersion = T.ApiVersion
   if ApiVersion == nil or ApiVersion == '' then ApiVersion = DEFAULT_API_VERSION end

   local Instance = setmetatable({}, Client)
   Instance.domain        = Domain
   Instance.client_id     = T.ClientId or ''
   Instance.client_secret = T.ClientSecret or ''
   Instance.key           = (T.Key and T.Key ~= '') and T.Key or nil
   Instance.api_version   = ApiVersion
   Instance.timeout       = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls    = T.VerifyTls ~= false
   Instance.live          = T.Live ~= false

   -- Scoping the cached token by credential and environment.
   Instance.cache_key = Instance.client_id .. '@' .. Instance.domain

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table:
--
--    local SF, Config = Salesforce.fromNodeConfig()
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      Domain       = Config['Domain'],
      ClientId     = Config['Client ID'],
      ClientSecret = Config['Client Secret'],
      Key          = Config['Key'],
      ApiVersion   = Config['API Version'],
      VerifyTls    = Config['Verify TLS'],
      Live         = Config['Live Mode'],
   }

   return Instance, Config
end

return M

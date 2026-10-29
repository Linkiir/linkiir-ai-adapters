-- ---------------------------------------------------------------------------
-- Salesforce Adapter - Transform Custom
--
-- Receives inbound data describing which Salesforce record to query and how to
-- update it. The script queries the specified object, updates the matching
-- records, and pushes the results downstream.
--
-- What to change where:
--   connection credentials and API version  ->  node config
--   what to query and how to update         ->  this script
--   how Salesforce is called                ->  salesforce library
-- ---------------------------------------------------------------------------

-- The library modules live in the salesforce/ subfolder.
package.path = linkiir.sys.nodeDir() .. '/salesforce/?.lua;' .. package.path

local Salesforce = require 'salesforce'

function main(Data)
   local SF = Salesforce.fromNodeConfig()

   -- Parse the inbound message to determine the operation
   local Ok, Input = pcall(linkiir.json.parse, Data)
   if not Ok or type(Input) ~= 'table' then
      linkiir.log.error('Salesforce Adapter: inbound data is not valid JSON')
      return
   end

   local Object   = Input.object or 'Account'
   local Where    = Input.where
   local Fields   = Input.fields
   local Limit    = Input.limit
   local UpdateFields = Input.update

   -- Query records
   local Done, Records, QueryErr = SF:query{
      object = Object,
      where  = Where,
      fields = Fields,
      limit  = Limit,
   }

   if QueryErr then
      linkiir.log.error(string.format(
         'Salesforce Adapter: query failed [%s] %s',
         tostring(QueryErr.code), tostring(QueryErr.message)))
      return
   end

   if not Records or #Records == 0 then
      linkiir.log.info('Salesforce Adapter: query returned no records.')
      return
   end

   -- If update fields are specified, modify each returned record
   if UpdateFields and type(UpdateFields) == 'table' then
      for _, Record in ipairs(Records) do
         local _, ModifyErr = SF:modify{
            object     = Object,
            object_id  = Record.Id,
            parameters = UpdateFields,
         }
         if ModifyErr then
            linkiir.log.error(string.format(
               'Salesforce Adapter: modify failed for %s [%s] %s',
               tostring(Record.Id), tostring(ModifyErr.code), tostring(ModifyErr.message)))
         end
      end
   end

   -- Push query results downstream
   linkiir.flow.push{ data = linkiir.json.serialize(Records) }
   linkiir.log.info(string.format(
      'Salesforce Adapter: pushed %d %s record(s).', #Records, Object))
end

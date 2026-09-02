-- ---------------------------------------------------------------------------
-- Azure OpenAI Adapter - Transform Custom
--
-- Receives an inbound message (FHIR, HL7 or arbitrary text), sends it to an
-- Azure OpenAI model, and pushes the model's text output downstream.
--
-- Supports two endpoint modes inferred from Model URI:
--   - chat_completions: /openai/deployments/{name}/chat/completions
--   - responses:        /openai/responses
--
-- Supports two authentication modes:
--   - API Key:  static bearer token (no token exchange)
--   - Entra ID: OAuth 2.0 client_credentials against Microsoft identity
--
-- What to change where:
--   Authentication, Model URI, System Prompt  ->  node config
--   how the model output is processed         ->  this script
--   how Azure is called                       ->  azure_openai library
-- ---------------------------------------------------------------------------

package.path = linkiir.sys.nodeDir() .. '/azure_openai/?.lua;' .. package.path

local AzureOpenAI = require 'azure_openai'

function main(Data)
   -- Build client from node configuration (validates on construction)
   local Client, Config = AzureOpenAI.fromNodeConfig()
   if not Client then
      linkiir.log.error(string.format(
         'Azure OpenAI Adapter: configuration error [%s] %s',
         tostring(Config.code), tostring(Config.message)))
      return
   end

   local EndpointMode = Client.endpoint.mode
   local SystemPrompt = Config['System Prompt'] or 'You are a helpful assistant.'

   -- Call the appropriate endpoint
   local Response, Err

   if EndpointMode == 'chat_completions' then
      Response, Err = Client:chatCompletionsCreate{
         messages = {
            { role = 'system', content = SystemPrompt },
            { role = 'user',   content = Data },
         },
         max_tokens  = Config['Max Tokens'],
         temperature = Config['Temperature'],
         top_p       = Config['TopP'],
      }

   elseif EndpointMode == 'responses' then
      local ModelName = Config['Model Name']
      if not ModelName or ModelName == '' then
         linkiir.log.error('Azure OpenAI Adapter: Model Name is required for responses endpoint mode.')
         return
      end

      Response, Err = Client:responsesCreate{
         model            = ModelName,
         input            = 'system prompt:\n' .. SystemPrompt .. '\nuser prompt:\n' .. Data,
         max_output_tokens = Config['Max Tokens'],
         temperature      = Config['Temperature'],
         top_p            = Config['TopP'],
      }
   end

   -- Handle errors
   if not Response then
      linkiir.log.error(string.format(
         'Azure OpenAI Adapter: API call failed [%s] %s',
         tostring(Err.code), tostring(Err.message)))
      return
   end

   -- Simulated mode (Live Mode is off)
   if Response.simulated then
      linkiir.log.info('Azure OpenAI Adapter: Live Mode is off, no request was sent.')
      return
   end

   -- Extract text from response based on endpoint mode
   local OutputText

   if EndpointMode == 'chat_completions' then
      OutputText = AzureOpenAI.completionText(Response)
   elseif EndpointMode == 'responses' then
      OutputText = AzureOpenAI.responseText(Response)
   end

   if not OutputText then
      linkiir.log.error('Azure OpenAI Adapter: no text content in model response.')
      return
   end

   -- Push model output downstream
   linkiir.flow.push{ data = OutputText }
   linkiir.log.info('Azure OpenAI Adapter: pushed model output downstream.')
end

require 'net/http'
require 'json'
require 'uri'

Puppet::Functions.create_function(:myFunction1) do
  dispatch :execute do
    param 'String', :url
    return_type 'Variant[Hash, Array, String]'
  end

  def execute(url)
    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          response.body
        end
      else
        { 'status' => 'error', 'code' => response.code }
      end
    rescue => e
      { 'status' => 'unreachable', 'error' => e.message }
    end
  end
end

require 'net/http'
require 'uri'

Puppet::Type.type(:myType1).provide(:myProvider1) do
  desc "Provider executing HTTP check for myType1"

  def exists?
    uri = URI.parse(resource[:url])
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end

  def create
    raise "Resource myType1 failed: URL #{resource[:url]} is unreachable"
  end

  def destroy
    # No-op for check resource
  end
end

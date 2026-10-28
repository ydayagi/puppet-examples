require 'net/http'
require 'fileutils'
require 'open-uri'

Puppet::Type.type(:myDeploy1).provide(:myDeployProvider) do
  desc "Deploys an application artifact and tracks the installed version"

  def exists?
    version_file = File.join(resource[:install_dir], 'version.txt')
    return false unless File.exist?(version_file)
    File.read(version_file).strip == resource[:version]
  end

  def create
    FileUtils.mkdir_p(resource[:install_dir])
    artifact = File.join(resource[:install_dir], 'artifact.tar.gz')
    download(resource[:url], artifact)
    extract(artifact, resource[:install_dir])
    File.write(File.join(resource[:install_dir], 'version.txt'), resource[:version])
  end

  def destroy
    FileUtils.rm_rf(resource[:install_dir])
  end

  def download(url, dest)
    URI.open(url) do |body|
      File.binwrite(dest, body.read)
    end
  end

  def extract(archive, dest)
    system('tar', '-xzf', archive, '-C', dest) or raise "Failed to extract #{archive}"
  end
end

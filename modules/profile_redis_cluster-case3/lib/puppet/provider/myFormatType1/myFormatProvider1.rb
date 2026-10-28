Puppet::Type.type(:myFormatType1).provide(:myFormatProvider1) do
  desc "Manages !key=value entries in the proprietary CompanyApp settings format.

Each line of the settings file is either a comment (starting with '#') or an
entry in the form '!key=value'. Lines starting with '!' that are not valid
entries are left untouched."

  def exists?
    found = current_value
    found && found == resource[:value].to_s
  end

  def create
    write_lines(existing_lines.reject { |l| entry_key(l) == resource[:entry] } + ["!#{resource[:entry]}=#{resource[:value]}"])
  end

  def destroy
    write_lines(existing_lines.reject { |l| entry_key(l) == resource[:entry] })
  end

  private

  def current_value
    existing_lines.each do |line|
      key, val = parse_entry(line)
      return val if key == resource[:entry]
    end
    nil
  end

  def entry_key(line)
    key, = parse_entry(line)
    key
  end

  def parse_entry(line)
    return [nil, nil] unless line.start_with?('!')
    key, sep, val = line[1..].partition('=')
    return [nil, nil] if sep.empty?
    [key.strip, val.strip]
  end

  def existing_lines
    return [] unless File.exist?(resource[:file])
    File.readlines(resource[:file]).map(&:chomp)
  end

  def write_lines(lines)
    File.open(resource[:file], 'w') { |f| f.puts(lines) }
  end
end

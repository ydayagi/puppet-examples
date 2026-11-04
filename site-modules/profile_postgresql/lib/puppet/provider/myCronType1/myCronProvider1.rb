require 'stringio'

Puppet::Type.type(:myCronType1).provide(:myCronProvider1) do
  desc "Manages cron entries for the root user via the crontab command"

  def exists?
    crontab_lines.any? { |line| line.include?(resource[:command]) }
  end

  def create
    lines = crontab_lines
    lines << "#{resource[:minute]} #{resource[:hour]} * * * #{resource[:command]}"
    write_crontab(lines)
  end

  def destroy
    write_crontab(crontab_lines.reject { |line| line.include?(resource[:command]) })
  end

  private

  def crontab_lines
    out = `crontab -l 2>/dev/null`
    out.strip.empty? ? [] : out.lines.map(&:chomp)
  end

  def write_crontab(lines)
    input = StringIO.new(lines.join("\n") + "\n")
    system('crontab', '-', in: input) or raise "Failed to update crontab"
  end
end

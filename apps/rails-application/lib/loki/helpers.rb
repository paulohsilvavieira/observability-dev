# lib/loki/helpers.rb
module Loki
  module Helpers
    # Remove cores e códigos ANSI do log
    def self.strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end

    def self.extract_log_message(message, progname, block)
      message || (block && block.call) || progname || ""
    end
  end
end

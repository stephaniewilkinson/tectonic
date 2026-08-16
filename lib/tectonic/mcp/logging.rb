# frozen_string_literal: true

require 'logger'

class Tectonic < Roda
  module MCP
    class << self
      # One structured line per tool call (spec §6): tool, account, outcome, and
      # duration. Kept quiet in the test environment so the suite output stays clean.
      def log_call(tool:, account:, status:, duration_ms:)
        logger.info("mcp tool=#{tool} account=#{account} status=#{status} duration_ms=#{duration_ms}")
      end

      def logger
        @logger ||= build_logger
      end

      private

      def build_logger
        logger = Logger.new($stdout)
        logger.level = ENV['RACK_ENV'] == 'test' ? Logger::FATAL : Logger::INFO
        logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
        logger
      end
    end
  end
end


require 'logger'
module RailsSemanticLogger #:nodoc:
  class Railtie < Rails::Railtie #:nodoc:
    # Make the SemanticLogger config available in the Rails application config
    #
    # Example: Add the MongoDB logging appender in the Rails environment
    #          initializer in file config/environments/development.rb
    #
    #   Rails::Application.configure do
    #     # Add the MongoDB logger appender only once Rails is initialized
    #     config.after_initialize do
    #       config.semantic_logger.add_appender SemanticLogger::Appender::Mongo.new(
    #         :db => Mongo::Connection.new['development_development']
    #        )
    #     end
    #   end
    config.semantic_logger = ::SemanticLogger::Logger

    # Initialize SemanticLogger. In a Rails environment it will automatically
    # insert itself above the configured rails logger to add support for its
    # additional features
    #
    # Loaded after Rails logging is initialized since SemanticLogger will continue
    # to forward logging to the Rails Logger
    initializer :initialize_semantic_logger, :before => :initialize_logger do
      config = Rails.application.config

      # Set the default log level based on the Rails config
      SemanticLogger.default_level = config.log_level

      # Existing loggers are ignored because servers like trinidad supply their
      # own file loggers which would result in duplicate logging to the same log file
      Rails.logger = config.logger = begin
        # First check for Rails 3.2 path, then fallback to pre-3.2
        path = ((config.paths.log.to_a rescue nil) || config.paths['log']).first
        unless File.exist? File.dirname path
          FileUtils.mkdir_p File.dirname path
        end

        # Set internal logger to log to file only, in case another appender
        # experiences errors during writes
        appender = SemanticLogger::Appender::File.new(path, config.log_level)
        appender.name = "SemanticLogger"
        SemanticLogger::Logger.logger = appender

        # Add the log file to the list of appenders
        # Use the colorized formatter if Rails colorized logs are enabled
        formatter = SemanticLogger::Appender::Base.colorized_formatter unless config.colorize_logging == false
        SemanticLogger.add_appender(path, nil, &formatter)
        SemanticLogger[Rails]
      rescue StandardError => exc
        # If not able to log to file, log to standard error with warning level only
        SemanticLogger.default_level = :warn

        SemanticLogger::Logger.logger = SemanticLogger::Appender::File.new(STDERR)
        SemanticLogger.add_appender(STDERR)

        logger = SemanticLogger[Rails]
        logger.warn(
          "Rails Error: Unable to access log file. Please ensure that #{path} exists and is chmod 0666. " +
            "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed.",
          exc
        )
        logger
      end

      # Replace the default Rails loggers
      ActiveSupport.on_load(:active_record)     { self.logger = SemanticLogger['ActiveRecord'] }
      ActiveSupport.on_load(:action_controller) { self.logger = SemanticLogger['ActionController'] }
      ActiveSupport.on_load(:action_mailer)     { self.logger = SemanticLogger['ActionMailer'] }
    end

    # Support fork frameworks
    config.after_initialize do
      # Passenger provides the :starting_worker_process event for executing
      # code after it has forked, so we use that and reconnect immediately.
      if defined?(PhusionPassenger)
        PhusionPassenger.on_event(:starting_worker_process) do |forked|
          ::SemanticLogger.reopen if forked
        end
      end

      # Re-open appenders after Resque has forked a worker
      if defined?(Resque)
        Resque.after_fork { |job| ::SemanticLogger.reopen }
      end
    end

    # Before any initializers run
    config.before_initialize do
      # Replace the Mongoid Loggers after the gems have been loaded
      Mongoid.logger = SemanticLogger[Mongoid] if defined?(Mongoid)
      Moped.logger = SemanticLogger[Moped] if defined?(Moped)
    end

  end
end
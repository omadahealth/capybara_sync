require "capybara/poltergeist"
require "rails"

#TODO: If errors continue, consider blocking requests until another capybara command is called
#      Will want all queued requests to go through before test is allowed to continue

module Capybara::Sync
  class Locks
    @request_mutex = Mutex.new

    def self.request_start
      @request_mutex.try_lock || raise("Locked by someone else?")
    end

    def self.request_end
      @request_mutex.unlock
    end

    def self.request_wait
      if @request_mutex.locked? # Not thread safe, but I'm ok with that
        @request_mutex.lock
        @request_mutex.unlock
      end
    end
  end

  # Sets mutexes to block tests
  class Middleware
    def initialize(app)
      @app = app
      @ignore_assets = true
    end

    def call(env)
      status, headers, response = [nil, nil, nil]

      if @ignore_assets && env["PATH_INFO"] =~ /^\/assets\//
        status, headers, response = @app.call(env)
      else
        Locks.request_start
        begin
          status, headers, response = @app.call(env)
        ensure
          Locks.request_end
        end
      end
      [status, headers, response]
    end
  end
  #
  #class Railtie < Rails::Railtie
  #  initializer("Load Capybara::SyncMiddleware") do |app|
  #    app.middleware.use Capybara::Sync::Middleware
  #  end
  #end
end

################################################################################
########## POLTERGEIST
################################################################################

# Create a new browser to block during requests
module Capybara::Poltergeist
  class SyncDriver < Driver
    def browser
      @browser ||= begin
        browser = SyncBrowser.new(server, client, logger)
        browser.js_errors  = options[:js_errors] if options.key?(:js_errors)
        browser.extensions = options.fetch(:extensions, [])
        browser.debug      = true if options[:debug]
        browser
      end
    end
  end
  class SyncBrowser < Browser
    def command(*args)
      resp = super(*args)
      # wait for a small amount of time
      Thread.pass
      # block until request is done
      Capybara::Sync::Locks.request_wait
      resp
    end
  end
end

# register new driver
Capybara.register_driver :poltergeist_sync do |app|
  Capybara::Poltergeist::SyncDriver.new(app)
end

################################################################################
########## SELENIUM
################################################################################

# Create a new 'selenium_sync' driver, that syncs, without touching the existing 'selenium' driver.
# Tag cucumber scenarios with @selenium_sync in feature files
#
# Capybara/Selenium actually sends the commands to the browser in Selenium::WebDriver::Firefox::Bridge#execute
# The instance of Selenium::WebDriver::Firefox::Bridge is created in Selenium::WebDriver::Driver.for()
#
# In the selenium_sync context, we use Selenium::WebDriver::SyncDriver.for() to create a
# Selenium::WebDriver::Firefox::SyncBridge that contains a call to Capybara::Sync::Locks.request_wait

require 'selenium-webdriver'

module Capybara::Selenium
  class SyncDriver < Driver
    def browser
      unless @browser
        # Call down directly into WebDriver::SyncDriver.for, as we don't want to override WebDriver#for
        # and we can't subclass WebDriver as it is a Module
        # @browser = Selenium::WebDriver::Driver.for(options[:browser], options.reject { |key,val| SPECIAL_OPTIONS.include?(key) })
        @browser = Selenium::WebDriver::SyncDriver.for(options[:browser], options.reject { |key,val| SPECIAL_OPTIONS.include?(key) })

        main = Process.pid
        at_exit do
          # Store the exit status of the test run since it goes away after calling the at_exit proc...
          @exit_status = $!.status if $!.is_a?(SystemExit)
          quit if Process.pid == main
          exit @exit_status if @exit_status # Force exit with stored status
        end
      end
      @browser
    end
  end
end

module Selenium
  module WebDriver
    class SyncDriver < Driver

      class << self
        def for_with_sync_support(browser, opts = {})
          case browser
          when :firefox, :ff
           listener = opts.delete(:listener)
           bridge = Firefox::SyncBridge.new(opts)
           bridge = Support::EventFiringBridge.new(bridge, listener) if listener
           new(bridge)
          else
           for_without_sync_support(browser, opts)
          end
        end

        alias_method_chain :for, :sync_support
      end
    end

    module Firefox
      class SyncBridge < Bridge
        def execute(*args)
          resp = raw_execute(*args)['value']
          # wait for a small amount of time
          Thread.pass
          # block until request is done
          Capybara::Sync::Locks.request_wait
          resp
        end
      end
    end
  end
end

Capybara.register_driver :selenium_sync do |app|
  Capybara::Selenium::SyncDriver.new(app)
end


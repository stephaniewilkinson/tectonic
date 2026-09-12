# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/error_reporting'

Reporting = Tectonic::ErrorReporting

# Where errors get reported, for every process that runs this app's code. #386.
#
# Sentry was initialised in config.ru, which the web server loads and nothing else does. That
# was invisible rather than wrong until you notice what else runs: `render.yaml` runs
# `rake db:migrate && rake library:exercises` on every deploy, before the new version accepts
# a single request, and neither had any reporting at all.
#
# That is how a pre-deploy failure sat unnoticed for six days in September -- seven merged
# commits never reached production, CI was green throughout because it only runs the suite,
# and Render leaves the previous version live on a failure so nothing looked wrong outside.
#
# Nothing here talks to Sentry. The suite has no DSN and must never open a network connection
# per exception, so what is asserted is the decision -- which environments report, what a
# missing DSN does, and that a failure to report can never replace the failure being reported.
module Reported
  # Runs a block with RACK_ENV set to something, and puts it back. Every spec here turns on
  # the one switch the suite otherwise never flips.
  def in_environment(name)
    was = ENV.fetch('RACK_ENV', nil)
    ENV['RACK_ENV'] = name
    yield
  ensure
    ENV['RACK_ENV'] = was
  end
end

describe 'which environments report' do
  include Reported

  # Development and test have nowhere to report to, and a suite that opened a network
  # connection per exception is a suite nobody can run on a train.
  it 'is not on in test' do
    refute Reporting.reporting_environment?
  end

  it 'is on in production and staging' do
    in_environment('production') { assert Reporting.reporting_environment? }
    in_environment('staging') { assert Reporting.reporting_environment? }
  end

  it 'does nothing at all where there is nowhere to report to' do
    Reporting.setup!

    refute Reporting.on?
  end
end

# A missing DSN switches reporting off rather than refusing the boot, and missing means both
# ways a variable can be: unset, or set to the empty string by a file that lists the name.
#
# Deliberately unlike OAuthKeys, which raises without OAUTH_JWT_PRIVATE_KEY. An app that
# cannot sign access tokens is broken in a way that hides itself; one that cannot report its
# errors serves every request exactly as before. Refusing to boot over a missing monitoring
# credential turns it into an outage -- a worse failure than the ones it would have reported,
# landing mid-deploy.
describe 'a production boot with no DSN' do
  include Reported

  def setup_with(dsn)
    was = ENV.fetch('SENTRY_DSN', nil)
    ENV['SENTRY_DSN'] = dsn
    in_environment('production') { Reporting.setup! }
    Reporting.on?
  ensure
    ENV['SENTRY_DSN'] = was
  end

  it 'switches reporting off rather than raising' do
    assert_output(nil, /SENTRY_DSN is not set/) { refute setup_with(nil) }
  end

  # Empty counts as absent, as it does everywhere else here: dotenv sets a name listed
  # without a value to the empty string, and every fallback in this project tests for nil.
  it 'treats an empty string as absent' do
    assert_output(nil, /error reporting is off/) { refute setup_with('') }
  end

  # Said once, on stderr, where the deploy log keeps it. Silence would make an unreported
  # boot indistinguishable from a reported one.
  it 'says so where the deploy log will keep it' do
    assert_output(nil, /reporting is off for this boot/) { setup_with('') }
  end
end

describe 'reporting a failed rake task' do
  # Nothing to report to, so this is the no-op path -- which is the one every local run and
  # every CI run takes, and therefore the one that must not raise.
  it 'is silent and harmless where Sentry was never initialised' do
    refute Reporting.on?
    Reporting.capture_task_failure('db:migrate', RuntimeError.new('boom'))
  end

  # Asserted on the object rather than on a return value: what matters is that rake is left
  # exactly as it was, not what the installer answered.
  it 'installs no hook where there is nothing to report to' do
    application = FakeRake.new(%w[db:migrate])
    Reporting.install_rake_reporting!(application)

    refute_includes application.singleton_class.ancestors, Tectonic::ErrorReporting::RakeReporting
  end
end

# A stand-in for rake's own application object, answering only what the hook asks of one.
# Rake funnels everything that escapes a task through display_error_message, which is why that
# is the single place worth hooking: there is no list of tasks to keep in step, so a task
# added later is covered because every task is.
class FakeRake
  attr_reader :printed

  def initialize(tasks)
    @tasks = tasks
  end

  def top_level_tasks = @tasks

  def display_error_message(exception)
    @printed = exception.message
  end
end

# The hook. Prepended rather than redefined, so rake's own message prints exactly as it did
# and this only adds the report beside it.
describe 'the rake hook' do
  before do
    @reported = []
    reported = @reported
    Reporting.singleton_class.alias_method(:real_capture, :capture_task_failure)
    Reporting.singleton_class.define_method(:capture_task_failure) do |task, exception|
      reported << [task, exception.message]
    end
    @application = FakeRake.new(%w[db:migrate])
    @application.singleton_class.prepend(Tectonic::ErrorReporting::RakeReporting)
  end

  after do
    Reporting.singleton_class.alias_method(:capture_task_failure, :real_capture)
  end

  it 'reports the task that failed, by name' do
    @application.display_error_message(RuntimeError.new('boom'))

    assert_equal [['db:migrate', 'boom']], @reported
  end

  # The whole point of prepending. A hook that replaced the message would trade one silence
  # for another -- the deploy log would stop saying what went wrong.
  it "leaves rake's own message printing" do
    @application.display_error_message(RuntimeError.new('boom'))

    assert_equal 'boom', @application.printed
  end
end

# rake db:migrate && rake library:exercises is two processes, but a single invocation can
# carry several tasks and the tag should say which run failed rather than only the first.
describe 'a rake run carrying more than one task' do
  before do
    @reported = []
    reported = @reported
    Reporting.singleton_class.alias_method(:real_capture, :capture_task_failure)
    Reporting.singleton_class.define_method(:capture_task_failure) do |task, exception|
      reported << [task, exception.message]
    end
  end

  after do
    Reporting.singleton_class.alias_method(:capture_task_failure, :real_capture)
  end

  it 'names every task the run was asked for' do
    application = FakeRake.new(%w[db:migrate library:exercises])
    application.singleton_class.prepend(Tectonic::ErrorReporting::RakeReporting)
    application.display_error_message(RuntimeError.new('boom'))

    assert_equal [['db:migrate library:exercises', 'boom']], @reported
  end
end


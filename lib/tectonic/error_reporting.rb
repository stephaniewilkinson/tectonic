# frozen_string_literal: true

class Tectonic < Roda
  # Where errors get reported, for every process that runs this app's code. #386.
  #
  # This was inside config.ru, which the web server loads and nothing else does. That was
  # invisible rather than wrong until you notice what else runs: `render.yaml` runs
  # `rake db:migrate && rake library:exercises` on every deploy, before the new version
  # accepts a single request, and neither task had any reporting at all. A migration that
  # raises fails the deploy, prints a backtrace into Render's build log, and produces no
  # event -- and that log is not searchable across deploys and nobody is subscribed to it.
  #
  # That is exactly how a pre-deploy failure sat unnoticed for six days in September: seven
  # merged commits never reached production, GitHub Actions was green the whole time because
  # it only runs the suite, and Render leaves the previous version live on a failure so the
  # app went on serving and nothing looked wrong from outside.
  #
  # So the decision moves here and both entry points ask for it. The reasoning below was
  # written for the web boot and applies unchanged to a rake task; it simply lived in a file
  # rake never reads.
  #
  # Error reporting, in the two environments that have somewhere to report to. This was
  # Rollbar, configured from an access token written into config.ru, in a public repository,
  # where it sat readable for three years. Sentry replaces it and the DSN comes from the
  # environment, so nothing here is a credential any more and there is no longer a secret in
  # the source to rotate.
  #
  # A DSN that is missing switches reporting off rather than refusing the boot, and missing
  # means both ways a variable can be: unset, or set to the empty string by a file that lists
  # the name. That is deliberately unlike OAuthKeys, which raises without
  # OAUTH_JWT_PRIVATE_KEY. An app that cannot sign access tokens is broken in a way that hides
  # itself -- it mints an ephemeral key and every token already issued quietly stops verifying
  # -- whereas an app that cannot report its errors serves every request exactly as before.
  # Refusing to boot over a missing monitoring credential would turn it into an outage, a
  # worse failure than the ones it would have been reporting and one that lands mid-deploy, so
  # the absence is said once on stderr where the deploy log keeps it.
  module ErrorReporting
    # The environments with somewhere to report to. Development and test have none, and a
    # suite that opened a network connection per exception would be a suite nobody could run
    # on a train.
    REPORTING = %w[production staging].freeze

    module_function

    # Whether reporting is on, and by extension whether the middleware below is worth adding.
    # Answering from Sentry itself rather than from a flag of our own, so there is one truth
    # about it and `setup` can be called twice without the second call disagreeing.
    def on?
      defined?(Sentry) && Sentry.initialized?
    end

    def reporting_environment?
      REPORTING.include?(ENV.fetch('RACK_ENV', nil))
    end

    # Initialises Sentry where there is a DSN and an environment that wants one. Safe to call
    # more than once: the web boot calls it and so does the Rakefile, and a process that is
    # somehow both should not end up with two clients.
    #
    # Answers nothing. Whether reporting ended up on is `on?`, which reads it off Sentry
    # itself -- one truth about it, rather than a return value a caller could cache and a
    # second call could contradict.
    def setup!
      return unless reporting_environment?
      return if on?

      require 'sentry-ruby'
      dsn = ENV.fetch('SENTRY_DSN', nil).to_s
      return warn 'SENTRY_DSN is not set: error reporting is off for this boot.' if dsn.empty?

      initialise(dsn)
      nil
    end

    def initialise(dsn)
      Sentry.init do |config|
        config.dsn = dsn
        # Production and staging report to the same project and have to be told apart there.
        # send_default_pii stays off, its default: turning it on would ship request headers
        # and IP addresses of people's training logs to a third party, which is a decision for
        # whoever owns the Sentry project rather than a line in a config file.
        config.environment = ENV.fetch('RACK_ENV')
      end
    end

    # A path with its ids taken out, for use as a Sentry tag. #385.
    #
    # `route: request.path` is what the issue suggests and is the one thing that would make
    # the tag useless: a tag is what Sentry filters and groups on, and `/workouts/43689/session`
    # is a distinct value per session. A month of traffic would be thousands of route tags with
    # one event each, which answers no question at all -- where "every failure on the session
    # screen" is the question worth being able to ask.
    #
    # So numeric segments become `:id`. It is a small transform and it is the whole difference
    # between a tag and a copy of the URL. Nothing else is touched: the words in a path are the
    # app's own vocabulary, not anybody's data.
    # The root is its own case, because String#split drops the trailing empty field: "/"
    # splits to nothing at all and would join back to an empty tag, which is worse than no
    # tag -- Sentry would group the busiest page in the app under a blank.
    def route_tag(path)
      segments = path.to_s.split('/')
      return '/' if segments.empty?

      segments.map { |segment| segment.match?(/\A\d+\z/) ? ':id' : segment }.join('/')
    end

    # Who and where, attached to whatever this request goes on to report. #385.
    #
    # Nothing called `Sentry.set_user`, so "users affected" read zero on every issue and an
    # error seen 400 times was indistinguishable from one seen 400 times by a single lifter
    # with a stuck client. The id alone is right: send_default_pii is off on purpose and an
    # email address would walk that back from a different file.
    #
    # The surface tag is the division this app most needs and could not make: the web app and
    # the MCP endpoint share a Sentry project through the same URLMap, deliberately, so
    # without it a tool failure and a page failure are the same haystack.
    #
    # Rescued, like every other reporting hook here: enrichment that raised would turn a
    # request that was going to work into a 500.
    def describe_request(path:, account_id: nil)
      return unless on?

      Sentry.set_tags(surface: 'web', route: route_tag(path))
      Sentry.set_user(id: account_id) if account_id
    rescue StandardError => e
      warn "Could not describe the request to Sentry: #{e.message}"
    end

    # Structured detail for the operation about to run, so a failure inside it arrives with
    # the thing it was working on rather than a bare backtrace. #385.
    #
    # A context rather than a tag, because these are ids and would be exactly the high
    # cardinality `route_tag` exists to avoid -- and because a context is the right shape for
    # "what was this doing", which is a bag of fields rather than something to group on.
    def note(name, fields)
      return unless on?

      Sentry.set_context(name, fields)
    rescue StandardError => e
      warn "Could not note #{name} to Sentry: #{e.message}"
    end

    # A rake task that failed, reported before the process exits.
    #
    # **`Sentry.close` matters and is easy to miss.** The Ruby SDK sends events on a
    # background thread, and a rake task that raises and exits immediately can terminate
    # before the event leaves the process -- so a task that reports and then dies reports
    # nothing. Web requests never hit this because the process outlives them. Closing flushes
    # the queue while there is still a process to flush it from.
    #
    # The task name goes on as a tag rather than into the message, because a tag is what
    # Sentry filters and groups on: "every failure of library:exercises" is a question worth
    # being able to ask, and it is not answerable from a string inside a title.
    #
    # **Nothing here may raise.** A broken DSN, a network that is down, a Sentry outage --
    # any of them escaping would replace the failure being reported with a failure to report
    # it, and the operator needs the first one. Reporting is an addition to a failure, never
    # a substitute for it, and never a cause of a different one.
    def capture_task_failure(task_name, exception)
      return unless on?

      Sentry.set_tags(rake_task: task_name, surface: 'rake')
      Sentry.capture_exception(exception)
      Sentry.close
    rescue StandardError => e
      warn "Could not report #{task_name} failure to Sentry: #{e.message}"
    end

    # Reports every rake task that fails, by hooking the one place rake funnels them through.
    #
    # The alternative was a `reported('db:migrate') { ... }` wrapper around each task body,
    # which is what #386 sketches. This does the same job without the failure mode that
    # version carries: a task added later and not wrapped reports nothing, silently, which is
    # precisely the shape of bug this issue exists to fix. There is no list to keep in step
    # here -- `backup:drill`, `exercises:merge` and `oauth:prune` are covered because every
    # task is.
    #
    # `display_error_message` is where `standard_exception_handling` sends anything that
    # escapes a task, so it runs after rake has decided the run failed and before it exits.
    # super still prints what it always printed; this only adds the report.
    # The application is resolved after the guard rather than in a default argument, because a
    # default is evaluated before the body: asking Rake for its application on a boot with
    # nothing to report to is a call into a constant that may not be loaded, to answer a
    # question that was already no.
    def install_rake_reporting!(application = nil)
      return unless on?

      (application || Rake.application).singleton_class.prepend(RakeReporting)
      nil
    end

    # Prepended rather than redefined, so rake's own message still prints exactly as it did.
    module RakeReporting
      def display_error_message(exception)
        ErrorReporting.capture_task_failure(top_level_tasks.join(' '), exception)
        super
      end
    end
  end
end


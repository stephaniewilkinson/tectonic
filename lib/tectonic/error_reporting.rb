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
        # Which deploy an event came from. #387.
        #
        # Without it every event in the project belongs to the same unnamed version, and the
        # thing that costs most is regression detection: Sentry reopens a resolved issue when
        # it reappears in a *later* release, and with no release there is no later -- so
        # resolving is permanent until somebody notices by hand, and a bug that comes back
        # after a fix comes back into the same issue with nothing announcing it.
        #
        # It is worth more here than in most apps because of render.yaml's preDeployCommand.
        # Migrations run on deploy, so a whole class of production error is *caused* by a
        # specific deploy -- a column that changed shape, a backfill that half-ran -- and
        # those are exactly the errors where "which release did this start in" is the entire
        # diagnosis.
        #
        # RENDER_GIT_COMMIT is exported by the host, so this is the deployed SHA rather than
        # anything this repository has to be told. Nil locally and in CI, which is today's
        # behaviour exactly.
        config.release = ENV.fetch('RENDER_GIT_COMMIT', nil)
        # How long things take, as against what broke. #388.
        #
        # Sentry has two halves and only the error half was on. That left three numbers in
        # this system resting on reasoning nobody had checked against a measurement: the
        # twenty-second request timeout in config.ru, whose comment argues that nothing here
        # is "within an order of magnitude" of it; the connection pool in config/puma.rb,
        # sized from arithmetic that admits the database plan's ceiling "is not something
        # this repo knows"; and the MCP endpoint, which says outright that nobody has watched
        # its request pattern because an LLM drives it.
        #
        # All three are claims about a distribution nobody has. Tracing is what turns them
        # into a p95 that can be watched crossing a line -- and the first of them only ever
        # gets worse, silently, because Volume.weekly aggregates an account's *whole history*
        # and that quantity only goes up.
        config.traces_sample_rate = traces_sample_rate
        # Query spans, which are the layer that actually answers "which part of the volume
        # page is slow". Not on by default -- DEFAULT_PATCHES is redis, puma and http -- and
        # guarded, because requiring it in a process with no Sequel raises.
        config.enabled_patches += [:sequel] if load_query_instrumentation?
        # And the reason that guard is not optional: every span description is scrubbed on the
        # way out, because Sequel writes literals into its SQL. See scrub_sql.
        config.before_send_transaction = ->(event, _hint) { scrub_spans(event) }
      end
      instrument_open_databases!
    end

    # How much of the traffic is timed, as a fraction. #388.
    #
    # **Everything, by default, and that is the opposite of what #388 first suggested.** That
    # issue proposed 10% as "a small number of transactions and enough for percentiles within
    # a week", which is the right advice for a busy app. This one had a single active account
    # and 123 sets logged in thirty days when the number was checked, so a tenth of that is
    # not a sample, it is a rounding error -- months before the slowest 5% of anything could
    # be said with a straight face. The only argument against recording everything is cost,
    # and there is barely any traffic here to cost anything.
    #
    # **Read from the environment, which is the part that matters most.** #388 carries a
    # caveat worth respecting: a transaction holds a reference to the Rack env for its
    # lifetime, and a sibling app on the same kind of small Render instance saw that as RSS
    # growth across a day. Turning the rate down therefore has to be something that can be
    # done *now*, from a dashboard, by somebody watching a memory graph climb -- not a commit,
    # a review and a deploy. Setting SENTRY_TRACES_SAMPLE_RATE to 0 switches tracing off
    # entirely without touching the error reporting beside it.
    #
    # Clamped rather than trusted: a typo that set this to 100 meaning "100%" would be read by
    # the SDK as an invalid rate and silently disable tracing, which is the failure that looks
    # like it worked.
    TRACES_SAMPLE_RATE = 'SENTRY_TRACES_SAMPLE_RATE'
    DEFAULT_TRACES_SAMPLE_RATE = 1.0

    def traces_sample_rate
      ENV.fetch(TRACES_SAMPLE_RATE, DEFAULT_TRACES_SAMPLE_RATE).to_f.clamp(0.0, 1.0)
    end

    # Whether to instrument database queries, which needs the integration loaded first.
    #
    # Guarded on Sequel already being there rather than requiring it. `sentry/sequel` calls
    # `Sequel::Database.register_extension` at load time, so requiring it in a process that
    # has not loaded Sequel raises NameError -- and the Rakefile calls `setup!` at line 24,
    # long before `migrator_db` requires the database at line 75. Unguarded, this would break
    # every rake task in the app, including the two that run on every deploy.
    #
    # That is the third time this shape has bitten: the tzinfo gem reached the load path only
    # through a development dependency, and Clock reached app.rb only through a file that was
    # deleted. A require that works because something else happened to load first is a require
    # that will stop working.
    #
    # False in a rake process is also the right answer on its own terms. Query spans hang off
    # a request transaction, and a rake task has none for them to hang from.
    def load_query_instrumentation?
      return false unless defined?(::Sequel::Database)

      require 'sentry/sequel'
      true
    rescue LoadError
      false
    end

    # The database this app is already connected to, instrumented by hand.
    #
    # **Without this the whole thing is configured and does nothing**, which is worth spelling
    # out because everything else says it is working. `enabled_patches` includes `:sequel`, the
    # integration is loaded, the patch runs -- and no query span is ever produced.
    #
    # The gem's patch is `Sequel::Database.extension(:sentry)`, and that class-level call loads
    # an extension into *future* Database objects only. This app's `DB` is created at require
    # time in lib/tectonic/db.rb, which app.rb loads, which config.ru loads before it calls
    # `setup!` -- so by the time Sentry initialises, the one database that matters already
    # exists and the patch sails straight past it. Checked rather than assumed: extending the
    # class leaves `DB.singleton_class.ancestors` without the module, and extending the
    # instance puts it there.
    #
    # `Sequel::DATABASES` rather than this app's own `DB` constant, so this file keeps knowing
    # nothing about the schema it reports on -- and so a second connection, if one ever exists,
    # is covered by the same line.
    #
    # The class-level patch above is left on anyway. It is the right hook for anything
    # connected after this point, and the two together mean the instrumentation does not
    # depend on load order in either direction.
    def instrument_open_databases!
      return unless defined?(::Sequel::DATABASES)

      ::Sequel::DATABASES.each { |db| db.extension(:sentry) }
      nil
    rescue StandardError => e
      warn "Could not instrument database queries for Sentry: #{e.message}"
      nil
    end

    # Every span description on its way out, with the data taken out of it. #388.
    #
    # **This is the reason the Sequel integration is safe to have on at all.** #388 recommends
    # it in one line -- "worth enabling alongside" -- and enabling it as written would have
    # shipped people's email addresses to a third party.
    #
    # Sequel does not use bound parameters by default; it builds SQL with the literals
    # inlined. So the description the integration attaches to a query span is the whole
    # statement, values and all:
    #
    #   SELECT * FROM "accounts" WHERE ("email" = 'someone@example.com')
    #
    # That is checked rather than assumed -- it is the literal output of Sequel for that
    # query. And it would walk back, from a monitoring config file, a decision this app has
    # made carefully and in several places: send_default_pii is deliberately off, the MCP
    # audit hook sends argument *keys* and never values, and describe_request sends an account
    # id rather than an email. A query span carrying the email in plain text undoes all three.
    #
    # **It also makes the traces better, not just safer.** Sentry groups spans by description,
    # so `account_id = 407` and `account_id = 408` are two different spans of one query. With
    # the literals out they are one, which is the aggregate the whole feature is for.
    #
    # Applied to every `db.` span rather than to Sequel's alone, so a database integration
    # added later is covered by something that already exists rather than by somebody
    # remembering. HTTP spans are left alone on purpose: their description is a method and a
    # URL that the SDK already sanitises, and blanking the numbers in one would destroy the
    # part worth reading.
    #
    # The spans arrive as plain hashes at this point rather than as Span objects, which is
    # checked rather than assumed -- `before_send_transaction` runs after the event has been
    # built and its spans flattened.
    def scrub_spans(event)
      event.spans&.each do |span|
        span[:description] = scrub_sql(span[:description]) if span[:op].to_s.start_with?('db.')
      end
      event
    rescue StandardError => e
      # A scrubber that raised would drop the transaction, and a dropped transaction is the
      # quiet half of this failing: no error, no event, and a performance page that is simply
      # emptier than it should be. Better to lose the scrub than the trace -- except that
      # losing the scrub is the one thing that is not acceptable here, so the event goes too.
      warn "Could not scrub a span description: #{e.message}"
      nil
    end

    # A SQL statement with its values replaced. Quoted strings first, then bare numbers.
    #
    # Single quotes are unambiguous in Sequel's output: it double-quotes identifiers, so
    # anything in single quotes is a literal. `(?:[^']|\'\')*` keeps a doubled quote -- SQL's
    # own escape for a quote inside a string -- from ending the match early and leaving the
    # tail of somebody's text behind.
    #
    # Numbers are taken second and only where they stand alone. The lookarounds keep the
    # digits inside an identifier ("account_plates" has none, but a future table may) and the
    # index of a bound parameter ($1) from being blanked, which would turn a readable
    # statement into a puzzle for no gain.
    def scrub_sql(sql)
      return sql if sql.nil?

      sql.gsub(/'(?:[^']|'')*'/, "'?'")
         .gsub(/(?<![\w."$])-?\d+(?:\.\d+)?(?![\w"])/, '?')
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


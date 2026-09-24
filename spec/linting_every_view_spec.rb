# frozen_string_literal: true

require_relative 'spec_helper'

# #587. The view linter used to be invoked as `erb_lint views/*/* views/*`, a glob the shell
# expanded, and that spelling had three problems in one line. It reached exactly one
# directory deep, so a template at `views/a/b/c.erb` would have gone unlinted with nothing
# saying so. It could not be run at all in several sandboxed environments, which cost four
# contributors an afternoon between them and produced three different local workarounds. And
# because the expansion happened in the shell rather than anywhere readable, "every view" was
# not a definition anybody could check or correct -- it was a pattern you had to simulate in
# your head.
#
# `rake lint:views` computes the list in Ruby, from a recursive glob, and CI runs that task
# rather than a glob of its own. What this file defends is the sameness: the command in the
# README, the command in the workflow and the command somebody types are one command, so
# "green locally" and "green in CI" mean the same thing. A workflow that quietly went back to
# a glob would still be green, and would still be linting a different set of files than
# anybody local.
module ViewLint
  ROOT = File.expand_path('..', __dir__)

  # `include?` rather than `assert_includes`, because the haystacks here are a whole README
  # and a whole workflow and minitest prints the haystack.
  def self.mentions?(path, command) = File.read(File.join(ROOT, path)).include?(command)

  TASK = 'rake lint:views'
  # The old spelling, kept as a literal to be refused rather than described in prose. It is
  # the thing that must not come back, and it comes back by being pasted.
  SHELL_GLOB = 'erb_lint views/*/* views/*'
end

describe 'the view linter' do
  it 'is one rake task that CI runs' do
    assert ViewLint.mentions?('.github/workflows/ruby.yml', ViewLint::TASK),
           "the workflow does not run `#{ViewLint::TASK}`, so CI is linting views its own way again"
  end

  it 'is the same task the README tells a contributor to run' do
    assert ViewLint.mentions?('README.md', ViewLint::TASK),
           "the README does not name `#{ViewLint::TASK}`, so a contributor will invent an invocation"
  end

  # Both files, because the README is where the workaround would be copied from and the
  # workflow is where it would stop mattering that it does not run anywhere else.
  it 'is not a shell glob in either place' do
    refute ViewLint.mentions?('.github/workflows/ruby.yml', ViewLint::SHELL_GLOB), "the workflow is back on #587's glob"
    refute ViewLint.mentions?('README.md', ViewLint::SHELL_GLOB), "the README is back on #587's glob"
  end

  # What the task lints is `Dir['views/**/*.erb']`, and a spec asserting that a recursive
  # glob is recursive would only restate the Rakefile. What is worth writing down is that
  # there is something for it to find: an empty list is how this task would pass forever if
  # views ever moved, and `sh` with no files is erb_lint linting nothing and exiting zero.
  # The task aborts on that, and this is the check that the directory it aborts about is
  # the directory the templates are actually in.
  it 'has templates to lint, at more than one depth' do
    inside_views = File.join(ViewLint::ROOT, 'views/')
    templates = Dir[File.join(inside_views, '**', '*.erb')].map { |path| path.delete_prefix(inside_views) }

    refute_empty templates
    refute_empty templates.select { |path| path.include?('/') },
                 'every view is top level now, so nothing here is checking the recursion'
  end
end


# frozen_string_literal: true

require_relative 'spec_helper'

# The rules in DESIGN.md, held against the templates. Read from the markup rather than the
# rendered pages for the reason named_styles_spec gives: what is guarded is where a decision
# is written, and a heading that spells its own classes out renders identically today and is
# the one that drifts later. Twenty heading class lists and seven page widths are what the
# app had before these rules, and nothing ever failed on the way there.
module OneDesign
  def templates = Dir[File.expand_path('../views/**/*.erb', __dir__)]

  def tags(name)
    templates.flat_map do |path|
      File.read(path).scan(/<#{name}\b[^>]*class="([^"]*)"/).flatten.map { |classes| [path, classes] }
    end
  end
end

describe 'a heading' do
  include OneDesign

  # serif is the display surface DESIGN.md keeps, and a class list with ERB in it is built
  # by something that is not a heading rule (the lift names on the session screen).
  it 'takes its look from heading_style unless it is a display surface' do
    %w[h1 h2].each do |name|
      tags(name).each do |path, classes|
        next if classes.split.include?('serif') || classes.include?('<%')

        flunk "#{File.basename(path)}: <#{name} class=\"#{classes}\"> spells its own style out"
      end
    end
  end
end

describe 'a page width' do
  include OneDesign

  # The widths DESIGN.md retired. The form pages' sm:max-w-sm and the session screen's
  # max-w-md column are the two that stay written out, and so are pop-overs and prose caps
  # inside a page, which are not page widths -- so this looks only at the widths no page
  # should use any more.
  it 'is one of the three' do
    templates.each do |path|
      File.read(path).scan(/class="([^"]*)"/).flatten.each do |classes|
        next unless classes.split.include?('mx-auto')

        retired = classes.split & %w[max-w-3xl max-w-4xl max-w-xl]
        assert_empty retired, "#{File.basename(path)} centres a page at #{retired.join}"
      end
    end
  end
end


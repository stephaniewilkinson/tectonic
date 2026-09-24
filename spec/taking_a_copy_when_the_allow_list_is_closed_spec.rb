# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/tectonic/backup/render_export'

# No database and no spec_helper, on purpose: this is the one piece of the app that has to work
# when the database is the thing that is broken, so its specs should not need one either. Nor
# is there a network here.
#
# What can be specced is every decision the backup makes -- which export is ours, what a copy
# is called, how old the newest one is, which ones retention may delete, where a dump is
# allowed to live, and what counts as a dump at all -- and that is the whole of the judgement.
# The HTTP itself is the part a spec cannot usefully cover: without a live Render account and a
# real export, which #588 says not to take, the only thing left to write is a mock of Render's
# API, and a spec against a mock asserts that this file agrees with itself. That half was
# proved by running the download and restore path against a dump of a database made for the
# purpose; BACKUPS.md records exactly what was run.
#
# The two names are reached through a module rather than through constants of their own,
# because rake loads every spec file into one process and a constant called Copies in this file
# is a constant called Copies in all of them.
module TakingACopy
  def backup = TectonicBackup

  def export = TectonicBackup::RenderExport

  def named(*dates) = dates.map { |date| "tectonic-#{date}T09-00Z.dir.tar.gz" }
end

describe 'finding the export Render has just taken' do
  include TakingACopy

  let(:already_there) { { 'id' => 'dpe-old', 'createdAt' => '2026-09-01T09:00:00Z', 'url' => 'https://x/old' } }

  it 'ignores the exports that were already in the list' do
    fresh = { 'id' => 'dpe-new', 'createdAt' => '2026-09-24T09:00:00Z' }
    assert_equal fresh, export.arrived([already_there, fresh], ['dpe-old'])
  end

  it 'has nothing to report while Render is still working' do
    assert_nil export.arrived([already_there], ['dpe-old'])
  end

  it 'takes the newest by Render timestamp rather than by position in the list' do
    older = { 'id' => 'a', 'createdAt' => '2026-09-24T09:00:00Z' }
    newer = { 'id' => 'b', 'createdAt' => '2026-09-24T10:00:00Z' }
    assert_equal newer, export.arrived([newer, older], [])
  end

  # The failure this prevents is downloading nothing and calling it a backup: an export appears
  # in the list before Render has finished writing it, and only grows a url once it is a file.
  it 'refuses to call an export ready until it has a download url' do
    assert_nil export.ready({ 'id' => 'dpe-new', 'createdAt' => '2026-09-24T09:00:00Z' })
    assert_nil export.ready({ 'url' => '' })
    assert_equal 'https://x/new', export.ready({ 'url' => 'https://x/new' })
  end
end

describe 'naming a copy' do
  include TakingACopy

  it 'names it for the moment Render took the dump, in UTC' do
    assert_equal 'tectonic-2026-09-24T09-14Z.dir.tar.gz', backup.filename({ 'createdAt' => '2026-09-24T09:14:33Z' })
  end

  # A name is not worth failing a finished download over, but a wrong name would be, so this
  # falls back to the clock rather than to a guess at what Render meant.
  it 'falls back to the clock when Render sends a timestamp it cannot read' do
    now = Time.utc(2026, 9, 24, 11, 30)
    assert_equal 'tectonic-2026-09-24T11-30Z.dir.tar.gz', backup.filename({ 'createdAt' => 'nonsense' }, now: now)
  end

  # filename and taken_at are inverses, and every judgement about age depends on that.
  it 'can read back the moment out of the name it wrote' do
    name = backup.filename({ 'createdAt' => '2026-09-24T09:14:33Z' })
    assert_equal Time.utc(2026, 9, 24, 9, 14), backup.taken_at(name)
  end

  it 'refuses to guess an age from a file it did not name' do
    assert_raises(TectonicBackup::Refused) { backup.taken_at('yesterday.dump') }
  end
end

describe 'noticing that no copy has been taken' do
  include TakingACopy

  let(:now) { Time.utc(2026, 9, 24) }

  # The whole point. A backup that stops being taken says nothing on its own, so the alarm has
  # to come from asking -- and asking is only worth anything if it can answer badly.
  it 'calls an empty folder stale rather than fine' do
    assert backup.stale?([], now: now)
  end

  it 'is content while the newest copy is inside the window' do
    refute backup.stale?(named('2026-09-20'), now: now)
  end

  it 'raises the alarm once the newest copy is older than Render keeps its own' do
    refute backup.stale?(named('2026-09-16'), now: now)
    assert backup.stale?(named('2026-09-15'), now: now)
  end

  it 'judges by the newest copy, not by how many there are' do
    assert backup.stale?(named('2026-09-01', '2026-09-02', '2026-09-03'), now: now)
  end
end

describe 'deleting copies that have outlived their retention' do
  include TakingACopy

  let(:now) { Time.utc(2026, 9, 24) }

  it 'leaves a copy taken inside the window alone' do
    assert_empty backup.expired(named('2026-09-20', '2026-09-13', '2026-09-06', '2026-09-01'), now: now)
  end

  it 'deletes one taken before the window' do
    assert_equal named('2026-07-01'),
                 backup.expired(named('2026-09-20', '2026-09-13', '2026-09-06', '2026-07-01'), now: now)
  end

  # The case that matters more than the policy: nobody has run this since July, so every copy is
  # expired, and a retention pass obeying the policy literally would leave no backups at all --
  # in the exact circumstance where they are the only backups there are.
  it 'never deletes the newest few, however old every copy is' do
    assert_empty backup.expired(named('2026-07-03', '2026-07-02', '2026-07-01'), now: now)
  end

  it 'keeps the newest few and deletes the rest of an old pile' do
    pile = named('2026-07-05', '2026-07-04', '2026-07-03', '2026-07-02', '2026-07-01')
    assert_equal named('2026-07-02', '2026-07-01').sort, backup.expired(pile, now: now).sort
  end
end

describe 'where a dump is allowed to live' do
  include TakingACopy

  # A dump is every account's training history and every email address in the database, and this
  # repository is public. A file committed to git history is not deleted by deleting it.
  it 'refuses anywhere inside a git repository, however far down' do
    assert backup.inside_a_repository?(File.join(__dir__, '..'))
    assert backup.inside_a_repository?(File.join(__dir__, '..', 'assets', 'css'))
  end

  it 'allows a folder that no repository contains' do
    Dir.mktmpdir { |directory| refute backup.inside_a_repository?(directory) }
  end
end

describe 'deciding whether what came back is a dump' do
  include TakingACopy

  it 'refuses a download that is not gzipped at all' do
    Dir.mktmpdir do |directory|
      not_a_dump = File.join(directory, 'tectonic-2026-09-24T09-00Z.dir.tar.gz')
      File.write(not_a_dump, '<html>403 Forbidden</html>')
      refused = assert_raises(TectonicBackup::Refused) { backup.unpack(not_a_dump, into: directory) }
      assert_match(/not gzipped/, refused.message)
    end
  end

  # The most convincing way to be wrong, and the reason the restore drill checks for it too: a
  # schema-only dump has every table, restores without an error, and gives back an app in which
  # every account has vanished. Here it is a table of contents with nothing in it.
  it 'refuses a table of contents that carries no rows' do
    toc = %w[a b].map { |id| "#{id}; 2 TABLE public thing tectonic\n" }
    refused = assert_raises(TectonicBackup::Refused) { backup.tally(toc, 'somewhere') }
    assert_match(/schema and no table data/, refused.message)
  end

  # A TABLE DATA line contains " TABLE " too, which counted every table twice and reported a
  # real 23-table dump as 46 until this said otherwise.
  it 'counts a table and its rows as one table with rows, not as two tables' do
    toc = ["1; 2 TABLE public sets tectonic\n", "3; 4 TABLE DATA public sets tectonic\n"]
    assert_equal({ entries: 2, tables: 1, data: 1 }, backup.tally(toc, 'somewhere'))
  end
end

describe 'reading the Render API key' do
  include TakingACopy

  # The same rule as the Fathom token in AGENTS.md: a bare value in a file outside every repo.
  it 'reads it from a file as a bare value, trailing newline and all' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'api-key')
      File.write(path, "rnd_notarealkey\n")
      assert_equal 'rnd_notarealkey', export.credential(env: {}, file: path)
    end
  end

  it 'prefers the environment when something has set it' do
    assert_equal 'rnd_fromtheenvironment',
                 export.credential(env: { 'RENDER_API_KEY' => ' rnd_fromtheenvironment ' }, file: '/nowhere')
  end

  # Refusing is the behaviour worth having: the alternative is a run that reaches Render
  # unauthorised and reports something about HTTP 401 rather than about what is actually wrong.
  it 'refuses, with the instructions, when there is no key anywhere' do
    refused = assert_raises(TectonicBackup::Refused) { export.credential(env: {}, file: '/nowhere/api-key') }
    assert_match(/no Render API key, so no backup was taken/, refused.message)
    assert_match(%r{dashboard\.render\.com/settings}, refused.message)
  end

  it 'refuses a key file somebody created and never filled in' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'api-key')
      File.write(path, "\n")
      assert_raises(TectonicBackup::Refused) { export.credential(env: {}, file: path) }
    end
  end
end


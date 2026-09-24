# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'time'

# The copies in hand: what they are called, how old they are, how long they are kept, where
# they are allowed to live, and whether what came back is a dump at all.
#
# This half knows nothing about Render. Its sibling, TectonicBackup::RenderExport, is the half
# that asks Render for an export over an API the database's allow list does not touch;
# everything here would be the same if the file arrived by some other road, which is most of
# the reason the seam is here. The other reason is that all the judgement is on this side --
# which copies have outlived their welcome, whether the newest one is old enough to be an
# alarm, whether a downloaded tarball is a backup or an error page with a .tar.gz on the end
# -- and judgement is the part worth having specs for, which means the part that has to be
# reachable without a network, a Render account or a credential.
#
# A namespace of its own rather than `Tectonic::Backup`, which is where a file in lib/tectonic
# belongs and which this cannot be: `Tectonic` is not a module here, it is `class Tectonic <
# Roda`, so every one of its fifty-odd files begins by requiring roda. Reopening it would put a
# gem between this laptop and its backups -- the one dependency this file is written to do
# without, since the day it is needed is a day when things are already broken. Loaded into the
# suite alongside the app it would also be a TypeError, which is how this was found.
#
# #588, and BACKUPS.md for the argument.
module TectonicBackup
  # Raised for every refusal, in both halves. There is one class because every refusal means
  # the same thing to the person running this: you do not have the backup you think you
  # have. `bin/backup` turns it into a sentence and a non-zero exit, and nothing anywhere
  # catches it to carry on regardless -- carrying on regardless is the failure this whole
  # thing exists to prevent.
  class Refused < StandardError; end

  # Outside every repository on purpose. See `inside_a_repository?`.
  DEFAULT_DIRECTORY = '~/backups/tectonic'
  # How long a copy is kept. A dump is training logs and email addresses, and
  # `legal/privacy.md` promises that deleting an account takes the training data with it --
  # which a copy sitting in a folder quietly makes untrue until that copy is gone. Thirty
  # days is the shortest window that still covers the failure BACKUPS.md was written for: a
  # billing lapse suspends the instance, Render's own recovery data goes with it, and three
  # days of point-in-time recovery is not long enough to notice a card that expired. Longer
  # buys nothing except a longer period in which a deleted account is not really deleted.
  RETENTION_DAYS = 30
  # ...except that retention must never be the thing that leaves you with nothing. If nobody
  # has run this for two months then every copy is expired, and deleting them all would be
  # obedient and catastrophic. The newest few survive any policy.
  KEEP_AT_LEAST = 3
  # When the newest copy stops being a note and becomes an alarm. Render keeps its own
  # exports for seven days regardless of plan, so past that there is no twin left on Render
  # either: the only copy of anything since then is the live database.
  STALE_AFTER_DAYS = 8
  PREFIX = 'tectonic-'
  # Render's export is a directory-format dump inside a gzipped tar, and the name says so.
  # The extension is what the restore drill dispatches on -- `load_dump` sends anything not
  # ending in .sql to pg_restore -- and handing pg_restore a tarball fails loudly, which is
  # the acceptable kind of wrong. It is still worth not doing by accident.
  SUFFIX = '.dir.tar.gz'

  # Named for the moment Render took the dump, in UTC, in an order that sorts. On a run
  # somebody does by hand the filename is the whole health check: the newest name is a date,
  # and a date you have to squint at is a date you will not check.
  def self.filename(export, now: Time.now)
    taken = begin
      Time.parse(export['createdAt'].to_s)
    rescue ArgumentError
      now
    end
    "#{PREFIX}#{taken.utc.strftime('%Y-%m-%dT%H-%MZ')}#{SUFFIX}"
  end

  # When a copy was taken, read out of its name rather than off its mtime, and the inverse
  # of `filename` above -- which is why the two live together. Copying a file, restoring a
  # folder from a laptop backup or syncing it to a second disk all rewrite mtime and change
  # nothing about what is inside; a staleness check that can be reset by touching a file
  # will one day be reset by touching a file.
  def self.taken_at(path)
    stamp = File.basename(path).delete_prefix(PREFIX).delete_suffix(SUFFIX)
    written = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})Z\z/.match(stamp)
    raise Refused, "FAILED: #{path} is not named like a copy this script took." unless written

    Time.utc(*written.captures)
  end

  # The copies already in hand. Only files this script itself named: a folder somebody keeps
  # backups in may hold other things, and nothing here should ever consider deleting a file
  # it did not write. Dir.glob sorts, and these names sort chronologically, so `.max` is the
  # newest throughout.
  def self.copies(directory)
    Dir.glob(File.join(File.expand_path(directory), "#{PREFIX}*#{SUFFIX}"))
  end

  def self.age_in_days(path, now: Time.now)
    (now - taken_at(path)) / 86_400.0
  end

  # The alarm. A backup that stops being taken reports nothing, by definition -- BACKUPS.md
  # says a backup nobody has restored is a belief rather than a backup, and the same is true
  # of one nobody has taken. Nothing here can make a run happen. What it can do is turn a
  # missing run into a sentence and an exit code, which is what `bin/backup --check` is, and
  # which is the seam anything scheduled would later hang an alert on.
  def self.stale?(copies, now: Time.now, after: STALE_AFTER_DAYS)
    newest = copies.max
    return true if newest.nil?

    age_in_days(newest, now: now) > after
  end

  # Which copies have outlived the retention window -- never the newest `keep` of them,
  # whatever their age. See KEEP_AT_LEAST.
  def self.expired(copies, now: Time.now, retention: RETENTION_DAYS, keep: KEEP_AT_LEAST)
    copies.sort.reverse.drop(keep).select { |copy| age_in_days(copy, now: now) > retention }
  end

  # Refuses to keep dumps anywhere inside a git repository, checked by walking up rather than
  # by looking at the one directory: `~/repos/tectonic/backups` is inside a repository and
  # does not look it. A dump is every account's training history and every email address in
  # the database, this repository is public, and a file committed to git history is not
  # deleted by deleting it -- which would turn "delete your account and your training data
  # goes with it" into a sentence this project could not honour. A `.git` that is a file
  # rather than a directory is a worktree, and counts.
  def self.inside_a_repository?(directory)
    path = File.expand_path(directory)
    until path == File.dirname(path)
      return true if File.exist?(File.join(path, '.git'))

      path = File.dirname(path)
    end
    false
  end

  # Two shapes of wrong that a download can be while still being a file: a gzip that is
  # really an error page, and a tarball that unpacks into something pg_restore will not read.
  # Both are checked when the copy is taken rather than discovered during a restore, because
  # the point of taking a backup today is to find out today.
  def self.unpack(tarball, into:)
    raise Refused, "FAILED: #{tarball} is not gzipped -- Render sent something else." unless gzip?(tarball)

    FileUtils.mkdir_p(into)
    _out, err, status = Open3.capture3('tar', 'xzf', tarball, '-C', into)
    raise Refused, "FAILED: could not untar #{tarball} -- #{err.strip}" unless status.success?

    dump_directory(into, tarball)
  end

  # A directory-format dump is a directory with a toc.dat in it, so that is what is looked
  # for rather than trusting whatever name Render gave the folder inside the tarball.
  def self.dump_directory(workspace, tarball)
    found = Dir.children(workspace).map { |child| File.join(workspace, child) }
               .find { |child| File.directory?(child) && File.exist?(File.join(child, 'toc.dat')) }
    raise Refused, "FAILED: #{tarball} does not contain a directory-format dump." unless found

    found
  end

  def self.gzip?(path)
    File.binread(path, 2) == "\x1F\x8B".b
  end

  # What is actually in the dump, asked of pg_restore rather than assumed. This is the cheap
  # half of the restore drill: it reads the table of contents without needing a database, so
  # it can run on every copy, every time, in under a second. The expensive half -- restore it
  # and ask the restored copy questions -- is `rake backup:drill`, and this does not replace
  # it, which is why a successful run prints the drill command rather than a clean bill.
  def self.contents(directory)
    out, err, status = Open3.capture3('pg_restore', '--list', directory)
    raise Refused, "FAILED: pg_restore cannot read the dump -- #{err.strip}" unless status.success?

    tally(out.lines.reject { |line| line.start_with?(';') }, directory)
  end

  # The number that matters is TABLE DATA. A schema-only dump has every table and no rows: it
  # restores without an error and gives back an app where every account has vanished, which
  # BACKUPS.md already calls the most convincing way to be wrong. Here that is a file with a
  # perfectly good table of contents and nothing in it, so it is refused by name.
  # A TABLE DATA line also contains " TABLE ", which counted every table twice and reported a
  # 23-table dump as 46 until a real dump was put through it. Two numbers that should be equal
  # and were not is the sort of thing a person skims past, so they are told apart here.
  def self.tally(entries, directory)
    data = entries.count { |line| line.include?(' TABLE DATA ') }
    raise Refused, no_rows(directory) if data.zero?

    tables = entries.count { |line| line.include?(' TABLE ') && !line.include?(' TABLE DATA ') }
    { entries: entries.length, tables: tables, data: data }
  end

  def self.no_rows(directory)
    "FAILED: #{directory} has a schema and no table data. That is what pg_dump -s gives, " \
      'it restores without an error, and it brings back an app with no accounts in it.'
  end
end


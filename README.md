Aptlier
=======

Aptlier is a tool to manage [aptly](https://www.aptly.info/)
repositories of Debian/Ubuntu packages. Its main goal is to publish
a single repository that merges multiple mirrors and repositories with
local packages.

It was written with one particular usage pattern in mind: all servers
of the project should have only the Debian/Ubuntu mirror and a
centrally managed repo in its `sources.list` file. All third-party
software should be available in a project-local repository that
mirrors all needed external repositories and PPAs. This makes
upgrades and audits much more manageable than adding multiple software
sources and signing keys to each of the server.

This is very early stage software. It might be incomplete, and it
might change in an incompatible way.

Installation
------------

Aptlier is written in [Ruby](https://www.ruby-lang.org/), and can be
installed as a gem.  There is no versioned gem uploaded to
rubygems.org yet, though. Easiest way to install is to use
[bundler](https://bundler.io/) with a `Gemfile` like this:

    source 'https://rubygems.org'
    gem 'aptlier', git: 'https://github.com/3ofcoins/aptlier.git'

You can also use aptlier in-place by running `bundle install --path=.bundle`
and run it as `bundle exec aptlier`, or build a gem locally.

Usage
-----

 - `aptlier init` initializes a new repo in current directory (which
   should be empty). It creates an aptly repository, initial aptly
   config, and a gnupg config directory (**NOTE:** aptly supports only
   gnupg version 1). After initialization, both configs can be freely
   edited.
 - `aptlier aptly ...` runs aptly command for current repo
 - `aptlier gpg ...` runs gpg command for current repo
 - `aptlier add_key KEY [GPG_OPTIONS]` adds a gnupg key that can sign
   source repositories. A key can be specified as:
   - Email address that is passed to `gpg --search-keys`
   - Key ID in `0xAAAAAAAA` format that is passed to `gpg --recv-keys`
   - Path to file that contains a public key
   - `-` to read key from standard input
   - `https://` URL to public key (unencrypted http is not accepted)
   - `ppa:OWNER/ARCHIVE` – adds a key of [Ubuntu PPA](https://help.ubuntu.com/community/PPA)
   - `packagecloud:OWNER/ARCHIVE` – adds a key of [packagecloud](https://packagecloud.io/) repository
   - If key name is an `--option`, it's just passed to gpg as an
     argument
 - `aptlier add_mirror NAME URL ...` is passed to `aptly mirror
   create`. It also supports special URL format `ppa:OWNER/ARCHIVE` or
   `packagecloud:OWNER/ARCHIVE`, which is expanded to full URL and its
   public key is automatically fetched.
 - `aptlier update [NAME [NAME [...]]]` update specified mirrors. If
   no mirrors are specified, all of them are updated

TODO
----
 - Support for merging & publishing repository
 - Configuration
   - publish endpoint/distro
   - autopublish toggle?
   - maybe config can specify aptly config / aptly dir / gnupg dir
     separate from the file?
 - Support for specifying repo location on command line or in
   environment instead of simply using current dir
 - Support archiving list of mirrors and their associated keys for
   easy recreation of a repository

Contributing
------------

Bug reports and pull requests are welcome on GitHub at
https://github.com/3ofcoins/aptlier. This project is intended to be a
safe, welcoming space for collaboration, and contributors are expected
to adhere to the [Contributor Covenant](http://contributor-covenant.org)
code of conduct.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Aptlier project’s codebases, issue
trackers, chat rooms and mailing lists is expected to follow the
[code of conduct](https://github.com/3ofcoins/aptlier/blob/master/CODE_OF_CONDUCT.md).

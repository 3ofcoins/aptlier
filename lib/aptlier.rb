# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'json'
require 'open3'
require 'open-uri'
require 'shellwords'
require 'tempfile'
require 'time'

require 'aptlier/version'

module Aptlier
  class NFY < RuntimeError; end

  class CLI
    DEFAULT_OPTIONS = {
      aptly_command: 'aptly',
      distributor: 'ubuntu',
      gpg_command: nil, # gpg1, fallback to gpg
      publish_name: 'main',
      release: 'xenial',
      snapshots_file: 'snapshots',
      verbose: true,
      work_dir: '.'
    }.freeze

    attr_reader :work_dir, :options

    def initialize(dir = '.', options = {})
      if dir.is_a?(Hash)
        options = dir
        dir = '.'
      end
      @work_dir = File.expand_path(dir)
      @options = DEFAULT_OPTIONS.merge(options)
    end

    def run(command, *args)
      case command
      when 'aptly'
        aptly(*args)
      when 'gpg'
        gpg(*args)
      when 'init'
        init_repo
      when 'add_key', 'add-key'
        add_key(*args)
      when 'list'
        list(*args)
      when 'add_mirror', 'add-mirror'
        name = args.shift
        case name
        when /^ppa:/
          url = "http://ppa.launchpad.net/#{$'}/#{options[:distributor]}"

          release = args.shift
          release = options[:release] if
            release.nil? || release == '' || release == '-'

          add_key name
          add_mirror name, url, release, 'main'
        when /^packagecloud:/
          url = "https://packagecloud.io/#{$'}/#{options[:distributor]}"

          release = args.shift
          release = options[:release] if
            release.nil? || release == '' || release == '-'

          add_key name
          add_mirror name, url, release, 'main'
        else
          add_mirror name, *args
        end
      when 'update', 'update_mirror', 'update-mirror'
        if args.empty?
          args = aptly_mirrors
                   .select { |mn| loaded_snapshots.key?(mn) }
                   .sort
        end
        args.each do |mn|
          update_mirror mn
        end
        # TODO: where does saving snapshots file go? also, publish
        save_snapshots
      when 'add_package', 'add-package', 'add'
        repo = args.shift
        aptly 'repo', 'add', repo, *args
        update_repo repo
        # TODO: where does saving snapshots file go? also, publish
        save_snapshots
      when 'publish'
        publish!
      when 'help', 'usage'
        usage
      else
        usage
        exit 1
      end
    end

    def usage
      puts <<EOF
Usage: #{$PROGRAM_NAME} [OPTIONS] COMMAND [ARGS...]

Options: TBD

Commands:
  Porcelain:
    init -- initialize repository
    add_key KEY [GPG OPTIONS...] -- add public key
    add_mirror NAME URL ...
    update[_mirror] [NAME [NAME ...]]
    add[_package] REPO FILE [FILE ...]
    list
    publish

  Plumbing:
    aptly ... -- run aptly
    gpg ... -- run gnupg

    help -- show this help message
EOF
    end

    def self.run(command = 'help', *args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      new('.', options).run(command, *args)
    end

    def list
      mirrors = aptly_mirrors
      repos = aptly_repos
      item_len = (mirrors + repos).map(&:length).max

      puts 'Mirrors:'
      mirrors.sort.each do |mirror|
        if (ts = loaded_snapshots[mirror])
          pad = ' ' * (item_len - mirror.length)
          puts " - #{mirror}#{pad}  #{ts}"
        else
          puts " - #{mirror}"
        end
      end

      puts 'Repos:'
      repos.sort.each do |repo|
        if (ts = loaded_snapshots[repo])
          pad = ' ' * (item_len - repo.length)
          puts " - #{repo}#{pad}  #{ts}"
        else
          puts " - #{repo}"
        end
      end
    end

    def init_repo
      gpg '--no-default-keyring', '--fingerprint'
      aptly 'db', 'cleanup'
    end

    def add_key(key, *args)
      case key
      when %r{^ppa:([-\w]+)/([-\w]+)$}
        # PPA
        fingerprint = ppa_fingerprint($1, $2)
        gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg',
            '--keyserver', 'hkp://keyserver.ubuntu.com',
            *args,
            '--recv-keys', fingerprint
      when %r{^packagecloud:([-\w]+/[-\w]+)$}
        # packagecloud repo
        Tempfile.create ['aptly-pubkey', '.asc'] do |keyfile|
          keyfile.write(URI.parse("https://packagecloud.io/#{$1}/gpgkey").read)
          keyfile.close
          gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', *args,
              '--import', keyfile.path
        end
      when %r{^https://}
        # Key URL
        Tempfile.create ['aptly-pubkey', '.asc'] do |keyfile|
          keyfile.write(URI.parse(key).read)
          keyfile.close
          gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', *args,
              '--import', keyfile.path
        end
      when %r{^http://}
        # HTTP URL, refuse to comply
        raise 'WTF, dude???'
      when /.@.+\../
        # email address / key id
        gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', *args,
            '--search-keys', key
      when /^-./
        # gnupg option, we assume it's raw gpg command line
        gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', key, *args
      when /^(0x)?[0-9a-fA-F]+$/
        # key id
        gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', *args,
            '--recv-keys', key
      else
        # filename or '-'
        gpg '--no-default-keyring', '--keyring', 'trustedkeys.gpg', *args,
            '--import', key
      end
    end

    def add_mirror(name, *args)
      aptly 'mirror', 'create', name, *args
      update_mirror name
      save_snapshots # FIXME: where should we be saving?
    end

    def update_mirror(name)
      aptly 'mirror', 'update', name
      update_snapshot(name, 'mirror')
    end

    def update_repo(name)
      update_snapshot(name, 'repo')
    end

    private

    def reset!
      @timestamp = nil
      @loaded_snapshots = nil
      @updated_snapshots = nil
    end

    def log(msg)
      warn(msg) if options[:verbose]
    end

    def timestamp
      @timestamp ||= Time.now.gmtime.strftime('%Y%m%d.%H%M')
    end

    def expand_path(path)
      File.expand_path(path, work_dir)
    end

    def updated_snapshots
      @updated_snapshots ||= {}
    end

    def loaded_snapshots
      @loaded_snapshots ||= load_snapshots
    end

    def loaded_snapshot(name)
      ts = loaded_snapshots[name]
      "#{name}@#{ts}" if ts
    end

    def snapshots
      loaded_snapshots.update(updated_snapshots)
    end

    def update_snapshot(name, kind)
      new_snapshot = "#{name}@#{timestamp}"

      aptly 'snapshot', 'create', new_snapshot, 'from', kind, name

      if (old_snapshot = loaded_snapshot(name))
        diff_out = capture2(
          *aptly_cmdline('snapshot', 'diff', old_snapshot, new_snapshot)
        )
        if diff_out == "Snapshots are identical.\n"
          puts 'No changes, undoing snapshot'
          aptly 'snapshot', 'drop', new_snapshot
          return nil
        end
        updated_snapshots[name] = timestamp
        puts diff_out # maybe we want to save it? commit something to git?
      else
        updated_snapshots[name] = timestamp
      end
      new_snapshot
    end

    def snapshots_path
      @snapshots_path ||= expand_path(options[:snapshots_file])
    end

    def load_snapshots
      snapshots = {}
      File.open(snapshots_path) do |f|
        f.each_line do |ln|
          base, timestamp = ln.strip.split('@', 2)
          snapshots[base] = timestamp
        end
      end
      snapshots
    rescue Errno::ENOENT
      # snapshots file does not exist
      {}
    end

    def save_snapshots
      if @updated_snapshots.nil? || @updated_snapshots.empty?
        log 'Snapshots not modified, not saving'
        return false
      end

      new_snapshots = snapshots
                        .map { |n, ts| "#{n}@#{ts}\n" }
                        .sort
                        .join

      log "Saving snapshots #{snapshots_path}, changed: #{@updated_snapshots}"
      snapshots_tmp = snapshots_path + '.tmp'
      snapshots_bak = snapshots_path + '~'
      File.write snapshots_tmp, new_snapshots
      File.unlink snapshots_bak if File.exist?(snapshots_bak)
      File.link snapshots_path, snapshots_bak if File.exist?(snapshots_path)
      File.rename snapshots_tmp, snapshots_path

      reset!

      true
    end

    def merge_snapshots!
      snapshot_name = "publish:#{options[:publish_name]}@#{timestamp}"
      aptly 'snapshot', 'merge', snapshot_name,
            *snapshots
               .map { |n, ts| "#{n}@#{ts}" }
               .sort
      snapshot_name
    end

    def publish!
      snapshot_name = merge_snapshots!
      if aptly_lines('publish', 'list', '-raw').include?(options[:publish_name])
        # TODO: compare snapshots
        aptly 'publish', 'switch',
              options[:release],
              options[:publish_name],
              snapshot_name
      else
        aptly 'publish', 'snapshot',
              "-distribution=#{options[:release]}",
              snapshot_name,
              options[:publish_name]
      end
    end

    def aptly_mirrors
      aptly_lines('mirror', 'list', '-raw')
    end

    def aptly_repos
      aptly_lines('repo', 'list', '-raw')
    end

    def ensure_dir(path, opts = {})
      path = expand_path(path)
      unless File.directory?(path)
        log "+ mkdir -p #{path.shellescape}" if options[:verbose]
        FileUtils.mkdir_p(path, opts)
      end
      path
    end

    def ensure_config(path, default_content)
      path = expand_path(path)
      unless File.exist?(path)
        log "> #{path.shellescape}" if options[:verbose]
        File.write(path, default_content)
      end
      path
    end

    def aptly_cmdline(*args)
      @aptly_home ||= ensure_dir('aptly')
      @aptly_conf ||= ensure_config('aptly.json', <<EOF)
{
    "rootDir": "#{@aptly_home}",
    "downloadConcurrency": 4,
    "downloadSpeedLimit": 0,
    "architectures": [],
    "dependencyFollowSuggests": false,
    "dependencyFollowRecommends": false,
    "dependencyFollowAllVariants": false,
    "dependencyFollowSource": false,
    "dependencyVerboseResolve": false,
    "gpgDisableSign": false,
    "gpgDisableVerify": false,
    "gpgProvider": "internal",
    "downloadSourcePackages": false,
    "skipLegacyPool": true,
    "ppaDistributorID": "ubuntu",
    "ppaCodename": "",
    "skipContentsPublishing": false,
    "FileSystemPublishEndpoints": {},
    "S3PublishEndpoints": {},
    "SwiftPublishEndpoints": {}
}
EOF
      [options[:aptly_command], "-config=#{@aptly_conf}", *args]
    end

    def aptly(*args)
      system(*aptly_cmdline(*args))
    end

    def aptly_out(*args)
      capture2(*aptly_cmdline(*args))
    end

    def aptly_lines(*args)
      aptly_out(*args).lines.map(&:strip)
    end

    def gpg_home
      @gpg_home ||= begin
                      gpg_home_path = ensure_dir('gnupg', mode: 0o700)
                      ensure_config(File.join(gpg_home_path, 'gpg.conf'), <<EOF)
keyring trustedkeys.gpg
keyid-format long
list-options show-keyring
with-fingerprint
always-trust
# with-subkey-fingerprint
EOF
                      gpg_home_path
                    end
    end

    def gpg_cmdline(*args)
      @gpg_command ||= options[:gpg_command] || which('gpg1') || which('gpg')
      [@gpg_command, *args]
    end

    def gpg(*args)
      system(*gpg_cmdline(*args))
    end

    def ppa_fingerprint(owner, archive)
      fp_url = "https://api.launchpad.net/1.0/~#{owner}/+archive/#{archive}/signing_key_fingerprint" # rubocop:disable Metrics/LineLength
      JSON[URI(fp_url).read]
    end

    def child_environment
      @child_environment ||= { 'GNUPGHOME' => gpg_home }
    end

    def capture2(*args)
      log "< #{args.shelljoin}" if options[:verbose]
      output, status = Open3.capture2(child_environment, *args)
      raise "FATAL: #{status} (#{args.join(' ')})" unless status.success?
      output
    end

    def system(*args)
      log "+ #{args.shelljoin}" if options[:verbose]
      Kernel.system(child_environment, *args) or
        raise "FATAL: #{$CHILD_STATUS} (#{args.join(' ')})"
    end

    # https://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby/5471032#5471032
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end
  end
end

# frozen_string_literal: true

require_relative './spec_helper'

module Aptlier
  describe CLI do
    describe 'Plumbing' do
      subject do
        cli = CLI.new
        class << cli
          attr_reader :ensured_dirs, :ensured_configs

          def ensure_dir(path, _options = {})
            path = File.expand_path(path, work_dir)
            @ensured_dirs ||= []
            @ensured_dirs << path
            path
          end

          def ensure_config(path, default_content)
            path = File.expand_path(path, work_dir)
            @ensured_configs ||= {}
            @ensured_configs[path] = default_content
            path
          end

          def log(msg)
            (@logs ||= []) << msg
          end
        end
        cli
      end

      specify '#child_environment creates gpg home' do
        env = subject.send(:child_environment)

        expected_gnupghome = File.expand_path('./gnupg')

        _(env).must_include 'GNUPGHOME'
        _(env['GNUPGHOME']).must_equal expected_gnupghome
        _(subject.ensured_dirs).must_include expected_gnupghome
      end

      specify '#aptly_cmdline creates aptly home and config' do
        subject.send(:aptly_cmdline)

        aptly_home_path = File.expand_path('./aptly')
        aptly_conf_path = File.expand_path('./aptly.json')

        _(subject.ensured_dirs).must_include aptly_home_path
        _(subject.ensured_configs).must_include aptly_conf_path

        aptly_conf = JSON[subject.ensured_configs[aptly_conf_path]]
        _(aptly_conf['rootDir']).must_equal aptly_home_path
        _(aptly_conf['gpgProvider']).must_equal 'internal'
      end

      specify 'child environment is passed to #capture2' do
        env = subject.send(:capture2, 'env')
        _(env.lines).must_include "GNUPGHOME=#{File.expand_path('./gnupg')}\n"
      end

      specify 'child environment is passed to #system' do
        # if test is true, it won't raise exception; no specific expectation here
        subject.send(:system, 'sh', '-c', "test \"x$GNUPGHOME\" = 'x#{File.expand_path('./gnupg')}'")
      end
    end

    describe '#ensure_dir' do
      it 'creates a directory if it does not exist' do
        given_path = 'test/path'
        expanded_path = File.expand_path(given_path)
        mkdir_p_trace = nil
        rv = nil
        cli = CLI.new

        File.stub :directory?, false do
          FileUtils.stub :mkdir_p, ->(path, _options = {}) { mkdir_p_trace = path } do
            rv = cli.send(:ensure_dir, given_path)
          end
        end

        _(mkdir_p_trace).must_equal expanded_path
        _(rv).must_equal expanded_path
      end
    end
  end
end

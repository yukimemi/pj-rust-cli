# Run with: ruby tests/release_workflow_test.rb [rendered-workflow]
require 'minitest/autorun'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ReleaseWorkflowTest < Minitest::Test
  HOOK = 'scripts/ci/release-post-build.sh'
  PIN = 'deploy/macos/signing-cert.sha1'
  PATH = ARGV.shift || File.expand_path('../.github/workflows/release.yml.template', __dir__)
  WORKFLOW = YAML.load_file(PATH)
  STEPS = WORKFLOW.fetch('jobs').fetch('build').fetch('steps')
  SIGN = 'Sign binaries (post-build hook)'
  VERIFY = 'Verify packaged signatures (post-build hook)'
  GUARD = 'Require post-build hook when a signing pin exists'
  SECRETS = %w[MACOS_SIGN_CERT_P12_BASE64 MACOS_SIGN_CERT_PASSWORD].freeze

  def step(name)
    STEPS.find { |s| s['name'] == name } || flunk("missing step: #{name}")
  end

  def test_order_and_conditions
    names = ['smoke', GUARD, SIGN, 'package (unix)', 'package (windows)', VERIFY]
    indices = names.map { |name| STEPS.index(step(name)) }
    assert_equal indices.sort, indices
    names.each { |name| refute step(name).fetch('continue-on-error', false) }
    refute WORKFLOW.fetch('jobs').fetch('build').fetch('continue-on-error', false)
    upload = STEPS.index { |s| s.fetch('uses', '').start_with?('actions/upload-artifact@') }
    assert_operator indices.last, :<, upload
    assert_equal "${{ hashFiles('#{PIN}') != '' && hashFiles('#{HOOK}') == '' }}", step(GUARD)['if']
    [SIGN, VERIFY].each do |name|
      assert_equal "${{ hashFiles('#{HOOK}') != '' }}", step(name)['if']
      assert_equal 'bash', step(name)['shell']
      assert_equal '${{ matrix.target }}', step(name).fetch('env').fetch('TARGET')
    end
    assert_equal "bash #{HOOK} sign", step(SIGN)['run']
    assert_equal "bash #{HOOK} verify-dist", step(VERIFY)['run']
    assert_equal "runner.os != 'Windows'", step('package (unix)')['if']
    assert_equal "runner.os == 'Windows'", step('package (windows)')['if']
    assert_equal 'pwsh', step('package (windows)')['shell']
    assert_includes step('package (windows)')['run'], 'Compress-Archive'
  end

  def test_secrets_are_scoped_to_sign
    SECRETS.each do |key|
      assert_equal "${{ secrets.#{key} }}", step(SIGN).fetch('env').fetch(key)
      assert_equal 1, File.read(PATH).scan("secrets.#{key}").size
      refute_includes WORKFLOW.fetch('env'), key
      WORKFLOW.fetch('jobs').each_value { |job| refute_includes job.fetch('env', {}), key }
      STEPS.reject { |s| s == step(SIGN) }.each { |s| refute_includes s.to_s, key }
    end
    assert_equal({ 'TARGET' => '${{ matrix.target }}' }, step(VERIFY)['env'])
  end

  # Exercise the actual hook/guard/package commands with a disposable consumer.
  # This models default success() gating, not the GitHub Actions runner itself.
  # Windows archive execution remains a runner-specific integration check.
  def run_consumer(pin:, hook:, fail_at: nil)
    Dir.mktmpdir('release-consumer-', File.dirname(__dir__)) do |dir|
      target = 'aarch64-apple-darwin'
      FileUtils.mkdir_p("#{dir}/target/#{target}/release")
      File.write("#{dir}/target/#{target}/release/demo", 'binary')
      if pin
        FileUtils.mkdir_p("#{dir}/deploy/macos")
        File.write("#{dir}/#{PIN}", 'pinned identity')
      end
      if hook
        FileUtils.mkdir_p("#{dir}/scripts/ci")
        File.write("#{dir}/#{HOOK}", <<~'SH')
          set -eu
          test "$TARGET" = aarch64-apple-darwin
          echo "$1" >> calls
          test "${FAIL_AT:-}" != "$1"
          case "$1" in
            sign)
              test "$MACOS_SIGN_CERT_P12_BASE64" = dummy
              test "$MACOS_SIGN_CERT_PASSWORD" = dummy
              printf signed >> "target/$TARGET/release/$BIN_NAME"
              ;;
            verify-dist)
              test "${MACOS_SIGN_CERT_P12_BASE64+x}" != x
              test "${MACOS_SIGN_CERT_PASSWORD+x}" != x
              test "$(tar xOzf "dist/$BIN_NAME-$TARGET.tar.gz")" = binarysigned
              ;;
            *) exit 1 ;;
          esac
        SH
      end
      executed = []
      succeeded = true
      [GUARD, SIGN, 'package (unix)', VERIFY].each do |name|
        next if name == GUARD && !(pin && !hook)
        next if [SIGN, VERIFY].include?(name) && !hook
        s = step(name)
        refute_includes s.fetch('if', ''), 'always()'
        env = SECRETS.to_h { |key| [key, name == SIGN ? 'dummy' : nil] }
        env.merge!('BIN_NAME' => 'demo', 'TARGET' => target, 'FAIL_AT' => fail_at)
        command = s.fetch('run').gsub('${{ matrix.target }}', target)
        executed << name
        output, status = Open3.capture2e(env, 'bash', '-e', '-o', 'pipefail', '-c', command, chdir: dir)
        unless status.success?
          succeeded = false
          break
        end
        flunk(output) if output.include?('::error::')
      end
      executed << 'upload' if succeeded
      yield executed
    end
  end

  def test_opt_in_and_failure_paths
    run_consumer(pin: false, hook: false) { |s| assert_equal ['package (unix)', 'upload'], s }
    run_consumer(pin: true, hook: false) { |s| assert_equal [GUARD], s }
    [false, true].each do |pin|
      run_consumer(pin: pin, hook: true) { |s| assert_equal [SIGN, 'package (unix)', VERIFY, 'upload'], s }
      run_consumer(pin: pin, hook: true, fail_at: 'sign') { |s| assert_equal [SIGN], s }
      run_consumer(pin: pin, hook: true, fail_at: 'verify-dist') { |s| assert_equal [SIGN, 'package (unix)', VERIFY], s }
    end
  end
end

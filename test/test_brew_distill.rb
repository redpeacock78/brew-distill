#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
require "tmpdir"

load File.expand_path("../homebrew-distill", __dir__)

def assert(condition, message)
  raise message unless condition
end

def assert_raises(error_class)
  yield
  raise "expected #{error_class}"
rescue error_class
  true
end

Dir.mktmpdir("brew-distill-test") do |dir|
  formula_data = {
    "formulae" => [
      {
        "name" => "bar",
        "versions" => { "stable" => "1.0" },
        "revision" => 0,
        "ruby_source_checksum" => { "sha256" => "b" * 64 },
        "bottle" => { "stable" => { "files" => { "all" => { "sha256" => "a" * 64 } } } },
        "dependencies" => []
      },
      {
        "name" => "foo",
        "versions" => { "stable" => "2.0" },
        "revision" => 1,
        "ruby_source_checksum" => { "sha256" => "f" * 64 },
        "dependencies" => ["bar"]
      }
    ]
  }
  formula_path = File.join(dir, "formulae.json")
  File.write(formula_path, JSON.generate(formula_data))

  provider = BrewDistill::FormulaProvider.new(data_path: formula_path)
  ordered = BrewDistill::Resolver.new(provider).resolve("foo")
  assert(ordered.map(&:name) == %w[bar foo], "dependency order is wrong")

  fingerprint = BrewDistill::Resolver.new(provider).dependency_fingerprint(provider.formula("foo"))
  expected = Digest::SHA256.hexdigest(
    '{"dependencies":[{"name":"bar","revision":0,"version":"1.0"}]}'
  )
  assert(fingerprint == expected, "dependency fingerprint is not canonical")

  bottle_path = File.join(dir, "foo.bottle.tar.gz")
  File.write(bottle_path, "test bottle")
  bottle_sha = Digest::SHA256.file(bottle_path).hexdigest
  platform = BrewDistill::Platform.new(
    "os" => "macos",
    "version" => "13",
    "arch" => "x86_64",
    "bottle_tag" => "ventura"
  )
  registry_path = File.join(dir, "registry.json")
  File.write(
    registry_path,
    JSON.pretty_generate(
      "schema" => 4,
      "bottles" => [
        {
          "formula" => provider.formula("foo").identity,
          "platform" => platform.data,
          "dependencies" => { "fingerprint" => fingerprint },
          "artifact" => { "path" => File.basename(bottle_path), "sha256" => bottle_sha }
        }
      ]
    )
  )
  registry = BrewDistill::Registry.new(registry_path)
  entry = registry.find(provider.formula("foo"), platform, dependency_fingerprint: fingerprint)
  assert(entry, "registry did not match formula identity")
  assert(registry.artifact_path(entry) == bottle_path, "registry artifact path is wrong")
  assert(BrewDistill::ArtifactVerifier.verify!(bottle_path, bottle_sha) == bottle_sha, "artifact verification failed")

  platform_path = File.join(dir, "platform.json")
  File.write(platform_path, JSON.generate(platform.data))
  toolchain_path = File.join(dir, "toolchain.json")
  File.write(toolchain_path, JSON.generate("clang_version" => "test clang"))
  manifest_path = File.join(dir, "foo.bottle.json")
  manifest_out = StringIO.new
  manifest_err = StringIO.new
  manifest_status = BrewDistill::CLI.new(
    ["manifest", "foo", "--artifact", bottle_path, "--output", manifest_path,
     "--formula-data", formula_path, "--platform-json", platform_path,
     "--toolchain-json", toolchain_path],
    out: manifest_out,
    err: manifest_err
  ).run
  assert(manifest_status == 0 && File.file?(manifest_path), "manifest generation failed")
  bad_toolchain_path = File.join(dir, "bad-toolchain.json")
  File.write(bad_toolchain_path, JSON.generate("clang_version" => "test clang", "fingerprint" => "0" * 64))
  assert_raises(BrewDistill::Error) { BrewDistill::Toolchain.from_file(bad_toolchain_path) }
  verify_out = StringIO.new
  verify_err = StringIO.new
  verify_status = BrewDistill::CLI.new(["verify", manifest_path], out: verify_out, err: verify_err).run
  assert(verify_status == 0 && verify_out.string.include?("verified"), "manifest CLI verification failed")
  bottle_json = File.join(dir, "homebrew-bottle.json")
  File.write(bottle_json, "metadata\n")
  bottle_json_sha = BrewDistill::ArtifactVerifier.sha256(bottle_json)
  bottle_verify_out = StringIO.new
  bottle_verify_status = BrewDistill::CLI.new(
    ["verify", bottle_json, "--sha256", bottle_json_sha], out: bottle_verify_out, err: StringIO.new
  ).run
  assert(bottle_verify_status == 0, "Bottle JSON was treated as a manifest")
  escaping_manifest_path = File.join(dir, "escaping.manifest.json")
  escaping_manifest = JSON.parse(File.read(manifest_path))
  escaping_manifest["artifact"]["path"] = "../outside.bottle.tar.gz"
  File.write(escaping_manifest_path, JSON.generate(escaping_manifest))
  escaping_status = BrewDistill::CLI.new(
    ["verify", escaping_manifest_path], out: StringIO.new, err: StringIO.new
  ).run
  assert(escaping_status != 0, "manifest verification allowed path traversal")

  plan_out = StringIO.new
  plan_err = StringIO.new
  plan_status = BrewDistill::CLI.new(
    ["foo", "--dry-run", "--json", "--formula-data", formula_path, "--registry", registry_path,
     "--platform-json", platform_path],
    out: plan_out,
    err: plan_err
  ).run
  plan = JSON.parse(plan_out.string)
  assert(plan_status == 0 && plan["items"].map { |item| item["name"] } == %w[bar foo], "shorthand plan failed")
  assert(plan["items"].first["source"] == "official", "official bottle was not selected")
  assert(plan["items"].last["source"] == "distill", "registry bottle was not selected")

  request_out = StringIO.new
  request_status = BrewDistill::CLI.new(
    ["request", "foo", "--formula-data", formula_path, "--platform-json", platform_path],
    out: request_out, err: StringIO.new
  ).run
  request = JSON.parse(request_out.string)
  assert(request_status == 0 && request["status"] == "requested" && request["formula"]["name"] == "foo", "request command failed")

  brew_log = File.join(dir, "brew.log")
  brew_out = StringIO.new
  brew_err = StringIO.new
  state_path = File.join(dir, "state.json")
  ENV["BREW_LOG"] = brew_log
  install_status = BrewDistill::CLI.new(
    ["install", "foo", "--formula-data", formula_path, "--registry", registry_path,
     "--platform-json", platform_path, "--bottle-dir", dir, "--brew", File.expand_path("fake-brew", __dir__),
     "--state", state_path],
    out: brew_out,
    err: brew_err
  ).run
  assert(install_status == 0, "local Bottle install failed: #{brew_err.string}")
  assert(File.read(brew_log).lines.map(&:strip).grep(/install --formula/).length == 2, "install was not sequential")
  saved_state = JSON.parse(File.read(state_path))
  assert(saved_state["formulae"].keys.sort == %w[bar foo], "installed state was not recorded")
  pin_status = BrewDistill::CLI.new(
    ["protect", "foo", "--brew", File.expand_path("fake-brew", __dir__)], out: StringIO.new, err: StringIO.new
  ).run
  unpin_status = BrewDistill::CLI.new(
    ["unprotect", "foo", "--brew", File.expand_path("fake-brew", __dir__)], out: StringIO.new, err: StringIO.new
  ).run
  assert(pin_status == 0 && unpin_status == 0, "protect commands failed")
  assert(File.read(brew_log).lines.map(&:strip).grep(/pin foo/).any?, "protect was not delegated to Homebrew")

  remote_registry_path = File.join(dir, "remote-registry.json")
  remote_registry = JSON.parse(File.read(registry_path))
  remote_sha = Digest::SHA256.hexdigest("prefetched artifact\n")
  remote_registry["bottles"][0]["artifact"] = {
    "url" => "https://artifacts.example.invalid/foo.bottle.tar.gz",
    "sha256" => remote_sha
  }
  File.write(remote_registry_path, JSON.generate(remote_registry))
  ENV["DISTILL_CURL"] = File.expand_path("fake-curl", __dir__)
  remote_status = BrewDistill::CLI.new(
    ["install", "foo", "--formula-data", formula_path, "--registry", remote_registry_path,
     "--platform-json", platform_path, "--bottle-dir", dir, "--brew", File.expand_path("fake-brew", __dir__),
     "--state", File.join(dir, "remote-state.json")],
    out: StringIO.new, err: StringIO.new
  ).run
  ENV.delete("DISTILL_CURL")
  assert(remote_status == 0, "verified remote Bottle install failed")

  state_fixture = {
    "schema" => 1,
    "formulae" => {
      "foo" => provider.formula("foo").identity,
      "missing" => provider.formula("bar").identity,
      "drifted" => provider.formula("bar").identity
    }
  }
  state_fixture_path = File.join(dir, "state-fixture.json")
  File.write(state_fixture_path, JSON.generate(state_fixture))
  statuses = BrewDistill::StateStore.new(state_fixture_path).statuses(
    "foo" => "2.0",
    "drifted" => "9.0",
    "external" => "1.0"
  )
  assert(statuses == { "drifted" => "drifted", "external" => "external", "foo" => "managed", "missing" => "missing" }, "state reconciliation is wrong")
  reconciled_state = BrewDistill::StateStore.new(state_fixture_path)
  reconciled, changed = reconciled_state.reconcile!("foo" => "2.0")
  assert(changed && reconciled["missing"] == "missing" && !reconciled_state.statuses("foo" => "2.0").key?("missing"), "missing state was not cleaned up")

  cas_dir = File.join(dir, "cas")
  referenced_sha = "a" * 64
  unused_sha = "c" * 64
  [referenced_sha, unused_sha].each do |sha|
    object_dir = File.join(cas_dir, "sha256", sha[0, 2], sha[2, 2])
    FileUtils.mkdir_p(object_dir)
    File.write(File.join(object_dir, sha), sha)
  end
  mapping_path = File.join(cas_dir, "urls.json")
  File.write(mapping_path, JSON.generate("https://example" => { "sha256" => referenced_sha }))
  gc_out = StringIO.new
  assert(BrewDistill::CLI.new(["gc", "--cas", cas_dir, "--mapping", mapping_path, "--json"], out: gc_out, err: StringIO.new).run == 0, "GC report failed")
  assert(JSON.parse(gc_out.string)["candidates"].length == 1, "GC did not find an unreferenced object")
  assert(BrewDistill::CLI.new(["gc", "--cas", cas_dir, "--mapping", mapping_path, "--apply"], out: StringIO.new, err: StringIO.new).run == 0, "GC apply failed")
  assert(File.file?(File.join(cas_dir, "sha256", "aa", "aa", referenced_sha)), "GC removed a referenced object")
  assert(!File.exist?(File.join(cas_dir, "sha256", "cc", "cc", unused_sha)), "GC kept an unreferenced object")

  mismatched_registry_path = File.join(dir, "mismatched-registry.json")
  mismatched = JSON.parse(File.read(registry_path))
  mismatched["bottles"][0]["dependencies"]["fingerprint"] = "0" * 64
  File.write(mismatched_registry_path, JSON.generate(mismatched))
  assert_raises(BrewDistill::Error) do
    BrewDistill::Registry.new(mismatched_registry_path).find(
      provider.formula("foo"),
      platform,
      dependency_fingerprint: fingerprint
    )
  end

  cycle_data = {
    "formulae" => [
      formula_data["formulae"][0].merge("name" => "a", "dependencies" => ["b"]),
      formula_data["formulae"][0].merge("name" => "b", "dependencies" => ["a"])
    ]
  }
  cycle_path = File.join(dir, "cycle.json")
  File.write(cycle_path, JSON.generate(cycle_data))
  cycle_provider = BrewDistill::FormulaProvider.new(data_path: cycle_path)
  assert_raises(BrewDistill::Error) { BrewDistill::Resolver.new(cycle_provider).resolve("a") }

  assert_raises(BrewDistill::Error) do
    BrewDistill::ArtifactVerifier.verify!(bottle_path, "0" * 64)
  end
end

puts "ok"

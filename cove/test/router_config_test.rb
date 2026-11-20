# The seam's own tests. They boot the real application (not a mock of it), point it
# at a throwaway state directory, and then try to break the three properties the
# router file is supposed to have: total, pure, honest.
require "minitest/autorun"
require "tmpdir"
require "fileutils"

ENV["RAILS_ENV"] ||= "development"
require_relative "../config/environment"

class RouterConfigTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("cove-test-")
    Cove.state_dir = @tmp
    FileUtils.mkdir_p(Cove.agents_dir)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_sheet(attrs)
    Sheet.create!(attrs)
  end

  def write_services(rows)
    Cove.write_atomic(Cove.services_file, YAML.dump({ "services" => rows }))
  end

  def test_render_is_pure
    write_services([{ "name" => "forgejo", "address" => "10.88.0.3:3000" }])
    write_sheet("name" => "alpha", "services" => ["forgejo"])
    write_sheet("name" => "beta")
    first = RouterConfig.render(Sheet.all, ServiceBook.all)
    second = RouterConfig.render(Sheet.all, ServiceBook.all)
    assert_equal first, second, "identical intent must render identical bytes"
    refute_includes first, "rendered at", "no timestamps in the seam"
  end

  def test_render_is_total_and_survives_mutation_of_the_file
    write_services([{ "name" => "forgejo", "address" => "10.88.0.3:3000" }])
    write_sheet("name" => "alpha", "services" => %w[forgejo])
    RouterConfig.write!
    original = File.read(Cove.router_file)
    assert_includes original, %(agent "alpha")
    assert_includes original, %(allow "alpha" "forgejo")

    # Mutate the artefact, not the source, then make a change elsewhere. The whole
    # file must come back: this is what "the file is a projection" means.
    File.write(Cove.router_file, "# gutted\n")
    write_sheet("name" => "beta")
    RouterConfig.write!
    rewritten = File.read(Cove.router_file)
    assert_includes rewritten, %(agent "alpha")
    assert_includes rewritten, %(allow "alpha" "forgejo"), "a line deleted by hand must come back"
    assert_includes rewritten, %(agent "beta")
  end

  def test_unknown_service_is_unresolved_never_invented
    write_services([{ "name" => "forgejo", "address" => "10.88.0.3:3000" }])
    write_sheet("name" => "alpha", "services" => %w[forgejo ghost])
    body = RouterConfig.render(Sheet.all, ServiceBook.all)
    assert_includes body, %(unresolved "alpha" "ghost")
    refute_includes body, %(service "ghost"), "the Manager must not invent an address"
    refute_includes body, %(allow "alpha" "ghost"), "an unresolvable permit is not a permit"
  end

  def test_atomic_write_leaves_no_temp_files_and_valid_content
    write_services([])
    write_sheet("name" => "alpha")
    RouterConfig.write!
    leftovers = Dir.glob(Cove.state_dir.join("**/.*.tmp").to_s)
    assert_empty leftovers, "temp files must not survive a write"
    assert_includes File.read(Cove.router_file), %(agent "alpha")
  end

  def test_sheet_preserves_unknown_keys
    path = Cove.agents_dir.join("alpha.yml")
    Cove.write_atomic(path, "name: alpha\nfuture_field: keep me\n")
    sheet = Sheet.load(path)
    assert_equal "keep me", sheet.data["future_field"]
    sheet.assign("name" => "alpha2")
    sheet.save!
    assert_equal "keep me", YAML.safe_load(File.read(path))["future_field"],
                 "law 2: a writer that rebuilds from a fixed field list deletes what it doesn't know"
  end

  def test_slug_is_stable_across_rename
    sheet = write_sheet("name" => "Old Name")
    assert_equal "old-name", sheet.slug
    sheet.assign("name" => "A Totally Different Name")
    sheet.save!
    assert_equal "old-name", sheet.slug, "renaming must not orphan the pod or move the file"
    assert File.exist?(Cove.agents_dir.join("old-name.yml"))
  end
end

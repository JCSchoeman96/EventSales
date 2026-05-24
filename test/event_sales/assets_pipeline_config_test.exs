defmodule EventSales.AssetsPipelineConfigTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Contract tests for the Tailwind v4 + esbuild pipeline configuration.
  These tests assert on source text so the pipeline is verifiable without
  running the asset build tools.
  """

  @mix_exs File.read!("mix.exs")
  @config_exs File.read!("config/config.exs")
  @dev_exs File.read!("config/dev.exs")

  describe "mix.exs deps" do
    test "declares tailwind dep" do
      assert @mix_exs =~ ~s|{:tailwind, "~> 0.3", runtime: Mix.env() == :dev}|
    end

    test "declares esbuild dep" do
      assert @mix_exs =~ ~s|{:esbuild, "~> 0.9", runtime: Mix.env() == :dev}|
    end
  end

  describe "mix.exs aliases" do
    test "assets.build alias" do
      assert @mix_exs =~ ~s|"assets.build": ["tailwind event_sales", "esbuild event_sales"]|
    end

    test "assets.deploy alias contains minify and digest" do
      assert @mix_exs =~ ~s|"tailwind event_sales --minify"|
      assert @mix_exs =~ ~s|"esbuild event_sales --minify"|
      assert @mix_exs =~ ~s|"phx.digest"|
    end

    test "setup alias includes assets.build" do
      assert @mix_exs =~ ~s|setup: ["deps.get", "ecto.setup", "assets.build"]|
    end
  end

  describe "config/config.exs" do
    test "tailwind event_sales config present" do
      assert @config_exs =~ ~s|config :tailwind|
      assert @config_exs =~ ~s|event_sales:|
      assert @config_exs =~ ~s|--input=assets/css/app.css|
      assert @config_exs =~ ~s|--output=priv/static/assets/app.css|
    end

    test "esbuild event_sales config present" do
      assert @config_exs =~ ~s|config :esbuild|
      assert @config_exs =~ ~s|assets/js/app.js|
      assert @config_exs =~ ~s|--outfile=priv/static/assets/app.js|
    end

    test "esbuild NODE_PATH configured for Hex deps as an OS string" do
      assert @config_exs =~ ~s|NODE_PATH|
      assert @config_exs =~ ~s|Enum.join(if(match?({:win32, _}, :os.type()), do: ";", else: ":"))|
    end
  end

  describe "config/dev.exs" do
    test "tailwind watcher present" do
      assert @dev_exs =~ ~s|tailwind: {Tailwind, :install_and_run, [:event_sales|
    end

    test "esbuild watcher present" do
      assert @dev_exs =~ ~s|esbuild: {Esbuild, :install_and_run, [:event_sales|
    end

    test "old stub tailwind version line removed" do
      refute @dev_exs =~ ~s|config :tailwind, version:|
    end
  end

  describe "file system" do
    test "tailwind.config.js deleted" do
      refute File.exists?("assets/tailwind.config.js")
    end

    test ".gitignore ignores generated assets" do
      gitignore = File.read!(".gitignore")
      assert gitignore =~ ~r|/priv/static/assets/|
    end

    test "daisyui.mjs vendored" do
      assert File.exists?("assets/vendor/daisyui.mjs")
    end

    test "daisyui-theme.mjs is optional and not referenced by app.css" do
      app_css = File.read!("assets/css/app.css")
      refute app_css =~ "daisyui-theme.mjs"
    end

    test "topbar.js vendored" do
      assert File.exists?("assets/vendor/topbar.js")
    end
  end
end

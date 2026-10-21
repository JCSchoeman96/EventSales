defmodule EventSales.ReleaseEnvContractTest do
  use ExUnit.Case, async: true

  @env_template_path Path.expand("../../rel/env.sh.eex", __DIR__)

  test "server start and daemon commands configure node identity and listener" do
    for release_command <- ["start", "start_iex", "daemon", "daemon_iex"] do
      {output, status} =
        System.cmd(
          "sh",
          [
            "-c",
            "unset RELEASE_DISTRIBUTION RELEASE_NODE ERL_EPMD_ADDRESS ELIXIR_ERL_OPTIONS; . \"$1\"; printf 'D=%s\\nN=%s\\nE=%s\\nO=%s\\n' \"$RELEASE_DISTRIBUTION\" \"$RELEASE_NODE\" \"$ERL_EPMD_ADDRESS\" \"$ELIXIR_ERL_OPTIONS\"",
            "sh",
            @env_template_path
          ],
          env: [
            {"EVENTSALES_NODE_IP", "10.250.0.10"},
            {"RELEASE_COOKIE", "release-cookie-test-only"},
            {"RELEASE_COMMAND", release_command}
          ],
          stderr_to_stdout: true
        )

      assert status == 0
      assert output =~ "D=name\n"
      assert output =~ "N=event_sales@10.250.0.10\n"
      assert output =~ "E=10.250.0.10\n"
      assert output =~ "-kernel inet_dist_use_interface {10,250,0,10}"
      refute output =~ "release-cookie-test-only"
    end
  end

  test "start appends the listener option without replacing existing VM options" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ". \"$1\"; printf '%s\\n' \"$ELIXIR_ERL_OPTIONS\"",
          "sh",
          @env_template_path
        ],
        env: [
          {"EVENTSALES_NODE_IP", "10.250.0.10"},
          {"RELEASE_COOKIE", "release-cookie-test-only"},
          {"RELEASE_COMMAND", "start"},
          {"ELIXIR_ERL_OPTIONS", "-heart"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "-heart"
    assert output =~ "-kernel inet_dist_use_interface {10,250,0,10}"
    refute output =~ "release-cookie-test-only"
  end

  test "rpc keeps the node identity but does not add a listener option" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ". \"$1\"; printf '%s\\n%s\\n%s\\n%s\\n' \"$RELEASE_DISTRIBUTION\" \"$RELEASE_NODE\" \"$ERL_EPMD_ADDRESS\" \"${ELIXIR_ERL_OPTIONS:-}\"",
          "sh",
          @env_template_path
        ],
        env: [
          {"EVENTSALES_NODE_IP", "10.250.0.10"},
          {"RELEASE_COOKIE", "release-cookie-test-only"},
          {"RELEASE_COMMAND", "rpc"},
          {"ELIXIR_ERL_OPTIONS", ""}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "name\nevent_sales@10.250.0.10\n10.250.0.10\n"
    refute output =~ "inet_dist_use_interface"
    refute output =~ "release-cookie-test-only"
  end

  test "without a node IP the template does not force VPS distribution settings" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "unset EVENTSALES_NODE_IP; . \"$1\"; printf '%s\\n%s\\n%s\\n%s\\n' \"$RELEASE_DISTRIBUTION\" \"$RELEASE_NODE\" \"$ERL_EPMD_ADDRESS\" \"$ELIXIR_ERL_OPTIONS\"",
          "sh",
          @env_template_path
        ],
        env: [
          {"RELEASE_DISTRIBUTION", "existing-distribution"},
          {"RELEASE_NODE", "existing-node"},
          {"ERL_EPMD_ADDRESS", "existing-epmd-address"},
          {"ELIXIR_ERL_OPTIONS", "existing-vm-options"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0

    assert output ==
             "existing-distribution\nexisting-node\nexisting-epmd-address\nexisting-vm-options\n"
  end

  test "a node IP without an external release cookie fails safely" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "unset RELEASE_COOKIE; . \"$1\"; printf reached-after-template",
          "sh",
          @env_template_path
        ],
        env: [{"EVENTSALES_NODE_IP", "10.250.0.10"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "RELEASE_COOKIE"
    refute output =~ "release-cookie-test-only"
    refute output =~ "reached-after-template"
  end

  test "invalid IPv4 node addresses fail closed" do
    for invalid_ip <- [
          "10.250.0",
          "10.250.0.10.20",
          "10.250.x.10",
          "10.250.300.10",
          "10..0.10",
          "-1.250.0.10"
        ] do
      {output, status} =
        System.cmd(
          "sh",
          [
            "-c",
            ". \"$1\"; printf reached-after-template",
            "sh",
            @env_template_path
          ],
          env: [
            {"EVENTSALES_NODE_IP", invalid_ip},
            {"RELEASE_COOKIE", "release-cookie-test-only"},
            {"RELEASE_COMMAND", "start"}
          ],
          stderr_to_stdout: true
        )

      assert status != 0, "expected #{inspect(invalid_ip)} to fail"
      assert output =~ "EVENTSALES_NODE_IP"
      refute output =~ "reached-after-template"
      refute output =~ "release-cookie-test-only"
    end
  end
end

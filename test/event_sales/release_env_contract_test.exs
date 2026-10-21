defmodule EventSales.ReleaseEnvContractTest do
  use ExUnit.Case, async: true

  @env_template_path Path.expand("../../rel/env.sh.eex", __DIR__)

  test "a configured node IP uses long names and the stable application basename" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "unset RELEASE_DISTRIBUTION RELEASE_NODE; . \"$1\"; printf '%s\\n%s\\n' \"$RELEASE_DISTRIBUTION\" \"$RELEASE_NODE\"",
          "sh",
          @env_template_path
        ],
        env: [
          {"EVENTSALES_NODE_IP", "10.250.0.10"},
          {"RELEASE_COOKIE", "release-cookie-test-only"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output == "name\nevent_sales@10.250.0.10\n"
    refute output =~ "release-cookie-test-only"
  end

  test "without a node IP the template does not force VPS distribution settings" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "unset EVENTSALES_NODE_IP; . \"$1\"; printf '%s\\n%s\\n' \"$RELEASE_DISTRIBUTION\" \"$RELEASE_NODE\"",
          "sh",
          @env_template_path
        ],
        env: [
          {"RELEASE_DISTRIBUTION", "existing-distribution"},
          {"RELEASE_NODE", "existing-node"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output == "existing-distribution\nexisting-node\n"
  end

  test "a node IP without an external release cookie fails safely" do
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ". \"$1\"; printf reached-after-template",
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
end
